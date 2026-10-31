import AVFoundation
import CoreMedia
import Speech

final class SystemAudioCapture: NSObject, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.mywizard.system-audio")
    private let timeline: CaptureTimeline
    @MainActor private var tap: (any SystemAudioTapControlling)?
    @MainActor private let makeTap: @MainActor () -> any SystemAudioTapControlling
    @MainActor private var tapGeneration: UUID?
    private var converter: AudioConverter?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var onLevel: (@Sendable (Double) -> Void)?
    private var onError: (@Sendable (String) -> Void)?
    private var onDeviceChange: (@Sendable (String) -> Void)?
    private var speakerInput: AsyncStream<[Float]>.Continuation?
    private var speakerConverter: AudioConverter?
    private var speakerSamples: [Float] = []
    private var onSpeakerError: (@Sendable (String) -> Void)?
    private var systemClock = AnalyzerSampleClock(sampleRate: 16_000)
    private var meterFrames = 0
    private var meterPeak: Double = 0
    private var recording: MeetingRecording?

    @MainActor
    init(timeline: CaptureTimeline, makeTap: (@MainActor () -> any SystemAudioTapControlling)? = nil) {
        self.timeline = timeline
        self.makeTap = makeTap ?? { SystemAudioTap() }
        super.init()
    }

    @MainActor var frameCount: Int64 { queue.sync { systemClock.frames } }

    @MainActor
    func start(format: AVAudioFormat, continuation: AsyncStream<AnalyzerInput>.Continuation,
               speakerInput: AsyncStream<[Float]>.Continuation? = nil,
               recording: MeetingRecording? = nil,
               onSpeakerError: @escaping @Sendable (String) -> Void = { _ in },
               onDeviceChange: (@Sendable (String) -> Void)? = nil,
               onLevel: @escaping @Sendable (Double) -> Void,
               onError: @escaping @Sendable (String) -> Void) async throws {
        queue.sync {
            self.converter = AudioConverter(outputFormat: format)
            self.recording = recording
            self.input = continuation
            self.onLevel = onLevel
            self.onError = onError
            self.onDeviceChange = onDeviceChange
            self.speakerInput = speakerInput
            self.onSpeakerError = onSpeakerError
            self.speakerConverter = speakerInput == nil ? nil : AudioConverter(
                outputFormat: AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!)
            self.speakerSamples = []
            self.systemClock = AnalyzerSampleClock(sampleRate: CMTimeScale(format.sampleRate))
            self.meterFrames = 0
            self.meterPeak = 0
        }
        do { try resume() }
        catch { await stop(); throw error }
    }

    @MainActor
    func pause() {
        tapGeneration = nil
        tap?.stop(queue: queue)
        tap = nil
        queue.sync {} // Drain callbacks before reporting that capture is paused.
    }

    @MainActor
    func resume() throws {
        guard tap == nil else { return }
        let callbacks = queue.sync { (onError, onDeviceChange) }
        guard let onError = callbacks.0 else { throw TranscriptionError.message("No active audio session to resume.") }
        timeline.beginSystemSegment()
        let tap = makeTap()
        let generation = UUID()
        tapGeneration = generation
        self.tap = tap
        do {
            try tap.start(queue: queue, receive: { [weak self] pcm, time in
                self?.receive(pcm, presentationTime: time)
            }, onError: { [weak self] message in
                Task { @MainActor in
                    guard self?.tapGeneration == generation else { return }
                    onError(message)
                }
            }, onDeviceChange: { [weak self] message in
                Task { @MainActor in
                    guard self?.tapGeneration == generation else { return }
                    (callbacks.1 ?? onError)(message)
                }
            })
        } catch {
            pause()
            throw error
        }
    }

    @MainActor
    func setOriginalAudioMuted(_ muted: Bool) throws {
        try tap?.setMuted(muted)
        queue.sync { recording?.systemMuted(muted) }
    }

    @MainActor
    func stop() async {
        pause()
        queue.sync {
            if !self.speakerSamples.isEmpty {
                if case .dropped = self.speakerInput?.yield(self.speakerSamples) {
                    self.onSpeakerError?("Live speaker identification fell behind. Uncertain speakers will remain unknown in the export.")
                }
            }
            self.speakerInput?.finish()
            self.speakerInput = nil
            self.speakerConverter = nil
            self.speakerSamples = []
            self.onSpeakerError = nil
            self.input = nil
            self.converter = nil
            self.onLevel = nil
            self.onError = nil
            self.onDeviceChange = nil
            self.recording = nil
        }
    }

    private func receive(_ pcm: AVAudioPCMBuffer, presentationTime: Double) {
        guard pcm.frameLength > 0, let converter, let input else { return }
        do {
            meterFrames += Int(pcm.frameLength)
            meterPeak = max(meterPeak, AudioConverter.level(pcm))
            if meterFrames >= Int(pcm.format.sampleRate / 5) {
                onLevel?(meterPeak)
                meterFrames = 0
                meterPeak = 0
            }
            let converted = try converter.convert(pcm)
            try recording?.append(converted, track: .system, time: presentationTime)
            if converted.frameLength > 0 {
                _ = timeline.startOffset(for: .systemAudio, presentationTime: presentationTime)
                let time = systemClock.next(frameCount: converted.frameLength)
                timeline.recordSystemBuffer(sampleTime: time.seconds, presentationTime: presentationTime)
                if case .dropped = input.yield(AnalyzerInput(buffer: converted, bufferStartTime: time)) {
                    throw TranscriptionError.message("Transcription cannot keep up with the audio. Restart listening.")
                }
            }
            if let speakerConverter, let speakerInput {
                let mono = try speakerConverter.convert(pcm)
                if let channel = mono.floatChannelData?[0] {
                    speakerSamples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(mono.frameLength)))
                }
                if speakerSamples.count >= 8_000 {
                    switch speakerInput.yield(speakerSamples) {
                    case .dropped:
                        // Never drop a timed chunk and then continue: that
                        // shifts all following speaker labels. Disable only
                        // this optional live path, not recognition/recording.
                        self.speakerInput?.finish()
                        self.speakerInput = nil
                        self.speakerConverter = nil
                        self.onSpeakerError?("Live speaker identification fell behind. Recording continues; uncertain speakers will remain unknown in the export.")
                    case .terminated:
                        self.speakerInput = nil
                        self.speakerConverter = nil
                    case .enqueued: break
                    @unknown default: break
                    }
                    speakerSamples.removeAll(keepingCapacity: true)
                }
            }
        } catch {
            self.input = nil
            onError?(error.localizedDescription)
        }
    }

}

import AVFoundation
import CoreMedia
import Speech

// Dedicated microphone pipeline. It owns its audio engine, conversion queue,
// sample clock and Speech analyzer input. No system-audio PCM buffer can enter
// this component; the shared timeline carries timestamps only.
final class MicrophoneCapture: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.mywizard.microphone-audio")
    private let timeline: CaptureTimeline
    @MainActor private var engine: AVAudioEngine?
    @MainActor private var silentOutput: AVAudioSourceNode?
    @MainActor private(set) var echoCancellationActive = false
    private var converter: AudioConverter?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var clock = AnalyzerSampleClock(sampleRate: 16_000)
    private var onError: (@Sendable (String) -> Void)?
    private var recording: MeetingRecording?

    init(timeline: CaptureTimeline) {
        self.timeline = timeline
    }

    @MainActor var frameCount: Int64 { queue.sync { clock.frames } }

    @MainActor
    func start(format analyzerFormat: AVAudioFormat,
               continuation: AsyncStream<AnalyzerInput>.Continuation? = nil,
               cancelsEcho: Bool = false,
               recording: MeetingRecording? = nil,
               onError: @escaping @Sendable (String) -> Void) async throws {
        let engine = AVAudioEngine()
        let node = engine.inputNode
        if cancelsEcho {
            // The two transcript tracks cannot remove acoustic leakage. Process
            // it here, before recognition. VoiceProcessingIO requires a running
            // output graph, but the microphone must NEVER be routed to output.
            do {
                try node.setVoiceProcessingEnabled(true)
                guard node.isVoiceProcessingEnabled else {
                    throw TranscriptionError.message("Voice processing did not activate.")
                }
            } catch {
                throw TranscriptionError.message("Microphone echo cancellation is unavailable: \(error.localizedDescription) Use headphones and turn off Microphone echo cancellation in Preferences to use raw capture.")
            }
            node.isVoiceProcessingBypassed = false
            node.isVoiceProcessingAGCEnabled = false
            node.voiceProcessingOtherAudioDuckingConfiguration = .init(
                enableAdvancedDucking: false, duckingLevel: .min)
            let output = AVAudioSourceNode { @Sendable isSilence, _, _, buffers in
                isSilence.pointee = true
                for buffer in UnsafeMutableAudioBufferListPointer(buffers) {
                    if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
                }
                return noErr
            }
            engine.attach(output)
            engine.connect(output, to: engine.outputNode, format: node.outputFormat(forBus: 0))
            silentOutput = output
        }
        // Enabling voice processing changes device formats. Query afterwards.
        let microphoneFormat = node.outputFormat(forBus: 0)
        guard microphoneFormat.sampleRate > 0, microphoneFormat.channelCount > 0 else {
            throw TranscriptionError.message("No microphone input is available. Check the input device in System Settings > Sound.")
        }

        queue.sync {
            // Use the first capture channel only; never downmix aggregate or
            // output-reference channels into microphone recognition.
            converter = AudioConverter(outputFormat: analyzerFormat, inputChannel: 0)
            input = continuation
            clock = AnalyzerSampleClock(sampleRate: CMTimeScale(analyzerFormat.sampleRate))
            self.onError = onError
            self.recording = recording
        }

        node.installTap(onBus: 0, bufferSize: 1024, format: microphoneFormat) { @Sendable [weak self] buffer, time in
            guard let self else { return }
            let presentationTime = AVAudioTime.seconds(forHostTime: time.hostTime)
            self.queue.sync { self.receive(buffer, presentationTime: presentationTime) }
        }
        self.engine = engine
        engine.prepare()
        do {
            try engine.start()
            echoCancellationActive = cancelsEcho && node.isVoiceProcessingEnabled && !node.isVoiceProcessingBypassed
            // Starting the engine does not guarantee that the device has
            // delivered data. Fail early instead of creating a silent track.
            for _ in 0..<60 {
                if queue.sync(execute: { clock.frames > 0 }) { return }
                try await Task.sleep(for: .milliseconds(50))
            }
            throw TranscriptionError.message("The microphone did not start delivering audio. Check the input device in System Settings > Sound, then try again.")
        } catch {
            await stop()
            throw error
        }
    }

    @MainActor
    func stop() async {
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        silentOutput = nil
        echoCancellationActive = false
        queue.sync {
            input = nil
            converter = nil
            onError = nil
            recording = nil
        }
    }

    private func receive(_ buffer: AVAudioPCMBuffer, presentationTime: Double) {
        guard buffer.frameLength > 0, let converter else { return }
        do {
            // The tap buffer is borrowed. Copy it before the callback returns.
            let pcm = try AudioConverter.copyPCM(buffer)
            let converted = try converter.convert(pcm)
            guard converted.frameLength > 0 else { return }
            _ = timeline.startOffset(for: .microphone, presentationTime: presentationTime)
            let time = clock.next(frameCount: converted.frameLength)
            try recording?.append(converted, track: .microphone, time: presentationTime)
            if case .dropped = input?.yield(AnalyzerInput(buffer: converted, bufferStartTime: time)) {
                throw TranscriptionError.message("Microphone transcription cannot keep up. Restart listening.")
            }
        } catch {
            self.input = nil
            self.converter = nil
            onError?(error.localizedDescription)
        }
    }
}

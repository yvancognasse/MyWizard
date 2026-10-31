import AVFoundation
import Speech

// Explicit opt-in hardware diagnostic. Plays an existing synthetic fixture via
// afplay and retains only energy/count measurements, never microphone recordings.
enum MicrophoneEchoCheck {
    @MainActor static func run() async throws {
        guard let fixture = ProcessInfo.processInfo.environment["MYWIZARD_ECHO_FIXTURE"],
              FileManager.default.fileExists(atPath: fixture) else {
            throw TranscriptionError.message("Set MYWIZARD_ECHO_FIXTURE to a synthetic speech file.")
        }
        guard await MicrophoneAuthorization.request() else {
            throw TranscriptionError.message("Microphone permission is required for the echo check.")
        }
        let raw = try await measure(fixture: fixture, cancelsEcho: false)
        let processed = try await measure(fixture: fixture, cancelsEcho: true)
        guard raw.rms > 0.0001, raw.otherFrames > 0, raw.otherRMS > 0.0001, processed.frames > 0 else {
            throw TranscriptionError.message("Echo check inconclusive: no usable microphone reference.")
        }
        let reduction = 20 * log10(raw.rms / max(processed.rms, 0.000000001))
        print("ECHO CHECK: raw RMS=\(raw.rms), processed RMS=\(processed.rms), reduction=\(reduction) dB, independent input raw=\(raw.otherRMS), processed=\(processed.otherRMS)")
        guard processed.otherFrames > 0, processed.otherRMS > 0.0001 else {
            throw TranscriptionError.message("Independent input became silent while voice processing was active.")
        }
        guard reduction >= 10 else {
            throw TranscriptionError.message("Echo reduction below 10 dB; hardware validation has not passed.")
        }
        print("ECHO CHECK PASS: real capture, external speech playback, independent input still active. Local speech and Zoom-call validation remain separate checks.")
    }

    @MainActor private static func measure(fixture: String, cancelsEcho: Bool) async throws
        -> (rms: Double, frames: Int, otherRMS: Double, otherFrames: Int) {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let capture = MicrophoneCapture(timeline: CaptureTimeline())
        let otherCapture = MicrophoneCapture(timeline: CaptureTimeline())
        let (stream, input) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingOldest(256))
        let (otherStream, otherInput) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingOldest(256))
        let meter = EchoCheckMeter()
        let otherMeter = EchoCheckMeter()
        let consumer = Task { for await input in stream { meter.add(input.buffer) } }
        let otherConsumer = Task { for await input in otherStream { otherMeter.add(input.buffer) } }
        let player = Process()
        player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        player.arguments = [fixture]
        do {
            // Keep a raw input alive first, simulating another input client.
            // This detects the shared-device silence regression, not full Zoom compatibility.
            // Both phases keep another input active: establish coexistence
            // without processing before attributing any silence to echo mode.
            try await otherCapture.start(format: format, continuation: otherInput, cancelsEcho: false,
                onError: { otherMeter.fail($0) })
            try await capture.start(format: format, continuation: input, cancelsEcho: cancelsEcho,
                onError: { meter.fail($0) })
            guard !cancelsEcho || capture.echoCancellationActive else {
                throw TranscriptionError.message("Echo cancellation is not active.")
            }
            try player.run()
            try await Task.sleep(for: .seconds(3))
            meter.begin(); otherMeter.begin()
            try await Task.sleep(for: .seconds(5))
            if player.isRunning { player.terminate() }
            await capture.stop(); await otherCapture.stop()
            input.finish(); otherInput.finish()
            await consumer.value; await otherConsumer.value
            let a = meter.result; let b = otherMeter.result
            if let error = a.error ?? b.error { throw TranscriptionError.message(error) }
            return (a.rms, a.frames, b.rms, b.frames)
        } catch {
            if player.isRunning { player.terminate() }
            await capture.stop(); await otherCapture.stop()
            input.finish(); otherInput.finish()
            consumer.cancel(); otherConsumer.cancel()
            throw error
        }
    }
}

private final class EchoCheckMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var measuring = false
    private var sum = 0.0
    private var frames = 0
    private var error: String?

    func begin() { lock.lock(); measuring = true; lock.unlock() }
    func fail(_ message: String) { lock.lock(); error = message; lock.unlock() }
    func add(_ pcm: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard measuring, let samples = pcm.floatChannelData?[0] else { return }
        for i in 0..<Int(pcm.frameLength) { sum += Double(samples[i]) * Double(samples[i]) }
        frames += Int(pcm.frameLength)
    }
    var result: (rms: Double, frames: Int, error: String?) {
        lock.lock()
        defer { lock.unlock() }
        return (frames == 0 ? 0 : sqrt(sum / Double(frames)), frames, error)
    }
}

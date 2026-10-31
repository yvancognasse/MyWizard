import AVFoundation
import CoreAudio

// Opt-in signed-app check. Plays a synthetic tone in an external process,
// checks that capture continues across mute/unmute, then checks own-voice
// exclusion. Keeps only energy measurements; never starts the microphone.
enum SystemAudioTapCheck {
    @MainActor static func run() async throws {
        let tap = SystemAudioTap()
        let meter = TapCheckMeter()
        try tap.start(queue: meter.queue, receive: { pcm, _ in meter.receive(pcm) },
                      onError: { message in meter.fail(message) })
        defer { tap.stop(queue: meter.queue) }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("MyWizard-tap-\(UUID()).caf")
        defer { try? FileManager.default.removeItem(at: file) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let tone = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000 * 14)!
        tone.frameLength = tone.frameCapacity
        for frame in 0..<Int(tone.frameLength) {
            tone.floatChannelData![0][frame] = Float(sin(Double(frame) * 2 * .pi * 440 / 48000) * 0.04)
        }
        do {
            let output = try AVAudioFile(forWriting: file, settings: format.settings)
            try output.write(from: tone)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        process.arguments = [file.path]
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        for muted in [false, true, false] {
            try tap.setMuted(muted)
            try await Task.sleep(for: .seconds(1))
            meter.reset()
            try await Task.sleep(for: .seconds(2))
            let rms = meter.rms
            print("TAP CAPTURE muted=\(muted) RMS=\(rms)")
            guard rms > 0.001, meter.error == nil else {
                throw TranscriptionError.message("Tap capture failed or became silent: \(meter.error ?? "no audio / permission denied").")
            }
        }
        process.terminate()
        try await Task.sleep(for: .seconds(1))
        meter.reset()
        try await Task.sleep(for: .seconds(1))
        let baseline = meter.rms
        guard baseline < 0.001 else { throw TranscriptionError.message("Other system audio prevents the own-voice isolation check.") }
        let reader = TranscriptReader()
        defer { reader.stop() }
        reader.read(paragraphs: [TranscriptParagraph(id: 0,
            text: String(repeating: "This is a synthetic voice isolation check. ", count: 8),
            speaker: 2, hasSpeakerLabel: true)], language: "en-US")
        try await Task.sleep(for: .seconds(3))
        meter.reset()
        try await Task.sleep(for: .seconds(2))
        guard reader.isReading, reader.errorMessage == nil, meter.rms < 0.001 else {
            throw TranscriptionError.message("MyWizard's own voice was captured or playback failed.")
        }
        print("SYSTEM AUDIO TAP CHECK PASS: live PCM across mute/unmute; own voice excluded; microphone unused.")
    }
}

private final class TapCheckMeter: @unchecked Sendable {
    let queue = DispatchQueue(label: "MyWizard.tap-check")
    private var sum = 0.0
    private var count = 0
    private var failure: String?
    var rms: Double { queue.sync { count == 0 ? 0 : sqrt(sum / Double(count)) } }
    var error: String? { queue.sync { failure } }
    func reset() { queue.sync { sum = 0; count = 0 } }
    func fail(_ message: String) { failure = message }
    func receive(_ pcm: AVAudioPCMBuffer) {
        guard let copy = try? SpeechPCM(copying: pcm) else { return }
        for channel in copy.channels {
            for value in channel { sum += Double(value) * Double(value); count += 1 }
        }
    }
}

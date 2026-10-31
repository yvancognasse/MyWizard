import AppKit
import AVFoundation
import ScreenCaptureKit

// Explicit developer opt-in, run from the signed app to preserve capture identity.
// No transcript or captured audio is stored: only aggregate RMS measurements.
enum AudioIsolationCheck {
    @MainActor static func run() async throws {
        guard CGPreflightScreenCaptureAccess() else {
            throw ReadingError.playbackFailed
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw ReadingError.playbackFailed }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let allMeter = IsolationMeter()
        let excludedMeter = IsolationMeter()
        func makeStream(excludingSelf: Bool, meter: IsolationMeter) throws -> SCStream {
            let config = SCStreamConfiguration()
            config.capturesAudio = true
            config.captureMicrophone = false
            config.excludesCurrentProcessAudio = excludingSelf
            config.width = 2; config.height = 2
            config.sampleRate = 48000; config.channelCount = 2
            config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            let stream = SCStream(filter: filter, configuration: config, delegate: nil)
            try stream.addStreamOutput(meter, type: .audio, sampleHandlerQueue: meter.queue)
            try stream.addStreamOutput(meter, type: .screen, sampleHandlerQueue: meter.queue)
            return stream
        }
        let all = try makeStream(excludingSelf: false, meter: allMeter)
        let excluded = try makeStream(excludingSelf: true, meter: excludedMeter)
        try await all.startCapture()
        do { try await excluded.startCapture() }
        catch { try? await all.stopCapture(); throw error }
        let reader = TranscriptReader()
        do {
            reader.read(paragraphs: [TranscriptParagraph(id: 0,
                text: String(repeating: "This is MyWizard's audio isolation test. Listening should continue without capturing this voice. ", count: 3),
                speaker: 1, hasSpeakerLabel: true)], language: "en-US")
            // Allow synthesis/device startup, then compare identical capture windows.
            try await Task.sleep(for: .seconds(3))
            allMeter.reset(); excludedMeter.reset()
            try await Task.sleep(for: .seconds(3))
            let ownAll = allMeter.rms; let ownExcluded = excludedMeter.rms
            reader.stop()
            guard reader.errorMessage == nil, ownAll > 0.001, ownExcluded < ownAll * 0.05 else {
                print("ISOLATION INCONCLUSIVE/FAILED: own all=\(ownAll) excluded=\(ownExcluded)")
                throw ReadingError.playbackFailed
            }
            print("OWN VOICE: all RMS=\(ownAll), excluded RMS=\(ownExcluded)")

            // External-process control proves that exclusion has not muted all capture.
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("MyWizard-control-\(UUID().uuidString).caf")
            defer { try? FileManager.default.removeItem(at: file) }
            let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
            let tone = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000 * 5)!
            tone.frameLength = tone.frameCapacity
            for frame in 0..<Int(tone.frameLength) {
                tone.floatChannelData![0][frame] = Float(sin(Double(frame) * 2 * .pi * 440 / 48000) * 0.08)
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
            try await Task.sleep(for: .seconds(1))
            allMeter.reset(); excludedMeter.reset()
            try await Task.sleep(for: .seconds(2))
            let externalAll = allMeter.rms; let externalExcluded = excludedMeter.rms
            print("EXTERNAL CONTROL: all RMS=\(externalAll), excluded RMS=\(externalExcluded)")
            guard externalAll > 0.001, externalExcluded > externalAll * 0.5,
                  externalExcluded < externalAll * 2 else { throw ReadingError.playbackFailed }
            if process.isRunning { process.terminate() }
            // Exercise natural completion and a change of speaker/voice as well.
            reader.read(paragraphs: [
                TranscriptParagraph(id: 0, text: "First voice.", speaker: 1, hasSpeakerLabel: true),
                TranscriptParagraph(id: 1, text: "Second voice.", speaker: 2, hasSpeakerLabel: true)
            ], language: "en-US")
            for _ in 0..<150 {
                if !reader.isReading { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard !reader.isReading, reader.errorMessage == nil else { throw ReadingError.playbackFailed }
            print("MULTI-VOICE PLAYBACK COMPLETION PASS")
            try await all.stopCapture(); try await excluded.stopCapture()
            print("AUDIO ISOLATION PASS")
        } catch {
            reader.stop()
            try? await all.stopCapture(); try? await excluded.stopCapture()
            throw error
        }
    }
}

private final class IsolationMeter: NSObject, SCStreamOutput, @unchecked Sendable {
    let queue = DispatchQueue(label: "MyWizard.isolation-meter")
    private var sum = 0.0
    private var count = 0
    var rms: Double { queue.sync { count == 0 ? 0 : sqrt(sum / Double(count)) } }
    func reset() { queue.sync { sum = 0; count = 0 } }
    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, let pcm = try? AudioConverter.copyPCM(from: sample),
              let copy = try? SpeechPCM(copying: pcm) else { return }
        for channel in copy.channels {
            for value in channel { sum += Double(value) * Double(value); count += 1 }
        }
    }
}

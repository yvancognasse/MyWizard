import AVFoundation
import Foundation

// Opt-in bilingual replay. Uses real local recognizers and a simulated tap;
// it never records a microphone, opens an audio device or plays any sound.
@MainActor
enum SpokenLanguageCheck {
    static func run() async throws {
        guard let fixtures = ProcessInfo.processInfo.environment["MYWIZARD_LANGUAGE_FIXTURES"] else {
            throw TranscriptionError.message("Set MYWIZARD_LANGUAGE_FIXTURES to a folder containing french.aiff and english.aiff.")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MyWizardLanguageCheck-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let preferences = MemoryPreferences()
        preferences.set(false, forKey: "includesMicrophone")
        preferences.set("fr-FR", forKey: "transcriptionLanguage")
        let tap = ReplayTap()
        let model = TranscriptionModel(preferences: preferences, recordingRoot: root, systemCaptureFactory: { timeline in
            SystemAudioCapture(timeline: timeline, makeTap: { tap })
        })
        await model.toggleCapture()
        try require(model.isCapturing, "Start failed: \(model.errorMessage ?? "")")
        var presentationTime = AVAudioTime.seconds(forHostTime: mach_absolute_time())
        try tap.send(URL(fileURLWithPath: fixtures).appendingPathComponent("french.aiff"), time: &presentationTime)
        let firstFrames = model.capturedFrameCounts.system
        model.selectSpokenLanguage("en-US")
        try await waitForChange(model)
        try require(model.language == "en-US", "French to English failed: \(model.errorMessage ?? "")")
        try require(model.transcript.localizedCaseInsensitiveContains("projet"), "French text missing after switch")
        let frenchText = model.unfilteredParagraphs.filter { $0.language == "fr-FR" }.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        try tap.send(URL(fileURLWithPath: fixtures).appendingPathComponent("english.aiff"), time: &presentationTime)
        try require(model.capturedFrameCounts.system > firstFrames, "New language did not receive audio")
        model.selectSpokenLanguage("fr-FR")
        try await waitForChange(model)
        try require(model.language == "fr-FR", "English to French failed: \(model.errorMessage ?? "")")
        let retainedFrench = model.unfilteredParagraphs.filter { $0.language == "fr-FR" }.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        try require(retainedFrench == frenchText, "Switch changed French text: expected [\(frenchText)], retained [\(retainedFrench)]; paragraphs: \(model.unfilteredParagraphs.map { "\($0.language ?? "nil") at \($0.startTime ?? -1): \($0.text)" })")
        try require(model.transcript.localizedCaseInsensitiveContains("project"), "English text missing after switch")
        try require(model.paragraphs.contains { $0.language == "fr-FR" } && model.paragraphs.contains { $0.language == "en-US" }, "Paragraph languages were lost")
        try require(tap.starts == 1 && tap.stops == 0, "Language switch restarted the audio tap")
        let frames = model.capturedFrameCounts.system
        await model.toggleCapture()
        try require(!model.isCapturing && model.needsProcessing, "Stop failed")
        let directories = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { $0.pathExtension == "mywizard" }
        try require(directories.count == 1, "Switch split the recording")
        let saved = try RecordedMeeting.load(directories[0])
        try require(saved.manifest.languageChanges?.count == 2, "Language history missing")
        let audio = try AVAudioFile(forReading: saved.audio(.system))
        try require(audio.length >= frames, "Recorded audio samples were lost")
        let snapshot = try saved.loadLiveTranscript()
        try require(snapshot.display.contains { $0.language == "en-US" }, "Saved snapshot lost English language")
        await model.shutDown()

        // Exercise export-only microphone recognition using a synthetic track.
        let mic = try MeetingRecording(language: "fr-FR", microphone: true, detectSpeakers: false, root: root, origin: 100) { _ in }
        var micTime = 100.0
        try append(URL(fileURLWithPath: fixtures).appendingPathComponent("french.aiff"), recording: mic, time: &micTime)
        let switchTime = micTime - 100
        try mic.changeLanguage(to: "en-US", at: switchTime)
        try append(URL(fileURLWithPath: fixtures).appendingPathComponent("english.aiff"), recording: mic, time: &micTime)
        let recorded = await mic.finish()
        let words = try await MeetingProcessor().transcribeMultilingualMicrophone(recorded.audio(.microphone), manifest: recorded.manifest)
        try require(words.contains { $0.start < switchTime && $0.text.localizedCaseInsensitiveContains("projet") }, "French microphone export missing")
        try require(words.contains { $0.start >= switchTime && $0.text.localizedCaseInsensitiveContains("project") }, "English microphone export missing or timestamps reset")
        print("SPOKEN LANGUAGE CHECK PASS: real French/English recognizers; two live switches; earlier text and paragraph languages preserved; one uninterrupted tap and recording; saved language history; bilingual microphone export with restored timestamps; no audio devices opened")
    }

    private static func waitForChange(_ model: TranscriptionModel) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(120))
        while model.isLanguageChanging && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        try require(!model.isLanguageChanging, "Language change exceeded diagnostic deadline")
    }

    private static func append(_ url: URL, recording: MeetingRecording, time: inout Double) throws {
        try buffers(url) { buffer in
            try recording.append(buffer, track: .microphone, time: time)
            time += Double(buffer.frameLength) / buffer.format.sampleRate
        }
    }

    private static func buffers(_ url: URL, receive: (AVAudioPCMBuffer) throws -> Void) throws {
        let file = try AVAudioFile(forReading: url)
        let converter = AudioConverter(outputFormat: MeetingRecording.format)
        while file.framePosition < file.length {
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096)!
            try file.read(into: buffer)
            let converted = try converter.convert(buffer)
            if converted.frameLength > 0 { try receive(converted) }
        }
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw TranscriptionError.message(message) }
    }

    private final class ReplayTap: SystemAudioTapControlling {
        var starts = 0
        var stops = 0
        private var queue: DispatchQueue?
        private var receive: (@Sendable (AVAudioPCMBuffer, Double) -> Void)?
        func start(queue: DispatchQueue, receive: @escaping @Sendable (AVAudioPCMBuffer, Double) -> Void,
                   onError: @escaping @Sendable (String) -> Void, onDeviceChange: (@Sendable (String) -> Void)?) throws {
            starts += 1
            self.queue = queue
            self.receive = receive
        }
        func stop(queue: DispatchQueue) { stops += 1; receive = nil }
        func setMuted(_ muted: Bool) throws {}
        func send(_ url: URL, time: inout Double) throws {
            guard let queue, let receive else { throw TranscriptionError.message("Replay tap is not active") }
            try SpokenLanguageCheck.buffers(url) { buffer in
                let stamp = time
                queue.sync { receive(buffer, stamp) }
                time += Double(buffer.frameLength) / buffer.format.sampleRate
            }
        }
    }
}

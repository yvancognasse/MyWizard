import AVFoundation
import Foundation
import Speech
import Testing
@testable import MyWizard

struct SpokenLanguageChangeTests {
    @Test func delayedOldResultsKeepLanguageAndSpeakerIdentity() {
        var document = SpeakerTranscript()
        document.beginSession(detectsSpeakers: true, language: "fr-FR")
        document.receive([.init(text: "Bonjour", start: 0, end: 1)], isFinal: false)
        document.changeLanguage(to: "en-US", at: 2)
        document.receive([.init(text: "Bonjour.", start: 0, end: 1.9)], isFinal: true)
        // Apple's first word can start slightly before the input boundary.
        // Recognition provenance wins over that approximate timestamp.
        document.receive([.init(text: "Hello.", start: 1.99, end: 3, language: "en-US")], isFinal: true)
        document.updateSpeakers(.init(intervals: [.init(slot: 8, start: 0, end: 4)], processedThrough: 4))
        let cached = document.cachedSystemDisplayParagraphs()
        #expect(cached.map(\.language) == ["fr-FR", "en-US"])
        #expect(cached.map(\.speaker) == [1, 1])
        #expect(cached == document.systemDisplayParagraphs)
        let snapshot = document.liveSnapshot(names: [1: "Guest"])
        #expect(snapshot.display.map(\.language) == ["fr-FR", "en-US"])
        #expect(snapshot.words.map(\.text).joined().contains("Bonjour."))
        #expect(snapshot.words.map(\.text).joined().contains("Hello."))
        let analysis = snapshot.addingMicrophone([])
        #expect(analysis.paragraphs?.map(\.language) == ["fr-FR", "en-US"])
        var exported = SpeakerTranscript()
        exported.beginSession(detectsSpeakers: true, language: "fr-FR")
        exported.replaceCurrentSession(with: analysis)
        #expect(exported.finalizedParagraphs.map(\.language) == ["fr-FR", "en-US"])
        document.updateSpeakers(.init(intervals: [.init(slot: 8, start: 0, end: 5)], processedThrough: 5))
        #expect(document.cachedSystemDisplayParagraphs().map(\.language) == ["fr-FR", "en-US"])
    }

    @Test func failedFinalizationCannotEraseVisiblePreviousPhrase() {
        var document = SpeakerTranscript()
        document.beginSession(detectsSpeakers: false, language: "fr-FR")
        document.receive([.init(text: "Dernière phrase", start: 0, end: 1)], isFinal: false)
        document.changeLanguage(to: "en-US", at: 2)
        document.preservePendingSystemWords()
        document.receive([.init(text: "New phrase", start: 2, end: 3)], isFinal: false)
        #expect(document.systemDisplayParagraphs.map(\.language) == ["fr-FR", "en-US"])
        #expect(document.systemDisplayParagraphs.map(\.text).joined().contains("Dernière phrase"))
        #expect(document.systemDisplayParagraphs.map(\.text).joined().contains("New phrase"))
    }

    @Test func microphoneSegmentsKeepInitialLanguageAndRepeatedSwitches() throws {
        let changes: [SpokenLanguageChange] = [.init(time: 4, language: "en-US"), .init(time: 9, language: "fr-FR")]
        let segments = try SpokenLanguageChange.segments(initial: "fr-FR", changes: changes, duration: 12)
        #expect(segments == [.init(start: 0, end: 4, language: "fr-FR"),
                             .init(start: 4, end: 9, language: "en-US"),
                             .init(start: 9, end: 12, language: "fr-FR")])
        #expect(try SpokenLanguageChange.segments(initial: "fr-FR", changes: changes, duration: 3) == [.init(start: 0, end: 3, language: "fr-FR")])
        #expect(throws: (any Error).self) {
            try SpokenLanguageChange.segments(initial: "fr-FR", changes: [.init(time: -1, language: "en-US")], duration: 3)
        }
    }

    @Test @MainActor func audioSwapPreservesTapSamplesAndManifest() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MyWizardLanguageTest-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let recording = try MeetingRecording(language: "fr-FR", microphone: false, detectSpeakers: false, root: root, origin: 100) { _ in }
        let tap = LanguageTestTap()
        let capture = SystemAudioCapture(timeline: CaptureTimeline(), makeTap: { tap })
        let (oldStream, oldInput) = AsyncStream<AnalyzerInput>.makeStream()
        let (newStream, newInput) = AsyncStream<AnalyzerInput>.makeStream()
        try await capture.start(format: AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: false)!, continuation: oldInput, recording: recording,
                                onLevel: { _ in }, onError: { _ in })
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: MeetingRecording.format, frameCapacity: 1600))
        buffer.frameLength = 1600
        buffer.floatChannelData![0].initialize(repeating: 0.1, count: 1600)
        tap.deliver(buffer, at: 100)
        // A failed manifest write must leave both the old route and history intact.
        let manifestURL = recording.directory.appendingPathComponent("session.json")
        let previousManifest = try Data(contentsOf: manifestURL)
        try FileManager.default.removeItem(at: manifestURL)
        try FileManager.default.createDirectory(at: manifestURL, withIntermediateDirectories: false)
        #expect(throws: (any Error).self) {
            try capture.replaceTranscriptionInput(newInput, language: "en-US", at: 104)
        }
        tap.deliver(buffer, at: 100.1)
        try FileManager.default.removeItem(at: manifestURL)
        try previousManifest.write(to: manifestURL)
        let boundary = try capture.replaceTranscriptionInput(newInput, language: "en-US", at: 104)
        tap.deliver(buffer, at: 100.2)
        #expect(abs(boundary - 0.2) < 0.0001)
        #expect(capture.frameCount == 4800)
        #expect(tap.starts == 1 && tap.stops == 0)
        await capture.stop()
        newInput.finish()
        var oldFrames = 0
        for await value in oldStream { oldFrames += Int(value.buffer.frameLength) }
        var newFrames = 0
        for await value in newStream { newFrames += Int(value.buffer.frameLength) }
        #expect(oldFrames == 3200 && newFrames == 1600)
        let saved = await recording.finish()
        let loaded = try RecordedMeeting.load(saved.directory)
        #expect(loaded.manifest.language == "fr-FR")
        #expect(loaded.manifest.languageChanges?.first?.language == "en-US")
        #expect(loaded.manifest.languageChanges?.first?.time == 4)
        #expect(loaded.manifest.languageChanges?.count == 1)
        let audio = try AVAudioFile(forReading: saved.audio(.system))
        #expect(audio.length == 4800)
        let key = try ExportCheckpoint.inputKey(loaded)
        var changed = loaded
        changed.manifest.languageChanges = nil
        #expect(try ExportCheckpoint.inputKey(changed) != key)
        var legacy = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(loaded.manifest)) as? [String: Any])
        legacy.removeValue(forKey: "languageChanges")
        #expect(try JSONDecoder().decode(RecordingManifest.self, from: JSONSerialization.data(withJSONObject: legacy)).languageChanges == nil)
    }
}

@MainActor
private final class LanguageTestTap: SystemAudioTapControlling {
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
    func deliver(_ buffer: AVAudioPCMBuffer, at time: Double) {
        guard let queue, let receive else { return }
        queue.sync { receive(buffer, time) }
    }
}

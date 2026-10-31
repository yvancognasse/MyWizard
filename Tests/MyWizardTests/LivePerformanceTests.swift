import Combine
import Foundation
import Testing
@testable import MyWizard

struct LivePerformanceTests {
    @Test func incrementalPresentationMatchesReferenceAcrossCorrections() {
        var document = SpeakerTranscript()
        document.beginSession(detectsSpeakers: true, language: "en-US", reservesOwnSpeaker: true)
        for index in 0..<60 {
            let start = Double(index)
            document.receive([.init(text: "Draft \(index) 👋 ", start: start, end: start + 0.8)], isFinal: false)
            #expect(document.cachedSystemDisplayParagraphs() == document.systemDisplayParagraphs)
            document.receive([.init(text: "Final \(index). ", start: start, end: start + 0.8)], isFinal: true)
            #expect(document.cachedSystemDisplayParagraphs() == document.systemDisplayParagraphs)
            if index % 5 == 0 {
                document.updateSpeakers(.init(intervals: [
                    .init(slot: 0, start: 0, end: start / 2),
                    .init(slot: 1, start: start / 2, end: start + 1)], processedThrough: start + 1))
                #expect(document.cachedSystemDisplayParagraphs() == document.systemDisplayParagraphs)
            }
        }
        // Removal and retroactive correction must invalidate cached labels.
        let revisions: [[SpeakerInterval]] = [[], [.init(slot: 2, start: 0, end: 60)]]
        for intervals in revisions {
            document.updateSpeakers(.init(intervals: intervals, processedThrough: 60))
            #expect(document.cachedSystemDisplayParagraphs() == document.systemDisplayParagraphs)
        }
        document.receive([.init(text: "Private answer", start: 62, end: 63)], isFinal: true, source: .microphone)
        #expect(document.cachedSystemDisplayParagraphs().allSatisfy { $0.source == .systemAudio })
        // An exceptional result arriving out of order falls back to timestamp sorting.
        document.receive([.init(text: "Late result", start: 2, end: 3)], isFinal: true)
        #expect(document.cachedSystemDisplayParagraphs() == document.systemDisplayParagraphs)
        document.beginSession(detectsSpeakers: true, language: "fr-FR")
        document.receive([.init(text: "Une autre réunion", start: 0, end: 1)], isFinal: true)
        #expect(document.cachedSystemDisplayParagraphs() == document.systemDisplayParagraphs)
        let copy = document
        document.clear()
        #expect(document.cachedSystemDisplayParagraphs().isEmpty)
        #expect(!copy.systemDisplayParagraphs.isEmpty)
        document.receive([.init(text: "Cleared", start: 0, end: 0.5),
                          .init(text: "New text", start: 2, end: 3)], isFinal: true)
        #expect(document.cachedSystemDisplayParagraphs() == document.systemDisplayParagraphs)
    }

    @Test @MainActor func burstsPublishOnceAndExportReadsLatestAcceptedText() async throws {
        let model = TranscriptionModel(preferences: MemoryPreferences())
        var updates = 0
        let observation = model.$paragraphs.dropFirst().sink { _ in updates += 1 }
        defer { observation.cancel() }
        for index in 0..<25 {
            model.receiveTranscript([.init(text: "Revision \(index)", start: 0, end: 1)],
                                    isFinal: false, coalescingDisplay: true)
        }
        #expect(model.paragraphs.isEmpty)
        #expect(model.transcript.contains("Revision 24"))
        for _ in 0..<100 where model.paragraphs.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(updates == 1)
        #expect(model.paragraphs.first?.text == "Revision 24")
        model.receiveTranscript([.init(text: "Final text", start: 0, end: 1)],
                                isFinal: true, coalescingDisplay: true)
        model.speakerNames[1] = "Renamed" // Explicit actions flush pending updates.
        #expect(model.transcript.contains("Final text"))
        #expect(!model.transcript.contains("Revision 24"))
        model.clear()
        try await Task.sleep(for: .milliseconds(120))
        #expect(model.paragraphs.isEmpty && model.transcript.isEmpty && !model.hasExportContent)
        await model.shutDown()
    }

    @Test @MainActor func displayBatchingDoesNotDelayReadAloud() async {
        let model = TranscriptionModel(preferences: MemoryPreferences())
        model.language = "en-US"
        model.readingLanguage = .french
        model.beginReading(followCapture: true)
        model.receiveTranscript([.init(text: "Read this immediately.", start: 0, end: 1)],
                                isFinal: false, coalescingDisplay: true)
        #expect(model.paragraphs.isEmpty)
        #expect(model.translationJob?.texts.joined().contains("Read this immediately.") == true)
        await model.shutDown()
    }

    @Test func periodicBackupsSkipUnchangedButSaveMetadataAndRetryFailures() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LiveBackup-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = TranscriptAutosave(directory: root)
        var document = SpeakerTranscript()
        document.beginSession(detectsSpeakers: true)
        document.receive([.init(text: "First", start: 0, end: 1)], isFinal: true)
        // The failed revision must not be treated as successfully saved.
        await #expect(throws: (any Error).self) {
            try await writer.save(document: document, names: [:], calendarMeeting: nil,
                                  codexProject: nil, metadataRevision: 0)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try await writer.save(document: document, names: [:], calendarMeeting: nil,
                              codexProject: nil, metadataRevision: 0)
        let file = root.appendingPathComponent("live-transcript.json")
        let marker = Date(timeIntervalSince1970: 100)
        try FileManager.default.setAttributes([.modificationDate: marker], ofItemAtPath: file.path)
        _ = document.cachedSystemDisplayParagraphs() // Cache changes are not content changes.
        try await writer.save(document: document, names: [:], calendarMeeting: nil,
                              codexProject: nil, metadataRevision: 0)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect(attributes[.modificationDate] as? Date == marker)
        try await writer.save(document: document, names: [1: "Alice"], calendarMeeting: nil,
                              codexProject: nil, metadataRevision: 1)
        var saved = try JSONDecoder().decode(LiveTranscriptSnapshot.self, from: Data(contentsOf: file))
        #expect(saved.names[1] == "Alice")
        let previous = document
        document.receive([.init(text: " Final tail", start: 2, end: 3)], isFinal: false)
        try await writer.finish(document.liveSnapshot(names: [1: "Alice"]))
        try await writer.save(document: previous, names: [:], calendarMeeting: nil,
                              codexProject: nil, metadataRevision: 0)
        saved = try JSONDecoder().decode(LiveTranscriptSnapshot.self, from: Data(contentsOf: file))
        #expect(saved.words.map(\.text).joined().contains("Final tail"))
        #expect(saved.names[1] == "Alice")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MYWIZARD_PERFORMANCE_CHECK"] == "1"))
    func incrementalLongMeetingPresentation() {
        var document = SpeakerTranscript()
        document.beginSession(detectsSpeakers: true, language: "en-US")
        document.receive((0..<20_000).map {
            .init(text: "word\($0) ", start: Double($0), end: Double($0) + 0.8)
        }, isFinal: true)
        document.updateSpeakers(.init(intervals: [.init(slot: 0, start: 0, end: 21_000)], processedThrough: 21_000))
        _ = document.cachedSystemDisplayParagraphs()
        var reference = document
        let clock = ContinuousClock()
        var incrementalCount = 0
        let incremental = clock.measure {
            for index in 0..<100 {
                document.receive([.init(text: "Tail \(index)", start: 20_001, end: 20_002)], isFinal: false)
                incrementalCount += document.cachedSystemDisplayParagraphs().count
            }
        }
        var fullCount = 0
        let full = clock.measure {
            for index in 0..<100 {
                reference.receive([.init(text: "Tail \(index)", start: 20_001, end: 20_002)], isFinal: false)
                fullCount += reference.systemDisplayParagraphs.count
            }
        }
        #expect(incrementalCount == fullCount)
        #expect(document.cachedSystemDisplayParagraphs() == reference.systemDisplayParagraphs)
        print("PERFORMANCE 100 provisional revisions after 20,000 words: incremental=\(incremental), full=\(full)")
    }
}

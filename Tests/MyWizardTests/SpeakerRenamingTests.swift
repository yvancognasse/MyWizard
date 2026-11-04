import Foundation
import Testing
@testable import MyWizard

struct SpeakerRenamingTests {
    private func meeting() -> SpeakerTranscript {
        var document = SpeakerTranscript()
        document.beginSession(detectsSpeakers: true, language: "en-US")
        document.receive([
            TimedText(text: "Earlier. ", start: 0, end: 1),
            TimedText(text: "Other. ", start: 2, end: 3),
            TimedText(text: "Selected. ", start: 4, end: 5),
            TimedText(text: "Reply. ", start: 6, end: 7),
            TimedText(text: "Later.", start: 8, end: 9)
        ], isFinal: true)
        document.updateSpeakers(SpeakerSnapshot(intervals: [
            .init(slot: 0, start: 0, end: 1), .init(slot: 1, start: 2, end: 3),
            .init(slot: 0, start: 4, end: 5), .init(slot: 1, start: 6, end: 7),
            .init(slot: 0, start: 8, end: 12)
        ], processedThrough: 12))
        return document
    }

    @Test func changesFromSelectedPassageIncludingFutureWordsAndCachedDisplay() throws {
        var document = meeting()
        let passage = document.cachedSystemDisplayParagraphs()[2]
        document.renameSpeaker(1, from: passage, oldName: "Alice", newName: "Bob")
        document.receive([TimedText(text: " Future.", start: 10, end: 11)], isFinal: true)
        let names = [1: "Bob", 2: "Carol"]
        #expect(document.systemDisplayParagraphs.map { $0.heading(names: names) } == ["Alice", "Carol", "Bob", "Carol", "Bob"])
        #expect(document.cachedSystemDisplayParagraphs() == document.systemDisplayParagraphs)
        #expect(document.systemDisplayParagraphs.last?.text.contains("Future") == true)
        let encoded = try JSONEncoder().encode(document.liveSnapshot(names: names))
        let snapshot = try JSONDecoder().decode(LiveTranscriptSnapshot.self, from: encoded)
        document.replaceCurrentSession(with: snapshot.addingMicrophone([
            TimedText(text: "My response.", start: 3, end: 3.5, source: .microphone)
        ]))
        #expect(document.systemDisplayParagraphs.map { $0.heading(names: names) } == ["Alice", "Carol", "Bob", "Carol", "Bob"])
        let exported = document.plainText(names: names)
        #expect(exported.contains("Alice:\nEarlier."))
        #expect(exported.contains("Bob:\nSelected."))
        #expect(exported.contains("Microphone:\nMy response."))
    }

    @Test func repeatedEditsAndEarlierCorrectionReplaceLaterNamesOnlyFromBoundary() {
        var document = meeting()
        document.renameSpeaker(1, from: document.systemDisplayParagraphs[2], oldName: "Alice", newName: "Bob")
        document.renameSpeaker(1, from: document.systemDisplayParagraphs[4], oldName: "Bob", newName: "Dan")
        #expect(document.systemDisplayParagraphs.filter { $0.speaker == 1 }.map { $0.heading(names: [1: "Dan"]) } == ["Alice", "Bob", "Dan"])
        document.renameSpeaker(1, from: document.systemDisplayParagraphs[2], oldName: "Dan", newName: "Speaker 1")
        #expect(document.systemDisplayParagraphs.filter { $0.speaker == 1 }.map { $0.heading(names: [:]) } == ["Alice", "Speaker 1", "Speaker 1"])
        document.beginSession(detectsSpeakers: true)
        #expect(document.systemDisplayParagraphs.filter { $0.speaker == 1 }.map { $0.heading(names: [:]) } == ["Alice", "Speaker 1", "Speaker 1"])
    }

    @Test func renameAfterExportPreservesEarlierNamesAndDoesNotMergeDifferentNames() {
        var document = meeting()
        let snapshot = document.liveSnapshot(names: [1: "Alice"])
        document.replaceCurrentSession(with: snapshot.addingMicrophone([]))
        document.renameSpeaker(1, from: document.systemDisplayParagraphs[2], oldName: "Alice", newName: "Bob")
        #expect(document.plainText(names: [1: "Bob"]).contains("Alice:\nEarlier."))
        #expect(document.plainText(names: [1: "Bob"]).contains("Bob:\nSelected."))
        let coalesced = ExportParagraphPolish.coalesce([
            .init(text: "One.", speaker: 1, start: 0, end: 1, speakerName: "Alice"),
            .init(text: "Two.", speaker: 1, start: 2, end: 3, speakerName: "Bob")
        ])
        #expect(coalesced.count == 2)
    }

    @Test func revisedDiarizationCannotMergeAcrossANameBoundary() {
        var document = meeting()
        document.renameSpeaker(1, from: document.systemDisplayParagraphs[2], oldName: "Alice", newName: "Bob")
        document.updateSpeakers(.init(intervals: [.init(slot: 0, start: 0, end: 12)], processedThrough: 12))
        #expect(document.cachedSystemDisplayParagraphs().map { $0.heading(names: [1: "Bob"]) } == ["Alice", "Bob"])
        #expect(document.cachedSystemDisplayParagraphs() == document.systemDisplayParagraphs)
    }

    @Test func displaySmoothingPreservesHistoricalNamesAndLeavesNameBoundariesUncertain() {
        let before = TranscriptParagraph(id: 0, text: "Before.", speaker: 1, hasSpeakerLabel: true, speakerName: "Alice")
        let fragment = TranscriptParagraph(id: 1, text: "A fragment", speaker: nil, hasSpeakerLabel: true)
        let same = TranscriptParagraph(id: 2, text: "After.", speaker: 1, hasSpeakerLabel: true, speakerName: "Alice")
        #expect(LiveSpeakerPresentation.smooth([before, fragment, same])[1].heading(names: [1: "Bob"]) == "Alice")
        var changed = same
        changed.speakerName = "Bob"
        #expect(LiveSpeakerPresentation.smooth([before, fragment, changed])[1].speaker == nil)
    }

    @Test @MainActor func firstAssignmentNamesAllPassagesThenPreferenceEditStartsAtLatest() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = try MeetingRecording(language: "en-US", microphone: false, detectSpeakers: true, root: root) { _ in }
        let saved = await recorder.finish()
        try saved.saveLiveTranscript(meeting().liveSnapshot(names: [:]))
        let model = TranscriptionModel(preferences: MemoryPreferences(), recordingRoot: root,
            voiceMemoryURL: root.appendingPathComponent("voices.json"))
        try model.recover(saved.directory)
        model.renameSpeaker(1, to: "Alice")
        #expect(model.paragraphs.filter { $0.speaker == 1 }.allSatisfy { $0.heading(names: model.speakerNames) == "Alice" })
        model.renameSpeaker(1, to: "Bob")
        #expect(model.transcript.contains("Alice:\nEarlier."))
        #expect(model.transcript.contains("Bob:\nLater."))
        #expect(await model.prepareExport())
        #expect(model.transcript.contains("Alice:\nEarlier."))
        #expect(model.transcript.contains("Bob:\nLater."))
        await model.shutDown()
    }
}

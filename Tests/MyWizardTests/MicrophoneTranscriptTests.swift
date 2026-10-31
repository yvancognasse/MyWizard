import Foundation
import Testing
@testable import MyWizard

struct MicrophoneTranscriptTests {
    @Test @MainActor func microphoneButtonBeforeCapturePersistsChoiceWithoutStartingCapture() async throws {
        let preferences = MemoryPreferences()
        let model = TranscriptionModel(preferences: preferences)
        await model.setMicrophoneEnabled(false)
        #expect(!model.includesMicrophone)
        #expect(!TranscriptionModel(preferences: preferences).includesMicrophone)
        await model.setMicrophoneEnabled(true)
        #expect(model.includesMicrophone)
        #expect(TranscriptionModel(preferences: preferences).includesMicrophone)
        #expect(!model.isCapturing)
        #expect(!model.isMicrophoneChanging)
        #expect(model.recordings.isEmpty)
        #expect(model.capturedFrameCounts.microphone == 0)
        #expect(model.errorMessage == nil)
    }

    @Test @MainActor func microphoneIsExportOnlyIncludingFinalTextAndDisplayTranslation() throws {
        let suite = "MyWizard.ExportOnlyTest.\(UUID())"
        let preferences = MemoryPreferences()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let model = TranscriptionModel(preferences: preferences)
        model.language = "en-US"
        model.speakerNames[SpeakerIdentity.microphone] = "My name"
        model.receiveTranscript([TimedText(text: "Remote speaker", start: 0, end: 1)], isFinal: true)
        model.receiveTranscript([TimedText(text: "My provisional reply", start: 3, end: 4)],
                                isFinal: false, source: .microphone)
        #expect(model.paragraphs.allSatisfy { $0.source == .systemAudio })
        #expect(model.displayTranslation.paragraphs.allSatisfy { $0.source == .systemAudio })
        model.receiveTranscript([TimedText(text: "My private final reply", start: 3, end: 4)],
                                isFinal: true, source: .microphone)
        #expect(!model.isCapturing)
        #expect(model.paragraphs.allSatisfy { $0.source == .systemAudio })
        #expect(model.exportParagraphs.contains { $0.source == .microphone })
        #expect(model.transcript.contains("My private final reply"))
        #expect(model.transcript.contains("My name"))
        model.displayLanguage = .french
        model.displayTranslation.startNextJob()
        let job = try #require(model.displayTranslation.job)
        #expect(job.texts.joined().contains("Remote speaker"))
        #expect(!job.texts.joined().contains("My private"))
        model.displayTranslation.completed(id: job.id, result: .success(job.texts.map { _ in "Interlocuteur" }))
        #expect(model.displayTranslation.paragraphs.allSatisfy { $0.source == .systemAudio })
        model.speakerNames[SpeakerIdentity.microphone] = "Renamed speaker"
        let file = root.appendingPathComponent("notes.txt")
        try TranscriptExporter(preferences: preferences).write(model.transcript, to: file)
        let saved = try String(contentsOf: file, encoding: .utf8)
        #expect(saved.contains("Renamed speaker"))
        #expect(saved.contains("My private final reply"))
        #expect(saved.contains("Remote speaker"))
        model.clear()
        #expect(model.transcript.isEmpty)
        #expect(model.paragraphs.isEmpty)
    }

    @Test @MainActor func microphoneOnlyTranscriptRemainsExportableButCannotBeReadAloud() async throws {
        let preferences = MemoryPreferences()
        let model = TranscriptionModel(preferences: preferences)
        model.receiveTranscript([TimedText(text: "My answer", start: 0, end: 1)],
                                isFinal: true, source: .microphone)
        #expect(model.paragraphs.isEmpty)
        #expect(model.displayTranslation.paragraphs.isEmpty)
        #expect(model.transcript.contains("My answer"))
        #expect(await model.prepareExport())
        await model.toggleReading()
        #expect(!model.isReadingEnabled)
    }

    @Test func trackStartupOffsetsAlsoAlignSystemDiarization() {
        let clock = CaptureTimeline()
        #expect(clock.startOffset(for: .microphone, presentationTime: 100) == 0)
        #expect(clock.startOffset(for: .systemAudio, presentationTime: 102) == 2)
        #expect(clock.startOffset(for: .systemAudio, presentationTime: 103) == 2)
        let snapshot = clock.alignSystemSpeakers(SpeakerSnapshot(intervals: [SpeakerInterval(slot: 0, start: 0, end: 1)], processedThrough: 1))
        #expect(snapshot.intervals.first?.start == 2)
        #expect(snapshot.intervals.first?.end == 3)
    }

    private func paragraph(_ text: String, source: TranscriptSource, speaker: Int? = 1) -> TranscriptParagraph {
        TranscriptParagraph(id: 0, text: text, speaker: speaker, hasSpeakerLabel: true, language: "fr-FR", source: source)
    }

    @Test func microphoneHasReservedIdentityWithoutDiarization() {
        var document = SpeakerTranscript()
        document.beginSession(detectsSpeakers: false, reservesOwnSpeaker: true)
        document.receive([TimedText(text: "Other person", start: 0, end: 1)], isFinal: true)
        document.receive([TimedText(text: "My reply", start: 1, end: 2)], isFinal: true, source: .microphone)
        #expect(document.paragraphs.map(\.source) == [.systemAudio, .microphone])
        #expect(document.paragraphs.last?.speaker == SpeakerIdentity.microphone)
        #expect(document.plainText(names: [SpeakerIdentity.microphone: "Yvan Cognasse"]).contains("Yvan Cognasse:\nMy reply"))
    }

    @Test func otherSpeakersStartAtOneAndMicrophoneIgnoresDiarization() {
        var document = SpeakerTranscript()
        document.beginSession(detectsSpeakers: true, reservesOwnSpeaker: true)
        document.receive([TimedText(text: "Other", start: 0, end: 1)], isFinal: true)
        document.receive([TimedText(text: "Mine", start: 1, end: 2)], isFinal: true, source: .microphone)
        document.updateSpeakers(SpeakerSnapshot(intervals: [SpeakerInterval(slot: 0, start: 0, end: 2)], processedThrough: 2))
        #expect(document.paragraphs.map(\.speaker) == [1, SpeakerIdentity.microphone])
        #expect(document.paragraphs.map { $0.heading(names: [SpeakerIdentity.microphone: "Yvan"]) } == ["Speaker 1", "Yvan"])
        #expect(document.paragraphs.last?.heading(names: [:]) == "Microphone")
    }

    @Test func systemResultsCanNeverDeleteOrRewriteFinalMicrophoneText() {
        var document = SpeakerTranscript()
        document.beginSession(detectsSpeakers: false, reservesOwnSpeaker: true)
        let phrase = "My own answer must remain visible."
        document.receive([TimedText(text: phrase, start: 10, end: 13)], isFinal: true, source: .microphone)
        document.receive([TimedText(text: phrase, start: 10, end: 13)], isFinal: true, source: .systemAudio)
        let microphone = document.paragraphs.filter { $0.source == .microphone }
        #expect(microphone.count == 1)
        #expect(microphone[0].text.trimmingCharacters(in: .whitespacesAndNewlines) == phrase)
    }

    @Test func provisionalUpdatesReplaceOnlyTheirOwnCaptureTrack() {
        var document = SpeakerTranscript()
        document.beginSession(detectsSpeakers: false, reservesOwnSpeaker: true)
        document.receive([TimedText(text: "My provisional answer", start: 2, end: 4)], isFinal: false, source: .microphone)
        document.receive([TimedText(text: "System draft", start: 0, end: 3)], isFinal: false)
        document.receive([TimedText(text: "System revised", start: 0, end: 3)], isFinal: false)
        let microphone = document.paragraphs.filter { $0.source == .microphone }
        #expect(microphone.map(\.text) == ["My provisional answer"])
    }

    @Test func independentPartialsClearAndArchivedSources() {
        var document = SpeakerTranscript()
        document.beginSession(detectsSpeakers: false, reservesOwnSpeaker: true)
        document.receive([TimedText(text: "The other", start: 0, end: 1)], isFinal: false)
        document.receive([TimedText(text: "My par", start: 1, end: 2)], isFinal: false, source: .microphone)
        document.receive([TimedText(text: "My part", start: 1, end: 2)], isFinal: true, source: .microphone)
        #expect(document.paragraphs.count == 2)
        #expect(document.paragraphs.first?.text == "The other")
        document.clear()
        document.receive([TimedText(text: "My part", start: 1, end: 2)], isFinal: true, source: .microphone)
        #expect(document.paragraphs.isEmpty)
        document.receive([TimedText(text: "New", start: 2, end: 3)], isFinal: true, source: .microphone)
        document.beginSession(detectsSpeakers: true, reservesOwnSpeaker: true)
        #expect(document.paragraphs.first?.source == .microphone)
        #expect(document.paragraphs.first?.canReadAloud == false)
    }

    @Test func readingAndTranslationExcludeSourceNotNamesOrNumbers() throws {
        let paragraphs = [paragraph("Never read me", source: .microphone, speaker: nil),
                          paragraph("Read this passage", source: .systemAudio)]
        let voice = ReadingVoice(identifier: "test", name: "Test", language: "fr-FR", quality: 1)
        let reading = try ReadingPlan.make(paragraphs: paragraphs, language: "fr-FR", voices: [voice])
        #expect(reading.map(\.text) == ["Read this passage"])
        let translation = ReadingTranslationPlan(paragraphs: paragraphs, fallbackSource: "fr-FR", target: "en-US")
        #expect(translation.jobs.flatMap(\.texts) == ["Read this passage"])
        #expect(translation.paragraphs.count == 1)
        #expect(try ReadingPlan.make(paragraphs: [paragraph("Me", source: .microphone)], language: "fr-FR", voices: []).isEmpty)
    }

    @Test func liveCursorDoesNotSkipOrRepeatOtherSpeechWhenMicrophoneArrives() {
        var cursor = LiveReadingCursor()
        let other = paragraph("Other. ", source: .systemAudio, speaker: 2)
        #expect(cursor.takeNew(from: [other]).map(\.text) == ["Other. "])
        let mine = paragraph("My long reply. ", source: .microphone)
        #expect(cursor.takeNew(from: [other, mine]).isEmpty)
        let next = paragraph("Next. ", source: .systemAudio, speaker: 2)
        #expect(cursor.takeNew(from: [other, mine, next]).map(\.text) == ["Next. "])
    }

    @Test @MainActor func nameAndMicrophonePreferencePersist() async {
        let defaults = MemoryPreferences()
        let model = TranscriptionModel(preferences: defaults)
        #expect(model.includesMicrophone)
        #expect(model.speakerNames[SpeakerIdentity.microphone] == "Yvan Cognasse")
        model.speakerNames[SpeakerIdentity.microphone] = "My custom name"
        model.speakerNames[1] = "A remote participant"
        #expect(defaults.string(forKey: "ownSpeakerName") == "My custom name")
        await model.setMicrophoneEnabled(false)
        let restored = TranscriptionModel(preferences: defaults)
        #expect(restored.speakerNames[SpeakerIdentity.microphone] == "My custom name")
        #expect(restored.speakerNames[1] == nil)
        #expect(!restored.includesMicrophone)
        restored.receiveTranscript([TimedText(text: "Only me", start: 0, end: 1)], isFinal: true, source: .microphone)
        await restored.toggleReading()
        #expect(!restored.isReadingEnabled)
        #expect(!restored.reader.isReading)
        #expect(restored.translationJob == nil)
        restored.readingLanguage = .english
        restored.beginReading(followCapture: true)
        #expect(restored.isReadingEnabled)
        #expect(restored.translationJob == nil)
        restored.receiveTranscript([TimedText(text: "Other speaker", start: 1, end: 2)], isFinal: true)
        #expect(restored.translationJob?.texts == ["Other speaker "])
        restored.stopReading()
    }

    @Test @MainActor func clearResetsParticipantNamesAndKeepsOwnName() {
        let defaults = MemoryPreferences()
        let model = TranscriptionModel(preferences: defaults)
        model.speakerNames = [SpeakerIdentity.microphone: "Me", 1: "A colleague", 2: "Another colleague"]
        model.receiveTranscript([TimedText(text: "Hello", start: 0, end: 1)], isFinal: true)
        model.clear()
        #expect(model.speakerNames == [SpeakerIdentity.microphone: "Me"])
        #expect(defaults.string(forKey: "ownSpeakerName") == "Me")
        #expect(model.paragraphs.isEmpty)
        #expect(model.transcript.isEmpty)
    }
}

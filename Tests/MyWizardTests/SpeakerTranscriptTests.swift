import Testing
@testable import MyWizard

struct SpeakerTranscriptTests {
    @Test @MainActor func delayedLiveSnapshotsReplaceUnknownLabelsAndUpdateDisplay() {
        var document = SpeakerTranscript()
        let timeline = CaptureTimeline()
        _ = timeline.startOffset(for: .microphone, presentationTime: 100)
        _ = timeline.startOffset(for: .systemAudio, presentationTime: 101)
        document.beginSession(detectsSpeakers: true, language: "en-US", reservesOwnSpeaker: true)
        document.receive(timeline.alignWords([
            TimedText(text: "First voice. ", start: 0, end: 1),
            TimedText(text: "Second voice.", start: 1, end: 2)
        ], source: .systemAudio), isFinal: true)
        document.receive([TimedText(text: "My answer", start: 4, end: 5)], isFinal: true, source: .microphone)
        #expect(document.paragraphs.first?.speaker == nil)
        document.updateSpeakers(timeline.alignSystemSpeakers(SpeakerSnapshot(intervals: [
            SpeakerInterval(slot: 7, start: 0, end: 1),
            SpeakerInterval(slot: 2, start: 1, end: 2)
        ], processedThrough: 2)))
        let visible = document.deduplicatedParagraphs.filter { $0.source == .systemAudio }
        #expect(visible.map(\.speaker) == [1, 2])
        #expect(visible.map { $0.heading(names: [:]) } == ["Speaker 1", "Speaker 2"])
        let display = DisplayTranslation()
        display.update(visible, source: "en-US", target: .original)
        #expect(display.paragraphs.map(\.speaker) == [1, 2])
        #expect(!display.paragraphs.contains { $0.source == .microphone })
        #expect(document.plainText(names: [SpeakerIdentity.microphone: "Me"]).contains("My answer"))
        // Later snapshots must retain assignments for the beginning of a meeting.
        document.updateSpeakers(timeline.alignSystemSpeakers(SpeakerSnapshot(intervals: [
            SpeakerInterval(slot: 7, start: 0, end: 1),
            SpeakerInterval(slot: 2, start: 1, end: 2),
            SpeakerInterval(slot: 7, start: 300, end: 301)
        ], processedThrough: 301)))
        #expect(document.paragraphs.filter { $0.source == .systemAudio }.map(\.speaker) == [1, 2])
    }

    @Test func separatesSpeakersAndExportsNames() {
        var document = SpeakerTranscript()
        document.beginSession(detectsSpeakers: true)
        document.receive([
            TimedText(text: "Hello. ", start: 0, end: 1),
            TimedText(text: "Bonjour !", start: 1, end: 2)
        ], isFinal: true)
        #expect(document.paragraphs.first?.speaker == nil)
        document.updateSpeakers(SpeakerSnapshot(intervals: [
            SpeakerInterval(slot: 0, start: 0, end: 1),
            SpeakerInterval(slot: 1, start: 1, end: 2)
        ], processedThrough: 2))
        #expect(document.paragraphs.map(\.speaker) == [1, 2])
        #expect(document.plainText(names: [:]) == "Speaker 1:\nHello.\n\nSpeaker 2:\nBonjour !")
        #expect(document.plainText(names: [2: "Alice"]).contains("Alice:\nBonjour !"))
    }

    @Test func overlappingVoicesRemainUnknown() {
        let word = TimedText(text: "Yes", start: 0, end: 1)
        let intervals = [SpeakerInterval(slot: 0, start: 0, end: 1),
                         SpeakerInterval(slot: 1, start: 0, end: 1)]
        #expect(SpeakerTranscript.speakerSlot(for: word, intervals: intervals) == nil)
        #expect(SpeakerTranscript.speakerSlot(for: word, intervals: []) == nil)
    }

    @Test func partialResultsAreReplacedAndClearDoesNotResurrectText() {
        var document = SpeakerTranscript()
        document.beginSession(detectsSpeakers: false)
        document.receive([TimedText(text: "Hel", start: 0, end: 1)], isFinal: false)
        document.receive([TimedText(text: "Hello", start: 0, end: 1)], isFinal: true)
        #expect(document.plainText(names: [:]) == "Hello")
        document.clear()
        document.receive([TimedText(text: "Hello", start: 0, end: 1),
                          TimedText(text: "New words", start: 1, end: 2)], isFinal: true)
        #expect(document.plainText(names: [:]) == "New words")
    }

    @Test func clearResetsDetectedSpeakerIdentities() {
        var document = SpeakerTranscript()
        document.beginSession(detectsSpeakers: true, reservesOwnSpeaker: true)
        document.updateSpeakers(SpeakerSnapshot(intervals: [
            SpeakerInterval(slot: 8, start: 0, end: 1)
        ], processedThrough: 1))
        document.clear()
        document.receive([TimedText(text: "A new meeting", start: 2, end: 3)], isFinal: true)
        document.updateSpeakers(SpeakerSnapshot(intervals: [
            SpeakerInterval(slot: 3, start: 2, end: 3)
        ], processedThrough: 3))
        #expect(document.paragraphs.map(\.speaker) == [1])
    }

    @Test func newSessionsDoNotReusePreviousVoiceIdentities() {
        var document = SpeakerTranscript()
        for _ in 0..<2 {
            document.beginSession(detectsSpeakers: true)
            document.receive([TimedText(text: "Hello", start: 0, end: 1)], isFinal: true)
            document.updateSpeakers(SpeakerSnapshot(intervals: [SpeakerInterval(slot: 0, start: 0, end: 1)], processedThrough: 1))
        }
        #expect(document.paragraphs.map(\.speaker) == [1, 2])
    }
}

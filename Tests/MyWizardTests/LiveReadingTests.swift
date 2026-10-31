import Foundation
import Testing
@testable import MyWizard

struct LiveReadingTests {
    @Test func cursorHandlesGrowingAndRegroupedSpeakersWithoutRepeatingWords() {
        var cursor = LiveReadingCursor()
        func paragraph(_ text: String, _ speaker: Int) -> TranscriptParagraph {
            TranscriptParagraph(id: speaker, text: text, speaker: speaker, hasSpeakerLabel: true)
        }
        #expect(cursor.takeNew(from: [paragraph("Hello ", 1)]).map(\.text) == ["Hello "])
        #expect(cursor.takeNew(from: [paragraph("Hello world. ", 1)]).map(\.text) == ["world. "])
        #expect(cursor.takeNew(from: [paragraph("Hello ", 2), paragraph("world. ", 1)]).isEmpty)
        #expect(cursor.takeNew(from: [paragraph("Hello ", 2), paragraph("world. Bonjour 👋🏽", 1)]).map(\.text) == ["Bonjour 👋🏽"])
    }

    @Test func volatileWordsAreNotReadTwiceWhenFinalized() {
        var document = SpeakerTranscript()
        var cursor = LiveReadingCursor()
        document.beginSession(detectsSpeakers: false, language: "en-US")
        document.receive([TimedText(text: "Hello", start: 0, end: 1)], isFinal: false)
        #expect(cursor.takeNew(from: document.finalizedParagraphs).isEmpty)
        document.receive([TimedText(text: "Hello world.", start: 0, end: 2)], isFinal: true)
        #expect(cursor.takeNew(from: document.finalizedParagraphs).map(\.text) == ["Hello world. "])
        #expect(cursor.takeNew(from: document.finalizedParagraphs).isEmpty)
    }

    @Test @MainActor func translationQueuesNewPhrasesAndStaysArmedWhileIdle() throws {
        let prefs = MemoryPreferences()
        let reader = TranscriptReader(playbackVolume: 0)
        let model = TranscriptionModel(preferences: prefs, reader: reader)
        model.language = "en-US"
        model.readingLanguage = .french
        model.beginReading(followCapture: true)
        #expect(model.isReadingEnabled)
        model.receiveTranscript([TimedText(text: "Hello.", start: 0, end: 1)], isFinal: true)
        let first = try #require(model.translationJob)
        model.receiveTranscript([TimedText(text: "Next sentence.", start: 2, end: 3)], isFinal: true)
        #expect(model.translationJob?.id == first.id)
        model.translationCompleted(id: first.id, result: .success(["Bonjour."]))
        #expect(reader.isReading)
        // Simulate playback completion, without playing test audio.
        reader.stop(); reader.onFinished?(true)
        let next = try #require(model.translationJob)
        #expect(next.texts == ["Next sentence. "])
        model.translationCompleted(id: next.id, result: .success(["Phrase suivante."]))
        reader.stop(); reader.onFinished?(true)
        #expect(model.isReadingEnabled)
        #expect(model.translationJob == nil)
        model.receiveTranscript([TimedText(text: "After a pause.", start: 10, end: 11)], isFinal: true)
        #expect(model.translationJob?.texts == ["After a pause. "])
        model.stopReading()
        model.receiveTranscript([TimedText(text: "Do not read.", start: 12, end: 13)], isFinal: true)
        #expect(!model.isReadingEnabled)
        #expect(model.translationJob == nil)
    }

    @Test func voiceAssignmentsRemainStableAcrossLiveBatches() throws {
        let voices = [ReadingVoice(identifier: "A", name: "A", language: "fr-FR", quality: 1),
                      ReadingVoice(identifier: "B", name: "B", language: "fr-FR", quality: 1)]
        let paragraph = TranscriptParagraph(id: 0, text: "Encore.", speaker: 2, hasSpeakerLabel: true)
        let result = try ReadingPlan.make(paragraphs: [paragraph], language: "fr-FR", voices: voices, knownSpeakerIDs: [1, 2])
        #expect(result.first?.voiceIdentifier == "B")
    }
}

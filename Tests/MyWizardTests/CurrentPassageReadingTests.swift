import Foundation
import Testing
@testable import MyWizard

struct CurrentPassageReadingTests {
    @MainActor private func withModel(_ body: (TranscriptionModel) throws -> Void) rethrows {
        let preferences = MemoryPreferences()
        let model = TranscriptionModel(preferences: preferences)
        model.language = "en-US"
        model.readingLanguage = .french
        defer {
            model.stopReading()
        }
        try body(model)
    }

    @Test @MainActor func startsAtLatestPassageNotEntireSingleSpeakerParagraph() {
        withModel { model in
            model.receiveTranscript([TimedText(text: "Old meeting history.", start: 0, end: 2)], isFinal: true)
            model.receiveTranscript([TimedText(text: "The current passage.", start: 3, end: 5)], isFinal: true)
            #expect(model.paragraphs.count == 1)
            model.beginReading(followCapture: true)
            #expect(model.translationJob?.texts == ["The current passage. "])
        }
    }

    @Test @MainActor func currentPartialStartsImmediatelyAndFinalDoesNotReplayIt() throws {
        try withModel { model in
            model.receiveTranscript([TimedText(text: "Already in the transcript.", start: 0, end: 2)], isFinal: true)
            model.receiveTranscript([TimedText(text: "This passage is current", start: 3, end: 4)], isFinal: false)
            model.beginReading(followCapture: true)
            let first = try #require(model.translationJob)
            #expect(first.texts == ["This passage is current"])
            #expect(model.isReadingEnabled)
            model.receiveTranscript([TimedText(text: "This passage is current.", start: 3, end: 6)], isFinal: true)
            model.receiveTranscript([TimedText(text: "And then the next phrase.", start: 7, end: 9)], isFinal: true)
            model.translationCompleted(id: first.id, result: .success(["La phrase corrigée."]))
            model.reader.stop(); model.reader.onFinished?(true)
            #expect(model.translationJob?.texts == ["And then the next phrase. "])
        }
    }

    @Test func provisionalGrowthCorrectionsAndFinalSuffixDoNotRepeatSpokenWords() {
        var cursor = LiveReadingCursor()
        func p(_ text: String, source: TranscriptSource = .systemAudio) -> [TranscriptParagraph] {
            [TranscriptParagraph(id: 0, text: text, speaker: 2, hasSpeakerLabel: true, source: source)]
        }
        #expect(cursor.takeProvisional(from: p("Hello world")).map(\.text) == ["Hello world"])
        #expect(cursor.takeProvisional(from: p("Hello, world!")).isEmpty)
        #expect(cursor.takeProvisional(from: p("Hello, world! Here we are")).map(\.text) == ["Here we are"])
        #expect(cursor.takeProvisional(from: p("Never read my microphone", source: .microphone)).isEmpty)
        #expect(cursor.takeFinalized(from: p("Hello, world! Here we are today. ")).map(\.text) == ["today. "])
        #expect(cursor.takeProvisional(from: p("The next passage")).map(\.text) == ["The next passage"])
        #expect(cursor.takeFinalized(from: p("Hello, world! Here we are today. The next passage. ")).isEmpty)
    }

    @Test @MainActor func busyPlaybackCollectsGrowingPreviewForNextBatchWithoutWaitingForFinal() throws {
        try withModel { model in
            model.receiveTranscript([TimedText(text: "A current passage", start: 0, end: 1)], isFinal: false)
            model.beginReading(followCapture: true)
            let first = try #require(model.translationJob)
            model.receiveTranscript([TimedText(text: "A current passage with more words", start: 0, end: 2)], isFinal: false)
            #expect(model.translationJob?.id == first.id)
            model.translationCompleted(id: first.id, result: .success(["Un passage en cours."]))
            model.reader.stop(); model.reader.onFinished?(true)
            #expect(model.translationJob?.texts == ["with more words"])
        }
    }

    @Test @MainActor func longPassageStartsWithShortBlockAndPreservesEveryRemainingCharacter() throws {
        try withModel { model in
            let text = String(repeating: "A complete sentence to translate. ", count: 30)
            model.receiveTranscript([TimedText(text: text, start: 0, end: 30)], isFinal: true)
            model.beginReading(followCapture: false)
            var received = ""
            var batches = 0
            while let job = model.translationJob {
                let block = try #require(job.texts.first)
                #expect(block.count <= 180)
                received += block
                batches += 1
                model.translationCompleted(id: job.id, result: .success(["Une phrase."]))
                model.reader.stop(); model.reader.onFinished?(true)
                if batches > 100 { Issue.record("Reading failed to drain"); break }
            }
            #expect(received == text + " ")
            #expect(batches > 1)
            #expect(!model.isReadingEnabled)
        }
    }

    @Test @MainActor func restartReturnsToLivePassageInsteadOfOldQueue() {
        withModel { model in
            model.receiveTranscript([TimedText(text: "First phrase.", start: 0, end: 2)], isFinal: true)
            model.beginReading(followCapture: true)
            model.receiveTranscript([TimedText(text: "An old queued phrase.", start: 3, end: 4)], isFinal: true)
            model.stopReading()
            model.receiveTranscript([TimedText(text: "Now we are here.", start: 5, end: 6)], isFinal: true)
            model.beginReading(followCapture: true)
            #expect(model.translationJob?.texts == ["Now we are here. "])
        }
    }

    @Test func archiveClearAndMicrophoneCannotMoveCursorBackToHistory() {
        var document = SpeakerTranscript()
        document.beginSession(detectsSpeakers: false, reservesOwnSpeaker: true)
        document.receive([TimedText(text: "An earlier session.", start: 0, end: 2)], isFinal: true)
        document.beginSession(detectsSpeakers: false, reservesOwnSpeaker: true)
        var cursor = LiveReadingCursor(startingAt: document.currentReadingStart)
        #expect(cursor.takeNew(from: document.finalizedParagraphs).isEmpty)
        document.receive([TimedText(text: "My own words must stay silent.", start: 0, end: 2)], isFinal: true, source: .microphone)
        #expect(cursor.takeNew(from: document.finalizedParagraphs).isEmpty)
        document.receive([TimedText(text: "New system phrase.", start: 3, end: 5)], isFinal: true)
        #expect(cursor.takeNew(from: document.finalizedParagraphs).map(\.text) == ["New system phrase. "])
        document.clear()
        #expect(document.currentReadingStart == 0)
    }

    @Test @MainActor func stoppedTranscriptUsesLatestPassage() {
        withModel { model in
            model.receiveTranscript([TimedText(text: "Old transcription.", start: 0, end: 2)], isFinal: true)
            model.receiveTranscript([TimedText(text: "Latest transcription.", start: 3, end: 4)], isFinal: true)
            model.beginReading(followCapture: false)
            #expect(model.translationJob?.texts == ["Latest transcription. "])
        }
    }
}

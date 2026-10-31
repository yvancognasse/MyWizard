import Foundation
import Testing
@testable import MyWizard

@MainActor
struct DisplayTranslationTests {
    @Test func regionalTargetsDoNotShareCachedOrInFlightTranslations() throws {
        let display = DisplayTranslation()
        let original = [paragraph("Hello.")]
        display.update(original, source: "en-US", target: .portuguesePortugal)
        display.startNextJob()
        let european = try #require(display.job)
        #expect(european.target == "pt-PT")
        display.update(original, source: "en-US", target: .portuguese)
        display.completed(id: european.id, result: .success(["Old regional result"]))
        #expect(display.paragraphs.isEmpty)
        display.startNextJob()
        let brazilian = try #require(display.job)
        #expect(brazilian.target == "pt")
        display.completed(id: brazilian.id, result: .success(["Olá."]))
        #expect(display.paragraphs.first?.text == "Olá.")
        #expect(original.first?.text == "Hello.")
    }

    func paragraph(_ text: String, speaker: Int = 2, source: TranscriptSource = .systemAudio) -> TranscriptParagraph {
        TranscriptParagraph(id: speaker, text: text, speaker: speaker, hasSpeakerLabel: true, language: "en-US", source: source)
    }

    @Test func translatesMicrophoneAndKeepsSpeakersAndSourceText() throws {
        let display = DisplayTranslation()
        let original = [paragraph("Hello."), paragraph("My answer.", speaker: 1, source: .microphone)]
        display.update(original, source: "en-US", target: .french)
        display.startNextJob()
        let job = try #require(display.job)
        #expect(job.texts == ["Hello.", "My answer."])
        display.completed(id: job.id, result: .success(["Bonjour.", "Ma réponse."]))
        #expect(display.paragraphs.map(\.text) == ["Bonjour.", "Ma réponse."])
        #expect(display.paragraphs.map(\.speaker) == [2, 1])
        #expect(display.paragraphs.last?.source == .microphone)
        #expect(!display.isPending)
        display.update(original, source: "en-US", target: .original)
        #expect(display.paragraphs == original)
        #expect(display.job == nil)
    }

    @Test func ignoresOldLanguageAndClearedResults() throws {
        let display = DisplayTranslation()
        display.update([paragraph("Hello.")], source: "en-US", target: .french)
        display.startNextJob()
        let old = try #require(display.job)
        display.update([paragraph("Hello.")], source: "en-US", target: .german)
        display.completed(id: old.id, result: .success(["Bonjour."]))
        #expect(display.paragraphs.isEmpty)
        display.startNextJob()
        let current = try #require(display.job)
        display.reset()
        display.update([], source: "en-US", target: .german)
        display.completed(id: current.id, result: .success(["Hallo."]))
        #expect(display.paragraphs.isEmpty)
    }

    @Test func revisionsKeepTranslatedSnapshotAndItsSpeakerUntilReplacementIsReady() throws {
        let display = DisplayTranslation()
        display.update([paragraph("Hello.")], source: "en-US", target: .french)
        display.startNextJob()
        let old = try #require(display.job)
        display.update([paragraph("Goodbye.", speaker: 3)], source: "en-US", target: .french)
        display.completed(id: old.id, result: .success(["Bonjour."]))
        #expect(display.paragraphs.first?.text == "Bonjour.")
        #expect(display.paragraphs.first?.speaker == 2)
        #expect(display.isPending)
        display.startNextJob()
        let next = try #require(display.job)
        display.completed(id: next.id, result: .success(["Au revoir."]))
        display.update([paragraph("Goodbye.", speaker: 4)], source: "en-US", target: .french)
        #expect(display.paragraphs.first?.text == "Au revoir.")
        #expect(display.paragraphs.first?.speaker == 4)
        #expect(!display.isPending)
    }

    @Test func failurePreservesOriginalAndCanRetry() throws {
        let display = DisplayTranslation()
        display.update([paragraph("Hello.")], source: "en-US", target: .french)
        display.startNextJob()
        let job = try #require(display.job)
        display.completed(id: job.id, result: .success([]))
        #expect(display.errorMessage != nil)
        #expect(display.paragraphs.isEmpty)
        display.retry()
        display.startNextJob()
        #expect(display.job != nil)
    }

    @Test func growingSpeechNeverFlashesSourceAndDoesNotStarveUpdates() throws {
        let display = DisplayTranslation()
        display.update([paragraph("Hello")], source: "en-US", target: .french)
        #expect(display.paragraphs.isEmpty)
        display.startNextJob()
        let first = try #require(display.job)
        display.update([paragraph("Hello everyone")], source: "en-US", target: .french)
        display.completed(id: first.id, result: .success(["Bonjour"]))
        #expect(display.paragraphs.first?.text == "Bonjour")
        #expect(display.isPending)
        display.startNextJob()
        let next = try #require(display.job)
        display.update([paragraph("Hello everyone today")], source: "en-US", target: .french)
        #expect(display.paragraphs.first?.text == "Bonjour")
        display.completed(id: next.id, result: .success(["Bonjour à tous"]))
        #expect(display.paragraphs.first?.text == "Bonjour à tous")
        display.startNextJob()
        let last = try #require(display.job)
        display.completed(id: last.id, result: .failure(TranscriptionError.message("Test failure")))
        #expect(display.paragraphs.first?.text == "Bonjour à tous")
        #expect(display.errorMessage != nil)
    }

    @Test func multiBatchSnapshotPublishesAtomicallyAndClearDiscardsIt() throws {
        let display = DisplayTranslation()
        let input = (2...10).map { paragraph("Sentence \($0)", speaker: $0) }
        display.update(input, source: "en-US", target: .french)
        display.startNextJob()
        let first = try #require(display.job)
        #expect(first.texts.count == 8)
        display.completed(id: first.id, result: .success((2...9).map { "Phrase \($0)" }))
        #expect(display.paragraphs.isEmpty)
        // No extra 450 ms pause between batches of the same frozen snapshot.
        #expect(display.job != nil)
        display.startNextJob()
        let last = try #require(display.job)
        display.completed(id: last.id, result: .success(["Phrase 10"]))
        #expect(display.paragraphs.map(\.text) == (2...10).map { "Phrase \($0)" })
        #expect(!display.isPending)
        display.reset()
        display.update([], source: "en-US", target: .french)
        #expect(display.paragraphs.isEmpty)
    }

    @Test func displaySettingPersistsIndependentlyOfReadingAndExport() throws {
        let prefs = MemoryPreferences()
        let model = TranscriptionModel(preferences: prefs)
        model.language = "en-US"
        model.displayLanguage = .french
        model.readingLanguage = .german
        model.receiveTranscript([TimedText(text: "Hello.", start: 0, end: 1)], isFinal: true)
        let original = model.transcript
        model.displayTranslation.startNextJob()
        let job = try #require(model.displayTranslation.job)
        model.displayTranslation.completed(id: job.id, result: .success(["Bonjour."]))
        #expect(model.transcript == original)
        #expect(model.displayTranslation.paragraphs.first?.text == "Bonjour.")
        let restored = TranscriptionModel(preferences: prefs)
        #expect(restored.displayLanguage == .french)
        #expect(restored.readingLanguage == .german)
    }

    @Test func obsoleteProvisionalTranslationsDoNotAccumulate() throws {
        let display = DisplayTranslation()
        for index in 0..<100 {
            display.update([paragraph("Revision \(index)")], source: "en-US", target: .french)
            display.startNextJob()
            let job = try #require(display.job)
            display.completed(id: job.id, result: .success(["Révision \(index)"]))
            #expect(display.cachedTranslationCount == 1)
        }
        #expect(display.paragraphs.first?.text == "Révision 99")
    }
}

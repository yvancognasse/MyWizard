import Foundation
import Testing
@testable import MyWizard

struct ReadingTranslationTests {
    @Test func translationJobsKeepRegionalChoicesAndChineseScriptsDistinct() throws {
        let french = [TranscriptParagraph(id: 0, text: "Bonjour", speaker: 1, hasSpeakerLabel: true, language: "fr-CA")]
        let british = ReadingTranslationPlan(paragraphs: french, fallbackSource: "fr-FR", target: "en-GB")
        #expect(british.jobs.first?.source == "fr-CA")
        #expect(british.jobs.first?.target == "en-GB")
        let chinese = [TranscriptParagraph(id: 0, text: "汉字", speaker: 1, hasSpeakerLabel: true, language: "zh-CN")]
        let traditional = ReadingTranslationPlan(paragraphs: chinese, fallbackSource: "zh-CN", target: "zh-TW")
        #expect(traditional.jobs.count == 1)
        #expect(traditional.jobs.first?.target == "zh-TW")
        let english = [TranscriptParagraph(id: 0, text: "Hello", speaker: 1, hasSpeakerLabel: true, language: "en-US")]
        let sameLanguage = ReadingTranslationPlan(paragraphs: english, fallbackSource: "en-US", target: "en-GB")
        #expect(sameLanguage.jobs.isEmpty)
        #expect(sameLanguage.paragraphs == english)
    }

    @Test func preservesSpeakersAndOriginalWhileTranslatingMixedSessions() throws {
        let original = [
            TranscriptParagraph(id: 0, text: "Bonjour.", speaker: 1, hasSpeakerLabel: true, language: "fr-FR"),
            TranscriptParagraph(id: 1, text: "Guten Tag.", speaker: 2, hasSpeakerLabel: true, language: "de-CH"),
            TranscriptParagraph(id: 2, text: "Hello.", speaker: 1, hasSpeakerLabel: true, language: "en-US")
        ]
        var plan = ReadingTranslationPlan(paragraphs: original, fallbackSource: "fr-FR", target: "en-US")
        #expect(Set(plan.jobs.map(\.source)) == ["fr", "de-CH"])
        #expect(plan.jobs.allSatisfy { $0.target == "en" })
        for job in plan.jobs { try plan.apply(["Good morning."], job: job) }
        #expect(plan.paragraphs.map(\.text) == ["Good morning.", "Good morning.", "Hello."])
        #expect(plan.paragraphs.map(\.speaker) == [1, 2, 1])
        #expect(plan.paragraphs.map(\.id) == [0, 1, 2])
        #expect(plan.paragraphs.allSatisfy { $0.hasSpeakerLabel })
        #expect(original[0].text == "Bonjour.")
    }

    @Test func sameLanguageNeedsNoTranslationAndSwissUsesGerman() {
        let paragraphs = [TranscriptParagraph(id: 0, text: "Guten Tag", speaker: nil, hasSpeakerLabel: false, language: "de-CH")]
        let plan = ReadingTranslationPlan(paragraphs: paragraphs, fallbackSource: "en-US", target: "de-DE")
        #expect(plan.jobs.isEmpty)
        #expect(plan.paragraphs == paragraphs)
    }

    @Test func incompleteTranslationsAreRejectedWithoutMutatingText() throws {
        let paragraphs = [TranscriptParagraph(id: 0, text: "Bonjour", speaker: nil, hasSpeakerLabel: false)]
        var plan = ReadingTranslationPlan(paragraphs: paragraphs, fallbackSource: "fr-FR", target: "en-US")
        let job = try #require(plan.jobs.first)
        #expect(throws: (any Error).self) { try plan.apply([], job: job) }
        #expect(throws: (any Error).self) { try plan.apply([" "], job: job) }
        #expect(plan.paragraphs == paragraphs)
    }

    @Test func sessionLanguageSurvivesArchivingAndReindexing() {
        var document = SpeakerTranscript()
        document.beginSession(detectsSpeakers: false, language: "fr-FR")
        document.receive([TimedText(text: "Bonjour", start: 0, end: 1)], isFinal: true)
        document.beginSession(detectsSpeakers: false, language: "de-CH")
        document.receive([TimedText(text: "Guten Tag", start: 0, end: 1)], isFinal: true)
        #expect(document.paragraphs.map(\.language) == ["fr-FR", "de-CH"])
    }

    @Test @MainActor func readingLanguageIsIndependentAndRemembered() throws {
        let preferences = MemoryPreferences()
        let model = TranscriptionModel(preferences: preferences)
        #expect(model.readingLanguage == .original)
        model.language = "de-CH"
        for language in ReadingLanguage.allCases {
            model.readingLanguage = language
            let restored = TranscriptionModel(preferences: preferences)
            #expect(restored.readingLanguage == language)
            #expect(restored.language == "de-CH")
        }
        model.stopReading()
        model.translationCompleted(id: UUID(), result: .success(["Stale reply"]))
        #expect(!model.reader.isReading)
        #expect(model.translationJob == nil)
        preferences.set("unknown", forKey: "readingLanguage")
        #expect(TranscriptionModel(preferences: preferences).readingLanguage == .original)
    }
}

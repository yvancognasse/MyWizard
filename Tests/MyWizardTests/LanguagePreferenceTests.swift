import AVFoundation
import Foundation
import Testing
@testable import MyWizard

struct LanguagePreferenceTests {
    @Test func regionalModelsCannotSilentlySwitchLanguageOrRegion() {
        #expect(TranscriptionLanguage.frenchSwitzerland.accepts(Locale(identifier: "fr_CH")))
        #expect(!TranscriptionLanguage.frenchSwitzerland.accepts(Locale(identifier: "fr-FR")))
        #expect(!TranscriptionLanguage.frenchSwitzerland.accepts(Locale(identifier: "de-CH")))
        #expect(TranscriptionLanguage.chineseTaiwan.accepts(Locale(identifier: "zh_TW")))
        #expect(!TranscriptionLanguage.chineseTaiwan.accepts(Locale(identifier: "zh-CN")))
        #expect(!TranscriptionLanguage.cantoneseChina.accepts(Locale(identifier: "zh-CN")))
        #expect(TranscriptionLanguage.cantoneseChina.accepts(Locale(identifier: "yue_CN")))
    }

    @Test func englishSpeechVariantsStayDistinct() {
        #expect(TranscriptionLanguage.englishUS.title == "English (US)")
        #expect(TranscriptionLanguage.englishUK.title == "English (UK)")
        #expect(TranscriptionLanguage.englishUS.accepts(Locale(identifier: "en-US")))
        #expect(!TranscriptionLanguage.englishUS.accepts(Locale(identifier: "en-GB")))
        #expect(TranscriptionLanguage.englishUK.accepts(Locale(identifier: "en-GB")))
        #expect(!TranscriptionLanguage.englishUK.accepts(Locale(identifier: "en-US")))
    }

    @Test @MainActor
    func obsoleteReadingSpeedPreferencesAreRemoved() throws {
        let preferences = MemoryPreferences()
        preferences.set(4, forKey: "readingSpeedLevel")
        preferences.set(1.5, forKey: "readingSpeed")
        preferences.set(false, forKey: "automaticReadingSpeed")
        _ = TranscriptionModel(preferences: preferences)
        #expect(preferences.object(forKey: "readingSpeedLevel") == nil)
        #expect(preferences.object(forKey: "readingSpeed") == nil)
        #expect(preferences.object(forKey: "automaticReadingSpeed") == nil)
    }

    @Test @MainActor
    func selectionSurvivesModelRecreation() throws {
        let preferences = MemoryPreferences()
        let first = TranscriptionModel(preferences: preferences)
        #expect(first.language == "fr-FR")
        first.language = "en-US"
        #expect(first.detectsSpeakers)
        preferences.set(false, forKey: "detectSpeakers")
        let second = TranscriptionModel(preferences: preferences)
        #expect(second.language == "en-US")
        second.language = "en-GB"
        #expect(TranscriptionModel(preferences: preferences).language == "en-GB")
        #expect(second.detectsSpeakers)
        #expect(preferences.object(forKey: "detectSpeakers") == nil)
        second.language = "fr-FR"
        #expect(TranscriptionModel(preferences: preferences).language == "fr-FR")
        for language in TranscriptionLanguage.allCases {
            second.language = language.rawValue
            #expect(TranscriptionModel(preferences: preferences).language == language.rawValue)
        }
        preferences.set("unknown", forKey: "transcriptionLanguage")
        #expect(TranscriptionModel(preferences: preferences).language == "fr-FR")
    }
}

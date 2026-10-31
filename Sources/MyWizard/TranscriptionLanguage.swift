import Foundation

// SpeechTranscriber locales verified on the target Mac. These are transcription
// models, independent of the languages supported by Apple Translation.
enum TranscriptionLanguage: String, CaseIterable {
    case cantoneseChina = "yue-CN"
    case chineseChina = "zh-CN"
    case chineseHongKong = "zh-HK"
    case chineseTaiwan = "zh-TW"
    case englishAustralia = "en-AU"
    case englishCanada = "en-CA"
    case englishIndia = "en-IN"
    case englishIreland = "en-IE"
    case englishNewZealand = "en-NZ"
    case englishSingapore = "en-SG"
    case englishSouthAfrica = "en-ZA"
    case englishUK = "en-GB"
    case englishUS = "en-US"
    case frenchBelgium = "fr-BE"
    case frenchCanada = "fr-CA"
    case french = "fr-FR"
    case frenchSwitzerland = "fr-CH"
    case germanAustria = "de-AT"
    case german = "de-DE"
    case germanSwitzerland = "de-CH"
    case italian = "it-IT"
    case italianSwitzerland = "it-CH"
    case japanese = "ja-JP"
    case korean = "ko-KR"
    case portugueseBrazil = "pt-BR"
    case portuguesePortugal = "pt-PT"
    case spanishChile = "es-CL"
    case spanishMexico = "es-MX"
    case spanish = "es-ES"
    case spanishUS = "es-US"

    var title: String {
        switch self {
        case .cantoneseChina: "Cantonese (China)"
        case .chineseChina: "Chinese (Mainland China)"
        case .chineseHongKong: "Chinese (Hong Kong)"
        case .chineseTaiwan: "Chinese (Taiwan)"
        case .englishAustralia: "English (Australia)"
        case .englishCanada: "English (Canada)"
        case .englishIndia: "English (India)"
        case .englishIreland: "English (Ireland)"
        case .englishNewZealand: "English (New Zealand)"
        case .englishSingapore: "English (Singapore)"
        case .englishSouthAfrica: "English (South Africa)"
        case .englishUK: "English (UK)"
        case .englishUS: "English (US)"
        case .frenchBelgium: "French (Belgium)"
        case .frenchCanada: "French (Canada)"
        case .french: "French (France)"
        case .frenchSwitzerland: "French (Switzerland)"
        case .germanAustria: "German (Austria)"
        case .german: "German (Germany)"
        case .germanSwitzerland: "German (Switzerland)"
        case .italian: "Italian (Italy)"
        case .italianSwitzerland: "Italian (Switzerland)"
        case .japanese: "Japanese (Japan)"
        case .korean: "Korean (South Korea)"
        case .portugueseBrazil: "Portuguese (Brazil)"
        case .portuguesePortugal: "Portuguese (Portugal)"
        case .spanishChile: "Spanish (Chile)"
        case .spanishMexico: "Spanish (Mexico)"
        case .spanish: "Spanish (Spain)"
        case .spanishUS: "Spanish (US)"
        }
    }

    // Never silently replace the selected regional model with a nearby locale.
    // Compare components so Apple's underscore identifiers match stored BCP-47 tags.
    func accepts(_ locale: Locale) -> Bool {
        let requested = Locale(identifier: rawValue)
        return locale.language.languageCode?.identifier == requested.language.languageCode?.identifier
            && locale.region?.identifier == requested.region?.identifier
    }
}

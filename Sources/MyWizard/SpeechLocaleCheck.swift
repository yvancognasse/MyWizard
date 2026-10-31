import Foundation
import Speech

// Opt-in check from the signed application. Opens no audio devices, processes
// no speech, and uses the user's actual selected regional language.
@MainActor
enum SpeechLocaleCheck {
    static func run() async throws {
        let language = UserDefaults.standard.string(forKey: "transcriptionLanguage") ?? "fr-CH"
        let before = await AssetInventory.reservedLocales.map(\.identifier)
        print("SPEECH LOCALE CHECK before: \(before), maximum: \(AssetInventory.maximumReservedLocales), requested: \(language)")
        guard let prepared = try await PreparedSpeech.load(language: language, downloads: true) else {
            throw TranscriptionError.message("The selected speech model was not prepared.")
        }
        print("SPEECH LOCALE CHECK prepared: \(prepared.transcriber.selectedLocales.map(\.identifier)), reservations: \(await AssetInventory.reservedLocales.map(\.identifier)), status: \(await AssetInventory.status(forModules: [prepared.transcriber]))")
        await prepared.close()
        // Warmup may decline when Apple's inventory reports assets as missing.
        // In that case Start must still succeed, without exceeding the limit.
        let warm = try await PreparedSpeech.load(language: language, downloads: false)
        let next: PreparedSpeech
        if let warm { next = warm }
        else if let foreground = try await PreparedSpeech.load(language: language, downloads: true) { next = foreground }
        else { throw TranscriptionError.message("The selected language could not be prepared again.") }
        await next.close()
        if let path = ProcessInfo.processInfo.environment["MYWIZARD_LOCALE_CHECK_AUDIO"] {
            let words = try await MeetingProcessor().transcribe(URL(fileURLWithPath: path), language: language)
            guard !words.isEmpty else { throw TranscriptionError.message("The synthetic speech fixture produced no text.") }
            print("SPEECH LOCALE CHECK export passed: \(words.count) text segments")
        }
        let after = await AssetInventory.reservedLocales.map(\.identifier)
        guard after.count <= AssetInventory.maximumReservedLocales else {
            throw TranscriptionError.message("The speech language reservation limit was exceeded.")
        }
        print("SPEECH LOCALE CHECK PASS after: \(after); selected model prepared twice; no audio devices opened")
    }
}

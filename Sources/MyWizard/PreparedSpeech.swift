import AVFoundation
import Speech

@MainActor
final class PreparedSpeech {
    let transcriber: SpeechTranscriber
    let analyzer: SpeechAnalyzer
    private var localeLease: SpeechLocaleReservations.Lease?
    let format: AVAudioFormat

    private init(transcriber: SpeechTranscriber, analyzer: SpeechAnalyzer, format: AVAudioFormat,
                 localeLease: SpeechLocaleReservations.Lease) {
        self.transcriber = transcriber
        self.analyzer = analyzer
        self.format = format
        self.localeLease = localeLease
    }

    func close() async {
        await analyzer.cancelAndFinishNow()
        if let lease = localeLease {
            localeLease = nil
            await SpeechLocaleReservations.shared.end(lease)
        }
    }

    static func load(language: String, downloads: Bool,
                     status: @escaping @MainActor (String) -> Void = { _ in }) async throws -> PreparedSpeech? {
        guard SpeechTranscriber.isAvailable else {
            throw TranscriptionError.message("Apple's transcription engine is not available on this Mac.")
        }
        let locale: Locale?
        if let selected = TranscriptionLanguage(rawValue: language) {
            // Prefer the advertised exact regional locale; equivalentTo can
            // resolve to a nearby model even when the selected region is listed.
            locale = await SpeechTranscriber.supportedLocales.first(where: selected.accepts)
        } else {
            locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: language))
        }
        guard let locale else {
            throw TranscriptionError.message("This language is not supported by Apple's transcription engine. Choose another language.")
        }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults], attributeOptions: [.audioTimeRange])
        // Checking status is read-only; asking for an installation can reserve
        // another locale even when speculative preparation will be abandoned.
        let assetStatus = await AssetInventory.status(forModules: [transcriber])
        if !downloads, assetStatus != .installed { return nil }
        guard let lease = try await SpeechLocaleReservations.shared.acquire(locale, allowsEviction: downloads) else { return nil }
        do {
            if assetStatus != .installed,
               let installation = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                guard downloads else {
                    await SpeechLocaleReservations.shared.end(lease)
                    return nil
                }
                status("Downloading the Apple speech model…")
                let progressTask = Task { @MainActor in
                    while !Task.isCancelled {
                        status("Downloading the Apple speech model: \(Int(installation.progress.fractionCompleted * 100))%")
                        do { try await Task.sleep(for: .seconds(1)) } catch { return }
                    }
                }
                defer { progressTask.cancel() }
                try await installation.downloadAndInstall()
            }
            try Task.checkCancellation()
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
                throw TranscriptionError.message("No audio format is available for transcription.")
            }
            status("Loading the Apple speech model…")
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            do {
                try await analyzer.prepareToAnalyze(in: format)
                try Task.checkCancellation()
                return PreparedSpeech(transcriber: transcriber, analyzer: analyzer, format: format, localeLease: lease)
            } catch {
                await analyzer.cancelAndFinishNow()
                throw error
            }
        } catch {
            await SpeechLocaleReservations.shared.end(lease)
            throw error
        }
    }
}

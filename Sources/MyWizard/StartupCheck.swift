import Foundation

// Opt-in signed-app check. Loads the real engines but never opens an audio
// device. It also exercises speaker reset using generated silence only.
@MainActor
enum StartupCheck {
    static func run() async throws {
        let detector = SpeakerDetection()
        let cache = StartupPreparation<PreparedSpeech>(discard: { prepared in
            await prepared.close()
        })
        let language = "fr-FR"
        let load: StartupPreparation<PreparedSpeech>.Loader = { downloads in
            try await PreparedSpeech.load(language: language, downloads: downloads)
        }
        let began = ProcessInfo.processInfo.systemUptime
        cache.warm(key: language, load: load)
        let speakers = Task { try await detector.preload() }
        guard let speech = try await cache.take(key: language, load: load) else {
            throw TranscriptionError.message("Startup check could not prepare Apple speech.")
        }
        try await speakers.value
        let cold = ProcessInfo.processInfo.systemUptime - began
        try await detector.prepare()
        _ = try await detector.process([Float](repeating: 0, count: 32_000))
        _ = try await detector.finish()
        let resetBegan = ProcessInfo.processInfo.systemUptime
        try await detector.prepare()
        let resetDuration = ProcessInfo.processInfo.systemUptime - resetBegan
        let empty = try await detector.finish()
        guard empty.intervals.isEmpty, empty.processedThrough == 0 else {
            throw TranscriptionError.message("Speaker reset retained a previous session's timeline.")
        }
        await speech.close()
        let warmBegan = ProcessInfo.processInfo.systemUptime
        cache.warm(key: language, load: load)
        guard let fresh = try await cache.take(key: language, load: load) else {
            throw TranscriptionError.message("Startup check could not prepare the next session.")
        }
        guard fresh.analyzer !== speech.analyzer else {
            throw TranscriptionError.message("Startup check reused a consumed Apple analyzer.")
        }
        let nextSpeech = ProcessInfo.processInfo.systemUptime - warmBegan
        await fresh.close()
        print("STARTUP CHECK PASS: parallel preparation=\(cold)s, retained speaker reset=\(resetDuration)s, next Apple preparation=\(nextSpeech)s; no audio devices opened")
    }
}

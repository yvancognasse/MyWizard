import Speech

enum SpeechAuthorization {
    typealias Reply = @Sendable (SFSpeechRecognizerAuthorizationStatus) -> Void
    typealias Provider = @Sendable (@escaping Reply) -> Void

    // The callback itself must be nonisolated. A Task inside an actor-isolated
    // callback is too late: Swift checks isolation before entering its body.
    nonisolated static func request(
        using provider: Provider = { reply in
            SFSpeechRecognizer.requestAuthorization(reply)
        }
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            provider { @Sendable status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }
}

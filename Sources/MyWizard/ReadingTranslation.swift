import Foundation
import SwiftUI
// Apple's session is not annotated Sendable in this SDK. It remains owned and
// used sequentially by one SwiftUI translation task; it is never stored/shared.
@preconcurrency import Translation

struct ReadingTranslationJob: Identifiable {
    let id = UUID()
    let source: String
    let target: String
    let indices: [Int]
    let texts: [String]
}

struct ReadingTranslationPlan {
    var paragraphs: [TranscriptParagraph]
    let jobs: [ReadingTranslationJob]

    init(paragraphs: [TranscriptParagraph], fallbackSource: String, target: String) {
        let paragraphs = paragraphs.filter(\.canReadAloud)
        self.paragraphs = paragraphs
        let targetCode = Self.translationIdentifier(target)
        let groups = Dictionary(grouping: paragraphs.indices) {
            Self.translationIdentifier(paragraphs[$0].language ?? fallbackSource)
        }
        jobs = groups.keys.sorted().filter { Self.requiresTranslation(from: $0, to: targetCode) }.map { source in
            let indices = groups[source]!
            return ReadingTranslationJob(source: source, target: targetCode,
                indices: indices, texts: indices.map { paragraphs[$0].text })
        }
    }

    static func baseLanguage(_ locale: String) -> String {
        Locale(identifier: locale).language.languageCode?.identifier ?? locale
    }

    static func translationIdentifier(_ locale: String) -> String {
        Locale.Language(identifier: locale.replacingOccurrences(of: "_", with: "-")).minimalIdentifier
    }

    // Same-language regional choices select the requested reading voice but do
    // not ask Apple for unsupported dialect rewriting. Script changes (notably
    // Simplified versus Traditional Chinese) must not be skipped as identical.
    static func requiresTranslation(from source: String, to target: String) -> Bool {
        let sourceLanguage = Locale.Language(identifier: Locale.Language(identifier: source).maximalIdentifier)
        let targetLanguage = Locale.Language(identifier: Locale.Language(identifier: target).maximalIdentifier)
        return sourceLanguage.languageCode != targetLanguage.languageCode
            || sourceLanguage.script != targetLanguage.script
    }

    mutating func apply(_ translated: [String], job: ReadingTranslationJob) throws {
        guard translated.count == job.indices.count,
              translated.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw TranscriptionError.message("Translation returned incomplete text. Please try again.")
        }
        for (index, text) in zip(job.indices, translated) { paragraphs[index].text = text }
    }
}

// Bound to the visible window so Apple can present model-download consent.
// Each job contains one source language; archived sessions can have different languages.
struct ReadingTranslationTask: View {
    let job: ReadingTranslationJob
    let complete: @MainActor (UUID, Result<[String], Error>) -> Void

    var body: some View {
        Color.clear.frame(width: 1, height: 1)
            .translationTask(source: Locale.Language(identifier: job.source),
                             target: Locale.Language(identifier: job.target)) { session in
                do {
                    let status = await LanguageAvailability().status(
                        from: Locale.Language(identifier: job.source), to: Locale.Language(identifier: job.target))
                    guard status != .unsupported else {
                        throw TranscriptionError.message("This language pair is not supported by Apple Translation on this Mac.")
                    }
                    try await session.prepareTranslation()
                    var translations: [String] = []
                    // Sequential requests preserve speaker order and bound per-request size.
                    for text in job.texts {
                        var chunks: [String] = []
                        for chunk in TranscriptReader.chunks(text, limit: 2000) {
                            try Task.checkCancellation()
                            let response = try await session.translate(chunk)
                            chunks.append(response.targetText)
                        }
                        translations.append(chunks.joined(separator: " "))
                    }
                    try Task.checkCancellation()
                    complete(job.id, .success(translations))
                } catch {
                    complete(job.id, .failure(error))
                }
            }
    }
}

// Signed-app integration check with synthetic text only. Uses the same SwiftUI
// session/download flow as the actual read button, without speaking or recording.
struct ReadingTranslationCheck: View {
    private let job = ReadingTranslationJob(source: "fr", target: "en", indices: [0],
        texts: ["Bonjour, la réunion commence maintenant."])
    var body: some View {
        Text("Testing Apple Translation with a sample sentence…")
            .padding(24)
            .background {
                ReadingTranslationTask(job: job) { _, result in
                    switch result {
                    case let .success(texts):
                        print("TRANSLATION CHECK PASS: \(texts)")
                        exit(EXIT_SUCCESS)
                    case let .failure(error):
                        print("TRANSLATION CHECK FAILED: \(error)")
                        exit(EXIT_FAILURE)
                    }
                }
            }
    }
}

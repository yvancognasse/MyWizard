import Combine
import Foundation

// Translation is a presentation layer: recognition, speaker alignment and
// read-aloud cursors always use the untouched source document.
@MainActor
final class DisplayTranslation: ObservableObject {
    struct Key: Hashable {
        let text: String
        let source: String
        let target: String
        var needsTranslation: Bool {
            ReadingTranslationPlan.requiresTranslation(from: source, to: target)
        }
    }

    @Published private(set) var paragraphs: [TranscriptParagraph] = []
    @Published private(set) var job: ReadingTranslationJob?
    @Published private(set) var isPending = false
    @Published private(set) var errorMessage: String?
    private var original: [TranscriptParagraph] = []
    private var target: ReadingLanguage = .original
    private var fallbackSource = "fr-FR"
    private var cache: [Key: String] = [:]
    private var activeKeys: [Key] = []
    private var translatingSnapshot: [TranscriptParagraph]?
    private var debounce: Task<Void, Never>?
    var cachedTranslationCount: Int { cache.count }

    func update(_ paragraphs: [TranscriptParagraph], source: String, target: ReadingLanguage) {
        if self.target != target {
            reset()
        }
        self.original = paragraphs
        self.fallbackSource = source
        self.target = target
        render()
        schedule()
    }

    func reset() {
        debounce?.cancel()
        debounce = nil
        job = nil
        activeKeys = []
        cache = [:]
        translatingSnapshot = nil
        paragraphs = []
        errorMessage = nil
        isPending = false
    }

    func retry() {
        errorMessage = nil
        schedule()
    }

    private func keys(for paragraph: TranscriptParagraph) -> [Key] {
        let source = ReadingTranslationPlan.translationIdentifier(paragraph.language ?? fallbackSource)
        let target = ReadingTranslationPlan.translationIdentifier(target.rawValue)
        // Stable full chunks are reused while only the provisional tail changes.
        return TranscriptReader.chunks(paragraph.text, limit: 400).map {
            Key(text: $0, source: source, target: target)
        }
    }

    private func render() {
        if target == .original {
            if paragraphs != original { paragraphs = original }
            isPending = false
            return
        }
        if let latest = translated(original) {
            if paragraphs != latest { paragraphs = latest }
            translatingSnapshot = nil
            isPending = false
        } else {
            isPending = true
            // Publish a complete translated snapshot, including its speaker
            // labels. Never substitute source text during live revisions.
            // Finish the in-flight snapshot even if recognition has advanced,
            // so continuous speech cannot starve display updates.
            if let snapshot = translatingSnapshot, let ready = translated(snapshot) {
                if paragraphs != ready { paragraphs = ready }
                translatingSnapshot = nil
            }
        }
    }

    private func translated(_ snapshot: [TranscriptParagraph]) -> [TranscriptParagraph]? {
        var result: [TranscriptParagraph] = []
        for paragraph in snapshot {
            let chunks = keys(for: paragraph)
            guard chunks.allSatisfy({ !$0.needsTranslation || cache[$0] != nil }) else { return nil }
            var translated = paragraph
            translated.text = chunks.map { !$0.needsTranslation ? $0.text : cache[$0]! }.joined(separator: " ")
            translated.language = target.rawValue
            result.append(translated)
        }
        return result
    }

    private func schedule() {
        guard target != .original, job == nil, debounce == nil, errorMessage == nil, isPending else { return }
        // An already-frozen snapshot needs no further coalescing. Drain its
        // remaining batches immediately; debounce only new recognition revisions.
        if translatingSnapshot != nil {
            startNextJob()
            return
        }
        debounce = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(450)) } catch { return }
            guard let self else { return }
            self.debounce = nil
            self.startNextJob()
        }
    }

    func startNextJob() {
        guard target != .original, job == nil, errorMessage == nil else { return }
        debounce?.cancel()
        debounce = nil
        if translatingSnapshot == nil { translatingSnapshot = original }
        let missing = (translatingSnapshot ?? []).flatMap { keys(for: $0) }.filter { $0.needsTranslation && cache[$0] == nil }
        guard let first = missing.first else { render(); return }
        var seen = Set<Key>()
        activeKeys = Array(missing.filter { $0.source == first.source && seen.insert($0).inserted }.prefix(8))
        job = ReadingTranslationJob(source: first.source, target: first.target,
            indices: Array(activeKeys.indices), texts: activeKeys.map(\.text))
    }

    func completed(id: UUID, result: Result<[String], Error>) {
        guard job?.id == id else { return }
        do {
            let texts = try result.get()
            guard texts.count == activeKeys.count,
                  texts.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                throw TranscriptionError.message("Translation returned incomplete text.")
            }
            for (key, text) in zip(activeKeys, texts) { cache[key] = text }
        } catch {
            errorMessage = "Display translation paused. Original text is preserved. \(error.localizedDescription)"
        }
        job = nil
        activeKeys = []
        render()
        // Drop obsolete provisional translations, retaining stable chunks and
        // every chunk still needed by the current/in-flight snapshot.
        let retained = Set((original + (translatingSnapshot ?? [])).flatMap { keys(for: $0) })
        cache = cache.filter { retained.contains($0.key) }
        schedule()
    }
}

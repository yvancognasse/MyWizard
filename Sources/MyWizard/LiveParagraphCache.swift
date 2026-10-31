import Foundation

// Value semantics keep periodic backup copies independent of live mutations.
// Reuse finalized paragraphs, rebuilding from a paragraph boundary whenever
// diarization revises the past. Provisional recognition never enters this cache.
struct LiveParagraphCache: Sendable {
    private struct Entry: Sendable {
        var paragraph: TranscriptParagraph
        let firstWord: Int
        var latestEnd: Double
    }
    private var entries: [Entry] = []
    private var processed = 0

    mutating func invalidate(from time: Double) {
        guard let index = entries.firstIndex(where: { $0.latestEnd > time }) else { return }
        processed = entries[index].firstWord
        entries.removeSubrange(index...)
    }

    mutating func update(committed: [TimedText], provisional: [TimedText],
                         hasLabels: Bool, language: String?,
                         speaker: (TimedText) -> Int?) -> [TranscriptParagraph] {
        for index in processed..<committed.count {
            Self.append(committed[index], at: index, to: &entries,
                   hasLabels: hasLabels, language: language, speaker: speaker)
        }
        processed = committed.count
        var visible = entries
        for (index, word) in provisional.enumerated() {
            Self.append(word, at: processed + index, to: &visible,
                   hasLabels: hasLabels, language: language, speaker: speaker)
        }
        return visible.map(\.paragraph)
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .enumerated().map { index, paragraph in
                TranscriptParagraph(id: index, text: paragraph.text, speaker: paragraph.speaker,
                    hasSpeakerLabel: paragraph.hasSpeakerLabel, language: paragraph.language)
            }
    }

    private static func append(_ word: TimedText, at index: Int, to entries: inout [Entry],
                        hasLabels: Bool, language: String?, speaker: (TimedText) -> Int?) {
        let number = speaker(word)
        if let last = entries.last, last.paragraph.speaker == number {
            entries[entries.count - 1].paragraph.text += word.text
            entries[entries.count - 1].latestEnd = max(last.latestEnd, word.end)
        } else {
            entries.append(Entry(paragraph: TranscriptParagraph(id: entries.count,
                text: word.text, speaker: number, hasSpeakerLabel: hasLabels, language: language),
                firstWord: index, latestEnd: word.end))
        }
    }
}

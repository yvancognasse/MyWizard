import Foundation

// Counts characters in finalized text, not paragraph IDs, because diarization
// may regroup paragraphs after words have already been queued for reading.
struct LiveReadingCursor {
    private(set) var consumedCharacters = 0
    private var provisionalWordsRead = 0

    init(startingAt characterOffset: Int = 0) {
        consumedCharacters = max(0, characterOffset)
    }

    mutating func takeNew(from paragraphs: [TranscriptParagraph]) -> [TranscriptParagraph] {
        let paragraphs = paragraphs.filter(\.canReadAloud)
        var skip = consumedCharacters
        var output: [TranscriptParagraph] = []
        for paragraph in paragraphs {
            let count = paragraph.text.count
            if skip >= count { skip -= count; continue }
            var part = paragraph
            part.text = String(part.text.dropFirst(skip))
            skip = 0
            if !part.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { output.append(part) }
        }
        consumedCharacters = paragraphs.reduce(0) { $0 + $1.text.count }
        return output
    }

    // Speak the visible hypothesis without waiting for a potentially very late
    // final result. Track words, not characters: punctuation/spelling revisions
    // must not make the already spoken prefix start again.
    mutating func takeProvisional(from paragraphs: [TranscriptParagraph]) -> [TranscriptParagraph] {
        let readable = paragraphs.filter(\.canReadAloud)
        let output = Self.droppingWords(provisionalWordsRead, from: readable)
        provisionalWordsRead = max(provisionalWordsRead, Self.wordCount(readable))
        return output
    }

    mutating func takeFinalized(from paragraphs: [TranscriptParagraph]) -> [TranscriptParagraph] {
        let fresh = takeNew(from: paragraphs)
        let output = Self.droppingWords(provisionalWordsRead, from: fresh)
        provisionalWordsRead = 0
        return output
    }

    private static func wordCount(_ paragraphs: [TranscriptParagraph]) -> Int {
        paragraphs.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count }
    }

    private static func droppingWords(_ count: Int, from paragraphs: [TranscriptParagraph]) -> [TranscriptParagraph] {
        var skip = count
        return paragraphs.compactMap { paragraph in
            guard skip > 0 else { return paragraph }
            let words = paragraph.text.split(whereSeparator: \.isWhitespace)
            if words.count <= skip { skip -= words.count; return nil }
            var suffix = paragraph
            suffix.text = String(paragraph.text[words[skip].startIndex...])
            skip = 0
            return suffix
        }
    }
}

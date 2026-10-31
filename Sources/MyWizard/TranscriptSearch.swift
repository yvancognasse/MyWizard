import Foundation

struct TranscriptSearchMatch: Equatable, Identifiable {
    let paragraphID: Int
    let location: Int
    let length: Int
    var id: String { "\(paragraphID):\(location):\(length)" }
}

enum TranscriptSearch {
    static func matches(_ query: String, in paragraphs: [TranscriptParagraph]) -> [TranscriptSearchMatch] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        return paragraphs.flatMap { paragraph -> [TranscriptSearchMatch] in
            let text = paragraph.text.trimmingCharacters(in: .whitespacesAndNewlines)
            var matches: [TranscriptSearchMatch] = []
            var start = text.startIndex
            while start < text.endIndex,
                  let range = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive],
                                         range: start..<text.endIndex) {
                let nsRange = NSRange(range, in: text)
                matches.append(.init(paragraphID: paragraph.id, location: nsRange.location, length: nsRange.length))
                start = range.upperBound
            }
            return matches
        }
    }
}

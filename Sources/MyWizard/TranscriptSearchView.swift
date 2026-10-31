import SwiftUI

struct SearchableTranscriptText: View {
    let text: String
    let matches: [TranscriptSearchMatch]
    let selected: String?
    let fontSize: Double

    var body: some View {
        let value = highlighted
        VStack(alignment: .leading, spacing: 0) {
            if let match = matches.first(where: { $0.id == selected }),
               let range = Range(NSRange(location: match.location, length: match.length),
                                 in: text.trimmingCharacters(in: .whitespacesAndNewlines)),
               let split = AttributedString.Index(range.lowerBound, within: value) {
                if split > value.startIndex { Text(AttributedString(value[..<split])) }
                // An occurrence can be inside a very long paragraph. Anchor
                // its exact position, rather than scrolling to the paragraph.
                Text(AttributedString(value[split...])).id("search-result-\(match.id)")
            } else { Text(value) }
        }
        .font(.system(size: fontSize, weight: .medium, design: .rounded))
        .textSelection(.enabled)
    }

    private var highlighted: AttributedString {
        let plain = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var result = AttributedString(plain)
        for match in matches {
            guard let range = Range(NSRange(location: match.location, length: match.length), in: plain),
                  let start = AttributedString.Index(range.lowerBound, within: result),
                  let end = AttributedString.Index(range.upperBound, within: result) else { continue }
            result[start..<end].backgroundColor = match.id == selected ? Color.orange.opacity(0.65) : Color.yellow.opacity(0.4)
            result[start..<end].foregroundColor = .black
        }
        return result
    }
}

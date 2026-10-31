import Foundation

// Presentation-only echo heuristic. Never changes the recognition tracks or
// audio devices. Matches require content AND capture time; isolated short
// answers and unmatched words remain intact. Identical simultaneous speech is
// ambiguous. Original recognition tracks are retained independently.
enum MicrophoneDuplicateFilter {
    struct Token: Sendable {
        let key: String
        let word: TimedText
    }

    private static let expression = try! NSRegularExpression(pattern: #"[\p{L}\p{N}]+(?:['’][\p{L}\p{N}]+)*"#)
    private static let qualifiers: Set<String> = ["no", "not", "never", "dont", "isnt", "cannot", "cant", "disagree",
        "non", "ne", "pas", "jamais", "nicht", "nein", "kein", "keine"]
    private static let shortReplies: Set<String> = ["yes", "yeah", "yep", "ok", "okay", "oui", "ouais", "daccord", "merci", "thanks", "ja", "danke"]

    static func isProtectedReply(_ key: String) -> Bool {
        qualifiers.contains(key) || shortReplies.contains(key) || key.contains(where: \.isNumber)
    }

    static func microphone(_ microphone: [TimedText], excludingEchoOf system: [TimedText],
                           matchesCompactPassages: Bool = false) -> [TimedText] {
        guard !system.isEmpty, !microphone.isEmpty else { return microphone }
        return filter(microphone, reference: tokens(system), input: tokens(microphone), matchesCompactPassages: matchesCompactPassages)
    }

    static func filter(_ microphone: [TimedText], reference: [Token], input: [Token],
                       matchesCompactPassages: Bool = false) -> [TimedText] {
        let reference = reference.sorted { $0.word.start < $1.word.start }
        let input = input.sorted { $0.word.start < $1.word.start }
        guard reference.count >= 2, input.count >= 2 else { return microphone }
        let positions = Dictionary(grouping: reference.indices, by: { reference[$0].key })
        var removed = Set<Int>()
        // Echo recognition often contains substitutions that break every long
        // exact phrase into short fragments. Match sustained time-aligned runs
        // and their small internal recognition substitutions as one echo passage.
        // Independent replies, numbers and objections must survive that passage.
        var anchors: [(input: Int, reference: Int)] = []
        func flushAnchors() {
            guard let first = anchors.first, let last = anchors.last else { return }
            let density = Double(anchors.count) / Double(last.input - first.input + 1)
            let sustained = anchors.count >= 8 && density >= 0.65
            // Export only: a shorter echo may contain a missed article or a
            // recognition substitution. Require denser anchors and a compact
            // time span, not a lower bar for arbitrary short microphone replies.
            let compact = matchesCompactPassages && anchors.count >= 6 && density >= 0.75
                && input[last.input].word.end - input[first.input].word.start <= 6
                && zip(anchors, anchors.dropFirst()).allSatisfy { $1.input - $0.input <= 3 }
            guard sustained || compact,
                  anchors.reduce(0, { $0 + input[$1.input].key.count }) >= 28 else { return }
            let matched = Set(anchors.map(\.input))
            let qualified = (max(0, first.input - 2)..<min(input.count, last.input + 3)).contains {
                !matched.contains($0) && qualifiers.contains(input[$0].key)
            }
            guard !qualified else { return }
            removed.formUnion(matched)
            for pair in zip(anchors, anchors.dropFirst()) {
                let gap = (pair.0.input + 1)..<pair.1.input
                guard !gap.isEmpty, gap.count <= 4,
                      pair.1.reference - pair.0.reference <= 8 else { continue }
                let protected = gap.contains { i in
                    qualifiers.contains(input[i].key) || shortReplies.contains(input[i].key)
                    || input[i].key.contains(where: \.isNumber)
                }
                if !protected { removed.formUnion(gap) }
            }
            // A recognizer can begin an echo passage with the truncated end of
            // the preceding remote word. Only extend an already well-matched
            // passage when that suffix is present at the same audio time.
            for index in max(0, first.input - 2)..<first.input {
                let prefix = index..<first.input
                guard !prefix.contains(where: {
                    qualifiers.contains(input[$0].key) || shortReplies.contains(input[$0].key)
                    || input[$0].key.contains(where: \.isNumber)
                }) else { continue }
                let fragment = input[index]
                guard fragment.key.count >= 3 else { continue }
                let matchesSuffix = reference[max(0, first.reference - 3)..<first.reference].contains { remote in
                    remote.key.count >= fragment.key.count + 3 && remote.key.hasSuffix(fragment.key)
                    && remote.word.start <= fragment.word.end + 0.35 && remote.word.end >= fragment.word.start - 0.35
                }
                if matchesSuffix { removed.formUnion(prefix) }
            }
        }
        for (index, token) in input.enumerated() {
            let candidates = positions[token.key] ?? []
            var low = 0, high = candidates.count
            while low < high {
                let middle = (low + high) / 2
                if reference[candidates[middle]].word.end < token.word.start - 1 { low = middle + 1 }
                else { high = middle }
            }
            let candidate = candidates[low...].prefix { reference[$0].word.start <= token.word.end + 0.35 }
                .min { abs(reference[$0].word.start - token.word.start) < abs(reference[$1].word.start - token.word.start) }
            guard let candidate, !token.key.isEmpty else { continue }
            if let last = anchors.last,
               index - last.input > 5 || candidate <= last.reference || candidate - last.reference > 8
                || token.word.start - input[last.input].word.end > 6
                || (index > 0 && token.word.start - input[index - 1].word.end > 1.5) {
                flushAnchors()
                anchors = []
            }
            anchors.append((index, candidate))
        }
        flushAnchors()
        var index = 0
        while index < input.count {
            let token = input[index]
            let candidates = positions[token.key] ?? []
            // Lists are time-ordered; inspect only a bounded acoustic-delay
            // window, not every occurrence of common words in a long meeting.
            var lower = 0
            var upper = candidates.count
            while lower < upper {
                let middle = (lower + upper) / 2
                if reference[candidates[middle]].word.start < token.word.start - 1.0 { lower = middle + 1 }
                else { upper = middle }
            }
            var longest = 0
            for candidate in candidates[lower...] {
                if reference[candidate].word.start > token.word.start + 0.35 { break }
                var count = 0
                var letters = 0
                while index + count < input.count, candidate + count < reference.count {
                    let own = input[index + count]
                    let other = reference[candidate + count]
                    let delay = own.word.start - other.word.start
                    guard !own.key.isEmpty, own.key == other.key, delay >= -0.35, delay <= 1.0 else { break }
                    letters += own.key.count
                    count += 1
                }
                // Do not turn a partly matching objection into a lone "not".
                // Nearby unmatched negations protect the accompanying phrase.
                let nearby = max(0, index - 2)..<min(input.count, index + count + 2)
                let qualified = nearby.contains { position in
                    !(index..<(index + count)).contains(position) && qualifiers.contains(input[position].key)
                }
                if !qualified && ((count >= 4 && letters >= 10) || (count >= 3 && letters >= 14) || (count >= 2 && letters >= 16)) {
                    longest = max(longest, count)
                }
            }
            if longest > 0 {
                removed.formUnion(index..<(index + longest))
                index += longest
            } else { index += 1 }
        }
        guard !removed.isEmpty else { return microphone }
        return input.enumerated().compactMap { removed.contains($0.offset) ? nil : $0.element.word }
    }

    static func tokens(_ words: [TimedText]) -> [Token] {
        words.sorted { $0.start < $1.start }.flatMap { word -> [Token] in
            guard word.start.isFinite, word.end.isFinite, word.end >= word.start else { return [Token(key: "", word: word)] }
            let matches = expression.matches(in: word.text, range: NSRange(word.text.startIndex..., in: word.text))
            guard !matches.isEmpty else { return [Token(key: "", word: word)] }
            return matches.enumerated().compactMap { index, match in
                guard let range = Range(match.range, in: word.text) else { return nil }
                let start = index == 0 ? word.text.startIndex : range.lowerBound
                let end = index + 1 < matches.count
                    ? Range(matches[index + 1].range, in: word.text)!.lowerBound : word.text.endIndex
                var key = String(word.text[range]).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                    .replacingOccurrences(of: "’", with: "'")
                // Elided French articles differ frequently between the two
                // recognitions (l'exploitation / d'exploitation). Match their
                // content word, without changing exported spelling/punctuation.
                if key.hasPrefix("l'") || key.hasPrefix("d'") { key = String(key.dropFirst(2)) }
                key = key.replacingOccurrences(of: "'", with: "")
                let duration = (word.end - word.start) / Double(matches.count)
                return Token(key: key, word: TimedText(text: String(word.text[start..<end]),
                    start: word.start + duration * Double(index), end: word.start + duration * Double(index + 1), source: word.source))
            }
        }
    }
}

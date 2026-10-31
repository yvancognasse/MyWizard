import Foundation

struct MicrophoneEchoFrame: Codable, Sendable {
    let start: Double
    let end: Double
    let correlation: Double
    let residualRatio: Double
    let referencePower: Double
}

// Export-only second opinion for orphan words. Audio correspondence alone is
// insufficient: require a surrounding phrase recognized on both tracks too.
enum MicrophoneEchoContext {
    private struct ReferenceRanges {
        let spans: [(start: Double, end: Double)]
        let maximumEnds: [Double]

        init(_ values: [(String, Double, Double)]) {
            spans = values.map { ($0.1, $0.2) }.sorted { $0.start < $1.start }
            var maximum = -Double.infinity
            maximumEnds = spans.map { maximum = max(maximum, $0.end); return maximum }
        }

        func overlaps(_ word: TimedText) -> Bool {
            var low = 0, high = spans.count
            while low < high {
                let middle = (low + high) / 2
                if maximumEnds[middle] < word.start - 0.75 { low = middle + 1 }
                else { high = middle }
            }
            return spans[low...].prefix { $0.start <= word.end + 0.75 }
                .contains { $0.end >= word.start - 0.75 }
        }
    }

    static func filter(_ remaining: [TimedText], recognition: [TimedText], reference: [TimedText],
                       frames: [MicrophoneEchoFrame]) -> [TimedText] {
        guard !frames.isEmpty, !remaining.isEmpty else { return remaining }
        let input = MicrophoneDuplicateFilter.tokens(recognition)
        let maximumDuration = input.map { $0.word.end - $0.word.start }.max() ?? 0
        // Do not invent equal word durations when Apple supplied only a phrase
        // range. Match against the original range and retain its uncertainty.
        let remote = reference.flatMap { phrase in
            MicrophoneDuplicateFilter.tokens([phrase]).map { ($0.key, phrase.start, phrase.end) }
        }
        let positions = Dictionary(grouping: remote, by: { $0.0 }).mapValues(ReferenceRanges.init)
        let matched = input.map { token in
            positions[token.key]?.overlaps(token.word) ?? false
        }
        // A coherent run of different words needs stronger acoustic evidence
        // than one orphan substitution inside a matching remote phrase.
        var islands = [Int](repeating: 0, count: input.count)
        var index = 0
        while index < input.count {
            if matched[index] { index += 1; continue }
            let first = index
            index += 1
            while index < input.count, !matched[index], input[index].word.start - input[index - 1].word.end <= 0.6 {
                index += 1
            }
            for i in first..<index { islands[i] = index - first }
        }
        let supported = ExportAudioActivity(spans: frames.compactMap {
            $0.correlation >= 0.18 && $0.residualRatio <= 0.85 && $0.referencePower > 1e-8
                ? AudioEchoInterval(start: $0.start, end: $0.end) : nil
        })
        let weaklySupported = ExportAudioActivity(spans: frames.compactMap {
            $0.correlation >= 0.1 && $0.residualRatio <= 1.05 && $0.referencePower > 1e-8
                ? AudioEchoInterval(start: $0.start, end: $0.end) : nil
        })
        let substitutionSupport = ExportAudioActivity(spans: frames.compactMap {
            $0.correlation >= 0.18 && $0.residualRatio <= 0.65 && $0.referencePower > 1e-8
                ? AudioEchoInterval(start: $0.start, end: $0.end) : nil
        })
        let phraseSupport = ExportAudioActivity(spans: frames.compactMap {
            $0.correlation >= 0.18 && $0.residualRatio <= 0.5 && $0.referencePower > 1e-8
                ? AudioEchoInterval(start: $0.start, end: $0.end) : nil
        })
        let candidates = MicrophoneDuplicateFilter.tokens(remaining)
        let retained: [TimedText] = candidates.compactMap { token in
            let word = token.word
            guard word.end > word.start, !MicrophoneDuplicateFilter.isProtectedReply(token.key) else { return word }
            let start = max(frames.first?.start ?? 0, word.start - 0.35)
            let end = min(frames.last?.end ?? word.end, word.end + 0.35)
            guard end > start else { return word }
            let directAudio = supported.duration(from: start, to: end) >= (end - start) * 0.7
            // Recognition may split one echoed phrase into many tiny runs.
            // Keep a bounded phrase context, including at recording edges.
            let contextStart = max(frames.first?.start ?? 0, word.start - 8)
            let contextEnd = min(frames.last?.end ?? word.end, max(word.end + 8, contextStart + 16))
            var low = 0, high = input.count
            while low < high {
                let middle = (low + high) / 2
                if input[middle].word.start < contextStart - maximumDuration { low = middle + 1 }
                else { high = middle }
            }
            let context = input.indices[low...].prefix { input[$0].word.start <= contextEnd }
                .filter { input[$0].word.end >= contextStart }
            let anchors = context.filter { matched[$0] }
            let density = Double(anchors.count) / Double(max(1, context.count))
            guard anchors.count >= 6, anchors.reduce(0, { $0 + input[$1].key.count }) >= 28,
                  density >= 0.55 else { return word }
            let exact = positions[token.key]?.overlaps(word) ?? false
            if !exact {
                let ownIndex = context.first { input[$0].key == token.key && abs(input[$0].word.start - word.start) < 0.001 }
                let truncatedCompound = word.text.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("-")
                    && ownIndex.map { i in
                        i + 1 < input.count && matched[i + 1] && input[i + 1].word.start - word.end <= 0.3
                    } == true
                if !truncatedCompound {
                    let evidence = ownIndex.map { islands[$0] >= 3 } == true ? phraseSupport : substitutionSupport
                    guard evidence.duration(from: start, to: end) >= (end - start) * 0.7 else { return word }
                }
            }
            if !directAudio {
                // Only an exact, time-aligned word can bridge a short lapse in
                // cancellation. Require dense text agreement and echo on BOTH
                // sides; a microphone-only phrase or a silent reference cannot.
                let before = max(frames.first?.start ?? 0, start - 3)
                let after = min(frames.last?.end ?? end, end + 3)
                guard exact, density >= 0.8,
                      weaklySupported.duration(from: start, to: end) >= (end - start) * 0.7,
                      start - before >= 2, after - end >= 2,
                      supported.duration(from: before, to: start) >= (start - before) * 0.7,
                      supported.duration(from: end, to: after) >= (after - end) * 0.7 else { return word }
            }
            // A nearby independent answer/objection protects its full phrase.
            let objection = context.contains {
                !matched[$0] && MicrophoneDuplicateFilter.isProtectedReply(input[$0].key)
                && input[$0].word.end >= word.start - 1 && input[$0].word.start <= word.end + 1
            }
            return objection ? word : nil
        }
        // Do not retime/resegment a microphone recognition when nothing was
        // removed (including when cached evidence lies outside its time range).
        let phraseFiltered = removeResidualPhrases(retained, reference: reference, frames: frames)
        return phraseFiltered.count == candidates.count ? remaining : phraseFiltered
    }

    // A few complete playback phrases survive token-by-token filtering when
    // the two recognizers disagree on a name or an article. Require sustained
    // acoustic echo AND ordered text agreement before removing such a phrase.
    private static func removeResidualPhrases(_ remaining: [TimedText], reference: [TimedText],
                                              frames: [MicrophoneEchoFrame]) -> [TimedText] {
        let input = MicrophoneDuplicateFilter.tokens(remaining)
        guard input.count >= 5 else { return remaining }
        let remote = MicrophoneDuplicateFilter.tokens(reference)
        let strong = ExportAudioActivity(spans: frames.compactMap {
            $0.correlation >= 0.30 && $0.residualRatio <= 0.60 && $0.referencePower > 1e-8
                ? AudioEchoInterval(start: $0.start, end: $0.end) : nil
        })
        var removed = Set<Int>()
        for start in input.indices where !removed.contains(start) {
            let upper = min(input.count, start + 15)
            guard start + 5 <= upper else { continue }
            // Prefer the longest supported phrase. A real reply next to echo
            // cannot be absorbed unless its own time range also has evidence.
            for end in stride(from: upper, through: start + 5, by: -1) {
                let own = Array(input[start..<end])
                let duration = own.last!.word.end - own.first!.word.start
                guard duration > 0, duration <= 7,
                      zip(own, own.dropFirst()).allSatisfy({ $1.word.start - $0.word.end <= 0.75 }),
                      !((start..<end).contains { removed.contains($0) }),
                      strong.duration(from: own.first!.word.start, to: own.last!.word.end) >= duration * 0.65 else { continue }
                var low = 0, high = remote.count
                while low < high {
                    let middle = (low + high) / 2
                    if remote[middle].word.start < own.first!.word.start - 1.5 { low = middle + 1 }
                    else { high = middle }
                }
                let nearby = remote[low...].prefix { $0.word.start <= own.last!.word.end + 0.75 }
                    .filter { $0.word.end >= own.first!.word.start - 0.75 }
                guard nearby.count >= 5 else { continue }
                // Ordered agreement tolerates a small substitution such as
                // "NatWest" versus "Not West" without accepting a bag of
                // common words from an independent overlapping speaker.
                var previous = [Int](repeating: 0, count: nearby.count + 1)
                for token in own {
                    var current = [Int](repeating: 0, count: nearby.count + 1)
                    for (index, other) in nearby.enumerated() {
                        current[index + 1] = token.key == other.key && !token.key.isEmpty
                            ? previous[index] + 1 : max(previous[index + 1], current[index])
                    }
                    previous = current
                }
                let matches = previous.last ?? 0
                let remoteKeys = Set(nearby.map(\.key))
                let protectedWordsSupported = own.enumerated().allSatisfy { position, token in
                    guard MicrophoneDuplicateFilter.isProtectedReply(token.key),
                          !remoteKeys.contains(token.key) else { return true }
                    // A protected token can be part of a differently segmented
                    // proper name ("Not West" / "NatWest"). Require its next
                    // token and a near-identical compound on the remote track.
                    guard position + 1 < own.count else { return false }
                    let compound = token.key + own[position + 1].key
                    return nearby.contains { other in
                        compound.count >= 6 && compound.count == other.key.count
                            && zip(compound, other.key).filter { $0.0 != $0.1 }.count <= 1
                    }
                }
                guard matches >= 4, Double(matches) / Double(own.count) >= 0.65,
                      own.reduce(0, { $0 + $1.key.count }) >= 22,
                      protectedWordsSupported else { continue }
                removed.formUnion(start..<end)
                break
            }
        }
        guard !removed.isEmpty else { return remaining }
        return input.enumerated().compactMap { removed.contains($0.offset) ? nil : $0.element.word }
    }
}

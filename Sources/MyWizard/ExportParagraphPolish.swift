import Foundation

// Export-only: retain every recognized character and every known identity.
enum ExportParagraphPolish {
    static func resolve(_ blocks: [LiveTranscriptBlock], intervals: [SpeakerInterval],
                        numbers: [Int: Int], activity: ExportAudioActivity? = nil) -> [LiveTranscriptBlock] {
        let evidence = intervals.filter { $0.end > $0.start }.sorted { $0.start < $1.start }
        let longest = evidence.map { $0.end - $0.start }.max() ?? 0
        func nearby(_ start: Double, _ end: Double) -> [SpeakerInterval] {
            var low = 0, high = evidence.count
            while low < high {
                let middle = (low + high) / 2
                if evidence[middle].start < start - longest - 0.15 { low = middle + 1 }
                else { high = middle }
            }
            return evidence[low...].prefix { $0.start < end + 0.15 }
                .filter { $0.end > start - 0.15 }
        }
        let resolved = blocks.map { block in
            guard block.speaker == nil, block.end > block.start else { return block }
            let nearby = nearby(block.start, block.end)
            let identities = Set(nearby.compactMap { numbers[$0.slot] })
            // Any competing or unmapped voice keeps the label uncertain.
            guard identities.count == 1, let identity = identities.first, identity != SpeakerIdentity.microphone,
                  nearby.allSatisfy({ numbers[$0.slot] == identity }) else { return block }
            var coverage = 0.0, audibleCoverage = 0.0, coveredUntil = block.start
            for interval in nearby {
                let start = max(coveredUntil, max(block.start, interval.start - 0.15))
                let end = min(block.end, interval.end + 0.15)
                coverage += max(0, end - start)
                if end > start { audibleCoverage += activity?.duration(from: start, to: end) ?? 0 }
                coveredUntil = max(coveredUntil, end)
            }
            let audible = activity?.duration(from: block.start, to: block.end) ?? 0
            let supportedAudible = audible >= max(0.12, (block.end - block.start) * 0.1)
                && audibleCoverage >= audible * 0.8
            guard coverage >= (block.end - block.start) * 0.8 || supportedAudible else { return block }
            return LiveTranscriptBlock(text: block.text, speaker: identity, start: block.start, end: block.end)
        }
        // Fill a brief hole only when independently supported turns on BOTH
        // sides agree. Do not chain inferred labels across a long unknown run.
        var result = resolved
        var index = 0
        while index < resolved.count {
            guard resolved[index].speaker == nil else { index += 1; continue }
            let start = index
            while index < resolved.count, resolved[index].speaker == nil { index += 1 }
            guard start > 0, index < resolved.count else { continue }
            let left = resolved[start - 1], right = resolved[index]
            let first = resolved[start], last = resolved[index - 1]
            guard let identity = left.speaker, identity != SpeakerIdentity.microphone,
                  right.speaker == identity, last.end - first.start <= 2,
                  resolved[start..<index].reduce(0, { $0 + $1.text.split(whereSeparator: \.isWhitespace).count }) <= 6,
                  first.start >= left.end - 0.05, first.start - left.end <= 0.4,
                  right.start >= last.end - 0.05, right.start - last.end <= 0.4,
                  (start + 1..<index).allSatisfy({ resolved[$0].start - resolved[$0 - 1].end <= 0.4 }) else { continue }
            let witnesses = nearby(first.start - 0.4, last.end + 0.4)
            guard !witnesses.isEmpty,
                  witnesses.allSatisfy({ numbers[$0.slot] == identity }),
                  witnesses.contains(where: { $0.start < first.start && $0.end >= first.start - 0.4 }),
                  witnesses.contains(where: { $0.end > last.end && $0.start <= last.end + 0.4 }) else { continue }
            for position in start..<index {
                let block = resolved[position]
                result[position] = LiveTranscriptBlock(text: block.text, speaker: identity, start: block.start, end: block.end)
            }
        }
        // Word blocks often extend beyond the actual sound (roughly one second
        // for a single word). Bridge a short text fragment between two known
        // turns only when the system track is audible and no rival voice occurs.
        if resolved.count >= 3 {
            for position in 1..<(resolved.count - 1) where resolved[position].speaker == nil
                && result[position].speaker == nil {
                let block = resolved[position]
                let left = resolved[position - 1], right = resolved[position + 1]
                let normalized = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: .punctuationCharacters).lowercased()
                let standaloneReply: Set<String> = ["yeah", "yep", "yes", "no", "okay", "good", "right", "um", "uh"]
                guard let identity = left.speaker, identity != SpeakerIdentity.microphone,
                      right.speaker == identity, block.end > block.start,
                      block.end - block.start <= 3,
                      block.text.trimmingCharacters(in: .whitespacesAndNewlines).count <= 28,
                      block.text.split(whereSeparator: \.isWhitespace).count <= 3,
                      !standaloneReply.contains(normalized),
                      block.start >= left.end - 0.05, block.start - left.end <= 0.75,
                      right.start >= block.end - 0.05, right.start - block.end <= 0.75,
                      (activity?.duration(from: block.start, to: block.end) ?? 0) >= 0.12,
                      nearby(block.start - 0.25, block.end + 0.25)
                        .allSatisfy({ numbers[$0.slot] == identity }) else { continue }
                result[position] = LiveTranscriptBlock(text: block.text, speaker: identity,
                                                       start: block.start, end: block.end)
            }
        }
        return result
    }

    static func coalesce(_ blocks: [LiveTranscriptBlock]) -> [WhisperExportParagraph] {
        var result: [WhisperExportParagraph] = []
        for block in blocks {
            let punctuation = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if block.speaker == nil, !punctuation.isEmpty,
               punctuation.unicodeScalars.allSatisfy({ CharacterSet.punctuationCharacters.contains($0) || CharacterSet.whitespacesAndNewlines.contains($0) }),
               let previousIndex = result.lastIndex(where: { $0.speaker != SpeakerIdentity.microphone }) {
                let previous = result[previousIndex]
                result[previousIndex] = WhisperExportParagraph(speaker: previous.speaker, text: previous.text + block.text)
                continue
            }
            if let previous = result.last, let speaker = block.speaker, previous.speaker == speaker {
                // Insert only a missing separator; never rewrite punctuation or names.
                let separator = previous.text.last?.isWhitespace == false && block.text.first?.isWhitespace == false ? " " : ""
                result[result.count - 1] = WhisperExportParagraph(speaker: speaker, text: previous.text + separator + block.text)
            } else { result.append(WhisperExportParagraph(speaker: block.speaker, text: block.text)) }
        }
        return result
    }
}

import Foundation

struct AudioEchoInterval: Codable, Sendable {
    let start: Double
    let end: Double
}

struct EchoReductionResult: Sendable {
    let audio: URL
    let echoOnly: [AudioEchoInterval]
    var systemActivity: ExportAudioActivity? = nil
    var contextFrames: [MicrophoneEchoFrame] = []

    // Suppress recognizer artifacts that fall inside audio already classified
    // as echo-only. Do not infer a person's presence from an open microphone.
    func removingEchoArtifacts(from words: [TimedText], reference: [TimedText] = []) -> [TimedText] {
        guard !echoOnly.isEmpty else { return words }
        let remote = Dictionary(grouping: MicrophoneDuplicateFilter.tokens(reference), by: \.key)
        return MicrophoneDuplicateFilter.tokens(words).compactMap { token in
            let word = token.word
            let duration = word.end - word.start
            guard duration > 0, duration.isFinite else { return word }
            var low = 0, high = echoOnly.count
            while low < high {
                let middle = (low + high) / 2
                if echoOnly[middle].end <= word.start { low = middle + 1 } else { high = middle }
            }
            var covered = 0.0
            for index in low..<echoOnly.count {
                let span = echoOnly[index]
                if span.start >= word.end { break }
                covered += max(0, min(word.end, span.end) - max(word.start, span.start))
            }
            if covered >= duration * 0.8 { return nil }
            // A short residual needs TWO independent clues: acoustic echo over
            // most of its duration and the same remote word at the same time.
            // Never extend this rule to a yes/no reply, objection or number.
            if covered >= duration * 0.5, token.key.count >= 3,
               !MicrophoneDuplicateFilter.isProtectedReply(token.key),
               remote[token.key, default: []].contains(where: {
                   $0.word.start <= word.end && $0.word.end >= word.start
               }) { return nil }
            return word
        }
    }
}

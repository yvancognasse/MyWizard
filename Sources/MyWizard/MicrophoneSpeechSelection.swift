import AVFoundation

// Conservative silence compaction, NOT a loudness gate or a claim of voice
// identity. Keep even very quiet activity and 1 s context on both sides.
struct MicrophoneSpeechSelection {
    struct Span: Equatable {
        let start: Double
        var end: Double
    }

    static func spans(activity: [Bool], step: Double, duration: Double) -> [Span] {
        var result: [Span] = []
        for (index, active) in activity.enumerated() where active {
            let start = max(0, Double(index) * step - 1)
            let end = min(duration, Double(index + 1) * step + 1)
            if let previous = result.last, start - previous.end <= 2 {
                result[result.count - 1].end = end
            } else { result.append(Span(start: start, end: end)) }
        }
        return result
    }

    static func useful(_ spans: [Span], duration: Double) -> Bool {
        let retained = spans.reduce(0) { $0 + $1.end - $1.start }
        return !spans.isEmpty && duration - retained >= 10 && retained <= duration * 0.7
    }

    static func inspect(_ url: URL) throws -> (spans: [Span], duration: Double) {
        let file = try AVAudioFile(forReading: url)
        let rate = file.processingFormat.sampleRate
        let frames = AVAudioFrameCount(max(1, Int(rate / 10)))
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames)!
        var activity: [Bool] = []
        while file.framePosition < file.length {
            try Task.checkCancellation()
            try file.read(into: buffer, frameCount: frames)
            guard buffer.frameLength > 0 else { break }
            // Below the existing hasSound threshold; no noise-floor estimate
            // that could confuse a quiet local response with background noise.
            guard let channels = buffer.floatChannelData else {
                return ([Span(start: 0, end: Double(file.length) / rate)], Double(file.length) / rate)
            }
            let active = (0..<Int(buffer.format.channelCount)).contains { channel in
                (0..<Int(buffer.frameLength)).contains { abs(channels[channel][$0]) > 0.00005 }
            }
            activity.append(active)
        }
        let duration = Double(file.length) / rate
        return (spans(activity: activity, step: Double(frames) / rate, duration: duration), duration)
    }

    struct Mapping {
        let sourceStart: Double
        let packedStart: Double
        let duration: Double
    }

    static func pack(_ source: URL, spans: [Span], destination: URL) throws -> [Mapping] {
        let file = try AVAudioFile(forReading: source)
        let rate = file.processingFormat.sampleRate
        let output = try AVAudioFile(forWriting: destination, settings: file.processingFormat.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8192)!
        var mapping: [Mapping] = []
        for span in spans {
            let start = AVAudioFramePosition((span.start * rate).rounded(.down))
            let end = min(file.length, AVAudioFramePosition((span.end * rate).rounded(.up)))
            file.framePosition = start
            mapping.append(Mapping(sourceStart: Double(start) / rate,
                packedStart: Double(output.framePosition) / rate, duration: Double(end - start) / rate))
            while file.framePosition < end {
                try Task.checkCancellation()
                try file.read(into: buffer, frameCount: AVAudioFrameCount(min(8192, end - file.framePosition)))
                guard buffer.frameLength > 0 else { throw TranscriptionError.message("Unexpected end of microphone audio.") }
                try output.write(from: buffer)
            }
        }
        return mapping
    }

    static func restore(_ words: [TimedText], mapping: [Mapping]) -> [TimedText]? {
        var result: [TimedText] = []
        for word in words {
            // A word spanning a cut is ambiguous: retry the untouched track.
            guard let span = mapping.first(where: {
                word.start >= $0.packedStart - 0.001 && word.end <= $0.packedStart + $0.duration + 0.001
            }) else { return nil }
            let offset = span.sourceStart - span.packedStart
            result.append(TimedText(text: word.text, start: word.start + offset,
                end: word.end + offset, source: word.source))
        }
        return result
    }
}

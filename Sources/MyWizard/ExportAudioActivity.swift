import AVFoundation

// Only discounts digital/near-digital silence from a word's time range. This
// is not voice recognition and never chooses a speaker without saved evidence.
struct ExportAudioActivity: Codable, Sendable {
    let spans: [AudioEchoInterval]

    struct Collector {
        private var pending: [Float] = []
        private var frames: Int64 = 0
        private var spans: [AudioEchoInterval] = []

        mutating func consume(_ samples: [Float]) {
            let combined = pending + samples
            let complete = combined.count / 320 * 320
            if complete > 0 {
                ExportAudioActivity.append(Array(combined[..<complete]), startFrame: frames, to: &spans)
                frames += Int64(complete)
            }
            pending = Array(combined[complete...])
        }

        mutating func finish() -> ExportAudioActivity {
            ExportAudioActivity.append(pending, startFrame: frames, to: &spans)
            pending = []
            return ExportAudioActivity(spans: spans)
        }
    }

    static func append(_ samples: [Float], startFrame: Int64, to spans: inout [AudioEchoInterval]) {
        for offset in stride(from: 0, to: samples.count, by: 320) {
            let end = min(samples.count, offset + 320)
            guard samples[offset..<end].contains(where: { abs($0) > 0.00005 }) else { continue }
            let span = AudioEchoInterval(start: Double(startFrame + Int64(offset)) / 16000,
                                         end: Double(startFrame + Int64(end)) / 16000)
            if let last = spans.last, abs(last.end - span.start) < 0.00001 {
                spans[spans.count - 1] = AudioEchoInterval(start: last.start, end: span.end)
            } else { spans.append(span) }
        }
    }

    func duration(from start: Double, to end: Double) -> Double {
        var low = 0, high = spans.count
        while low < high {
            let middle = (low + high) / 2
            if spans[middle].end <= start { low = middle + 1 } else { high = middle }
        }
        var total = 0.0
        for span in spans[low...] {
            if span.start >= end { break }
            total += max(0, min(end, span.end) - max(start, span.start))
        }
        return total
    }

    static func read(_ url: URL) throws -> ExportAudioActivity {
        let file = try AVAudioFile(forReading: url)
        let rate = file.processingFormat.sampleRate
        let frames = AVAudioFrameCount(max(1, Int(rate * 0.02)))
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames)!
        var spans: [AudioEchoInterval] = []
        while file.framePosition < file.length {
            try Task.checkCancellation()
            let start = Double(file.framePosition) / rate
            try file.read(into: buffer, frameCount: frames)
            guard buffer.frameLength > 0 else { break }
            let end = Double(file.framePosition) / rate
            guard let channels = buffer.floatChannelData else {
                throw TranscriptionError.message("Unsupported activity audio format.")
            }
            let audible = (0..<Int(buffer.format.channelCount)).contains { channel in
                (0..<Int(buffer.frameLength)).contains { abs(channels[channel][$0]) > 0.00005 }
            }
            guard audible else { continue }
            if let last = spans.last, abs(last.end - start) < 0.00001 {
                spans[spans.count - 1] = AudioEchoInterval(start: last.start, end: end)
            } else { spans.append(AudioEchoInterval(start: start, end: end)) }
        }
        return ExportAudioActivity(spans: spans)
    }
}

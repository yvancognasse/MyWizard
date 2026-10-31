import AVFoundation
import Accelerate

// Offline, bounded-memory reference cancellation. Does not open a device or
// enable VoiceProcessingIO. Original recordings are never overwritten.
// A conservative correlation check avoids adapting to unrelated local speech.
struct OfflineEchoReducer {
    private(set) var echoOnlyFrames: [Range<Int>] = []
    private(set) var contextCorrelation = 0.0
    private(set) var contextResidualRatio = 1.0
    private(set) var contextReferencePower = 0.0
    private var weights = [Float](repeating: 0, count: 256)
    private var history = [Float](repeating: 0, count: 512)
    private var cursor = 0
    private var previousReference = [Float](repeating: 0, count: 8000)
    private var delay = 0

    mutating func process(microphone: [Float], reference: [Float]) -> [Float] {
        echoOnlyFrames = []
        contextCorrelation = 0
        contextResidualRatio = 1
        contextReferencePower = 0
        guard !microphone.isEmpty else { return [] }
        let context = previousReference + reference
        // Search every possible delay: sampling only every 16th lag misses
        // narrow correlation peaks and can mistake a pitch-period alias for
        // the acoustic delay. Subsample time instead, then refine at full rate.
        func correlation(_ lag: Int, stride: Int) -> Float {
            var xy: Float = 0, xx: Float = 0, yy: Float = 0
            for i in Swift.stride(from: 0, to: min(microphone.count, reference.count), by: stride) {
                let x = context[8000 + i - lag], y = microphone[i]
                xy += x * y; xx += x * x; yy += y * y
            }
            return abs(xy) / sqrt(max(1e-12, xx * yy))
        }
        var best = 0, score: Float = 0
        for lag in 0...8000 {
            let value = correlation(lag, stride: 32)
            if value > score { score = value; best = lag }
        }
        score = 0
        let coarseBest = best
        for lag in max(0, coarseBest - 16)...min(8000, coarseBest + 16) {
            let value = correlation(lag, stride: 1)
            if value > score { score = value; best = lag }
        }
        let coherent = score > 0.18
        if coherent, abs(best - delay) > 32 {
            weights = Array(repeating: 0, count: 256)
            history = Array(repeating: 0, count: 512)
            cursor = 0
            delay = best
        }
        if coherent { delay = best }
        // A local voice over near-silent reference samples must not drive
        // arbitrarily large adaptive coefficients (double-talk instability).
        let microphonePower = microphone.reduce(Float(0)) { $0 + $1 * $1 } / Float(microphone.count)
        let regularization = max(1e-5, microphonePower * 64)
        var result = microphone
        // Offline look-ahead lets a new filter converge before recognizing the
        // first syllable. Replay this block from the same history, keeping only
        // learned coefficients, so startup echo is not labeled as local speech.
        let needsWarmup = coherent && weights.allSatisfy { $0 == 0 }
        let initialHistory = history
        let initialCursor = cursor
        for pass in 0..<(needsWarmup ? 2 : 1) {
            if pass > 0 { history = initialHistory; cursor = initialCursor }
            for i in microphone.indices {
                let x = i < reference.count ? context[8000 + i - delay] : 0
                cursor = (cursor + 255) % 256
                history[cursor] = x; history[cursor + 256] = x
                var estimate: Float = 0, energy: Float = 0
                history.withUnsafeBufferPointer { h in
                    weights.withUnsafeBufferPointer { w in
                        vDSP_dotpr(h.baseAddress! + cursor, 1, w.baseAddress!, 1, &estimate, 256)
                        vDSP_svesq(h.baseAddress! + cursor, 1, &energy, 256)
                    }
                }
                let error = microphone[i] - estimate
                // Without evidence of acoustic correspondence, preserve the input.
                if coherent && energy > 1e-7 {
                    result[i] = max(-1, min(1, error))
                    let step: Float = 0.25 * error / (energy + regularization)
                    history.withUnsafeBufferPointer { h in
                        weights.withUnsafeMutableBufferPointer { w in
                            cblas_saxpy(256, step, h.baseAddress! + cursor, 1, w.baseAddress!, 1)
                        }
                    }
                }
            }
        }
        // Speech recognition can amplify even very quiet residual echo into
        // convincing words. Explicitly silence only windows with strong audio
        // evidence of echo, not merely because someone speaks on the system.
        // Independent near-end speech raises the residual energy and survives.
        if coherent {
            for start in stride(from: 0, to: microphone.count, by: 1600) {
                let end = min(start + 1600, microphone.count)
                var xx = 0.0, yy = 0.0, xy = 0.0, residual = 0.0
                for i in start..<end {
                    let x = Double(i < reference.count ? context[8000 + i - delay] : 0)
                    let y = Double(microphone[i])
                    xx += x * x; yy += y * y; xy += x * y
                    residual += Double(result[i]) * Double(result[i])
                }
                let count = Double(end - start)
                let correlationSquared = xy * xy / max(1e-20, xx * yy)
                // An unstable or stale filter must never amplify the input.
                if residual > yy * 1.25 {
                    for i in start..<end { result[i] = microphone[i] }
                    continue
                }
                guard xx / count > 1e-8, yy / count > 1e-10,
                      correlationSquared >= 0.995 || residual / yy <= 0.005 else { continue }
                echoOnlyFrames.append(start..<end)
                for i in start..<end { result[i] = 0 }
            }
        }
        contextCorrelation = Double(score)
        contextResidualRatio = Double(result.reduce(Float(0)) { $0 + $1 * $1 })
            / max(1e-20, Double(microphone.reduce(Float(0)) { $0 + $1 * $1 }))
        contextReferencePower = Double(reference.reduce(Float(0)) { $0 + $1 * $1 }) / Double(max(1, reference.count))
        previousReference = Array(context.suffix(8000))
        return result
    }

    static func reduce(_ meeting: RecordedMeeting, collectingActivity: Bool = false,
                       progress: @Sendable (Double) -> Void) throws -> EchoReductionResult {
        let microphone = try AVAudioFile(forReading: meeting.audio(.microphone))
        let system = try AVAudioFile(forReading: meeting.audio(.system))
        let reading = try AVAudioFile(forReading: meeting.audio(.reading))
        let url = meeting.directory.appendingPathComponent("microphone-cleaned.caf")
        let output = try MeetingRecording.makeFile(url)
        var reducer = OfflineEchoReducer()
        var position: Int64 = 0
        var echoOnly: [AudioEchoInterval] = []
        var contextFrames: [MicrophoneEchoFrame] = []
        var activity = ExportAudioActivity.Collector()
        var muted = false
        var eventIndex = 0
        let events = meeting.manifest.mutedSystem.sorted { $0.time < $1.time }
        while position < microphone.length {
            try Task.checkCancellation()
            let count = Int(min(16000, microphone.length - position))
            let own = try read(microphone, count: count)
            let availableSystem = Int(min(Int64(count), max(0, system.length - system.framePosition)))
            var reference = try read(system, count: count)
            if collectingActivity { activity.consume(Array(reference.prefix(availableSystem))) }
            let voice = try read(reading, count: count)
            for i in 0..<count {
                let time = Double(position + Int64(i)) / 16000
                while eventIndex < events.count, events[eventIndex].time <= time {
                    muted = events[eventIndex].muted; eventIndex += 1
                }
                reference[i] = (muted ? 0 : reference[i]) + voice[i]
            }
            let cleaned = reducer.process(microphone: own, reference: reference)
            contextFrames.append(.init(start: Double(position) / 16000, end: Double(position + Int64(count)) / 16000,
                correlation: reducer.contextCorrelation, residualRatio: reducer.contextResidualRatio,
                referencePower: reducer.contextReferencePower))
            for frames in reducer.echoOnlyFrames {
                let span = AudioEchoInterval(start: Double(position + Int64(frames.lowerBound)) / 16000,
                                             end: Double(position + Int64(frames.upperBound)) / 16000)
                if let last = echoOnly.last, abs(last.end - span.start) < 0.0001 {
                    echoOnly[echoOnly.count - 1] = AudioEchoInterval(start: last.start, end: span.end)
                } else { echoOnly.append(span) }
            }
            let buffer = AVAudioPCMBuffer(pcmFormat: MeetingRecording.format, frameCapacity: AVAudioFrameCount(count))!
            buffer.frameLength = buffer.frameCapacity
            cleaned.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: count) }
            try output.write(from: buffer)
            position += Int64(count)
            progress(Double(position) / Double(max(1, microphone.length)))
        }
        if collectingActivity {
            // Microphone capture can end before the system track.
            while system.framePosition < system.length {
                try Task.checkCancellation()
                let count = Int(min(16000, system.length - system.framePosition))
                activity.consume(try read(system, count: count))
            }
        }
        return EchoReductionResult(audio: url, echoOnly: echoOnly,
            systemActivity: collectingActivity ? activity.finish() : nil, contextFrames: contextFrames)
    }

    private static func read(_ file: AVAudioFile, count: Int) throws -> [Float] {
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(count))!
        if file.framePosition < file.length { try file.read(into: buffer, frameCount: AVAudioFrameCount(count)) }
        var samples = [Float](repeating: 0, count: count)
        if buffer.frameLength > 0, let data = buffer.floatChannelData?[0] {
            samples.replaceSubrange(0..<Int(buffer.frameLength), with: UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
        }
        return samples
    }
}

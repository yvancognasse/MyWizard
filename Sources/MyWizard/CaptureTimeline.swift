import Foundation
import CoreMedia

// Never round floating-point display offsets into analyzer input timestamps.
// Adjacent buffers must meet at exactly the same rational sample boundary.
struct AnalyzerSampleClock {
    let sampleRate: CMTimeScale
    private(set) var frames: Int64 = 0

    mutating func next(frameCount: UInt32) -> CMTime {
        let start = CMTime(value: frames, timescale: sampleRate)
        frames += Int64(frameCount)
        return start
    }
}

// System and microphone capture run in independent components and queues. Their
// presentation timestamps still share the host clock, so this small locked
// coordinator aligns display order without ever exchanging audio buffers.
final class CaptureTimeline: @unchecked Sendable {
    private let lock = NSLock()
    private var origin: Double?
    private var offsets: [TranscriptSource: Double] = [:]
    private var systemSegments: [(sample: Double, elapsed: Double)] = []
    private var needsSystemSegment = true

    func reset(origin: Double? = nil) {
        lock.lock()
        defer { lock.unlock() }
        self.origin = origin
        offsets = [:]
        systemSegments = []
        needsSystemSegment = true
    }

    func beginSystemSegment() {
        lock.lock()
        defer { lock.unlock() }
        needsSystemSegment = true
    }

    // Recognition and speaker inference retain continuous sample clocks while
    // devices are paused. Map each resumed segment back to the recording clock.
    func recordSystemBuffer(sampleTime: Double, presentationTime: Double) {
        lock.lock()
        defer { lock.unlock() }
        guard needsSystemSegment, sampleTime.isFinite, presentationTime.isFinite else { return }
        if origin == nil { origin = presentationTime }
        systemSegments.append((sampleTime, max(0, presentationTime - (origin ?? presentationTime))))
        needsSystemSegment = false
    }

    func startOffset(for source: TranscriptSource, presentationTime: Double) -> Double {
        lock.lock()
        defer { lock.unlock() }
        if let offset = offsets[source] { return offset }
        guard presentationTime.isFinite else { return 0 }
        if origin == nil { origin = presentationTime }
        let offset = max(0, presentationTime - (origin ?? presentationTime))
        offsets[source] = offset
        return offset
    }

    func alignSystemSpeakers(_ snapshot: SpeakerSnapshot) -> SpeakerSnapshot {
        lock.lock()
        defer { lock.unlock() }
        let intervals = snapshot.intervals.flatMap { interval -> [SpeakerInterval] in
            let cuts = [interval.start] + systemSegments.map(\.sample).filter {
                $0 > interval.start && $0 < interval.end
            } + [interval.end]
            return zip(cuts, cuts.dropFirst()).map { start, end in
                SpeakerInterval(slot: interval.slot, start: systemTime(start), end: systemTime(end, ending: true))
            }
        }
        return SpeakerSnapshot(intervals: intervals, processedThrough: systemTime(snapshot.processedThrough, ending: true),
                               voiceEmbeddings: snapshot.voiceEmbeddings, voiceMemoryWarning: snapshot.voiceMemoryWarning)
    }

    func alignWords(_ words: [TimedText], source: TranscriptSource) -> [TimedText] {
        if source == .systemAudio {
            lock.lock()
            defer { lock.unlock() }
            return words.map {
                TimedText(text: $0.text, start: systemTime($0.start),
                          end: max(systemTime($0.start), systemTime($0.end, ending: true)), source: source)
            }
        }
        let offset = offset(for: source)
        return words.map { TimedText(text: $0.text, start: $0.start + offset, end: $0.end + offset, source: source) }
    }

    private func systemTime(_ sample: Double, ending: Bool = false) -> Double {
        guard let segment = systemSegments.last(where: { ending ? $0.sample < sample : $0.sample <= sample })
            ?? systemSegments.first else { return sample + (offsets[.systemAudio] ?? 0) }
        return sample + segment.elapsed - segment.sample
    }

    private func offset(for source: TranscriptSource) -> Double {
        lock.lock()
        defer { lock.unlock() }
        return offsets[source] ?? 0
    }
}

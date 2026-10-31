import Foundation

// Per-track audio-time progress, not an estimate of total remaining wall time.
// Callbacks can originate from the analyzer and its result consumer concurrently.
final class TranscriptionProgress: @unchecked Sendable {
    private let lock = NSLock()
    private let duration: Double
    private let report: @Sendable (Int) -> Void
    private var last = -1
    private var finished = false

    init(duration: Double, report: @escaping @Sendable (Int) -> Void) {
        self.duration = duration
        self.report = report
    }

    func update(processedSeconds: Double) {
        lock.withLock {
            guard !finished, processedSeconds.isFinite else { return }
            let fraction = duration.isFinite && duration > 0 ? max(0, min(1, processedSeconds / duration)) : 0
            // Final results can still be pending when analysis reaches EOF.
            let percent = min(99, Int(fraction * 100))
            guard percent > last else { return }
            last = percent
            report(percent)
        }
    }

    func finish() {
        lock.withLock {
            guard !finished else { return }
            finished = true
            last = 100
            report(100)
        }
    }
}

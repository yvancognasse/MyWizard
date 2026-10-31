import Foundation

// Weighted completed work across the entire preparation, not elapsed time or
// a remaining-time prediction. Parallel workers may report in any order.
final class ExportProgress: @unchecked Sendable {
    enum Stage: Sendable { case models, system, echo, microphone, reading, speakers, finalization }
    private let lock = NSLock()
    private let weights: [Stage: Double]
    private let report: @Sendable (Int) -> Void
    private var fractions: [Stage: Double] = [:]
    private var last = -1
    private var finished = false

    init(microphone: Bool, speakers: Bool, report: @escaping @Sendable (Int) -> Void) {
        var weights: [Stage: Double] = [.models: 2, .system: 32, .finalization: 1]
        if microphone { weights.merge([.echo: 8, .microphone: 28, .reading: 5]) { _, new in new } }
        if speakers { weights[.speakers] = 24 }
        self.weights = weights
        self.report = report
    }

    func update(_ stage: Stage, fraction: Double) {
        lock.withLock {
            guard !finished, fraction.isFinite, weights[stage] != nil else { return }
            fractions[stage] = max(fractions[stage] ?? 0, min(1, max(0, fraction)))
            let completed = weights.reduce(0) { $0 + $1.value * (fractions[$1.key] ?? 0) }
            let percent = min(99, Int(completed / weights.values.reduce(0, +) * 100))
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

    // Relay a nested pipeline's total without publishing duplicate percentages
    // for every processed audio buffer. Completion remains explicit after save.
    func update(percent: Int) {
        lock.withLock {
            let value = max(0, min(99, percent))
            guard !finished, value > last else { return }
            last = value
            report(value)
        }
    }
}

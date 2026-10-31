import Foundation

// A warm preparation is shared with Start, then consumed exactly once. Session
// engines must never be reused after they have received audio or been cancelled.
@MainActor
final class StartupPreparation<Value: Sendable> {
    typealias Loader = @MainActor @Sendable (Bool) async throws -> Value?
    private var cleanup: Task<Void, Never>?
    private var pending: (key: String, task: Task<Value?, Error>)?
    private let discard: @MainActor @Sendable (Value) async -> Void

    init(discard: @escaping @MainActor @Sendable (Value) async -> Void) {
        self.discard = discard
    }

    func warm(key: String, load: @escaping Loader) {
        guard pending?.key != key else { return }
        invalidate()
        let discard = discard
        let cleanup = cleanup
        pending = (key, Task {
            await cleanup?.value
            try Task.checkCancellation()
            let value = try await load(false)
            if Task.isCancelled {
                if let value { await discard(value) }
                throw CancellationError()
            }
            return value
        })
    }

    func take(key: String, load: @escaping Loader) async throws -> Value? {
        if let pending, pending.key == key {
            self.pending = nil
            // A missing asset or failed speculative warmup must not prevent a
            // foreground attempt (which may download the selected language).
            if let value = try? await pending.task.value { return value }
        } else {
            invalidate()
        }
        await cleanup?.value
        try Task.checkCancellation()
        return try await load(true)
    }

    func invalidate() {
        guard let pending else { return }
        self.pending = nil
        pending.task.cancel()
        let discard = discard
        let previous = cleanup
        cleanup = Task {
            await previous?.value
            if let value = try? await pending.task.value { await discard(value) }
        }
    }
}

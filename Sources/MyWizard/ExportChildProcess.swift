import Foundation
import Darwin

// One child per invocation, continuously drained stderr, bounded diagnostics,
// and cancellation even while the process is loading a model. No shell used.
final class ExportChildProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func run(_ executable: URL, arguments: [String], line: @escaping @Sendable (String) -> Void = { _ in }) async throws {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                DispatchQueue.global(qos: .userInitiated).async { [self] in
                    do {
                        let child = Process()
                        let errors = Pipe()
                        child.executableURL = executable
                        child.arguments = arguments
                        child.standardInput = FileHandle.nullDevice
                        child.standardOutput = FileHandle.nullDevice
                        child.standardError = errors
                        try lock.withLock {
                            if cancelled { throw CancellationError() }
                            process = child
                            try child.run()
                        }
                        var pending = Data(), tail = Data()
                        while true {
                            let data = errors.fileHandleForReading.availableData
                            if data.isEmpty { break }
                            tail.append(data)
                            if tail.count > 8192 { tail = tail.suffix(8192) }
                            pending.append(data)
                            while let end = pending.firstIndex(of: 10) {
                                line(String(decoding: pending[..<end], as: UTF8.self))
                                pending.removeSubrange(...end)
                            }
                            if pending.count > 65536 { pending = pending.suffix(65536) }
                        }
                        if !pending.isEmpty { line(String(decoding: pending, as: UTF8.self)) }
                        child.waitUntilExit()
                        try lock.withLock {
                            process = nil
                            if cancelled { throw CancellationError() }
                        }
                        guard child.terminationReason == .exit, child.terminationStatus == 0 else {
                            throw TranscriptionError.message("\(executable.lastPathComponent) failed (\(child.terminationStatus)). \(String(decoding: tail, as: UTF8.self))")
                        }
                        continuation.resume()
                    } catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { self.cancel() }
    }

    private func cancel() {
        lock.withLock {
            cancelled = true
            guard let child = process, child.isRunning else { return }
            child.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak self, child] in
                self?.lock.withLock {
                    if self?.process === child, child.isRunning { kill(child.processIdentifier, SIGKILL) }
                }
            }
        }
    }
}

import Testing
@testable import MyWizard

@MainActor
struct StartupPreparationTests {
    @Test func startUsesPreparedEngineOnlyOnce() async throws {
        var loads: [Bool] = []
        let cache = StartupPreparation<Int>(discard: { _ in })
        let load: StartupPreparation<Int>.Loader = { downloads in
            loads.append(downloads)
            return loads.count
        }
        cache.warm(key: "fr", load: load)
        cache.warm(key: "fr", load: load)
        let first = try await cache.take(key: "fr", load: load)
        let second = try await cache.take(key: "fr", load: load)
        #expect(first == 1)
        #expect(second == 2)
        #expect(loads == [false, true])
    }

    @Test func startJoinsAnInFlightWarmup() async throws {
        let gate = Gate()
        var loads = 0
        let cache = StartupPreparation<Int>(discard: { _ in })
        let load: StartupPreparation<Int>.Loader = { _ in
            loads += 1
            await gate.wait()
            return 42
        }
        cache.warm(key: "fr", load: load)
        await gate.waitUntilEntered()
        let start = Task { try await cache.take(key: "fr", load: load) }
        gate.release()
        #expect(try await start.value == 42)
        #expect(loads == 1)
    }

    @Test func missingAssetIsDownloadedOnlyByStart() async throws {
        var loads: [Bool] = []
        let cache = StartupPreparation<Int>(discard: { _ in })
        let load: StartupPreparation<Int>.Loader = { downloads in
            loads.append(downloads)
            return downloads ? 7 : nil
        }
        cache.warm(key: "fr", load: load)
        #expect(try await cache.take(key: "fr", load: load) == 7)
        #expect(loads == [false, true])
    }

    @Test func failedWarmupRetriesAtStart() async throws {
        enum Failure: Error { case unavailable }
        let cache = StartupPreparation<Int>(discard: { _ in })
        let load: StartupPreparation<Int>.Loader = { downloads in
            if !downloads { throw Failure.unavailable }
            return 8
        }
        cache.warm(key: "fr", load: load)
        #expect(try await cache.take(key: "fr", load: load) == 8)
    }

    @Test func languageChangeDiscardsOldPreparedEngine() async throws {
        var discarded: [Int] = []
        let disposed = Gate()
        let loaded = Gate()
        let cache = StartupPreparation<Int>(discard: { value in
            discarded.append(value)
            disposed.release()
        })
        cache.warm(key: "fr") { _ in loaded.release(); return 1 }
        await loaded.wait()
        let result = try await cache.take(key: "de") { _ in
            #expect(discarded == [1]) // Cleanup must finish before allocating the next language.
            return 2
        }
        await disposed.wait()
        #expect(result == 2)
        #expect(discarded == [1])
    }

    @Test func invalidationCleansUpAnUncooperativeLoader() async {
        let gate = Gate()
        let disposed = Gate()
        var discarded: [Int] = []
        let cache = StartupPreparation<Int>(discard: { value in
            discarded.append(value)
            disposed.release()
        })
        cache.warm(key: "fr") { _ in await gate.wait(); return 1 }
        await gate.waitUntilEntered()
        cache.invalidate()
        gate.release()
        await disposed.wait()
        #expect(discarded == [1])
    }

    @MainActor private final class Gate {
        private var released = false
        private var entered = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var entryWaiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            entered = true
            entryWaiters.forEach { $0.resume() }
            entryWaiters.removeAll()
            if !released { await withCheckedContinuation { waiters.append($0) } }
        }

        func waitUntilEntered() async {
            if !entered { await withCheckedContinuation { entryWaiters.append($0) } }
        }

        func release() {
            released = true
            waiters.forEach { $0.resume() }
            waiters.removeAll()
        }
    }
}

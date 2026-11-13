import AVFoundation
import CoreAudio
import Foundation
import Testing
@testable import MyWizard

struct AudioOutputReadinessTests {
    private func process(_ id: UInt32, pid: Int32 = 200, bundle: String? = "us.zoom.xos", output: Bool) -> AudioOutputProcess {
        .init(id: id, pid: pid, bundleID: bundle, isRunningOutput: output)
    }

    @Test func idleAndInputOnlyClientsNeverBecomeTapSources() {
        var ready = ReadyAudioOutputs(ownPID: 100, ownBundleID: "com.mywizard")
        #expect(ready.update([process(1, output: false)], now: 0).ids.isEmpty)
        #expect(ready.update([process(1, output: false)], now: 100).retryAfter == nil)
        #expect(ready.update([process(1, output: true)], now: 101).ids.isEmpty)
        #expect(ready.update([process(1, output: true)], now: 101.1).ids == [1])
        // Rejoining must settle again, even when Core Audio reuses the object ID.
        #expect(ready.update([process(1, output: false)], now: 102).ids.isEmpty)
        #expect(ready.update([process(1, output: true)], now: 103).ids.isEmpty)
        #expect(ready.update([process(1, output: true)], now: 103.1).ids == [1])
    }

    @Test func recycledObjectIDWithAnotherPIDMustSettleAgain() {
        var ready = ReadyAudioOutputs(ownPID: 100, ownBundleID: "com.mywizard")
        _ = ready.update([process(9, pid: 200, output: true)], now: 0)
        #expect(ready.update([process(9, pid: 200, output: true)], now: 1).ids == [9])
        #expect(ready.update([process(9, pid: 201, output: true)], now: 2).ids.isEmpty)
        #expect(ready.update([process(9, pid: 201, output: true)], now: 2.1).ids == [9])
    }

    @Test func ownPlaybackHelpersAndOtherAppInstancesAreAlwaysExcluded() {
        var ready = ReadyAudioOutputs(ownPID: 100, ownBundleID: "com.mywizard")
        let sources = [process(1, pid: 100, bundle: nil, output: true),
                       process(2, bundle: "com.mywizard", output: true),
                       process(3, bundle: "com.mywizard.reader", output: true),
                       process(4, bundle: nil, output: true), process(5, output: true)]
        _ = ready.update(sources, now: 0)
        #expect(ready.update(sources, now: 1).ids == [4, 5])
    }

    @Test func transientOrTerminatedOutputsDoNotLeaveStaleProcessIDs() {
        var ready = ReadyAudioOutputs(ownPID: 100, ownBundleID: "com.mywizard")
        let first = ready.update([process(9, output: true)], now: 0)
        #expect(first.retryAfter != nil)
        #expect(ready.update([], now: 0.01).retryAfter == nil)
        #expect(ready.update([process(10, output: true)], now: 1).ids.isEmpty)
        #expect(ready.update([process(10, output: true)], now: 2).ids == [10])
    }
}

@MainActor
struct AudioProcessTapTests {
    @Test func startArmsWithoutOpeningIdleClientsAndTracksNewOutputs() throws {
        let monitor = Monitor()
        var sessions: [Session] = []
        let sut = SystemAudioTap(monitor: monitor, makeTap: { ids, muted in
            let session = Session(ids: ids, muted: muted)
            sessions.append(session)
            return session
        })
        let received = Counter(), errors = Counter()
        let queue = DispatchQueue(label: "tap-test")
        try sut.start(queue: queue, receive: { _, _ in received.increment() }, onError: { _ in errors.increment() }, onDeviceChange: nil)
        #expect(sessions.isEmpty)
        monitor.emit([20])
        #expect(sessions.count == 1)
        #expect(sessions[0].ids == [20])
        sessions[0].deliver()
        #expect(received.count == 1)
        monitor.emit([30, 20, 20])
        #expect(sessions.count == 2)
        #expect(sessions[0].stops == 1)
        #expect(sessions[1].ids == [20, 30])
        sessions[0].deliver() // An old queued buffer must not leak into the new clock.
        sessions[0].error?("late error")
        #expect(received.count == 1)
        #expect(errors.count == 0)
        sessions[1].deliver()
        #expect(received.count == 2)
        monitor.emit([20, 30])
        #expect(sessions.count == 2)
        monitor.emit([])
        #expect(sessions[1].stops == 1)
        #expect(errors.count == 0) // Silence is normal, not a device failure.
        sut.stop(queue: queue)
        monitor.emitStale([40])
        #expect(sessions.count == 2)
    }

    @Test func readingMuteAppliesBeforeStartingNewSourcesAndRestoresAtStop() throws {
        let monitor = Monitor()
        var sessions: [Session] = []
        let sut = SystemAudioTap(monitor: monitor, makeTap: { ids, muted in
            let session = Session(ids: ids, muted: muted)
            sessions.append(session)
            return session
        })
        let queue = DispatchQueue(label: "mute-test")
        try sut.start(queue: queue, receive: { _, _ in }, onError: { _ in }, onDeviceChange: nil)
        try sut.setMuted(true)
        monitor.emit([20])
        #expect(sessions[0].initiallyMuted)
        monitor.emit([20, 30])
        #expect(sessions[1].initiallyMuted)
        try sut.setMuted(false)
        #expect(sessions[1].muted == false)
        sut.stop(queue: queue)
        try sut.start(queue: queue, receive: { _, _ in }, onError: { _ in }, onDeviceChange: nil)
        monitor.emit([40])
        #expect(!sessions[2].initiallyMuted)
        sut.stop(queue: queue)
    }

    @Test func failedSourceStartIsReleasedAndReportedWithoutAcceptingLateAudio() throws {
        let monitor = Monitor()
        var session: Session?
        let sut = SystemAudioTap(monitor: monitor, makeTap: { ids, muted in
            let next = Session(ids: ids, muted: muted, fails: true)
            session = next
            return next
        })
        let received = Counter(), errors = Counter()
        let queue = DispatchQueue(label: "failure-test")
        try sut.start(queue: queue, receive: { _, _ in received.increment() }, onError: { _ in errors.increment() }, onDeviceChange: nil)
        monitor.emit([20])
        #expect(session?.stops == 1)
        #expect(errors.count == 1)
        session?.deliver()
        #expect(received.count == 0)
        sut.stop(queue: queue)
    }

    @Test func sourceExitDuringTapCreationReturnsToWaitingWithoutFailingTheMeeting() throws {
        let monitor = Monitor()
        monitor.replacementOnRefresh = []
        let errors = Counter()
        let queue = DispatchQueue(label: "short-source-test")
        let sut = SystemAudioTap(monitor: monitor, makeTap: { ids, muted in Session(ids: ids, muted: muted, fails: true) })
        try sut.start(queue: queue, receive: { _, _ in }, onError: { _ in errors.increment() }, onDeviceChange: nil)
        monitor.emit([20])
        #expect(errors.count == 0)
        #expect(sut.capturedProcessIDs.isEmpty)
        sut.stop(queue: queue)
    }

    private final class Monitor: AudioOutputMonitoring {
        var update: (@MainActor ([AudioObjectID]) -> Void)?
        var stale: (@MainActor ([AudioObjectID]) -> Void)?
        var last: [AudioObjectID] = []
        var replacementOnRefresh: [AudioObjectID]?
        func start(update: @escaping @MainActor ([AudioObjectID]) -> Void, failure: @escaping @MainActor (String) -> Void) throws {
            self.update = update
            stale = update
            update([])
        }
        func refresh() throws -> [AudioObjectID] {
            if let replacementOnRefresh {
                self.replacementOnRefresh = nil
                last = replacementOnRefresh
                update?(last)
            }
            return last
        }
        func stop() { update = nil }
        func emit(_ ids: [AudioObjectID]) { last = ids; update?(ids) }
        func emitStale(_ ids: [AudioObjectID]) { stale?(ids) }
    }

    private final class Session: SystemAudioTapControlling {
        let ids: [AudioObjectID]
        let initiallyMuted: Bool
        let fails: Bool
        var stops = 0
        var muted: Bool
        var receive: (@Sendable (AVAudioPCMBuffer, Double) -> Void)?
        var error: (@Sendable (String) -> Void)?
        init(ids: [AudioObjectID], muted: Bool, fails: Bool = false) {
            self.ids = ids; initiallyMuted = muted; self.muted = muted; self.fails = fails
        }
        func start(queue: DispatchQueue, receive: @escaping @Sendable (AVAudioPCMBuffer, Double) -> Void,
                   onError: @escaping @Sendable (String) -> Void, onDeviceChange: (@Sendable (String) -> Void)?) throws {
            self.receive = receive
            error = onError
            if fails { throw TranscriptionError.message("Unavailable source") }
        }
        func setMuted(_ muted: Bool) throws { self.muted = muted }
        func stop(queue: DispatchQueue) { stops += 1 }
        func deliver() {
            let pcm = AVAudioPCMBuffer(pcmFormat: MeetingRecording.format, frameCapacity: 100)!
            pcm.frameLength = 100
            receive?(pcm, 100)
        }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.withLock { value += 1 } }
        var count: Int { lock.withLock { value } }
    }
}

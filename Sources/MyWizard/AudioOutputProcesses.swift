import CoreAudio
import Foundation

struct AudioOutputProcess: Equatable, Sendable {
    let id: AudioObjectID
    let pid: pid_t
    let bundleID: String?
    let isRunningOutput: Bool

    func belongsToApp(pid: pid_t, bundle: String) -> Bool {
        self.pid == pid || bundleID == bundle || (bundleID?.hasPrefix(bundle + ".") ?? false)
    }
}

// Do not attach to clients that are still opening input/output. In particular,
// a global tap held Zoom's AudioDeviceStart on this Mac. Include only live
// output clients, after a short settling period; never restore them by bundle ID.
struct ReadyAudioOutputs {
    let ownPID: pid_t
    let ownBundleID: String
    var settlingTime: TimeInterval = 0.05
    private var firstSeen: [AudioObjectID: (pid: pid_t, time: TimeInterval)] = [:]

    mutating func update(_ processes: [AudioOutputProcess], now: TimeInterval) -> (ids: [AudioObjectID], retryAfter: TimeInterval?) {
        let external = processes.filter { $0.isRunningOutput && !$0.belongsToApp(pid: ownPID, bundle: ownBundleID) }
        let currentPIDs = Dictionary(external.map { ($0.id, $0.pid) }, uniquingKeysWith: { _, latest in latest })
        let eligible = Set(currentPIDs.keys)
        // HAL object numbers are recycled. A new PID must settle independently,
        // even if creation/removal notifications were coalesced into one update.
        firstSeen = firstSeen.filter { currentPIDs[$0.key] == $0.value.pid }
        for (id, pid) in currentPIDs where firstSeen[id] == nil { firstSeen[id] = (pid, now) }
        let ready = eligible.filter { now - (firstSeen[$0]?.time ?? now) >= settlingTime }.sorted()
        let remaining = eligible.subtracting(ready).map { max(0.001, settlingTime - (now - (firstSeen[$0]?.time ?? now))) }
        return (ready, remaining.min())
    }
}

@MainActor
protocol AudioOutputMonitoring: AnyObject {
    func start(update: @escaping @MainActor ([AudioObjectID]) -> Void,
               failure: @escaping @MainActor (String) -> Void) throws
    func refresh() throws -> [AudioObjectID]
    func stop()
}

// Notifications give fast updates. A bounded reconciliation scan also handles
// HAL output-running notifications that arrive before their new value is readable
// (observed with afplay on this Mac), or are missing entirely.
@MainActor
final class AudioOutputProcesses: AudioOutputMonitoring {
    private let system = AudioObjectID(kAudioObjectSystemObject)
    private var listListener: AudioObjectPropertyListenerBlock?
    private var listeners: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    private var listenerPIDs: [AudioObjectID: pid_t] = [:]
    private var update: (@MainActor ([AudioObjectID]) -> Void)?
    private var failure: (@MainActor (String) -> Void)?
    private var pending: Task<Void, Never>?
    private var reconciliation: Task<Void, Never>?
    private var generation = UUID()
    private var ready = ReadyAudioOutputs(ownPID: getpid(), ownBundleID: Bundle.main.bundleIdentifier ?? "com.yvancognasse.MyWizard")
    private var lastIDs: [AudioObjectID]?

    func start(update: @escaping @MainActor ([AudioObjectID]) -> Void,
               failure: @escaping @MainActor (String) -> Void) throws {
        stop()
        self.update = update
        self.failure = failure
        let generation = self.generation
        let listener: AudioObjectPropertyListenerBlock = { @Sendable [weak self] _, _ in
            Task { @MainActor in self?.changed(generation: generation) }
        }
        var property = Self.address(kAudioHardwarePropertyProcessObjectList)
        let status = AudioObjectAddPropertyListenerBlock(system, &property, .main, listener)
        guard status == noErr else { stop(); throw Self.error(status) }
        listListener = listener
        do { _ = try refresh() } catch { stop(); throw error }
        reconciliation = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                guard let self, generation == self.generation, self.update != nil else { return }
                self.changed(generation: generation)
            }
        }
    }

    func stop() {
        generation = UUID()
        pending?.cancel()
        pending = nil
        reconciliation?.cancel()
        reconciliation = nil
        update = nil
        failure = nil
        if let listListener {
            var property = Self.address(kAudioHardwarePropertyProcessObjectList)
            AudioObjectRemovePropertyListenerBlock(system, &property, .main, listListener)
        }
        listListener = nil
        for (id, listener) in listeners { remove(id, listener: listener) }
        listeners = [:]
        listenerPIDs = [:]
        lastIDs = nil
        ready = ReadyAudioOutputs(ownPID: getpid(), ownBundleID: Bundle.main.bundleIdentifier ?? "com.yvancognasse.MyWizard")
    }

    private func changed(generation: UUID) {
        guard generation == self.generation, update != nil else { return }
        do { _ = try refresh() }
        catch { failure?(error.localizedDescription) }
    }

    func refresh() throws -> [AudioObjectID] {
        pending?.cancel()
        pending = nil
        var property = Self.address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(system, &property, 0, nil, &size)
        guard status == noErr else { throw Self.error(status) }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.stride)
        if size > 0 {
            status = ids.withUnsafeMutableBytes {
                AudioObjectGetPropertyData(system, &property, 0, nil, &size, $0.baseAddress!)
            }
            // A process can disappear between the two reads; a list notification
            // will cause another refresh. Keep the current capture in that case.
            if status == kAudioHardwareBadPropertySizeError { schedule(after: 0.05); return lastIDs ?? [] }
            guard status == noErr else { throw Self.error(status) }
            ids = Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.stride))
        }
        let current = Set(ids)
        for id in Array(listeners.keys) where !current.contains(id) {
            if let listener = listeners.removeValue(forKey: id) { remove(id, listener: listener) }
            listenerPIDs.removeValue(forKey: id)
        }
        var processes: [AudioOutputProcess] = []
        for id in ids {
            guard let pid: pid_t = Self.scalar(id, kAudioProcessPropertyPID, initial: pid_t(0)) else { continue }
            let bundle = Self.bundleID(id)
            let identity = AudioOutputProcess(id: id, pid: pid, bundleID: bundle, isRunningOutput: false)
            if listenerPIDs[id] != pid, let stale = listeners.removeValue(forKey: id) {
                remove(id, listener: stale)
                listenerPIDs.removeValue(forKey: id)
            }
            // Do not watch our own helper clients. Apart from saving work, this
            // prevents a recycled helper object from retaining a dead listener.
            if identity.belongsToApp(pid: ready.ownPID, bundle: ready.ownBundleID) {
                if let stale = listeners.removeValue(forKey: id) { remove(id, listener: stale) }
                listenerPIDs.removeValue(forKey: id)
                continue
            }
            if listeners[id] == nil {
                let generation = self.generation
                let listener: AudioObjectPropertyListenerBlock = { @Sendable [weak self] _, _ in
                    Task { @MainActor in self?.changed(generation: generation) }
                }
                var runningProperty = Self.address(kAudioProcessPropertyIsRunningOutput)
                let result = AudioObjectAddPropertyListenerBlock(id, &runningProperty, .main, listener)
                if result == noErr { listeners[id] = listener; listenerPIDs[id] = pid }
                else if result == kAudioHardwareBadObjectError { continue }
                else { throw Self.error(result) }
            }
            // Subscribe before reading: a fast player can start its output in
            // between these operations, otherwise losing its only notification.
            guard let running: UInt32 = Self.scalar(id, kAudioProcessPropertyIsRunningOutput, initial: UInt32(0)) else { continue }
            processes.append(.init(id: id, pid: pid, bundleID: bundle, isRunningOutput: running != 0))
        }
        let result = ready.update(processes, now: ProcessInfo.processInfo.systemUptime)
        if result.ids != lastIDs {
            lastIDs = result.ids
            update?(result.ids)
        }
        if let delay = result.retryAfter { schedule(after: delay) }
        return result.ids
    }

    private func schedule(after delay: TimeInterval) {
        let generation = self.generation
        pending = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            self?.changed(generation: generation)
        }
    }

    private func remove(_ id: AudioObjectID, listener: @escaping AudioObjectPropertyListenerBlock) {
        var property = Self.address(kAudioProcessPropertyIsRunningOutput)
        AudioObjectRemovePropertyListenerBlock(id, &property, .main, listener)
    }

    private static func scalar<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, initial: T) -> T? {
        var result = initial, size = UInt32(MemoryLayout<T>.size), property = address(selector)
        let status = withUnsafeMutableBytes(of: &result) {
            AudioObjectGetPropertyData(id, &property, 0, nil, &size, $0.baseAddress!)
        }
        return status == noErr ? result : nil
    }

    private static func bundleID(_ id: AudioObjectID) -> String? {
        var raw: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size), property = address(kAudioProcessPropertyBundleID)
        let status = withUnsafeMutableBytes(of: &raw) {
            AudioObjectGetPropertyData(id, &property, 0, nil, &size, $0.baseAddress!)
        }
        guard status == noErr, let string = raw?.takeRetainedValue() else { return nil }
        return string as String
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        .init(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    private static func error(_ status: OSStatus) -> TranscriptionError {
        .message("Cannot monitor system audio sources (\(status)). Check Audio Recording permission, then retry.")
    }
}

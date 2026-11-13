import AVFoundation
import CoreAudio

@MainActor
protocol SystemAudioTapControlling: AnyObject {
    func start(queue: DispatchQueue, receive: @escaping @Sendable (AVAudioPCMBuffer, Double) -> Void,
               onError: @escaping @Sendable (String) -> Void, onDeviceChange: (@Sendable (String) -> Void)?) throws
    func setMuted(_ muted: Bool) throws
    func stop(queue: DispatchQueue)
}

// Arm capture at Start, but attach only to applications whose output is ready.
// A global tap could deadlock Zoom's input startup before it opens its output.
@MainActor
final class SystemAudioTap: SystemAudioTapControlling {
    private struct Callbacks {
        let queue: DispatchQueue
        let receive: @Sendable (AVAudioPCMBuffer, Double) -> Void
        let error: @Sendable (String) -> Void
        let changed: (@Sendable (String) -> Void)?
    }
    private let monitor: any AudioOutputMonitoring
    private let makeTap: @MainActor ([AudioObjectID], Bool) -> any SystemAudioTapControlling
    private let gate = AudioTapGeneration()
    private var callbacks: Callbacks?
    private var tap: (any SystemAudioTapControlling)?
    private var ids: [AudioObjectID] = []
    private var muted = false
    var capturedProcessIDs: [AudioObjectID] { ids }

    init(monitor: (any AudioOutputMonitoring)? = nil,
         makeTap: (@MainActor ([AudioObjectID], Bool) -> any SystemAudioTapControlling)? = nil) {
        self.monitor = monitor ?? AudioOutputProcesses()
        self.makeTap = makeTap ?? { ProcessAudioTap(processes: $0, muted: $1) }
    }

    func start(queue: DispatchQueue, receive: @escaping @Sendable (AVAudioPCMBuffer, Double) -> Void,
               onError: @escaping @Sendable (String) -> Void, onDeviceChange: (@Sendable (String) -> Void)? = nil) throws {
        stop(queue: queue)
        callbacks = Callbacks(queue: queue, receive: receive, error: onError, changed: onDeviceChange)
        do {
            try monitor.start(update: { [weak self] ids in self?.sourcesChanged(ids) },
                              failure: { [weak self] message in self?.callbacks?.error(message) })
        } catch { stop(queue: queue); throw error }
    }

    func setMuted(_ muted: Bool) throws {
        try tap?.setMuted(muted)
        self.muted = muted // Also applies to sources that start while reading.
    }

    func stop(queue: DispatchQueue) {
        monitor.stop()
        callbacks = nil
        gate.set(nil)
        tap?.stop(queue: queue)
        tap = nil
        ids = []
        muted = false
    }

    private func sourcesChanged(_ sources: [AudioObjectID]) {
        guard let callbacks else { return }
        let sources = Array(Set(sources)).sorted()
        guard sources != ids else { return }
        gate.set(nil)
        tap?.stop(queue: callbacks.queue)
        callbacks.queue.sync {} // Finish any accepted old buffers before the next source clock.
        tap = nil
        ids = []
        guard !sources.isEmpty else { return }
        let token = UUID()
        gate.set(token)
        let gate = self.gate
        let next = makeTap(sources, muted)
        do {
            try next.start(queue: callbacks.queue, receive: { pcm, time in
                guard gate.matches(token) else { return }
                callbacks.receive(pcm, time)
            }, onError: { message in
                guard gate.matches(token) else { return }
                callbacks.error(message)
            }, onDeviceChange: { message in
                guard gate.matches(token) else { return }
                (callbacks.changed ?? callbacks.error)(message)
            })
            tap = next
            ids = sources
        } catch {
            gate.set(nil)
            next.stop(queue: callbacks.queue)
            // A short-lived notification/player may exit between selection and
            // tap creation. Reconcile once instead of ending the whole meeting.
            do {
                let current = try monitor.refresh()
                if current != sources { return }
            } catch { /* Report the original start error if the catalog is unavailable. */ }
            callbacks.error(error.localizedDescription)
        }
    }
}

private final class AudioTapGeneration: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UUID?
    func set(_ token: UUID?) { lock.withLock { value = token } }
    func matches(_ token: UUID) -> Bool { lock.withLock { value == token } }
}

// A private, input-only aggregate. It never changes the user's default device
// or output volume. Control methods belong to the main actor; the callback is
// delivered on the capture's serial queue and must consume/copy borrowed PCM.
@MainActor
final class ProcessAudioTap: SystemAudioTapControlling {
    private let processes: [AudioObjectID]
    private let initiallyMuted: Bool

    init(processes: [AudioObjectID], muted: Bool) {
        precondition(!processes.isEmpty)
        self.processes = processes
        initiallyMuted = muted
    }

    private var tapID: AudioObjectID = 0
    private var deviceID: AudioObjectID = 0
    private var ioProc: AudioDeviceIOProcID?
    private var description: CATapDescription?
    private var formatListener: AudioObjectPropertyListenerBlock?
    private var outputListener: AudioObjectPropertyListenerBlock?

    func start(queue: DispatchQueue,
               receive: @escaping @Sendable (AVAudioPCMBuffer, Double) -> Void,
               onError: @escaping @Sendable (String) -> Void,
               onDeviceChange: (@Sendable (String) -> Void)? = nil) throws {
        let changed = onDeviceChange ?? onError
        do {
            let description = CATapDescription(stereoMixdownOfProcesses: processes)
            description.isProcessRestoreEnabled = false
            var size = UInt32(MemoryLayout<AudioObjectID>.size)
            var address = Self.address(kAudioTapPropertyFormat)
            description.name = "MyWizard system audio"
            description.isPrivate = true
            description.muteBehavior = initiallyMuted ? .mutedWhenTapped : .unmuted
            try Self.check(AudioHardwareCreateProcessTap(description, &tapID), "Create system audio capture")
            self.description = description

            var asbd = AudioStreamBasicDescription()
            size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            address = Self.address(kAudioTapPropertyFormat)
            try Self.check(AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd), "Read system audio format")
            guard let format = AVAudioFormat(streamDescription: &asbd), asbd.mBytesPerFrame > 0 else {
                throw TranscriptionError.message("System audio has an unsupported format.")
            }
            let composition: [String: Any] = [
                kAudioAggregateDeviceNameKey: "MyWizard capture",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceIsPrivateKey: true,
                // Never wait for a tapped client to produce its first audio:
                // that dependency can hold another client's AudioDeviceStart.
                kAudioAggregateDeviceTapAutoStartKey: false,
                kAudioAggregateDeviceTapListKey: [[
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true
                ]]
            ]
            try Self.check(AudioHardwareCreateAggregateDevice(composition as CFDictionary, &deviceID), "Create audio input")
            try Self.check(AudioDeviceCreateIOProcIDWithBlock(&ioProc, deviceID, queue) { @Sendable _, input, time, _, _ in
                let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
                guard let first = buffers.first, first.mDataByteSize > 0 else { return }
                let frames = AVAudioFrameCount(first.mDataByteSize / format.streamDescription.pointee.mBytesPerFrame)
                guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
                pcm.frameLength = frames
                let destination = UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList)
                guard buffers.count == destination.count else {
                    changed("System audio format changed.")
                    return
                }
                for (source, target) in zip(buffers, destination) {
                    guard source.mNumberChannels == target.mNumberChannels,
                          source.mDataByteSize <= target.mDataByteSize,
                          let from = source.mData, let to = target.mData else {
                        changed("System audio format changed.")
                        return
                    }
                    memcpy(to, from, Int(source.mDataByteSize))
                }
                receive(pcm, AVAudioTime.seconds(forHostTime: time.pointee.mHostTime))
            }, "Connect system audio input")
            try Self.check(AudioDeviceStart(deviceID, ioProc), "Start system audio capture (check Audio Recording permission)")
            let listener: AudioObjectPropertyListenerBlock = { @Sendable _, _ in
                changed("System audio format changed. Check the output device.")
            }
            try Self.check(AudioObjectAddPropertyListenerBlock(tapID, &address, queue, listener), "Monitor system audio format")
            formatListener = listener
            var outputAddress = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
            let outputListener: AudioObjectPropertyListenerBlock = { @Sendable _, _ in
                changed("The system audio output device changed.")
            }
            try Self.check(AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                &outputAddress, queue, outputListener), "Monitor system audio output")
            self.outputListener = outputListener
        } catch {
            stop(queue: queue)
            throw error
        }
    }

    func setMuted(_ muted: Bool) throws {
        guard tapID != 0, let description else { return }
        let behavior: CATapMuteBehavior = muted ? .mutedWhenTapped : .unmuted
        guard description.muteBehavior != behavior else { return }
        let previous = description.muteBehavior
        description.muteBehavior = behavior
        var value = description
        var address = Self.address(kAudioTapPropertyDescription)
        let status = withUnsafePointer(to: &value) { pointer in
            AudioObjectSetPropertyData(tapID, &address, 0, nil,
                UInt32(MemoryLayout<CATapDescription>.size), pointer)
        }
        if status != noErr { description.muteBehavior = previous }
        try Self.check(status, muted ? "Mute original audio" : "Restore original audio")
    }

    func stop(queue: DispatchQueue) {
        // mutedWhenTapped restores playback as soon as IO stops, even if a
        // subsequent device/tap destruction fails.
        try? setMuted(false)
        if let ioProc {
            AudioDeviceStop(deviceID, ioProc)
            AudioDeviceDestroyIOProcID(deviceID, ioProc)
        }
        ioProc = nil
        if let formatListener {
            var address = Self.address(kAudioTapPropertyFormat)
            AudioObjectRemovePropertyListenerBlock(tapID, &address, queue, formatListener)
        }
        formatListener = nil
        if let outputListener {
            var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, outputListener)
        }
        outputListener = nil
        if deviceID != 0 { AudioHardwareDestroyAggregateDevice(deviceID) }
        if tapID != 0 { AudioHardwareDestroyProcessTap(tapID) }
        deviceID = 0
        tapID = 0
        description = nil
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    private static func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else { throw TranscriptionError.message("\(operation) failed (\(status)).") }
    }
}

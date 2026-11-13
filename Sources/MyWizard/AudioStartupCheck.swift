import AVFoundation
import CoreAudio
import Foundation

// Opt-in regression probe. No meeting is joined and no microphone PCM is saved.
// A separate client starts the physical input/output before and during capture.
@MainActor
enum AudioStartupCheck {
    static func run() async throws {
        let tap = SystemAudioTap()
        let meter = StartupAudioMeter()
        try tap.start(queue: meter.queue, receive: { pcm, _ in meter.received(pcm) }, onError: { meter.failed($0) })
        defer { tap.stop(queue: meter.queue) }
        try await runClient(tap: tap, queue: meter.queue, stage: "armed before output")

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MyWizard-audio-startup-\(UUID()).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000 * 12)!
        silence.frameLength = silence.frameCapacity
        silence.floatChannelData![0].initialize(repeating: 0, count: Int(silence.frameLength))
        do { let file = try AVAudioFile(forWriting: url, settings: format.settings); try file.write(from: silence) }
        let player = Process()
        player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        player.arguments = [url.path]
        try player.run()
        defer { if player.isRunning { player.terminate() } }
        let buffersBefore = meter.buffers
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        var attached = false
        var attachedBaseline: Int?
        while meter.error == nil && ProcessInfo.processInfo.systemUptime < deadline {
            if let id = processObject(player.processIdentifier), tap.capturedProcessIDs.contains(id) {
                if let baseline = attachedBaseline, meter.buffers > baseline, meter.buffers > buffersBefore {
                    attached = true
                    break
                }
                if attachedBaseline == nil { attachedBaseline = meter.buffers }
            } else { attachedBaseline = nil }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard attached, meter.error == nil else {
            throw TranscriptionError.message("New output check failed: object=\(processObject(player.processIdentifier).map(String.init) ?? "missing"), attached=\(tap.capturedProcessIDs), buffers=\(meter.buffers), error=\(meter.error ?? "timeout").")
        }
        try await runClient(tap: tap, queue: meter.queue, stage: "capture already receiving output")
        guard meter.error == nil else { throw TranscriptionError.message(meter.error!) }
        print("AUDIO STARTUP CHECK PASS: physical input/output opened in separate clients before and during system capture; new external output captured; no microphone content saved.")
    }

    private static func runClient(tap: SystemAudioTap, queue: DispatchQueue, stage: String) async throws {
        let client = Process()
        client.executableURL = Bundle.main.executableURL
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "MYWIZARD_AUDIO_STARTUP_CHECK")
        environment["MYWIZARD_AUDIO_STARTUP_CLIENT"] = "1"
        client.environment = environment
        try client.run()
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        while client.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        if client.isRunning {
            // Free our tap before terminating the isolated test client. This
            // also releases the legacy deadlock, without touching Zoom.
            tap.stop(queue: queue)
            try await Task.sleep(for: .milliseconds(300))
            if client.isRunning { client.terminate() }
            try await Task.sleep(for: .milliseconds(300))
            if client.isRunning { kill(client.processIdentifier, SIGKILL) }
            throw TranscriptionError.message("AudioDeviceStart timed out in the test client (\(stage)).")
        }
        guard client.terminationStatus == 0 else {
            throw TranscriptionError.message("Audio startup test client failed (\(stage), status \(client.terminationStatus)).")
        }
    }

    static func runClient() async throws {
        var input: AudioObjectID = 0, output: AudioObjectID = 0
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var property = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size, &input), "Read default input")
        property.mSelector = kAudioHardwarePropertyDefaultOutputDevice
        try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size, &output), "Read default output")
        let queue = DispatchQueue(label: "MyWizard.startup-client")
        var clients: [(AudioObjectID, AudioDeviceIOProcID)] = []
        defer {
            for (id, io) in clients.reversed() {
                AudioDeviceStop(id, io)
                AudioDeviceDestroyIOProcID(id, io)
            }
        }
        for id in Array(Set([input, output])).sorted() {
            guard id != 0 else { throw TranscriptionError.message("No default audio device.") }
            var io: AudioDeviceIOProcID?
            try check(AudioDeviceCreateIOProcIDWithBlock(&io, id, queue) { @Sendable _, _, _, output, _ in
                // Never play borrowed or uninitialized samples. No input data is retained.
                for buffer in UnsafeMutableAudioBufferListPointer(output) {
                    if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
                }
            }, "Create isolated device client")
            guard let io else { throw TranscriptionError.message("No audio IOProc.") }
            clients.append((id, io))
            try check(AudioDeviceStart(id, io), "Start isolated audio client")
        }
        try await Task.sleep(for: .milliseconds(250))
        print("AUDIO STARTUP CLIENT PASS")
    }

    private static func processObject(_ process: pid_t) -> AudioObjectID? {
        var pid = process, object: AudioObjectID = 0
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var property = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property,
            UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr && object != 0 ? object : nil
    }

    private static func check(_ status: OSStatus, _ name: String) throws {
        if status != noErr { throw TranscriptionError.message("\(name) failed (\(status)).") }
    }
}

private final class StartupAudioMeter: @unchecked Sendable {
    let queue = DispatchQueue(label: "MyWizard.audio-startup-meter")
    private let lock = NSLock()
    private var count = 0
    private var message: String?
    var buffers: Int { lock.withLock { count } }
    var error: String? { lock.withLock { message } }
    func received(_ pcm: AVAudioPCMBuffer) { if pcm.frameLength > 0 { lock.withLock { count += 1 } } }
    func failed(_ error: String) { lock.withLock { message = error } }
}

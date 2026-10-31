import AVFoundation
import Foundation

// Isolated integration check: real speech/speaker engines, simulated taps,
// no microphone or system audio device is ever opened.
@MainActor
enum MeetingControlsCheck {
    static func run() async throws {
        let suite = "MyWizard.ControlsCheck.\(UUID())"
        let preferences = MemoryPreferences()
        preferences.set(false, forKey: "includesMicrophone")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        var taps: [CheckTap] = []
        var failNextTap = false
        let model = TranscriptionModel(preferences: preferences, recordingRoot: root, systemCaptureFactory: { timeline in
            SystemAudioCapture(timeline: timeline, makeTap: {
                let tap = CheckTap(fails: failNextTap)
                failNextTap = false
                taps.append(tap)
                return tap
            })
        })
        await model.toggleCapture()
        try require(model.isCapturing && !model.isPaused, "Start failed: \(model.statusMessage ?? "")")
        let buffer = AVAudioPCMBuffer(pcmFormat: MeetingRecording.format, frameCapacity: 8_000)!
        buffer.frameLength = 8_000
        buffer.floatChannelData![0].initialize(repeating: 0, count: 8_000)
        taps.last?.deliver(buffer)
        await model.retryInterruptedCapture()
        try require(model.isCapturing && !model.isPaused, "Retry interrupted a healthy capture")
        taps.last?.changed?("Simulated output device disconnected")
        for _ in 0..<100 {
            if model.isPaused && !model.isTransitioning { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try require(model.isPaused && model.captureInterruption != nil, "Device change did not pause capture")
        let frames = model.capturedFrameCounts.system
        taps.last?.deliver(buffer)
        try require(model.capturedFrameCounts.system == frames, "Interrupted capture accepted audio")
        failNextTap = true
        await model.retryInterruptedCapture()
        try require(model.isPaused && model.isCapturing, "Failed resume did not remain paused")
        await model.retryInterruptedCapture()
        try require(!model.isPaused && model.isCapturing, "Retry did not resume the same meeting")
        taps.last?.deliver(buffer)
        await model.toggleCapture()
        try require(!model.isCapturing && model.needsProcessing, "Stop did not retain the meeting for export")
        let folders = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "mywizard" }
        try require(folders.count == 1, "Audio retry created multiple meeting folders")
        let saved = try RecordedMeeting.load(folders[0])
        _ = try saved.loadLiveTranscript()
        try require(!FileManager.default.fileExists(atPath: saved.directory.appendingPathComponent("meeting-events.json").path), "Recording created a retired event log")
        await model.shutDown()
        print("MEETING CONTROLS CHECK PASS: healthy capture ignores retry; interruption excludes audio; failed retry stays interrupted; same-session recovery; snapshot persisted; no audio devices opened")
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw TranscriptionError.message(message) }
    }

    private final class CheckTap: SystemAudioTapControlling {
        let fails: Bool
        private var queue: DispatchQueue?
        private var receive: (@Sendable (AVAudioPCMBuffer, Double) -> Void)?
        var changed: (@Sendable (String) -> Void)?
        init(fails: Bool) { self.fails = fails }
        func start(queue: DispatchQueue, receive: @escaping @Sendable (AVAudioPCMBuffer, Double) -> Void,
                   onError: @escaping @Sendable (String) -> Void, onDeviceChange: (@Sendable (String) -> Void)?) throws {
            if fails { throw TranscriptionError.message("Simulated unavailable output") }
            self.queue = queue
            self.receive = receive
            changed = onDeviceChange
        }
        func stop(queue: DispatchQueue) { receive = nil }
        func setMuted(_ muted: Bool) throws {}
        func deliver(_ pcm: AVAudioPCMBuffer) {
            guard let receive, let queue else { return }
            let now = AVAudioTime.seconds(forHostTime: mach_absolute_time())
            queue.sync { receive(pcm, now) }
        }
    }
}

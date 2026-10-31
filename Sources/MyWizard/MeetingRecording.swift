import AVFoundation
import Foundation

enum RecordedTrack: String, Codable, CaseIterable, Sendable { case system, microphone, reading }

struct RecordingManifest: Codable, Sendable {
    let id: UUID
    let created: Date
    let language: String
    var microphone: Bool
    var detectSpeakers: Bool
    var state = "recording"
    var mutedSystem: [AudioMuteEvent] = []
    var failure: String?
}

struct AudioMuteEvent: Codable, Sendable {
    let time: Double
    let muted: Bool
}

struct RecordedMeeting: Sendable, Identifiable {
    let directory: URL
    var manifest: RecordingManifest
    var id: UUID { manifest.id }
    func audio(_ track: RecordedTrack) -> URL { directory.appendingPathComponent(track.rawValue + ".caf") }

    static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MyWizard/Recordings", isDirectory: true)
    }

    static func load(_ directory: URL) throws -> RecordedMeeting {
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true, directory.pathExtension == "mywizard" else {
            throw TranscriptionError.message("Choose a MyWizard recording folder.")
        }
        let manifestURL = directory.appendingPathComponent("session.json")
        guard try manifestURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw TranscriptionError.message("Recording files cannot be symbolic links.")
        }
        var manifest = try JSONDecoder().decode(RecordingManifest.self,
            from: Data(contentsOf: manifestURL))
        guard directory.deletingPathExtension().lastPathComponent == manifest.id.uuidString else {
            throw TranscriptionError.message("The recording identity is invalid.")
        }
        for track in RecordedTrack.allCases {
            let file = directory.appendingPathComponent(track.rawValue + ".caf")
            if FileManager.default.fileExists(atPath: file.path),
               try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
                throw TranscriptionError.message("Recording tracks cannot be symbolic links.")
            }
        }
        for name in ["session.json", "analysis.json", "live-transcript.json", "session.lock", "microphone-cleaned.caf", "meeting.mp4", "export-checkpoint.json"] {
            let file = directory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: file.path),
               try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
                throw TranscriptionError.message("Recording files cannot be symbolic links.")
            }
        }
        if manifest.state == "recording" {
            manifest.state = "interrupted"
            manifest.failure = "This recording was not closed cleanly. Some audio may be missing."
        }
        return RecordedMeeting(directory: directory, manifest: manifest)
    }

    func saveManifest() throws {
        try JSONEncoder().encode(manifest).write(to: directory.appendingPathComponent("session.json"), options: .atomic)
    }
}

// Owns its files/converters exclusively on one bounded writer queue. Audio
// callbacks only copy/enqueue; slow disks never block capture or silently drop.
final class MeetingRecording: @unchecked Sendable {
    let id: UUID
    let startedAt: Date
    let directory: URL
    private let queue = DispatchQueue(label: "MyWizard.recording", qos: .utility)
    private let lock = NSLock()
    private var pendingBytes = 0
    private var accepting = true
    private var lease: RecordingLease?
    private var files: [RecordedTrack: AVAudioFile] = [:]
    private var converters: [RecordedTrack: AudioConverter] = [:]
    private var writtenFrames: [RecordedTrack: Int64] = [:]
    private var meeting: RecordedMeeting
    private let origin: Double
    var hostTimeOrigin: Double { origin }
    private let onError: @Sendable (String) -> Void
    static let sampleRate = 16_000.0
    static var format: AVAudioFormat { AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)! }

    init(language: String, microphone: Bool, detectSpeakers: Bool, root: URL = RecordedMeeting.root,
         origin: Double = AVAudioTime.seconds(forHostTime: mach_absolute_time()),
         onError: @escaping @Sendable (String) -> Void) throws {
        self.origin = origin
        self.onError = onError
        let manifest = RecordingManifest(id: UUID(), created: Date(), language: language,
            microphone: microphone, detectSpeakers: detectSpeakers)
        id = manifest.id
        startedAt = manifest.created
        let directory = root.appendingPathComponent(manifest.id.uuidString + ".mywizard", isDirectory: true)
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        lease = try RecordingLease(directory: directory)
        meeting = RecordedMeeting(directory: directory, manifest: manifest)
        try meeting.saveManifest()
        for track in RecordedTrack.allCases where track != .microphone || microphone {
            files[track] = try Self.makeFile(meeting.audio(track))
            converters[track] = AudioConverter(outputFormat: Self.format)
        }
    }

    static func makeFile(_ url: URL) throws -> AVAudioFile {
        try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false],
            commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    // A session may start system-only and enable the microphone later. The
    // same track is reused after every mute/unmute; existing speech is retained.
    func enableMicrophone() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                do {
                    guard lock.withLock({ accepting }), meeting.manifest.failure == nil else {
                        throw TranscriptionError.message("This recording is no longer accepting microphone audio.")
                    }
                    if files[.microphone] == nil {
                        files[.microphone] = try Self.makeFile(meeting.audio(.microphone))
                        converters[.microphone] = AudioConverter(outputFormat: Self.format)
                    }
                    meeting.manifest.microphone = true
                    try meeting.saveManifest()
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func append(_ pcm: AVAudioPCMBuffer, track: RecordedTrack, time: Double) throws {
        guard pcm.frameLength > 0, time.isFinite else { return }
        let bytes = Int(pcm.frameLength) * Int(pcm.format.channelCount) * 4
        // Serialize acceptance, copying and enqueueing with finish, so an
        // accepted callback cannot be queued after the files have been closed.
        lock.lock()
        defer { lock.unlock() }
        guard accepting else { return }
            guard pendingBytes + bytes <= 16 * 1024 * 1024 else {
                throw TranscriptionError.message("The recording disk cannot keep up. Audio already recorded is preserved.")
            }
        let buffer = try AudioConverter.copyPCM(pcm)
        pendingBytes += bytes
        // This wrapper owns an independent PCM copy, never a borrowed tap buffer.
        let owned = OwnedRecordingBuffer(buffer: buffer)
        queue.async { [self] in
            defer { lock.withLock { pendingBytes -= bytes } }
            guard meeting.manifest.failure == nil else { return }
            do {
                guard let file = files[track], let converter = converters[track] else { return }
                let converted = try converter.convert(owned.buffer)
                let targetFrame = max(0, Int64(((time - origin) * Self.sampleRate).rounded()))
                // Preserve gaps (including reader pauses) and startup offsets.
                // Ignore sub-buffer timestamp jitter rather than duplicating audio.
                // CAF's reported length/position may lag buffered writes.
                // Count accepted frames ourselves on this sole writer queue.
                var written = writtenFrames[track] ?? 0
                if targetFrame > written + 160 {
                    try Self.writeSilence(frames: targetFrame - written, to: file)
                    written = targetFrame
                }
                try file.write(from: converted)
                writtenFrames[track] = written + Int64(converted.frameLength)
            } catch {
                meeting.manifest.failure = error.localizedDescription
                meeting.manifest.state = "interrupted"
                try? meeting.saveManifest()
                onError("Audio recording failed: \(error.localizedDescription). Existing files are preserved.")
            }
        }
    }

    func systemMuted(_ muted: Bool, at time: Double = AVAudioTime.seconds(forHostTime: mach_absolute_time())) {
        queue.async { [self] in
            meeting.manifest.mutedSystem.append(AudioMuteEvent(time: max(0, time - origin), muted: muted))
            do { try meeting.saveManifest() } catch { onError("Cannot save recording metadata: \(error.localizedDescription)") }
        }
    }

    func fail(_ message: String) {
        queue.async { [self] in
            guard meeting.manifest.failure == nil else { return }
            meeting.manifest.failure = message
            meeting.manifest.state = "interrupted"
            try? meeting.saveManifest()
            onError(message)
        }
    }

    func finish() async -> RecordedMeeting {
        lock.withLock { accepting = false }
        return await withCheckedContinuation { continuation in
            queue.async { [self] in
                files = [:] // Flush CAF headers before analysis or recovery.
                converters = [:]
                meeting.manifest.state = meeting.manifest.failure == nil ? "recorded" : "interrupted"
                do { try meeting.saveManifest() }
                catch { meeting.manifest.failure = error.localizedDescription }
                lease = nil
                continuation.resume(returning: meeting)
            }
        }
    }

    private static func writeSilence(frames: Int64, to file: AVAudioFile) throws {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192)!
        buffer.floatChannelData![0].initialize(repeating: 0, count: 8192)
        var remaining = frames
        while remaining > 0 {
            buffer.frameLength = AVAudioFrameCount(min(8192, remaining))
            try file.write(from: buffer)
            remaining -= Int64(buffer.frameLength)
        }
    }
}

private final class OwnedRecordingBuffer: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    init(buffer: AVAudioPCMBuffer) { self.buffer = buffer }
}

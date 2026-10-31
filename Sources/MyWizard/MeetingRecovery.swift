import Foundation
import Darwin

// Prevent recovery/export of a recording still being written by another
// instance. The OS releases the lease after a crash, so recovery remains possible.
final class RecordingLease: @unchecked Sendable {
    private let descriptor: Int32

    init(directory: URL) throws {
        descriptor = Darwin.open(directory.appendingPathComponent("session.lock").path,
                                 O_CREAT | O_RDWR | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw TranscriptionError.message("Cannot lock this recording.") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw TranscriptionError.message("This recording is open in another MyWizard window. Close it there before recovering.")
        }
    }

    deinit { flock(descriptor, LOCK_UN); close(descriptor) }
}

struct RecoveryCandidate: Identifiable, Sendable {
    let meeting: RecordedMeeting
    let issue: String?
    var id: UUID { meeting.id }

    static func discover(in root: URL) throws -> [RecoveryCandidate] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: root,
            includingPropertiesForKeys: [.isSymbolicLinkKey], options: [.skipsHiddenFiles]).compactMap { url in
            guard url.pathExtension == "mywizard", let meeting = try? RecordedMeeting.load(url) else { return nil }
            do {
                let lease = try RecordingLease(directory: url)
                return withExtendedLifetime(lease) {
                    do {
                        _ = try meeting.loadLiveTranscript()
                        return RecoveryCandidate(meeting: meeting, issue: nil)
                    } catch { return RecoveryCandidate(meeting: meeting, issue: error.localizedDescription) }
                }
            } catch { return nil } // An actively written meeting is not recoverable yet.
        }.sorted { $0.meeting.manifest.created > $1.meeting.manifest.created }
    }
}

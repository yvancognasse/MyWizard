import Foundation
import Testing
@testable import MyWizard

struct RecordingCleanupTests {
    func meeting(in root: URL) async throws -> RecordedMeeting {
        let recorder = try MeetingRecording(language: "en-US", microphone: false, detectSpeakers: false,
                                            root: root) { _ in }
        return await recorder.finish()
    }

    @Test func removesOnlyExportedSessionsAndKeepsTextAndOtherRecordings() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MyWizardCleanup-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let exported = try await meeting(in: root)
        let other = try await meeting(in: root)
        let text = root.appendingPathComponent("notes.txt")
        try Data("Speaker 2: Meeting notes".utf8).write(to: text)
        let result = RecordingCleanup.afterExport([exported, exported], remove: FileManager.default.removeItem(at:))
        #expect(result.removed == [exported.id])
        #expect(result.failures.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: exported.directory.path))
        #expect(FileManager.default.fileExists(atPath: other.directory.path))
        #expect(try String(contentsOf: text, encoding: .utf8) == "Speaker 2: Meeting notes")
    }

    @Test func cleanupFailureDoesNotPreventOtherExportedSessionsFromBeingRemoved() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MyWizardCleanup-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try await meeting(in: root)
        let second = try await meeting(in: root)
        let result = RecordingCleanup.afterExport([first, second]) { url in
            if url == first.directory { throw CocoaError(.fileWriteNoPermission) }
            try FileManager.default.removeItem(at: url)
        }
        #expect(result.removed == [second.id])
        #expect(result.failures.count == 1)
        #expect(FileManager.default.fileExists(atPath: first.directory.path))
    }

    @Test func rejectsBroadFoldersChangedIdentityAndSymbolicLinks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MyWizardCleanup-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let valid = try await meeting(in: root)
        let other = try await meeting(in: root)
        let link = root.appendingPathComponent("linked.mywizard")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: valid.directory)
        let invalid = [RecordedMeeting(directory: root, manifest: valid.manifest),
                       RecordedMeeting(directory: valid.directory, manifest: other.manifest),
                       RecordedMeeting(directory: link, manifest: valid.manifest)]
        var attempted = false
        let result = RecordingCleanup.afterExport(invalid) { _ in attempted = true }
        #expect(!attempted)
        #expect(result.removed.isEmpty)
        #expect(result.failures.count == 3)
        #expect(FileManager.default.fileExists(atPath: valid.directory.path))
    }
}

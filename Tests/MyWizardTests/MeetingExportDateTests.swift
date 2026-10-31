import Foundation
import Testing
@testable import MyWizard

@MainActor
struct MeetingExportDateTests {
    @Test func filenameKeepsRecordingStartAcrossSessionsCleanupAndReexport() throws {
        let preferences = MemoryPreferences()
        let model = TranscriptionModel(preferences: preferences)
        let start = try #require(ISO8601DateFormatter().date(from: "2026-09-30T21:24:00Z"))
        let nextDay = start.addingTimeInterval(7200)
        let paris = try #require(TimeZone(identifier: "Europe/Paris"))
        #expect(model.recordingStartedAt == nil)
        model.recordingBegan(at: start)
        model.recordingBegan(at: nextDay)
        model.recordingsRemoved([])
        #expect(model.recordingStartedAt == start)
        #expect(TranscriptExporter.defaultFilename(for: try #require(model.recordingStartedAt), timeZone: paris)
                == "Meeting Notes on 30 September 2026 23h24.txt")
        model.clear()
        #expect(model.recordingStartedAt == nil)
        model.recordingBegan(at: nextDay)
        #expect(TranscriptExporter.defaultFilename(for: try #require(model.recordingStartedAt), timeZone: paris)
                == "Meeting Notes on 1 October 2026 01h24.txt")
    }

    @Test func recoveredRecordingUsesItsOriginalManifestDate() async throws {
        let suite = "MyWizard.RecoveredDate.\(UUID())"
        let preferences = MemoryPreferences()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let recorder = try MeetingRecording(language: "en-US", microphone: false, detectSpeakers: true,
                                            root: root) { _ in }
        let saved = await recorder.finish()
        try saved.saveLiveTranscript(SpeakerTranscript().liveSnapshot(names: [:]))
        #expect(recorder.startedAt == saved.manifest.created)
        let original = Date(timeIntervalSince1970: 1_700_000_000)
        let oldManifest = RecordingManifest(id: saved.id, created: original, language: "en-US",
                                            microphone: false, detectSpeakers: true, state: "recorded")
        try RecordedMeeting(directory: saved.directory, manifest: oldManifest).saveManifest()
        let model = TranscriptionModel(preferences: preferences)
        try model.recover(saved.directory)
        #expect(model.recordingStartedAt == original)
    }
}

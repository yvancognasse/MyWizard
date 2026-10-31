import Foundation
import Testing
@testable import MyWizard

struct RecordingDurationTests {
    @Test func durationUsesHoursMinutesAndWholeSecondsWithoutWrapping() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        for (seconds, expected) in [(0.0, "00:00:00"), (0.999, "00:00:00"), (1, "00:00:01"),
                                    (59.999, "00:00:59"), (60, "00:01:00"), (61, "00:01:01"),
                                    (3599, "00:59:59"), (3600, "01:00:00"), (5407, "01:30:07"),
                                    (86400, "24:00:00"), (360001, "100:00:01"), (-60, "00:00:00")] {
            #expect(RecordingDuration.text(startedAt: start, now: start.addingTimeInterval(seconds)) == expected)
        }
    }

    @Test func newSessionStartsAgainAtZero() {
        let first = Date(timeIntervalSince1970: 1_700_000_000)
        let second = first.addingTimeInterval(5400)
        #expect(RecordingDuration.text(startedAt: first, now: second) == "01:30:00")
        #expect(RecordingDuration.text(startedAt: second, now: second) == "00:00:00")
        #expect(RecordingDuration.text(startedAt: second, now: second.addingTimeInterval(61)) == "00:01:01")
    }

    @MainActor @Test func idleCounterDoesNotUseTheRetainedExportStartDate() throws {
        let preferences = MemoryPreferences()
        let model = TranscriptionModel(preferences: preferences)
        #expect(model.activeRecordingStartedAt == nil)
        model.recordingBegan(at: Date(timeIntervalSince1970: 1_700_000_000))
        #expect(model.recordingStartedAt != nil)
        #expect(model.activeRecordingStartedAt == nil)
        model.clear()
        #expect(model.activeRecordingStartedAt == nil)
    }
}

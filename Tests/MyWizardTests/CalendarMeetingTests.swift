import Foundation
import Testing
@testable import MyWizard

@MainActor
struct CalendarMeetingTests {
    private func meeting() -> CalendarMeeting {
        .init(id: "event", title: "Budget / review: Q4", start: Date(timeIntervalSince1970: 1000),
              end: Date(timeIntervalSince1970: 2000), calendar: "Work", invitees: ["Alice", "Bob"])
    }

    @Test func titleBecomesAValidFilenameAndDefaultIsPreserved() throws {
        let date = Date(timeIntervalSince1970: 0)
        let zone = try #require(TimeZone(secondsFromGMT: 0))
        let filename = TranscriptExporter.defaultFilename(for: date, timeZone: zone, title: meeting().title)
        #expect(filename == "Budget   review  Q4 on 1 January 1970 00h00.txt")
        #expect(try TranscriptExporter.validatedFilename(filename) == filename)
        #expect(TranscriptExporter.defaultFilename(for: date, timeZone: zone, title: "...")
                == TranscriptExporter.defaultFilename(for: date, timeZone: zone))
    }

    @Test func inviteesAreTrimmedAndDeduplicated() {
        #expect(CalendarMeeting.names([" Alice ", "alice", "", "Bob"]) == ["Alice", "Bob"])
    }

    @Test func snapshotRoundTripsContextAndReadsLegacySnapshots() throws {
        var snapshot = SpeakerTranscript().liveSnapshot(names: [:])
        snapshot.calendarMeeting = meeting()
        let data = try JSONEncoder().encode(snapshot)
        #expect(try JSONDecoder().decode(LiveTranscriptSnapshot.self, from: data).calendarMeeting == meeting())
        var legacy = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "calendarMeeting")
        #expect(try JSONDecoder().decode(LiveTranscriptSnapshot.self,
                    from: JSONSerialization.data(withJSONObject: legacy)).calendarMeeting == nil)
    }

    @Test func clearRemovesContextWithoutRenamingVoices() throws {
        let preferences = MemoryPreferences()
        let model = TranscriptionModel(preferences: preferences)
        model.calendarMeeting = meeting()
        #expect(model.exportText.hasPrefix("Meeting: Budget / review: Q4\n\n"))
        #expect(model.speakerNames[1] == nil)
        model.clear()
        #expect(model.calendarMeeting == nil)
        #expect(model.exportText.isEmpty)
    }
}

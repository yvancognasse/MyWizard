import Foundation
import Testing
@testable import MyWizard

@MainActor
struct CalendarSpeakerTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func event(_ id: String = "meeting", from start: Double = -600, to end: Double = 1800,
                       names: [String] = ["Alice Smith", "Bob Martin"]) -> CalendarMeeting {
        CalendarMeeting(id: id, title: id, start: now.addingTimeInterval(start), end: now.addingTimeInterval(end),
                        calendar: "Work", invitees: names)
    }

    @Test func eventSelectionHandlesFiveMinuteMarginBoundariesAndOverlap() {
        let old = event("earlier", from: -3600, to: 60)
        let imminent = event("next", from: 120, to: 3600)
        #expect(CalendarMeeting.current(in: [old, imminent], at: now)?.id == "next")
        #expect(CalendarMeeting.current(in: [event(from: 300)], at: now) != nil)
        #expect(CalendarMeeting.current(in: [event(from: 301)], at: now) == nil)
        #expect(CalendarMeeting.current(in: [event(from: -1800, to: -300)], at: now) != nil)
        #expect(CalendarMeeting.current(in: [event(from: -1800, to: -301)], at: now) == nil)
        #expect(CalendarMeeting.current(in: [event("end", from: -1800, to: 0), event("start", from: 0)], at: now)?.id == "start")
        #expect(CalendarMeeting.current(in: [event("a"), event("b")], at: now) == nil)
        #expect(CalendarMeeting.current(in: [event("older", from: -1200), event("newer", from: -600)], at: now)?.id == "newer")
        #expect(CalendarMeeting.current(in: [event(from: 0, to: 0)], at: now) == nil)
    }

    @Test func automaticSelectionRetainsManualChoiceAndOptOutThenResetsAfterClear() async {
        var calls = 0
        let automatic = event("automatic")
        let model = TranscriptionModel(preferences: MemoryPreferences(), calendarLookup: { _ in
            calls += 1
            return CalendarLookupResult(meetings: [automatic])
        })
        await model.associateCurrentCalendarMeeting(at: now)
        #expect(model.calendarMeeting == automatic)
        #expect(model.exportText.hasPrefix("Meeting: automatic"))
        model.calendarMeeting = event("manual", from: 7200, to: 10800)
        await model.associateCurrentCalendarMeeting(at: now)
        #expect(model.calendarMeeting?.id == "manual")
        model.calendarMeeting = nil // Explicitly record without a meeting.
        await model.associateCurrentCalendarMeeting(at: now)
        #expect(model.calendarMeeting == nil)
        #expect(calls == 1)
        model.clear()
        await model.associateCurrentCalendarMeeting(at: now)
        #expect(model.calendarMeeting == automatic)
        #expect(calls == 2)
    }

    @Test func manualChoiceWinsOverAnInFlightCalendarQuery() async throws {
        var continuation: CheckedContinuation<CalendarLookupResult, Never>?
        let (started, signal) = AsyncStream<Void>.makeStream()
        let model = TranscriptionModel(preferences: MemoryPreferences(), calendarLookup: { _ in
            await withCheckedContinuation { pending in
                continuation = pending
                signal.yield(())
            }
        })
        let task = Task { await model.associateCurrentCalendarMeeting(at: now) }
        for await _ in started { break }
        model.calendarMeeting = event("manual")
        try #require(continuation).resume(returning: CalendarLookupResult(meetings: [event("automatic")]))
        await task.value
        #expect(model.calendarMeeting?.id == "manual")
    }

    @Test func unavailableOrAmbiguousCalendarDoesNotBlockTranscriptionModel() async {
        let denied = TranscriptionModel(preferences: MemoryPreferences(), calendarLookup: { _ in
            CalendarLookupResult(meetings: [], message: "Calendar access unavailable")
        })
        await denied.associateCurrentCalendarMeeting(at: now)
        #expect(denied.calendarMeeting == nil)
        #expect(denied.calendarAssociationMessage == "Calendar access unavailable")
        #expect(denied.errorMessage == nil)
        let events = [event("a"), event("b")]
        let ambiguous = TranscriptionModel(preferences: MemoryPreferences(), calendarLookup: { _ in
            CalendarLookupResult(meetings: events)
        })
        await ambiguous.associateCurrentCalendarMeeting(at: now)
        #expect(ambiguous.calendarMeeting == nil)
        #expect(ambiguous.calendarAssociationMessage != nil)
    }

    private func voice(_ name: String, index: Int = 0) -> RememberedVoice {
        var embedding = [Float](repeating: 0, count: 256)
        embedding[index] = 1
        return RememberedVoice(id: UUID(), name: name, embedding: embedding)
    }

    @Test func participantLinksIgnoreCaseAccentsAndNameOrderButRejectAmbiguity() {
        let alice = voice("SMITH, Alice"), bob = voice("Bob Martin", index: 1)
        let links = ParticipantVoiceLinks(participants: ["Alice Smith", "Bób  Martin"], voices: [alice, bob])
        #expect(links.participantByVoiceID[alice.id] == "Alice Smith")
        #expect(links.voiceIDByParticipantKey[VoiceMemory.nameKey("Bób Martin")] == bob.id)
        let abbreviated = ParticipantVoiceLinks(participants: ["Alice Smith"], voices: [voice("Alice")])
        #expect(abbreviated.participantByVoiceID.values.first == "Alice Smith")
        #expect(ParticipantVoiceLinks(participants: ["Alice Smith", "Alice Jones"], voices: [voice("Alice")]).participantByVoiceID.isEmpty)
        #expect(ParticipantVoiceLinks(participants: ["Alice"], voices: [voice("Alice Smith"), voice("Alice Jones")]).participantByVoiceID.isEmpty)
        #expect(ParticipantVoiceLinks(participants: ["alice@example.com"], voices: [voice("Alice")]).participantByVoiceID.isEmpty)
    }

    @Test func completionUsesTypedPrefixAndAllowsNewNames() {
        let names = ["Bob Martin", "Jérôme Smith", "Alice Smith"]
        #expect(SpeakerNameSuggestions.completion(for: "jer", names: names) == "Jérôme Smith")
        #expect(SpeakerNameSuggestions.completion(for: "AL", names: names) == "Alice Smith")
        #expect(SpeakerNameSuggestions.completion(for: "Smith", names: names) == nil)
        #expect(SpeakerNameSuggestions.completion(for: "", names: names) == nil)
        #expect(SpeakerNameSuggestions.completion(for: "Someone new", names: names) == nil)
    }

    @Test func acousticMatchLabelsCalendarParticipantAndManualConfirmationReusesProfile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("voices.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let memory = VoiceMemory(url: url)
        let saved = voice("SMITH, Alice")
        let samples = [saved.embedding, saved.embedding]
        let identity = try #require(try memory.remember(samples, name: saved.name))
        let model = TranscriptionModel(preferences: MemoryPreferences(), voiceMemoryURL: url)
        model.calendarMeeting = event()
        model.receiveSpeakerSnapshot(SpeakerSnapshot(intervals: [SpeakerInterval(slot: 0, start: 0, end: 20)],
            processedThrough: 20, voiceEmbeddings: [0: samples]))
        #expect(model.speakerNames[1] == "Alice Smith")
        model.speakerNames[1] = "alice smith"
        #expect(model.rememberedVoices.count == 1)
        #expect(model.rememberedVoices.first?.id == identity.id)
        #expect(model.rememberedVoices.first?.name == "SMITH, Alice")
        // Invitations alone never label an unknown voice.
        let unknown = voice("Unknown", index: 1)
        model.receiveSpeakerSnapshot(SpeakerSnapshot(intervals: [SpeakerInterval(slot: 1, start: 21, end: 40)],
            processedThrough: 40, voiceEmbeddings: [1: [unknown.embedding, unknown.embedding]]))
        #expect(model.speakerNames[2] == nil)
        // Without participants, saved identity names are used normally.
        model.calendarMeeting = event(names: [])
        #expect(model.speakerNames[1] == "alice smith") // Manual edit stays authoritative.
    }

    @Test func calendarChangeReconcilesAutomaticNamesWithoutTrainingVoiceMemory() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("voices.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let saved = voice("Alice Smith")
        let memory = VoiceMemory(url: url)
        _ = try memory.remember([saved.embedding, saved.embedding], name: saved.name)
        let model = TranscriptionModel(preferences: MemoryPreferences(), voiceMemoryURL: url)
        model.receiveSpeakerSnapshot(SpeakerSnapshot(intervals: [SpeakerInterval(slot: 0, start: 0, end: 20)],
            processedThrough: 20, voiceEmbeddings: [0: [saved.embedding, saved.embedding]]))
        model.calendarMeeting = event(names: ["SMITH, ALICE"])
        #expect(model.speakerNames[1] == "SMITH, ALICE")
        model.calendarMeeting = event(names: ["Bob Martin"])
        #expect(model.speakerNames[1] == "Alice Smith") // A known guest need not be on the invitation.
        model.calendarMeeting = nil
        #expect(model.speakerNames[1] == "Alice Smith")
        #expect(VoiceMemory(url: url).voices == memory.voices)
    }
}

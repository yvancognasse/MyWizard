import Testing
@testable import MyWizard

struct ReadingVoiceContinuityTests {
    private func paragraph(_ text: String, speaker: Int?, source: TranscriptSource = .systemAudio) -> TranscriptParagraph {
        TranscriptParagraph(id: 0, text: text, speaker: speaker,
            hasSpeakerLabel: true, source: source)
    }

    @Test func isolatedUnknownWordsKeepTheSameVoiceAcrossBatches() throws {
        var continuity = ReadingVoiceContinuity()
        let known = paragraph("The sales model works.", speaker: 3)
        let unknown = paragraph("So", speaker: nil)
        let next = paragraph("we need to act now.", speaker: 3)
        #expect(continuity.prepare(known, next: unknown).speaker == 3)
        let spoken = continuity.prepare(unknown, next: next)
        #expect(spoken.speaker == 3)
        #expect(spoken.text == unknown.text)
        #expect(unknown.speaker == nil)
        #expect(continuity.prepare(next, next: nil).speaker == 3)
        let voices = [ReadingVoice(identifier: "voice-a", name: "A", language: "en-US", quality: 1),
                      ReadingVoice(identifier: "voice-b", name: "B", language: "en-US", quality: 1)]
        let plan = try ReadingPlan.make(paragraphs: [known, spoken, next], language: "en-US", voices: voices)
        #expect(Set(plan.map(\.voiceIdentifier)).count == 1)
    }

    @Test func speakerChangeAndLongUnknownTurnStayUnassigned() {
        var continuity = ReadingVoiceContinuity()
        _ = continuity.prepare(paragraph("Earlier.", speaker: 3), next: nil)
        #expect(continuity.prepare(paragraph("Yes", speaker: nil),
            next: paragraph("Another person starts.", speaker: 4)).speaker == nil)
        #expect(continuity.prepare(paragraph("This longer passage has an uncertain voice and should stay neutral.", speaker: nil),
            next: paragraph("More from the first speaker.", speaker: 3)).speaker == nil)
        #expect(continuity.prepare(paragraph("Mic", speaker: nil, source: .microphone), next: nil).speaker == nil)
    }

    @Test func firstShortFragmentCanUseTheImmediatelyFollowingKnownVoice() {
        var continuity = ReadingVoiceContinuity()
        #expect(continuity.prepare(paragraph("And", speaker: nil),
            next: paragraph("here is the point.", speaker: 5)).speaker == 5)
        #expect(continuity.prepare(paragraph("Unknown introduction", speaker: nil), next: nil).speaker == nil)
    }

    @Test func liveDisplayHidesOnlyBracketedShortUnknownLabels() {
        let original = [paragraph("We have", speaker: 3), paragraph("So", speaker: nil),
                        paragraph("a clear plan.", speaker: 3), paragraph("A longer unknown passage should remain visibly uncertain.", speaker: nil),
                        paragraph("Different speaker.", speaker: 4), paragraph("No", speaker: nil),
                        paragraph("Back to first speaker.", speaker: 3)]
        let displayed = LiveSpeakerPresentation.smooth(original)
        #expect(displayed.map(\.text) == original.map(\.text))
        #expect(displayed.map(\.speaker) == [3, 3, 3, nil, 4, nil, 3])
        #expect(original[1].speaker == nil)
    }
}

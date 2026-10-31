import AVFoundation
import Testing
@testable import MyWizard

struct ExportPolishTests {
    @Test func shortAudibleBoundaryKeepsOneVoiceButProtectsReplyAndCompetitor() {
        let blocks = [LiveTranscriptBlock(text: "We are", speaker: 2, start: 0, end: 1),
                      .init(text: "So", speaker: nil, start: 1.1, end: 2.4),
                      .init(text: "ready.", speaker: 2, start: 2.4, end: 4)]
        let activity = ExportAudioActivity(spans: [.init(start: 1.1, end: 2.4)])
        let voice = [SpeakerInterval(slot: 5, start: 0, end: 0.4), .init(slot: 5, start: 2.7, end: 4)]
        let result = ExportParagraphPolish.resolve(blocks, intervals: voice, numbers: [5: 2], activity: activity)
        #expect(result.map(\.speaker) == [2, 2, 2])
        let reply = [blocks[0], .init(text: "Yeah", speaker: nil, start: 1.1, end: 2.4), blocks[2]]
        #expect(ExportParagraphPolish.resolve(reply, intervals: voice, numbers: [5: 2], activity: activity).map(\.speaker) == [2, nil, 2])
        let competitor = voice + [SpeakerInterval(slot: 6, start: 1.3, end: 2)]
        #expect(ExportParagraphPolish.resolve(blocks, intervals: competitor, numbers: [5: 2, 6: 3], activity: activity).map(\.speaker) == [2, nil, 2])
        #expect(ExportParagraphPolish.resolve(blocks, intervals: voice, numbers: [5: 2], activity: .init(spans: [])).map(\.speaker) == [2, nil, 2])
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MYWIZARD_JJ_EXPORT_REPLAY"] != nil))
    func replayJJExportWithoutChangingWordsOrKnownSpeakers() throws {
        let path = try #require(ProcessInfo.processInfo.environment["MYWIZARD_JJ_EXPORT_REPLAY"])
        let meeting = try RecordedMeeting.load(URL(fileURLWithPath: path))
        let snapshot = try meeting.loadLiveTranscript()
        let baseline = try JSONDecoder().decode(MeetingAnalysis.self,
            from: Data(contentsOf: meeting.directory.appendingPathComponent("analysis.json")))
        let checkpoint = try JSONDecoder().decode(ExportCheckpoint.self,
            from: Data(contentsOf: meeting.directory.appendingPathComponent("export-checkpoint.json")))
        let activity: ExportAudioActivity
        if let cached = checkpoint.activity { activity = cached }
        else { activity = try ExportAudioActivity.read(meeting.audio(.system)) }
        let updated = snapshot.addingMicrophone(checkpoint.microphone ?? [],
            echoEvidence: checkpoint.echo(for: meeting), systemActivity: activity)
        #expect(updated.system == baseline.system)
        #expect(updated.microphone == baseline.microphone)
        #expect(updated.liveSystemParagraphs == baseline.liveSystemParagraphs)
        let original = try #require(baseline.paragraphs)
        let revised = try #require(updated.paragraphs)
        let previousWords = original.map(\.text).joined(separator: " ").split(whereSeparator: \.isWhitespace)
        let currentWords = revised.map(\.text).joined(separator: " ").split(whereSeparator: \.isWhitespace)
        #expect(previousWords == currentWords)
        let beforeUnknown = original.filter { $0.speaker == nil }
        let afterUnknown = revised.filter { $0.speaker == nil }
        #expect(afterUnknown.count < beforeUnknown.count)
        print("JJ EXPORT REPLAY: unknown paragraphs \(beforeUnknown.count) -> \(afterUnknown.count)")
        print("REMAINING UNKNOWN: \(afterUnknown.map(\.text).joined(separator: " | "))")
        if let output = ProcessInfo.processInfo.environment["MYWIZARD_JJ_EXPORT_OUTPUT"] {
            var document = SpeakerTranscript()
            document.beginSession(detectsSpeakers: true, language: meeting.manifest.language, reservesOwnSpeaker: true)
            document.replaceCurrentSession(with: updated)
            let text = SpeakerTranscript.plainText(paragraphs: document.deduplicatedParagraphs, names: snapshot.names)
            try text.write(to: URL(fileURLWithPath: output), atomically: true, encoding: .utf8)
        }
    }

    @Test func trailingSilenceDoesNotMakeSupportedWordUnknown() {
        let blocks = [LiveTranscriptBlock(text: "pouvoirs.", speaker: nil, start: 1, end: 2.4)]
        let evidence = [SpeakerInterval(slot: 5, start: 0, end: 1.3)]
        let activity = ExportAudioActivity(spans: [.init(start: 0, end: 1.32)])
        #expect(ExportParagraphPolish.resolve(blocks, intervals: evidence, numbers: [5: 2]).first?.speaker == nil)
        #expect(ExportParagraphPolish.resolve(blocks, intervals: evidence, numbers: [5: 2], activity: activity).first?.speaker == 2)
        // Silence cannot create identity, nor excuse competing voice evidence.
        #expect(ExportParagraphPolish.resolve(blocks, intervals: [], numbers: [5: 2], activity: activity).first?.speaker == nil)
        #expect(ExportParagraphPolish.resolve(blocks, intervals: evidence, numbers: [5: 2],
            activity: .init(spans: [])).first?.speaker == nil)
        #expect(ExportParagraphPolish.resolve(blocks, intervals: evidence + [.init(slot: 6, start: 1.1, end: 1.3)],
            numbers: [5: 2, 6: 3], activity: activity).first?.speaker == nil)
        #expect(ExportParagraphPolish.resolve(blocks, intervals: evidence, numbers: [5: 2],
            activity: .init(spans: [.init(start: 1, end: 2.4)])).first?.speaker == nil)
    }

    @Test func bridgesShortUnknownRunWithSameVoiceOnBothSides() {
        let blocks: [LiveTranscriptBlock] = [
            .init(text: "Pour une", speaker: 2, start: 0, end: 1),
            .init(text: " illusion.", speaker: nil, start: 1, end: 2.2),
            .init(text: " Les", speaker: nil, start: 2.2, end: 2.6),
            .init(text: " jeunes hommes.", speaker: 2, start: 2.6, end: 4)]
        let evidence = [SpeakerInterval(slot: 5, start: 0, end: 1), .init(slot: 5, start: 2.6, end: 4)]
        let result = ExportParagraphPolish.resolve(blocks, intervals: evidence, numbers: [5: 2])
        #expect(result.map(\.speaker) == [2, 2, 2, 2])
        #expect(result.map(\.text) == blocks.map(\.text))
        #expect(ExportParagraphPolish.coalesce(result).count == 1)
        for competitor in [6, 7] {
            let ambiguous = ExportParagraphPolish.resolve(blocks,
                intervals: evidence + [.init(slot: competitor, start: 1.5, end: 2)], numbers: [5: 2, 6: 3])
            #expect(ambiguous.map(\.speaker) == [2, nil, nil, 2])
        }
        #expect(ExportParagraphPolish.resolve(blocks, intervals: [], numbers: [5: 2]).map(\.speaker) == [2, nil, nil, 2])
        let changedSpeaker = Array(blocks.dropLast()) + [.init(text: "Other voice", speaker: 3, start: 2.6, end: 4)]
        #expect(ExportParagraphPolish.resolve(changedSpeaker, intervals: evidence, numbers: [5: 2]).map(\.speaker) == [2, nil, nil, 3])
        let unbounded = Array(blocks.dropLast())
        #expect(ExportParagraphPolish.resolve(unbounded, intervals: evidence, numbers: [5: 2]).map(\.speaker) == [2, nil, nil])
        let longHole = [blocks[0], .init(text: "A long uncertain passage", speaker: nil, start: 1, end: 4),
            .init(text: "Next", speaker: 2, start: 4, end: 5)]
        #expect(ExportParagraphPolish.resolve(longHole, intervals: [.init(slot: 5, start: 0, end: 1),
            .init(slot: 5, start: 4, end: 5)], numbers: [5: 2])[1].speaker == nil)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MYWIZARD_RECORDED_FIXTURES"] != nil))
    func realSpeechSurvivesCompactionWithOriginalTimestamps() async throws {
        let directory = try #require(ProcessInfo.processInfo.environment["MYWIZARD_RECORDED_FIXTURES"])
        let source = try AVAudioFile(forReading: URL(fileURLWithPath: directory).appendingPathComponent("speaker-two.aiff"))
        let format = source.processingFormat
        let voice = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(source.length)))
        try source.read(into: voice)
        let silence = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(format.sampleRate * 70)))
        silence.frameLength = silence.frameCapacity
        let offset = Int(format.sampleRate * 20)
        for channel in 0..<Int(format.channelCount) {
            silence.floatChannelData![channel].initialize(repeating: 0, count: Int(silence.frameLength))
            silence.floatChannelData![channel].advanced(by: offset).update(from: voice.floatChannelData![channel], count: Int(voice.frameLength))
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("SelectionVoice-\(UUID()).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        do { let file = try AVAudioFile(forWriting: url, settings: format.settings); try file.write(from: silence) }
        let processor = MeetingProcessor()
        let fullStart = ContinuousClock.now
        let full = try await processor.transcribe(url, language: "en-US")
        let fullTime = fullStart.duration(to: .now)
        let selectedStart = ContinuousClock.now
        let selected = try await processor.transcribeSelectedMicrophone(url, language: "en-US")
        let selectedTime = selectedStart.duration(to: .now)
        let expected = MicrophoneDuplicateFilter.tokens(full).map(\.key)
        let actual = MicrophoneDuplicateFilter.tokens(selected).map(\.key)
        #expect(!expected.isEmpty)
        // Apple's decoder varies "cost"/"costs" with silence context on this
        // fixture. Permit only that observed inflection, not missing words or
        // arbitrary edits. In particular the first and last words must survive.
        #expect(actual.map { $0 == "costs" ? "cost" : $0 } == expected.map { $0 == "costs" ? "cost" : $0 })
        #expect(actual.prefix(7) == expected.prefix(7))
        #expect(actual.suffix(2) == expected.suffix(2))
        #expect(selected.allSatisfy { $0.start >= 19 && $0.end < 32 })
        let selection = try MicrophoneSpeechSelection.inspect(url)
        #expect(MicrophoneSpeechSelection.useful(selection.spans, duration: selection.duration))
        print("SILENCE COMPACTION: full=\(fullTime), selected=\(selectedTime), audio=\(selection.spans.reduce(0) { $0 + $1.end - $1.start })/70 s; exact words=\(actual == expected), only cost/costs variation allowed")
    }

    @Test func joinsOnlyConsecutiveKnownIdentitiesWithoutRewritingWords() {
        let blocks: [LiveTranscriptBlock] = [
            .init(text: "My Wizard 10.", speaker: 0, start: 0, end: 1),
            .init(text: "3 est prêt. ", speaker: 0, start: 1, end: 2),
            .init(text: "Oui.", speaker: 1, start: 2, end: 3),
            .init(text: "Suite.", speaker: 0, start: 3, end: 4),
            .init(text: "Qui", speaker: nil, start: 4, end: 5),
            .init(text: "parle ?", speaker: nil, start: 5, end: 6)]
        let result = ExportParagraphPolish.coalesce(blocks)
        #expect(result.map(\.text) == ["My Wizard 10. 3 est prêt. ", "Oui.", "Suite.", "Qui", "parle ?"])
        #expect(result.map(\.speaker) == [0, 1, 0, nil, nil])
    }

    @Test func recoversBoundaryFragmentOnlyWithUnopposedVoiceEvidence() {
        let blocks = [LiveTranscriptBlock(text: "Une", speaker: nil, start: 1, end: 1.2)]
        let voice = SpeakerInterval(slot: 7, start: 1.18, end: 3)
        #expect(ExportParagraphPolish.resolve(blocks, intervals: [voice], numbers: [7: 2]).first?.speaker == 2)
        let competitor = SpeakerInterval(slot: 8, start: 0.9, end: 1.1)
        #expect(ExportParagraphPolish.resolve(blocks, intervals: [voice, competitor], numbers: [7: 2, 8: 3]).first?.speaker == nil)
        #expect(ExportParagraphPolish.resolve(blocks, intervals: [voice, competitor], numbers: [7: 2]).first?.speaker == nil)
        #expect(ExportParagraphPolish.resolve(blocks, intervals: [], numbers: [7: 2]).first?.speaker == nil)
        #expect(ExportParagraphPolish.resolve(blocks, intervals: [voice], numbers: [7: 0]).first?.speaker == nil)
        let known = [LiveTranscriptBlock(text: "Une", speaker: 3, start: 1, end: 1.2)]
        #expect(ExportParagraphPolish.resolve(known, intervals: [voice], numbers: [7: 2]).first?.speaker == 3)
    }

    @Test func exportLabelRecoveryNeverChangesLiveWordsOrDisplay() {
        let words = [TimedText(text: "Une", start: 1, end: 1.2)]
        let display = [TranscriptParagraph(id: 0, text: "Une", speaker: nil, hasSpeakerLabel: true)]
        let snapshot = LiveTranscriptSnapshot(words: words,
            blocks: [.init(text: "Une", speaker: nil, start: 1, end: 1.2)], display: display,
            intervals: [.init(slot: 7, start: 1.18, end: 3)], speakerNumbers: [7: 2], names: [2: "Mike"])
        let result = snapshot.addingMicrophone([])
        #expect(result.paragraphs?.first?.speaker == 2)
        #expect(result.paragraphs?.first?.text == "Une")
        #expect(result.system == words)
        #expect(result.liveSystemParagraphs == display)
        #expect(result.speakerNumbers == snapshot.speakerNumbers)
    }

    @Test func shortEchoNeedsBothCluesAndProtectsRepliesNumbersAndObjections() {
        let evidence = EchoReductionResult(audio: URL(fileURLWithPath: "/unused"), echoOnly: [.init(start: 1, end: 1.6)])
        for text in ["oui", "non", "merci", "123", "pas"] {
            let word = TimedText(text: text, start: 1, end: 2, source: .microphone)
            #expect(evidence.removingEchoArtifacts(from: [word], reference: [word]) == [word])
        }
        let word = TimedText(text: "énergie", start: 1, end: 2, source: .microphone)
        #expect(evidence.removingEchoArtifacts(from: [word], reference: [word]).isEmpty)
        #expect(evidence.removingEchoArtifacts(from: [word], reference: []) == [word])
        #expect(evidence.removingEchoArtifacts(from: [word], reference: [.init(text: "énergie", start: 4, end: 5)]) == [word])
        let noEvidence = EchoReductionResult(audio: evidence.audio, echoOnly: [])
        #expect(noEvidence.removingEchoArtifacts(from: [word], reference: [word]) == [word])
    }

    @Test func selectionKeepsBriefActivityWithPaddingAndSkipsMinorSavings() {
        var activity = [Bool](repeating: false, count: 1000)
        activity[200] = true
        activity[500] = true
        let spans = MicrophoneSpeechSelection.spans(activity: activity, step: 0.1, duration: 100)
        #expect(spans.count == 2)
        #expect(spans[0].start == 19)
        #expect(abs(spans[0].end - 21.1) < 0.001)
        #expect(MicrophoneSpeechSelection.useful(spans, duration: 100))
        #expect(!MicrophoneSpeechSelection.useful([.init(start: 0, end: 95)], duration: 100))
        #expect(!MicrophoneSpeechSelection.useful([], duration: 100))
    }

    @Test func compactedAudioRetainsQuietSamplesAndRestoresOriginalClock() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SpeechSelection-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.caf")
        let destination = root.appendingPathComponent("packed.caf")
        let format = MeetingRecording.format
        let pcm = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16000 * 40))
        pcm.frameLength = pcm.frameCapacity
        pcm.floatChannelData![0].initialize(repeating: 0, count: Int(pcm.frameLength))
        // 100 ms response at -80 dB: quiet and short, still retained.
        for i in 160000..<161600 { pcm.floatChannelData![0][i] = 0.0001 }
        for i in 480000..<481600 { pcm.floatChannelData![0][i] = 0.1 }
        do { let file = try AVAudioFile(forWriting: source, settings: format.settings); try file.write(from: pcm) }
        let original = try Data(contentsOf: source)
        let selection = try MicrophoneSpeechSelection.inspect(source)
        let activity = try ExportAudioActivity.read(source)
        #expect(abs(activity.duration(from: 0, to: 40) - 0.2) < 0.025)
        #expect(activity.duration(from: 15, to: 25) == 0)
        #expect(abs(activity.duration(from: 10.05, to: 10.1) - 0.05) < 0.001)
        #expect(selection.spans.count == 2)
        let mapping = try MicrophoneSpeechSelection.pack(source, spans: selection.spans, destination: destination)
        #expect(try Data(contentsOf: source) == original)
        let packed = try AVAudioFile(forReading: destination)
        #expect(Double(packed.length) / packed.processingFormat.sampleRate < 5)
        let packedPCM = try #require(AVAudioPCMBuffer(pcmFormat: packed.processingFormat, frameCapacity: AVAudioFrameCount(packed.length)))
        try packed.read(into: packedPCM)
        for span in mapping {
            let sourceStart = Int((span.sourceStart * format.sampleRate).rounded())
            let packedStart = Int((span.packedStart * format.sampleRate).rounded())
            let length = Int((span.duration * format.sampleRate).rounded())
            #expect((0..<length).allSatisfy {
                packedPCM.floatChannelData![0][packedStart + $0] == pcm.floatChannelData![0][sourceStart + $0]
            })
        }
        let second = mapping[1]
        let words = [TimedText(text: "oui", start: second.packedStart + 1, end: second.packedStart + 1.1)]
        let restored = try #require(MicrophoneSpeechSelection.restore(words, mapping: mapping))
        #expect(abs(restored[0].start - 30) < 0.001)
        #expect(restored[0].text == "oui")
        #expect(MicrophoneSpeechSelection.restore([.init(text: "crossing", start: second.packedStart - 0.1,
            end: second.packedStart + 0.1)], mapping: mapping) == nil)
    }
}

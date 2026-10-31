import AVFoundation
import Foundation
import Testing
@testable import MyWizard

struct WhisperProductionExportTests {
    @Test func singleMixedTextGainsNamesWithoutDuplicateASRWords() {
        let intervals = [SpeakerInterval(slot: 5, start: 0, end: 1), .init(slot: 3, start: 1, end: 2)]
        let evidence = MicrophoneSourceEvidence(windows: (0..<20).map { i in
            .init(time: Double(i) / 10 + 0.05, systemPower: i < 10 ? 0.1 : 0.001,
                  microphonePower: i < 10 ? 0.001 : 0.1)
        })
        let own = evidence.microphoneSlots(intervals: intervals)
        #expect(own == [3])
        let words = [TimedText(text: "Remote sentence. ", start: 0, end: 1), .init(text: "My reply.", start: 1, end: 2)]
        let paragraphs = WhisperSpeakerAlignment.paragraphs(words: words, intervals: intervals, microphoneSlots: own)
        #expect(paragraphs.map(\.speaker) == [1, 0])
        #expect(paragraphs.map(\.text).joined() == words.map(\.text).joined())
        let export = WhisperExportResult(engine: "mixed", words: words, intervals: intervals, paragraphs: paragraphs, elapsedSeconds: 0)
        #expect(export.text(names: [0: "Yvan", 1: "Srini"]) == "Srini:\nRemote sentence.\n\nYvan:\nMy reply.\n")
        let echo = MicrophoneSourceEvidence(windows: (0..<20).map { i in
            .init(time: Double(i) / 10 + 0.05, systemPower: 0.1, microphonePower: 0.001)
        })
        #expect(echo.microphoneSlots(intervals: intervals).isEmpty)
        #expect(evidence.microphoneSlots(intervals: [.init(slot: 0, start: 0, end: 2), .init(slot: 1, start: 0, end: 2)]).isEmpty)
    }

    @Test func speakerInferenceRetriesFailureButNeverCancellationOrSuccessfulWork() async throws {
        enum Failure: Error { case gpu, fallback }
        let success = try await ExportInferenceRecovery.run(primary: { 42 }, fallback: { throw Failure.fallback })
        #expect(success == 42)
        let recovered = try await ExportInferenceRecovery.run(primary: { throw Failure.gpu }, fallback: { 43 })
        #expect(recovered == 43)
        await #expect(throws: CancellationError.self) {
            try await ExportInferenceRecovery.run(primary: { throw CancellationError() }, fallback: { 44 })
        }
        await #expect(throws: Failure.self) {
            try await ExportInferenceRecovery.run(primary: { throw Failure.gpu }, fallback: { throw Failure.fallback })
        }
    }

    @Test func finalTextRetainsNamesThroughClusterReorderingSaveAndNewSession() throws {
        var document = SpeakerTranscript()
        document.beginSession(detectsSpeakers: true, language: "en-US", reservesOwnSpeaker: true)
        document.updateSpeakers(.init(intervals: [.init(slot: 8, start: 0, end: 1),
                                                  .init(slot: 2, start: 2, end: 3)], processedThrough: 3))
        let anchors = document.exportSpeakerAnchors
        let words = [TimedText(text: "First voice. ", start: 0, end: 1),
                     TimedText(text: "My reply. ", start: 1, end: 2, source: .microphone),
                     TimedText(text: "Second voice.", start: 2, end: 3)]
        let intervals = [SpeakerInterval(slot: 4, start: 0, end: 1), .init(slot: 0, start: 2, end: 3)]
        let paragraphs = WhisperSpeakerAlignment.paragraphs(words: words, intervals: intervals, anchors: anchors)
        let analysis = MeetingAnalysis(system: words.filter { $0.source == .systemAudio },
            microphone: words.filter { $0.source == .microphone }, intervals: intervals,
            speakerNumbers: WhisperSpeakerAlignment.identities(intervals: intervals, anchors: anchors), paragraphs: paragraphs)
        // Analysis survives persistence without discarding final paragraph/name mapping.
        document.replaceCurrentSession(with: try JSONDecoder().decode(MeetingAnalysis.self, from: JSONEncoder().encode(analysis)))
        let names = [0: "Yvan", 1: "Srini", 2: "Mike"]
        let text = SpeakerTranscript.plainText(paragraphs: document.deduplicatedParagraphs, names: names)
        #expect(text == "Srini:\nFirst voice.\n\nYvan:\nMy reply.\n\nMike:\nSecond voice.")
        #expect(document.paragraphs.map(\.text).joined() == words.map(\.text).joined())
        #expect(document.paragraphs.filter(\.canReadAloud).map(\.speaker) == [1, 2])
        #expect(document.provisionalSystemParagraphs.isEmpty)
        document.beginSession(detectsSpeakers: true, reservesOwnSpeaker: true)
        #expect(document.exportFirstSpeakerNumber == 3)
        #expect(document.plainText(names: names) == text)
        document.receive([.init(text: "Next meeting", start: 0, end: 1)], isFinal: true)
        document.updateSpeakers(.init(intervals: [.init(slot: 0, start: 0, end: 1)], processedThrough: 1))
        #expect(document.paragraphs.last?.speaker == 3)
        document.clear()
        #expect(document.paragraphs.isEmpty)
    }

    @Test func shortVADBoundaryGapIsRecoveredButOverlapAndLongGapsAreNot() {
        let words = [TimedText(text: "boundary", start: 0.91, end: 1.09),
                     .init(text: "overlap", start: 2, end: 2.5), .init(text: "gap", start: 4, end: 4.5)]
        let intervals = [SpeakerInterval(slot: 0, start: 0, end: 0.99), .init(slot: 0, start: 2, end: 3),
                         .init(slot: 1, start: 2, end: 3)]
        #expect(WhisperSpeakerAlignment.speakerSlots(words: words, intervals: intervals) == [0, nil, nil])
    }

    @Test func oldAnalysisFilesStillDecode() throws {
        let analysis = try JSONDecoder().decode(MeetingAnalysis.self,
            from: Data(#"{"system":[],"microphone":[],"intervals":[]}"#.utf8))
        #expect(analysis.paragraphs == nil)
        #expect(analysis.speakerNumbers == nil)
    }

    @Test func unavailableWhisperDoesNotFallBackOrWriteAnAnalysis() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WhisperMissing-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = try MeetingRecording(language: "en-US", microphone: false, detectSpeakers: true,
            root: root, origin: 0) { _ in }
        let meeting = await recorder.finish()
        let original = try Data(contentsOf: meeting.audio(.system))
        let exporter = WhisperMeetingExporter(whisper: .init(configuration: .init(executable: root.appendingPathComponent("absent"))))
        await #expect(throws: (any Error).self) { try await MeetingProcessor(exporter: exporter).analyzeMixedForComparison(meeting) { _ in } }
        #expect(try Data(contentsOf: meeting.audio(.system)) == original)
        #expect(!FileManager.default.fileExists(atPath: meeting.directory.appendingPathComponent("analysis.json").path))
    }

    @Test(arguments: [false, true]) func silentLegacyMixedExportSkipsBothEngines(microphone: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WhisperSilence-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = try MeetingRecording(language: "en-US", microphone: microphone, detectSpeakers: true,
            root: root, origin: 0) { _ in }
        let meeting = await recorder.finish()
        // A readable dummy model plus true can never produce ASR JSON. Success
        // proves silence did not invoke either the CLI or speaker models.
        let exporter = WhisperMeetingExporter(whisper: .init(configuration: .init(
            executable: URL(fileURLWithPath: "/usr/bin/true"), model: meeting.audio(.system))))
        let result = try await MeetingProcessor(exporter: exporter).analyzeMixedForComparison(meeting) { _ in }
        #expect(result.system.isEmpty && result.microphone.isEmpty)
        #expect(result.paragraphs?.isEmpty == true)
        #expect(FileManager.default.fileExists(atPath: meeting.directory.appendingPathComponent("analysis.json").path))
        #expect(FileManager.default.fileExists(atPath: meeting.audio(.system).path))
    }
}

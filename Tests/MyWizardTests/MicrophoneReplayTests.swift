import Foundation
import Testing
@testable import MyWizard

struct MicrophoneReplayTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MYWIZARD_MIC_SNAPSHOT_REPLAY"] != nil))
    func replaySavedExportEvidenceWithoutReprocessingAudio() throws {
        let path = try #require(ProcessInfo.processInfo.environment["MYWIZARD_MIC_SNAPSHOT_REPLAY"])
        let meeting = try RecordedMeeting.load(URL(fileURLWithPath: path))
        let snapshot = try meeting.loadLiveTranscript()
        let baseline = try JSONDecoder().decode(MeetingAnalysis.self,
            from: Data(contentsOf: meeting.directory.appendingPathComponent("analysis.json")))
        let checkpoint = try JSONDecoder().decode(ExportCheckpoint.self,
            from: Data(contentsOf: meeting.directory.appendingPathComponent("export-checkpoint.json")))
        let raw = try #require(checkpoint.microphone)
        let echo = try #require(checkpoint.echo(for: meeting))
        let start = ContinuousClock.now
        let updated = snapshot.addingMicrophone(raw, echoEvidence: echo, systemActivity: echo.systemActivity)
        let duration = start.duration(to: .now)
        #expect(updated.system == baseline.system)
        #expect(updated.liveSystemParagraphs == baseline.liveSystemParagraphs)
        let beforeMicrophone = baseline.microphone.map(\.text).joined().lowercased()
        let afterMicrophone = updated.microphone.map(\.text).joined().lowercased()
        for echo in ["working closely with not west bank", "having covered", "not not not sap"] {
            #expect(beforeMicrophone.contains(echo))
            #expect(!afterMicrophone.contains(echo))
        }
        let genuine: [(Double, Double)] = [(1274, 1290), (1858, 1863), (1942, 1953),
                                           (2005, 2028), (2071, 2083), (2840, 2928)]
        for (begin, end) in genuine {
            let before = baseline.microphone.filter { $0.start >= begin && $0.end <= end }.map(\.text).joined()
            let after = updated.microphone.filter { $0.start >= begin && $0.end <= end }.map(\.text).joined()
            #expect(!before.isEmpty)
            #expect(after == before)
        }
        let removed = baseline.microphone.filter { word in
            !updated.microphone.contains { $0.start == word.start && $0.end == word.end && $0.text == word.text }
        }
        print("SAVED EXPORT REPLAY: before=\(baseline.microphone.count) after=\(updated.microphone.count) removed=\(removed.count) duration=\(duration)")
        print("REMOVED SPANS: \(removed.map { "\(Int($0.start)):\($0.text)" }.joined(separator: " | "))")
        if let output = ProcessInfo.processInfo.environment["MYWIZARD_MIC_SNAPSHOT_OUTPUT"] {
            var document = SpeakerTranscript()
            document.beginSession(detectsSpeakers: true, language: meeting.manifest.language, reservesOwnSpeaker: true)
            document.replaceCurrentSession(with: updated)
            let text = SpeakerTranscript.plainText(paragraphs: document.deduplicatedParagraphs, names: snapshot.names)
            try text.write(to: URL(fileURLWithPath: output), atomically: true, encoding: .utf8)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MYWIZARD_MIC_REPLAY"] != nil))
    func replaySavedMicrophoneWithoutChangingSystemTranscript() async throws {
        let environment = ProcessInfo.processInfo.environment
        let original = try RecordedMeeting.load(URL(fileURLWithPath: try #require(environment["MYWIZARD_MIC_REPLAY"])))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MyWizardMicReplay-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let copy = root.appendingPathComponent(original.id.uuidString + ".mywizard")
        try FileManager.default.copyItem(at: original.directory, to: copy)
        let meeting = try RecordedMeeting.load(copy)
        let snapshot = try meeting.loadLiveTranscript()
        let baseline = try JSONDecoder().decode(MeetingAnalysis.self,
            from: Data(contentsOf: original.directory.appendingPathComponent("analysis.json")))
        let cleaned = try OfflineEchoReducer.reduce(meeting) { _ in }
        let processor = MeetingProcessor()
        let fullStart = ContinuousClock.now
        let raw = try await processor.transcribe(cleaned.audio, language: meeting.manifest.language,
            reportsConfidence: environment["MYWIZARD_MIC_CONFIDENCE"] == "1").map {
            TimedText(text: $0.text, start: $0.start, end: $0.end, source: .microphone)
        }
        let fullDuration = fullStart.duration(to: .now)
        let old = snapshot.addingMicrophone(cleaned.removingEchoArtifacts(from: raw))
        let productionStart = ContinuousClock.now
        let updated = try await processor.analyze(meeting) { _ in }
        let productionDuration = productionStart.duration(to: .now)
        let resumedStart = ContinuousClock.now
        let resumed = try await processor.analyze(meeting) { _ in }
        let resumedDuration = resumedStart.duration(to: .now)
        #expect(resumed.system == updated.system)
        #expect(resumed.microphone == updated.microphone)
        #expect(resumed.paragraphs?.map(\.text) == updated.paragraphs?.map(\.text))
        #expect(resumed.paragraphs?.map(\.speaker) == updated.paragraphs?.map(\.speaker))
        let checkpoint = ExportCheckpoint.load(meeting, key: try ExportCheckpoint.inputKey(meeting))
        let scanned = try ExportAudioActivity.read(meeting.audio(.system))
        #expect(checkpoint.activity?.spans.map(\.start) == scanned.spans.map(\.start))
        #expect(checkpoint.activity?.spans.map(\.end) == scanned.spans.map(\.end))
        print("EXPORT CHECKPOINT REUSE: \(resumedDuration), same words and labels")
        let selection = try MicrophoneSpeechSelection.inspect(cleaned.audio)
        let selectedSeconds = selection.spans.reduce(0) { $0 + $1.end - $1.start }
        print("MICROPHONE TIMING: full ASR=\(fullDuration); complete production export=\(productionDuration); selected audio=\(selectedSeconds)/\(selection.duration) s; compaction=\(MicrophoneSpeechSelection.useful(selection.spans, duration: selection.duration))")
        let originalMicWords = try await processor.transcribe(meeting.audio(.microphone), language: meeting.manifest.language).map {
            TimedText(text: $0.text, start: $0.start, end: $0.end, source: .microphone)
        }
        let originalMicAnalysis = snapshot.addingMicrophone(originalMicWords, echoEvidence: cleaned)
        #expect(updated.system == snapshot.words)
        #expect(updated.liveSystemParagraphs == snapshot.display)
        if environment["MYWIZARD_MIC_EXPECT_SILENT"] == "1" {
            #expect(updated.microphone.isEmpty)
            #expect(updated.paragraphs?.contains(where: { $0.speaker == SpeakerIdentity.microphone }) == false)
        }
        // Optional human-labelled intervention spans supplied only by the
        // diagnostic caller, never used by production filtering.
        if let spans = environment["MYWIZARD_MIC_REPLAY_EXPECTED_SPANS"] {
            for span in spans.split(separator: ",") {
                let bounds = span.split(separator: ":").compactMap { Double($0) }
                #expect(bounds.count == 2)
                guard bounds.count == 2 else { continue }
                let expected = baseline.microphone.filter { $0.start >= bounds[0] && $0.end <= bounds[1] }.map(\.text).joined()
                let actual = updated.microphone.filter { $0.start >= bounds[0] && $0.end <= bounds[1] }.map(\.text).joined()
                #expect(!expected.isEmpty)
                #expect(actual == expected)
            }
        }
        if let output = environment["MYWIZARD_MIC_REPLAY_OUTPUT"] {
            let destination = URL(fileURLWithPath: output).appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            for (name, analysis) in [("original", baseline), ("before", old), ("after", updated), ("raw-audio", originalMicAnalysis)] {
                try encoder.encode(analysis).write(to: destination.appendingPathComponent(name + ".json"))
                var document = SpeakerTranscript()
                document.beginSession(detectsSpeakers: true, language: meeting.manifest.language, reservesOwnSpeaker: true)
                document.replaceCurrentSession(with: analysis)
                try document.plainText(names: snapshot.names).write(to: destination.appendingPathComponent(name + ".txt"), atomically: true, encoding: .utf8)
            }
            try encoder.encode(raw).write(to: destination.appendingPathComponent("raw-microphone.json"))
            try encoder.encode(cleaned.contextFrames).write(to: destination.appendingPathComponent("echo-context.json"))
            print("MICROPHONE REPLAY OUTPUT: \(destination.path)")
        }
        print("MICROPHONE REPLAY: original=\(baseline.microphone.count) before=\(old.microphone.count) after=\(updated.microphone.count) words; system unchanged")
    }
}

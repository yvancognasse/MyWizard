import AVFoundation
import Testing
@testable import MyWizard

struct ExportStabilityTests {
    @Test func autosaveCanRetryAfterDiskFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AutosaveRetry-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = TranscriptAutosave(directory: root)
        await #expect(throws: (any Error).self) { try await writer.save(snapshot()) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try await writer.save(snapshot("Recovered"))
        #expect(try JSONDecoder().decode(LiveTranscriptSnapshot.self,
            from: Data(contentsOf: root.appendingPathComponent("live-transcript.json"))).words[0].text == "Recovered")
    }

    @Test func cancellationAfterEchoKeepsCompletedStageForRetry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CancelCheckpoint-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = try MeetingRecording(language: "en-US", microphone: true, detectSpeakers: true,
            root: root, origin: 0) { _ in }
        let pcm = try #require(AVAudioPCMBuffer(pcmFormat: MeetingRecording.format, frameCapacity: 16000))
        pcm.frameLength = 16000
        pcm.floatChannelData![0].initialize(repeating: 0.2, count: 16000)
        try recorder.append(pcm, track: .microphone, time: 0)
        let meeting = await recorder.finish()
        try meeting.saveLiveTranscript(snapshot())
        let original = try Data(contentsOf: meeting.audio(.microphone))
        let task = Task {
            try await MeetingProcessor().analyze(meeting) { percent in
                if percent == 20 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        let cached = ExportCheckpoint.load(meeting, key: try ExportCheckpoint.inputKey(meeting))
        #expect(cached.echo(for: meeting) != nil)
        #expect(cached.microphone == nil)
        #expect(cached.analysis == nil)
        #expect(try Data(contentsOf: meeting.audio(.microphone)) == original)
    }

    @Test func checkpointRejectsSymbolicLinks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CheckpointLink-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = try MeetingRecording(language: "en-US", microphone: false, detectSpeakers: true, root: root) { _ in }
        let meeting = await recorder.finish()
        let destination = root.appendingPathComponent("keep.txt")
        try Data("Do not overwrite".utf8).write(to: destination)
        let cacheURL = meeting.directory.appendingPathComponent("export-checkpoint.json")
        try FileManager.default.createSymbolicLink(at: cacheURL, withDestinationURL: destination)
        let cache = ExportCheckpoint(key: "test")
        #expect(throws: (any Error).self) { try cache.save(meeting) }
        #expect(ExportCheckpoint.load(meeting, key: "test").analysis == nil)
        #expect(try String(contentsOf: destination, encoding: .utf8) == "Do not overwrite")
    }

    private func snapshot(_ text: String = "System words.") -> LiveTranscriptSnapshot {
        .init(words: [.init(text: text, start: 0, end: 1)],
            blocks: [.init(text: text, speaker: 1, start: 0, end: 1)],
            display: [.init(id: 0, text: text, speaker: 1, hasSpeakerLabel: true)],
            intervals: [], speakerNumbers: [:], names: [0: "Yvan"])
    }

    @Test func autosavePersistsNamesAndFinalSnapshotWinsOverLateWrites() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Autosave-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = TranscriptAutosave(directory: root)
        try await writer.save(snapshot("First"))
        let file = root.appendingPathComponent("live-transcript.json")
        #expect(try JSONDecoder().decode(LiveTranscriptSnapshot.self, from: Data(contentsOf: file)).words[0].text == "First")
        try await writer.finish(snapshot("Final"))
        try await writer.save(snapshot("Late"))
        let saved = try JSONDecoder().decode(LiveTranscriptSnapshot.self, from: Data(contentsOf: file))
        #expect(saved.words[0].text == "Final")
        #expect(saved.names[0] == "Yvan")
    }

    @Test func punctuationAttachesToPreviousSystemTextNotMicrophone() {
        let result = ExportParagraphPolish.coalesce([
            .init(text: "On écoute", speaker: 3, start: 0, end: 1),
            .init(text: "Oui", speaker: 0, start: 1, end: 2),
            .init(text: ".", speaker: nil, start: 2, end: 3)])
        #expect(result.map(\.text) == ["On écoute.", "Oui"])
        #expect(result.map(\.speaker) == [3, 0])
        let leading = ExportParagraphPolish.coalesce([.init(text: ".", speaker: nil, start: 0, end: 1)])
        #expect(leading.first?.speaker == nil)
        #expect(leading.first?.text == ".")
    }

    @Test func collectorMatchesActivityAcrossUnevenBuffers() {
        var data = [Float](repeating: 0, count: 17713)
        for i in 315..<380 { data[i] = 0.1 }
        for i in 15995..<16200 { data[i] = 0.01 }
        data[17712] = 0.01
        var expected: [AudioEchoInterval] = []
        ExportAudioActivity.append(data, startFrame: 0, to: &expected)
        var collector = ExportAudioActivity.Collector()
        for start in stride(from: 0, to: data.count, by: 457) {
            collector.consume(Array(data[start..<min(data.count, start + 457)]))
        }
        let actual = collector.finish()
        #expect(actual.spans.map(\.start) == expected.map(\.start))
        #expect(actual.spans.map(\.end) == expected.map(\.end))
    }

    @Test func checkpointsReuseStagesButInvalidateChangedInputsAndText() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Checkpoint-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = try MeetingRecording(language: "en-US", microphone: true, detectSpeakers: true, root: root) { _ in }
        let meeting = await recorder.finish()
        try meeting.saveLiveTranscript(snapshot())
        let clean = meeting.directory.appendingPathComponent("microphone-cleaned.caf")
        do { _ = try MeetingRecording.makeFile(clean) }
        let key = try ExportCheckpoint.inputKey(meeting)
        var cached = ExportCheckpoint(key: key)
        cached.cleanedStamp = try ExportCheckpoint.FileStamp.read(clean)
        cached.echoOnly = []
        cached.contextFrames = [.init(start: 0, end: 1, correlation: 0.4, residualRatio: 0.2, referencePower: 0.01)]
        cached.microphone = [.init(text: "My completed recognition.", start: 2, end: 3, source: .microphone)]
        try cached.save(meeting)
        #expect(ExportCheckpoint.load(meeting, key: key).echo(for: meeting) != nil)
        let cachedEvidence = ExportCheckpoint.load(meeting, key: key).echo(for: meeting)?.contextFrames
        #expect(cachedEvidence?.count == 1)
        #expect(cachedEvidence?.first?.correlation == 0.4)
        #expect(cachedEvidence?.first?.residualRatio == 0.2)
        let first = try await MeetingProcessor().analyze(meeting) { _ in }
        #expect(first.microphone == cached.microphone)
        let second = try await MeetingProcessor().analyze(meeting) { _ in }
        #expect(second.microphone == first.microphone)
        #expect(second.system == first.system)
        var staleAssembly = ExportCheckpoint.load(meeting, key: key)
        staleAssembly.assembledRevision = nil
        staleAssembly.analysis = MeetingAnalysis(system: [.init(text: "stale", start: 0, end: 1)],
            microphone: first.microphone, intervals: [])
        try staleAssembly.save(meeting)
        let rebuilt = try await MeetingProcessor().analyze(meeting) { _ in }
        #expect(rebuilt.system == first.system)
        #expect(ExportCheckpoint.load(meeting, key: key).assembledRevision == ExportCheckpoint.currentAssemblyRevision)
        try meeting.saveLiveTranscript(snapshot("Revised system text."))
        let revised = try await MeetingProcessor().analyze(meeting) { _ in }
        #expect(revised.system[0].text == "Revised system text.")
        #expect(revised.microphone == first.microphone)
        // Corrupt derived audio: a saved echo stage must no longer be reused.
        try Data("broken".utf8).write(to: clean)
        #expect(ExportCheckpoint.load(meeting, key: key).echo(for: meeting) == nil)
        // Same-length source edit still invalidates stamps (including ctime).
        let audio = meeting.audio(.microphone)
        var bytes = try Data(contentsOf: audio)
        bytes[bytes.count - 1] ^= 1
        try bytes.write(to: audio)
        let changed = try ExportCheckpoint.inputKey(meeting)
        #expect(changed != key)
        #expect(ExportCheckpoint.load(meeting, key: changed).microphone == nil)
        try Data("corrupt JSON".utf8).write(to: meeting.directory.appendingPathComponent("export-checkpoint.json"))
        #expect(ExportCheckpoint.load(meeting, key: changed).analysis == nil)
        var differentLanguage = meeting
        differentLanguage.manifest = RecordingManifest(id: meeting.id, created: meeting.manifest.created,
            language: "fr-FR", microphone: true, detectSpeakers: true)
        #expect(try ExportCheckpoint.inputKey(differentLanguage) != changed)
    }
}

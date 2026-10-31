import AVFoundation
import Foundation
import Testing
@testable import MyWizard

struct LiveTranscriptExportTests {
    @Test func completeEchoMatchingPrecedesRemovalOfIndividualAcousticTokens() {
        let system = "la vidéo explique comment construire un modèle pour cette usine avec des capteurs".split(separator: " ").enumerated().map {
            TimedText(text: String($0.element) + " ", start: Double($0.offset) * 0.25, end: Double($0.offset + 1) * 0.25)
        }
        var document = SpeakerTranscript()
        document.beginSession(detectsSpeakers: true, reservesOwnSpeaker: true)
        document.receive(system, isFinal: true)
        let snapshot = document.liveSnapshot(names: [0: "Yvan"])
        let echo = system.map { TimedText(text: $0.text, start: $0.start + 0.1, end: $0.end + 0.1, source: .microphone) }
        let evidence = EchoReductionResult(audio: URL(fileURLWithPath: "/unused"), echoOnly:
            echo.enumerated().filter { $0.offset % 2 == 0 }.map { .init(start: $0.element.start, end: $0.element.end) })
        let reply = TimedText(text: "1, 2, 3, voici mon avis, 1, 2, 3.", start: 4, end: 7, source: .microphone)
        // Old ordering leaves disconnected echo words after losing the anchors.
        #expect(!snapshot.addingMicrophone(evidence.removingEchoArtifacts(from: echo)).microphone.isEmpty)
        let result = snapshot.addingMicrophone(echo + [reply], echoEvidence: evidence)
        #expect(result.microphone.map(\.text).joined() == reply.text)
        #expect(result.system == snapshot.words)
    }

    @Test func liveAndRecordedWordsShareOriginDespiteStartupDelay() {
        let timeline = CaptureTimeline()
        timeline.reset(origin: 100)
        #expect(timeline.startOffset(for: .microphone, presentationTime: 100.3) > 0.29)
        #expect(timeline.startOffset(for: .systemAudio, presentationTime: 101.5) == 1.5)
        let live = timeline.alignWords([.init(text: "System", start: 2, end: 3)], source: .systemAudio)
        #expect(live.first?.start == 3.5)
        #expect(live.first?.end == 4.5)
        #expect(timeline.alignSystemSpeakers(.init(intervals: [.init(slot: 0, start: 2, end: 3)], processedThrough: 3)).intervals.first?.start == 3.5)
    }

    private func document() -> SpeakerTranscript {
        var document = SpeakerTranscript()
        document.beginSession(detectsSpeakers: true, language: "en-US", reservesOwnSpeaker: true)
        document.updateSpeakers(.init(intervals: [.init(slot: 8, start: 0, end: 2),
            .init(slot: 3, start: 4, end: 6)], processedThrough: 6))
        document.receive([.init(text: "The live sentence.", start: 0, end: 2)], isFinal: true)
        document.receive([.init(text: "The unfinished tail", start: 4, end: 6)], isFinal: false)
        return document
    }

    @Test func snapshotPersistsExactLiveTextLabelsNamesAndProvisionalTail() throws {
        var document = document()
        let display = document.systemDisplayParagraphs
        let snapshot = try JSONDecoder().decode(LiveTranscriptSnapshot.self,
            from: JSONEncoder().encode(document.liveSnapshot(names: [0: "Yvan", 1: "Mike", 2: "Alice"])))
        #expect(snapshot.names == [0: "Yvan", 1: "Mike", 2: "Alice"])
        #expect(snapshot.display == display)
        let own = [TimedText(text: "My complete reply.", start: 2.5, end: 3.5, source: .microphone)]
        let analysis = snapshot.addingMicrophone(own)
        document.replaceCurrentSession(with: analysis)
        #expect(document.systemDisplayParagraphs == display)
        #expect(document.deduplicatedParagraphs.map(\.speaker) == [1, 0, 2])
        #expect(document.deduplicatedParagraphs.filter(\.canReadAloud).map(\.text).joined() == display.map(\.text).joined())
        #expect(document.plainText(names: snapshot.names).contains("Yvan:\nMy complete reply."))
        #expect(document.plainText(names: snapshot.names).contains("Alice:\nThe unfinished tail"))
        document.replaceCurrentSession(with: analysis)
        #expect(document.deduplicatedParagraphs.count == 3) // retry is idempotent
        document.beginSession(detectsSpeakers: true, reservesOwnSpeaker: true)
        #expect(document.systemDisplayParagraphs == display)
        #expect(document.deduplicatedParagraphs.count == 3)
        #expect(document.exportFirstSpeakerNumber == 3)
        document.clear()
        #expect(document.systemDisplayParagraphs.isEmpty)
    }

    @Test func overlappingReplyStaysWholeAndNeverRewritesSystemText() {
        let snapshot = document().liveSnapshot(names: [0: "Yvan"])
        let own = [TimedText(text: "I ", start: 0.6, end: 0.8, source: .microphone),
                   TimedText(text: "disagree.", start: 1, end: 1.7, source: .microphone)]
        let result = snapshot.addingMicrophone(own)
        #expect(result.paragraphs?.map(\.text) == ["The live sentence. ", "I disagree.", "The unfinished tail"])
        #expect(result.paragraphs?.map(\.speaker) == [1, 0, 2])
        #expect(result.system == snapshot.words)
    }

    @Test func echoRemovalOnlyAffectsMicrophoneAndRetainsIndependentReply() {
        let snapshot = document().liveSnapshot(names: [:])
        let echo = snapshot.words.map { TimedText(text: $0.text, start: $0.start + 0.1, end: $0.end + 0.1, source: .microphone) }
        let result = snapshot.addingMicrophone(echo + [.init(text: "My separate contribution.", start: 8, end: 9, source: .microphone)])
        #expect(result.system == snapshot.words)
        #expect(result.microphone.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines) == "My separate contribution.")
        #expect(result.paragraphs?.last?.speaker == SpeakerIdentity.microphone)
    }

    @Test func sentenceBoundariesPermitRepliesInsideLongSpeakerTurns() {
        var document = SpeakerTranscript()
        document.beginSession(detectsSpeakers: true)
        document.updateSpeakers(.init(intervals: [.init(slot: 0, start: 0, end: 8)], processedThrough: 8))
        document.receive([.init(text: "First sentence. ", start: 0, end: 1),
                          .init(text: "Second sentence.", start: 4, end: 6)], isFinal: true)
        let snapshot = document.liveSnapshot(names: [:])
        let result = snapshot.addingMicrophone([.init(text: "My reply.", start: 2, end: 3, source: .microphone)])
        #expect(snapshot.display.count == 1)
        #expect(result.paragraphs?.map(\.speaker) == [1, 0, 1])
        #expect(result.paragraphs?.filter { $0.speaker == 1 }.map(\.text).joined() == snapshot.display.map(\.text).joined())
    }

    @Test(arguments: [false, true]) func normalExportKeepsLiveTextWithoutRecognitionWhenMicrophoneSilent(microphone: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LiveExport-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = try MeetingRecording(language: "en-US", microphone: microphone, detectSpeakers: true, root: root, origin: 0) { _ in }
        let meeting = await recorder.finish()
        let snapshot = document().liveSnapshot(names: [0: "Yvan", 1: "Mike"])
        try meeting.saveLiveTranscript(snapshot)
        // An absent system track proves neither system retranscription nor
        // offline diarization is needed in normal export.
        try FileManager.default.removeItem(at: meeting.audio(.system))
        let processor = MeetingProcessor()
        let progress = ExportProgressValues()
        let result = try await processor.analyze(meeting) { progress.append($0) }
        #expect(result.system == snapshot.words)
        #expect(result.microphone.isEmpty)
        #expect(result.paragraphs?.map(\.speaker) == [1, 2])
        #expect(result.liveSystemParagraphs == snapshot.display)
        #expect(progress.values.first == 0 && progress.values.last == 100)
        #expect(progress.values == progress.values.sorted())
        #expect(try meeting.loadLiveTranscript().words == snapshot.words)
    }

    @Test func missingSnapshotFailsExplicitlyWithoutInventingSystemTranscript() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LiveMissing-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = try MeetingRecording(language: "en-US", microphone: false, detectSpeakers: true, root: root, origin: 0) { _ in }
        let meeting = await recorder.finish()
        await #expect(throws: (any Error).self) { try await MeetingProcessor().analyze(meeting) { _ in } }
        #expect(FileManager.default.fileExists(atPath: meeting.audio(.system).path))
        #expect(!FileManager.default.fileExists(atPath: meeting.directory.appendingPathComponent("analysis.json").path))
    }

    @Test func microphoneFailurePreservesFrozenTextAndOriginalAudio() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LiveMicFailure-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = try MeetingRecording(language: "en-US", microphone: true, detectSpeakers: true, root: root, origin: 0) { _ in }
        let pcm = try #require(AVAudioPCMBuffer(pcmFormat: MeetingRecording.format, frameCapacity: 16000))
        pcm.frameLength = 16000
        pcm.floatChannelData![0].initialize(repeating: 0.2, count: 16000)
        try recorder.append(pcm, track: .microphone, time: 0)
        let meeting = await recorder.finish()
        let snapshot = document().liveSnapshot(names: [0: "Yvan"])
        try meeting.saveLiveTranscript(snapshot)
        let original = try Data(contentsOf: meeting.audio(.microphone))
        // Corrupt only a disposable echo reference to force a processing failure.
        try FileManager.default.removeItem(at: meeting.audio(.reading))
        let processor = MeetingProcessor()
        let progress = ExportProgressValues()
        await #expect(throws: (any Error).self) { try await processor.analyze(meeting) { progress.append($0) } }
        #expect(try meeting.loadLiveTranscript().words == snapshot.words)
        #expect(try Data(contentsOf: meeting.audio(.microphone)) == original)
        #expect(!progress.values.contains(100))
        #expect(!FileManager.default.fileExists(atPath: meeting.directory.appendingPathComponent("analysis.json").path))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MYWIZARD_RECORDED_FIXTURES"] != nil))
    func realMicrophoneSpeechIsExportedUnderYvanWithoutChangingLiveText() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["MYWIZARD_RECORDED_FIXTURES"])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LiveRealMic-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = try MeetingRecording(language: "en-US", microphone: true, detectSpeakers: true, root: root, origin: 0) { _ in }
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path).appendingPathComponent("speaker-two.aiff"))
        while file.framePosition < file.length {
            let time = Double(file.framePosition) / file.processingFormat.sampleRate
            let pcm = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8192))
            try file.read(into: pcm)
            try recorder.append(pcm, track: .microphone, time: time)
        }
        let meeting = await recorder.finish()
        var document = document()
        let snapshot = document.liveSnapshot(names: [0: "Yvan", 1: "Mike", 2: "Alice"])
        try meeting.saveLiveTranscript(snapshot)
        let original = try Data(contentsOf: meeting.audio(.microphone))
        let progress = ExportProgressValues()
        let started = Date()
        let result = try await MeetingProcessor().analyze(meeting) { progress.append($0) }
        #expect(result.microphone.map(\.text).joined().lowercased().contains("budget"))
        #expect(result.microphone.allSatisfy { $0.source == .microphone })
        #expect(result.system == snapshot.words)
        document.replaceCurrentSession(with: result)
        #expect(document.systemDisplayParagraphs == snapshot.display)
        #expect(document.systemDisplayParagraphs.allSatisfy { $0.canReadAloud })
        let text = document.plainText(names: snapshot.names)
        #expect(text.contains("Yvan:\n"))
        #expect(text.contains("Mike:\nThe live sentence."))
        #expect(text.contains("Alice:\nThe unfinished tail"))
        let destination = root.appendingPathComponent("meeting.txt")
        try await MainActor.run {
            let preferences = MemoryPreferences()
            try TranscriptExporter(preferences: preferences).write(text, to: destination)
        }
        #expect(try String(contentsOf: destination, encoding: .utf8) == text)
        #expect(progress.values.last == 100)
        #expect(progress.values == progress.values.sorted())
        #expect(try Data(contentsOf: meeting.audio(.microphone)) == original)
        print("LIVE + MICROPHONE CHECK: \(result.microphone.count) microphone words, \(Date().timeIntervalSince(started)) seconds; live text and names preserved")
    }
}

import AVFoundation
import Speech
import Testing
@testable import MyWizard

struct MeetingControlsTests {
    @Test func searchFindsEveryOccurrenceAcrossUnicodeAndAccents() {
        let paragraphs = [TranscriptParagraph(id: 7, text: "👋 Réunion, reunion et RÉUNION.", speaker: 1, hasSpeakerLabel: true),
                          TranscriptParagraph(id: 12, text: "Autre réunion.", speaker: 2, hasSpeakerLabel: true)]
        let matches = TranscriptSearch.matches("  reunion ", in: paragraphs)
        #expect(matches.count == 4)
        #expect(matches.map(\.paragraphID) == [7, 7, 7, 12])
        let text = paragraphs[0].text as NSString
        #expect(text.substring(with: NSRange(location: matches[0].location, length: matches[0].length)) == "Réunion")
        #expect(Set(matches.map(\.id)).count == 4)
        #expect(TranscriptSearch.matches("  ", in: paragraphs).isEmpty)
        #expect(TranscriptSearch.matches("absent", in: paragraphs).isEmpty)
        #expect(TranscriptSearch.matches("aa", in: [.init(id: 1, text: "aaa", speaker: nil, hasSpeakerLabel: false)]).count == 1)
    }

    @Test func pauseMappingPreservesWallTimeAndNeverAssignsSpeakersToTheGap() {
        let timeline = CaptureTimeline()
        timeline.reset(origin: 100)
        timeline.recordSystemBuffer(sampleTime: 0, presentationTime: 101)
        timeline.beginSystemSegment()
        timeline.recordSystemBuffer(sampleTime: 5, presentationTime: 121)
        timeline.beginSystemSegment()
        timeline.recordSystemBuffer(sampleTime: 8, presentationTime: 131)
        let words = timeline.alignWords([
            .init(text: "before", start: 4, end: 5),
            .init(text: "after", start: 5, end: 6),
            .init(text: "again", start: 8, end: 9)
        ], source: .systemAudio)
        #expect(words.map(\.start) == [5, 21, 31])
        #expect(words.map(\.end) == [6, 22, 32])
        let speakers = timeline.alignSystemSpeakers(.init(intervals: [.init(slot: 0, start: 4, end: 9)], processedThrough: 9))
        #expect(speakers.intervals == [.init(slot: 0, start: 5, end: 6), .init(slot: 0, start: 21, end: 24), .init(slot: 0, start: 31, end: 32)])
        #expect(speakers.processedThrough == 32)
        timeline.reset(origin: 200)
        timeline.recordSystemBuffer(sampleTime: 0, presentationTime: 200)
        #expect(timeline.alignWords([.init(text: "new", start: 1, end: 2)], source: .systemAudio)[0].start == 1)
    }

    @Test @MainActor func pausedCaptureStopsDeliveryAndResumesTheSameStreamsAndRecording() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let timeline = CaptureTimeline()
        timeline.reset(origin: 100)
        var taps: [FakeTap] = []
        let capture = SystemAudioCapture(timeline: timeline, makeTap: {
            let tap = FakeTap()
            taps.append(tap)
            return tap
        })
        let recording = try MeetingRecording(language: "en-US", microphone: false, detectSpeakers: true, root: root, origin: 100, onError: { _ in })
        let (audio, input) = AsyncStream<AnalyzerInput>.makeStream()
        let (speakers, speakerInput) = AsyncStream<[Float]>.makeStream()
        try await capture.start(format: MeetingRecording.format, continuation: input, speakerInput: speakerInput,
                                recording: recording, onLevel: { _ in }, onError: { _ in })
        let pcm = try #require(AVAudioPCMBuffer(pcmFormat: MeetingRecording.format, frameCapacity: 8_000))
        pcm.frameLength = 8_000
        pcm.floatChannelData![0].initialize(repeating: 0.1, count: 8_000)
        taps[0].deliver(pcm, at: 100)
        let frames = capture.frameCount
        capture.pause()
        taps[0].deliver(pcm, at: 110)
        #expect(capture.frameCount == frames)
        try capture.resume()
        #expect(taps.count == 2)
        taps[1].deliver(pcm, at: 120)
        #expect(capture.frameCount == frames * 2)
        await capture.stop()
        input.finish()
        var buffers = 0
        for await _ in audio { buffers += 1 }
        var speakerChunks = 0
        for await _ in speakers { speakerChunks += 1 }
        #expect(buffers == 2)
        #expect(speakerChunks == 2)
        let saved = await recording.finish()
        let file = try AVAudioFile(forReading: saved.audio(.system))
        #expect(file.length == 328_000) // 20.5 wall-clock seconds, including the pause.
        let resumed = timeline.alignWords([.init(text: "after", start: 0.5, end: 1)], source: .systemAudio)
        #expect(resumed[0].start == 20)
        #expect(resumed[0].end == 20.5)
        #expect(saved.id == recording.id)
    }

    @Test @MainActor func recoveryIgnoresRetiredMetadataAndSkipsAnActiveWriter() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let recording = try MeetingRecording(language: "fr-FR", microphone: false, detectSpeakers: true, root: root, onError: { _ in })
        let date = Date()
        let legacyURL = recording.directory.appendingPathComponent("meeting-events.json")
        let legacyData = Data("Retired metadata, intentionally not JSON".utf8)
        try legacyData.write(to: legacyURL)
        var document = SpeakerTranscript()
        document.beginSession(detectsSpeakers: true, language: "fr-FR", reservesOwnSpeaker: true)
        document.receive([.init(text: "Budget confirmé.", start: 0, end: 1)], isFinal: true)
        let snapshot = document.liveSnapshot(names: [:])
        let active = RecordedMeeting(directory: recording.directory,
            manifest: .init(id: recording.id, created: date, language: "fr-FR", microphone: false, detectSpeakers: true))
        try active.saveLiveTranscript(snapshot)
        #expect(try RecoveryCandidate.discover(in: root).isEmpty)
        let saved = await recording.finish()
        let candidates = try RecoveryCandidate.discover(in: root)
        #expect(candidates.count == 1)
        #expect(candidates[0].issue == nil)
        #expect(try Data(contentsOf: legacyURL) == legacyData)
        let preferences = MemoryPreferences()
        preferences.set("en-US", forKey: "transcriptionLanguage")
        let model = TranscriptionModel(preferences: preferences, recordingRoot: root)
        try model.recover(saved.directory)
        #expect(model.needsProcessing)
        #expect(model.language == "fr-FR")
        #expect(model.exportText.contains("Budget confirmé."))
        #expect(!model.exportText.contains("Retired metadata"))
        #expect(try Data(contentsOf: legacyURL) == legacyData)
        #expect(try RecoveryCandidate.discover(in: root).isEmpty)
        await model.shutDown()
    }

    @Test func incompleteMeetingsAreVisibleAndUnsafeLinksAreRejected() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let recording = try MeetingRecording(language: "fr-FR", microphone: false, detectSpeakers: true, root: root, onError: { _ in })
        let saved = await recording.finish()
        #expect(try RecoveryCandidate.discover(in: root)[0].issue != nil)
        let outside = root.appendingPathComponent("outside.json")
        try Data("[]".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: saved.directory.appendingPathComponent("live-transcript.json"), withDestinationURL: outside)
        #expect(throws: (any Error).self) { try RecordedMeeting.load(saved.directory) }
        #expect(FileManager.default.fileExists(atPath: outside.path))
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("MyWizard.Controls.\(UUID())")
    }

    @MainActor private final class FakeTap: SystemAudioTapControlling {
        private var receive: (@Sendable (AVAudioPCMBuffer, Double) -> Void)?
        private var queue: DispatchQueue?
        func start(queue: DispatchQueue, receive: @escaping @Sendable (AVAudioPCMBuffer, Double) -> Void,
                   onError: @escaping @Sendable (String) -> Void, onDeviceChange: (@Sendable (String) -> Void)?) throws {
            self.queue = queue
            self.receive = receive
        }
        func setMuted(_ muted: Bool) throws {}
        func stop(queue: DispatchQueue) { receive = nil }
        func deliver(_ pcm: AVAudioPCMBuffer, at time: Double) {
            guard let receive, let queue else { return }
            queue.sync { receive(pcm, time) }
        }
    }
}

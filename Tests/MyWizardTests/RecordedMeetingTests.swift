import AVFoundation
import Foundation
import Testing
@testable import MyWizard

struct RecordedMeetingTests {
    @Test func lateMicrophoneActivationAndResumeKeepEarlierAudioAndSilentGaps() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MyWizardMicSwitch-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = try MeetingRecording(language: "en-US", microphone: false, detectSpeakers: true,
                                            root: root, origin: 100) { _ in }
        try recorder.append(buffer(Array(repeating: 0.1, count: 48000)), track: .system, time: 100)
        try await recorder.enableMicrophone()
        try recorder.append(buffer(Array(repeating: 0.2, count: 8000)), track: .microphone, time: 101)
        // Input is stopped while muted; resuming must reuse, not truncate, the file.
        try await recorder.enableMicrophone()
        try recorder.append(buffer(Array(repeating: 0.3, count: 8000)), track: .microphone, time: 102)
        let meeting = await recorder.finish()
        #expect(meeting.manifest.microphone)
        #expect(try RecordedMeeting.load(meeting.directory).manifest.microphone)
        let samples = try read(meeting.audio(.microphone))
        #expect(samples.count == 40000)
        #expect(samples[..<16000].allSatisfy { $0 == 0 })
        #expect(abs(samples[17000] - 0.2) < 0.001)
        #expect(samples[24000..<32000].allSatisfy { $0 == 0 })
        #expect(abs(samples[33000] - 0.3) < 0.001)
        #expect(try read(meeting.audio(.system)).count == 48000)
        await #expect(throws: (any Error).self) { try await recorder.enableMicrophone() }
        #expect(try read(meeting.audio(.microphone)).count == 40000)
    }

    func buffer(_ samples: [Float]) -> AVAudioPCMBuffer {
        let pcm = AVAudioPCMBuffer(pcmFormat: MeetingRecording.format, frameCapacity: AVAudioFrameCount(samples.count))!
        pcm.frameLength = pcm.frameCapacity
        samples.withUnsafeBufferPointer { pcm.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        return pcm
    }

    func read(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let pcm = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: pcm)
        return Array(UnsafeBufferPointer(start: pcm.floatChannelData![0], count: Int(pcm.frameLength)))
    }

    @Test func separateTracksPreserveOffsetsAndRecoverAndMP4ContainsBothTracks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MyWizardRecordingTest-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = try MeetingRecording(language: "en-US", microphone: true, detectSpeakers: false, root: root, origin: 100) { _ in }
        try recorder.append(buffer(Array(repeating: 0.1, count: 16000)), track: .system, time: 100)
        try recorder.append(buffer(Array(repeating: 0.3, count: 8000)), track: .microphone, time: 100.25)
        recorder.systemMuted(true, at: 100.5)
        let meeting = await recorder.finish()
        #expect(meeting.manifest.failure == nil)
        let system = try read(meeting.audio(.system))
        let microphone = try read(meeting.audio(.microphone))
        #expect(system.count == 16000)
        #expect(microphone.count == 12000)
        #expect(microphone.prefix(4000).allSatisfy { $0 == 0 })
        #expect(abs(microphone[5000] - 0.3) < 0.001)
        #expect(abs(system[5000] - 0.1) < 0.001)
        #expect(try RecordedMeeting.load(meeting.directory).manifest.mutedSystem.first?.time == 0.5)
        try await RecordingMovie.write(meeting)
        let tracks = try await AVURLAsset(url: meeting.directory.appendingPathComponent("meeting.mp4")).loadTracks(withMediaType: .audio)
        #expect(tracks.count == 2)
        #expect(FileManager.default.fileExists(atPath: meeting.audio(.system).path))
        #expect(FileManager.default.fileExists(atPath: meeting.audio(.microphone).path))
    }

    @Test func cancellationAndWriterFailureKeepOriginalsAndMetadata() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MyWizardRecordingTest-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = try MeetingRecording(language: "en-US", microphone: false, detectSpeakers: false, root: root, origin: 0) { _ in }
        try recorder.append(buffer(Array(repeating: 0.1, count: 800)), track: .system, time: 0)
        recorder.fail("Simulated disk failure")
        let meeting = await recorder.finish()
        let recovered = try RecordedMeeting.load(meeting.directory)
        #expect(recovered.manifest.state == "interrupted")
        #expect(recovered.manifest.failure == "Simulated disk failure")
        #expect(try read(meeting.audio(.system)).count == 800)
    }

    @Test func adaptiveEchoReductionPreservesIndependentSpeech() {
        var state: UInt64 = 42
        func noise(_ count: Int) -> [Float] {
            (0..<count).map { _ in
                state = state &* 6364136223846793005 &+ 1
                return Float(Int64(bitPattern: state) >> 40) / Float(1 << 23) * 0.1
            }
        }
        let reference = noise(48000)
        let near = noise(48000).map { $0 * 0.2 }
        var reducer = OfflineEchoReducer()
        var output: [Float] = []
        var microphone: [Float] = []
        for i in reference.indices {
            microphone.append((i >= 320 ? reference[i - 320] * 0.5 : 0) + (i >= 16000 ? near[i] : 0))
        }
        for offset in stride(from: 0, to: 48000, by: 16000) {
            output += reducer.process(microphone: Array(microphone[offset..<offset + 16000]), reference: Array(reference[offset..<offset + 16000]))
        }
        let rawError = (20000..<48000).reduce(Float(0)) { $0 + pow(microphone[$1] - near[$1], 2) }
        let cleanError = (20000..<48000).reduce(Float(0)) { $0 + pow(output[$1] - near[$1], 2) }
        #expect(cleanError < rawError * 0.2)
        var unrelated = OfflineEchoReducer()
        #expect(unrelated.process(microphone: near, reference: Array(repeating: 0, count: near.count)) == near)
    }

    @Test func reprocessingDoesNotRenumberSpeakersOrLosePreviousSessions() {
        var document = SpeakerTranscript()
        document.beginSession(detectsSpeakers: true, language: "en-US", reservesOwnSpeaker: true)
        let analysis = MeetingAnalysis(system: [TimedText(text: "First meeting", start: 0, end: 1)], microphone: [],
            intervals: [SpeakerInterval(slot: 0, start: 0, end: 1)])
        document.replaceCurrentSession(with: analysis)
        let before = document.paragraphs
        document.replaceCurrentSession(with: analysis)
        #expect(document.paragraphs == before)
        document.beginSession(detectsSpeakers: true, language: "en-US", reservesOwnSpeaker: true)
        document.replaceCurrentSession(with: analysis)
        #expect(document.paragraphs.map(\.speaker) == [1, 2])
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MYWIZARD_RECORDED_FIXTURES"] != nil), arguments: [false, true])
    func recordedRemoteVoiceEchoDoesNotBecomeLocalSpeaker(withLocalSpeech: Bool) async throws {
        let path = try #require(ProcessInfo.processInfo.environment["MYWIZARD_RECORDED_FIXTURES"])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MyWizardEchoSpeech-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path).appendingPathComponent("speaker-one.aiff"))
        let converter = AudioConverter(outputFormat: MeetingRecording.format)
        var reference: [Float] = []
        while file.framePosition < file.length {
            let pcm = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8192)!
            try file.read(into: pcm)
            let converted = try converter.convert(pcm)
            reference += Array(UnsafeBufferPointer(start: converted.floatChannelData![0], count: Int(converted.frameLength)))
        }
        reference += Array(repeating: 0, count: 16000)
        var local = [Float](repeating: 0, count: reference.count)
        if withLocalSpeech {
            let file = try AVAudioFile(forReading: URL(fileURLWithPath: path).appendingPathComponent("speaker-two.aiff"))
            let converter = AudioConverter(outputFormat: MeetingRecording.format)
            var offset = 0
            while file.framePosition < file.length {
                let pcm = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8192)!
                try file.read(into: pcm)
                let converted = try converter.convert(pcm)
                let count = min(Int(converted.frameLength), local.count - offset)
                guard count > 0 else { break }
                for i in 0..<count { local[offset + i] = converted.floatChannelData![0][i] * 0.6 }
                offset += count
            }
        }
        let microphone = reference.indices.map { i -> Float in
            (i >= 1607 ? reference[i - 1607] * 0.3 : 0)
                + (i >= 1687 ? reference[i - 1687] * 0.06 : 0) + local[i]
        }
        let recorder = try MeetingRecording(language: "en-US", microphone: true, detectSpeakers: false, root: root, origin: 0) { _ in }
        try recorder.append(buffer(reference), track: .system, time: 0)
        try recorder.append(buffer(microphone), track: .microphone, time: 0)
        let meeting = await recorder.finish()
        let reduced = try OfflineEchoReducer.reduce(meeting) { _ in }
        let cleanSamples = try read(reduced.audio)
        let error = local.indices.reduce(Float(0)) { $0 + pow(cleanSamples[$1] - local[$1], 2) }
        let rawError = local.indices.reduce(Float(0)) { $0 + pow(microphone[$1] - local[$1], 2) }
        #expect(error < rawError)
        // Build a stand-in live snapshot from the synthetic system fixture.
        // This setup recognition is not part of the normal export below.
        var live = SpeakerTranscript()
        live.beginSession(detectsSpeakers: true, reservesOwnSpeaker: true)
        let fixtureWords = try await MeetingProcessor().transcribe(meeting.audio(.system), language: "en-US")
        live.receive(fixtureWords, isFinal: true)
        live.updateSpeakers(.init(intervals: [.init(slot: 0, start: 0, end: Double(reference.count) / 16000)],
                                  processedThrough: Double(reference.count) / 16000))
        let snapshot = live.liveSnapshot(names: [0: "Yvan", 1: "Remote"])
        try meeting.saveLiveTranscript(snapshot)
        let result = try await MeetingProcessor().analyze(meeting) { print("LIVE + MIC ECHO CHECK: \($0)") }
        #expect(result.system == snapshot.words)
        #expect(result.system.map(\.text).joined().lowercased().contains("project"))
        if withLocalSpeech {
            #expect(result.microphone.map(\.text).joined().lowercased().contains("budget"))
            #expect(result.paragraphs?.contains { $0.speaker == SpeakerIdentity.microphone } == true)
        } else {
            #expect(result.microphone.isEmpty)
        }
        #expect(try read(meeting.audio(.microphone)).contains { abs($0) > 0.01 })
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MYWIZARD_RECORDED_FIXTURES"] != nil))
    func recordedSpeechAnalysisHasBothSourcesAndNoLiveMicrophoneDependency() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["MYWIZARD_RECORDED_FIXTURES"])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MyWizardRecordedSpeech-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let detect = ProcessInfo.processInfo.environment["MYWIZARD_RECORDED_SPEAKERS"] == "1"
        let recorder = try MeetingRecording(language: "en-US", microphone: true, detectSpeakers: detect, root: root, origin: 0) { _ in }
        for (name, track) in [("speaker-one.aiff", RecordedTrack.system), ("speaker-two.aiff", RecordedTrack.microphone)] {
            let file = try AVAudioFile(forReading: URL(fileURLWithPath: path).appendingPathComponent(name))
            var seconds = 0.0
            while file.framePosition < file.length {
                let pcm = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8192)!
                try file.read(into: pcm)
                try recorder.append(pcm, track: track, time: seconds)
                seconds += Double(pcm.frameLength) / pcm.format.sampleRate
            }
        }
        let meeting = await recorder.finish()
        let progress = ExportProgressValues()
        let result = try await MeetingProcessor().analyzeWithApple(meeting) { progress.append($0) }
        #expect(result.system.map(\.text).joined().lowercased().contains("project"))
        #expect(result.microphone.map(\.text).joined().lowercased().contains("budget"))
        #expect(result.microphone.allSatisfy { $0.source == .microphone })
        if detect { #expect(!result.intervals.isEmpty) }
        #expect(!FileManager.default.fileExists(atPath: meeting.directory.appendingPathComponent("meeting.mp4").path))
        #expect(FileManager.default.fileExists(atPath: meeting.directory.appendingPathComponent("analysis.json").path))
        #expect(FileManager.default.fileExists(atPath: meeting.audio(.microphone).path))
        #expect(progress.values.first == 0)
        #expect(progress.values.last == 100)
        #expect(progress.values.contains { $0 > 0 && $0 < 100 })
        #expect(progress.values == progress.values.sorted())
        print("GLOBAL EXPORT PROGRESS: \(progress.values)")
    }

    @Test func cancelledPreparationKeepsAudioAndNeverReportsCompletion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MyWizardCancelledExport-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = try MeetingRecording(language: "en-US", microphone: false, detectSpeakers: false, root: root, origin: 0) { _ in }
        try recorder.append(buffer(Array(repeating: 0.1, count: 16000)), track: .system, time: 0)
        let meeting = await recorder.finish()
        let progress = ExportProgressValues()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await MeetingProcessor().analyze(meeting) { progress.append($0) }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!progress.values.contains(100))
        #expect(!FileManager.default.fileExists(atPath: meeting.directory.appendingPathComponent("analysis.json").path))
        #expect(try read(meeting.audio(.system)).count == 16000)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MYWIZARD_RECORDED_FIXTURES"] != nil), arguments: [false, true])
    func silentExportCompletesWithOptionalMicrophone(microphone: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MyWizardSilentExport-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = try MeetingRecording(language: "en-US", microphone: microphone, detectSpeakers: true, root: root, origin: 0) { _ in }
        try recorder.append(buffer(Array(repeating: 0, count: 16000)), track: .system, time: 0)
        let meeting = await recorder.finish()
        let progress = ExportProgressValues()
        let result = try await MeetingProcessor().analyzeWithApple(meeting) { progress.append($0) }
        #expect(result.system.isEmpty && result.microphone.isEmpty && result.intervals.isEmpty)
        #expect(progress.values.first == 0 && progress.values.last == 100)
        #expect(progress.values == progress.values.sorted())
        #expect(try read(meeting.audio(.system)).count == 16000)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MYWIZARD_RECORDED_FIXTURES"] != nil))
    func failingParallelTrackDoesNotCommitAnalysisOrRemoveOtherTrack() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MyWizardFailedExport-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = try MeetingRecording(language: "en-US", microphone: true, detectSpeakers: false, root: root, origin: 0) { _ in }
        try recorder.append(buffer(Array(repeating: 0.1, count: 16000)), track: .system, time: 0)
        let meeting = await recorder.finish()
        // Corrupt only this test's disposable recording, not a user's session.
        try FileManager.default.removeItem(at: meeting.audio(.microphone))
        let progress = ExportProgressValues()
        await #expect(throws: (any Error).self) {
            try await MeetingProcessor().analyzeWithApple(meeting) { progress.append($0) }
        }
        #expect(!progress.values.contains(100))
        #expect(!FileManager.default.fileExists(atPath: meeting.directory.appendingPathComponent("analysis.json").path))
        #expect(try read(meeting.audio(.system)).count == 16000)
    }
}

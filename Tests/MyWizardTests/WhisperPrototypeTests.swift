import AVFoundation
import Foundation
import Testing
@testable import MyWizard

struct WhisperPrototypeTests {
    @Test func microphoneUsesNamedIdentityAndSystemNumberingStartsAtOne() {
        let words = [TimedText(text: "Local ", start: 0, end: 1, source: .microphone),
                     TimedText(text: "remote ", start: 1, end: 2),
                     TimedText(text: "local again", start: 3, end: 4, source: .microphone)]
        let intervals = [SpeakerInterval(slot: 7, start: 0, end: 2)]
        let paragraphs = WhisperSpeakerAlignment.paragraphs(words: words, intervals: intervals,
            anchors: [.init(number: SpeakerIdentity.microphone, start: 0, end: 2)])
        #expect(paragraphs.map(\.speaker) == [SpeakerIdentity.microphone, 1, SpeakerIdentity.microphone])
        #expect(paragraphs.map(\.text).joined() == words.map(\.text).joined())
        let export = WhisperExportResult(engine: "test", words: words, intervals: intervals, paragraphs: paragraphs, elapsedSeconds: 0)
        #expect(export.text(names: [SpeakerIdentity.microphone: "Yvan"]).components(separatedBy: "Yvan:\n").count == 3)
        #expect(export.text(names: [SpeakerIdentity.microphone: "Other name"]).contains("Other name:\n"))
        #expect(export.text(names: [SpeakerIdentity.microphone: " "]).contains("Microphone:\n"))
        #expect(export.text(names: [SpeakerIdentity.microphone: "Yvan"]).contains("Speaker 1:\n"))
        #expect(!export.text().contains("Speaker 0"))
        #expect(WhisperSpeakerAlignment.paragraphs(words: words, intervals: []).map(\.speaker) == [SpeakerIdentity.microphone, nil, SpeakerIdentity.microphone])
    }

    @Test func mixedReferencePreservesBothTracksAndTheirTrailingAudio() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("WhisperMixTest-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        func fixture(_ name: String, count: Int, level: Float) throws -> URL {
            let url = folder.appendingPathComponent(name + ".caf")
            let file = try MeetingRecording.makeFile(url)
            let buffer = AVAudioPCMBuffer(pcmFormat: MeetingRecording.format, frameCapacity: AVAudioFrameCount(count))!
            buffer.frameLength = AVAudioFrameCount(count)
            buffer.floatChannelData![0].initialize(repeating: level, count: count)
            try file.write(from: buffer)
            return url
        }
        let system = try fixture("system", count: 9000, level: 0.2)
        let microphone = try fixture("microphone", count: 18000, level: 0.6)
        let before = try [Data(contentsOf: system), Data(contentsOf: microphone)]
        let output = folder.appendingPathComponent("mixed.wav")
        try WhisperAudioPreparation.mix(system: system, microphone: microphone, output: output)
        let file = try AVAudioFile(forReading: output)
        #expect(file.length == 18000)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 18000)!
        try file.read(into: buffer)
        #expect(abs(buffer.floatChannelData![0][100] - 0.4) < 0.001)
        #expect(abs(buffer.floatChannelData![0][17000] - 0.3) < 0.001)
        #expect(try Data(contentsOf: system) == before[0])
        #expect(try Data(contentsOf: microphone) == before[1])
        let systemOnly = folder.appendingPathComponent("system-only.wav")
        try WhisperAudioPreparation.mix(system: system, microphone: nil, output: systemOnly)
        let control = try AVAudioFile(forReading: systemOnly)
        try control.read(into: buffer)
        #expect(control.length == 9000)
        #expect(abs(buffer.floatChannelData![0][100] - 0.2) < 0.001)
    }

    @Test func alignmentPreservesAllTextIncludingZeroLengthAndMissingTokenTimes() throws {
        let json = #"{"transcription":[{"text":" Hello, we are ready.  ","offsets":{"from":0,"to":2000},"tokens":[{"text":" Hello,","offsets":{"from":50,"to":300}},{"text":" we","offsets":{"from":450,"to":450}},{"text":" are"},{"text":" ready.  ","offsets":{"from":1200,"to":1900}}]}]}"#
        let words = try WhisperAlignment.decode(Data(json.utf8), offset: 600, duration: 10)
        #expect(words.map(\.text).joined() == " Hello, we are ready.  ")
        #expect(words.count == 4)
        #expect(words.allSatisfy { $0.start >= 600 && $0.end > $0.start && $0.end <= 602.001 })
        #expect(words.map(\.start) == words.map(\.start).sorted())
    }

    @Test func unicodeAndMismatchedTokensFallBackWithoutDroppingWords() throws {
        let json = #"{"transcription":[{"text":" Ça, c’est Zürich !","offsets":{"from":0,"to":1000},"tokens":[{"text":"mismatch"}]}]}"#
        let words = try WhisperAlignment.decode(Data(json.utf8), offset: 0, duration: 1)
        #expect(words.map(\.text).joined() == " Ça, c’est Zürich !")
        #expect(words.allSatisfy { $0.end > $0.start })
    }

    @Test func unknownLabelsAndOverlapsNeverDeleteTranscriptContent() {
        let words = [TimedText(text: "Hello ", start: 0, end: 1), TimedText(text: "there. ", start: 1, end: 2),
                     TimedText(text: "We agree.", start: 2, end: 3)]
        let result = WhisperSpeakerAlignment.paragraphs(words: words, intervals: [.init(slot: 0, start: 0, end: 3), .init(slot: 1, start: 1, end: 2)])
        #expect(result.map(\.text).joined() == words.map(\.text).joined())
        #expect(result.map(\.speaker) == [1, nil, 1])
        #expect(!result.contains { $0.speaker == SpeakerIdentity.microphone })
    }

    @Test func trustedNamesFollowVoiceIntervalsNotNewClusterOrder() {
        let words = [TimedText(text: "First ", start: 0, end: 1), TimedText(text: "second", start: 2, end: 3)]
        let result = WhisperSpeakerAlignment.paragraphs(words: words,
            intervals: [.init(slot: 8, start: 0, end: 1), .init(slot: 3, start: 2, end: 3)],
            anchors: [.init(number: 5, start: 0, end: 1), .init(number: 2, start: 2, end: 3)])
        #expect(result.map(\.speaker) == [5, 2])
    }

    @Test func progressAndLanguageUseExplicitProtocol() throws {
        #expect(WhisperTranscriber.reportedPercent("whisper_print_progress_callback: progress =  45%") == 45)
        #expect(WhisperTranscriber.reportedPercent("GPU loaded 100%") == nil)
        #expect(try WhisperTranscriber.languageCode("de-CH") == "de")
        #expect(try WhisperTranscriber.languageCode("en-US") == "en")
        #expect(throws: (any Error).self) { try WhisperTranscriber.languageCode("../../unknown") }
    }

    @Test func cancelledChildCannotStart() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await ExportChildProcess().run(URL(fileURLWithPath: "/usr/bin/true"), arguments: [])
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func childFailureIsReportedAndPipesAreDrained() async throws {
        try await ExportChildProcess().run(URL(fileURLWithPath: "/usr/bin/true"), arguments: [])
        await #expect(throws: (any Error).self) {
            try await ExportChildProcess().run(URL(fileURLWithPath: "/usr/bin/false"), arguments: [])
        }
    }

    @Test func runningChildIsTerminatedOnCancellation() async throws {
        let began = ContinuousClock.now
        let task = Task { try await ExportChildProcess().run(URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"]) }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(began.duration(to: .now) < .seconds(5))
    }
}

import AVFoundation
import Foundation
import Speech
import Testing
@testable import MyWizard

struct DualSpeechIntegrationTests {
    // Uses synthetic fixtures only. No live microphone/system capture or playback.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MYWIZARD_DUAL_SPEECH_FIXTURES"] != nil))
    func twoAppleAnalyzersRunTogetherAndKeepSourcesSeparate() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["MYWIZARD_DUAL_SPEECH_FIXTURES"])
        async let system = transcribe(path + "/speaker-one.aiff")
        async let microphone = transcribe(path + "/speaker-two.aiff")
        let (systemWords, ownWords) = try await (system, microphone)
        #expect(!systemWords.isEmpty)
        #expect(!ownWords.isEmpty)
        #expect(systemWords.map(\.text) != ownWords.map(\.text))
        var document = SpeakerTranscript()
        document.beginSession(detectsSpeakers: false, reservesOwnSpeaker: true)
        document.receive(systemWords, isFinal: true)
        document.receive(ownWords, isFinal: true, source: .microphone)
        #expect(document.paragraphs.contains { $0.source == .microphone && $0.speaker == SpeakerIdentity.microphone })
        var cursor = LiveReadingCursor()
        let readable = cursor.takeNew(from: document.finalizedParagraphs)
        #expect(readable.allSatisfy { $0.source == .systemAudio })
        #expect(readable.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines) == systemWords.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines))
        print("DUAL SPEECH CHECK PASS: two Apple analyzers, independent results, microphone excluded from reading")
    }

    private func transcribe(_ path: String) async throws -> [TimedText] {
        let transcriber = SpeechTranscriber(locale: Locale(identifier: "en-US"),
            transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let format = try #require(await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]))
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        let converter = MyWizard.AudioConverter(outputFormat: format)
        let (sequence, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let results = Task { () throws -> [TimedText] in
            var words: [TimedText] = []
            for try await result in transcriber.results {
                for run in result.text.runs {
                    let range = run.audioTimeRange ?? result.range
                    words.append(TimedText(text: String(result.text[run.range].characters),
                                           start: range.start.seconds, end: range.end.seconds))
                }
            }
            return words
        }
        do {
            try await analyzer.prepareToAnalyze(in: format)
            try await analyzer.start(inputSequence: sequence)
            var sent: Int64 = 0
            while file.framePosition < file.length {
                let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8192))
                try file.read(into: buffer)
                let converted = try converter.convert(buffer)
                if converted.frameLength > 0 {
                    continuation.yield(AnalyzerInput(buffer: converted,
                        bufferStartTime: CMTime(value: sent, timescale: CMTimeScale(format.sampleRate))))
                    sent += Int64(converted.frameLength)
                }
            }
            continuation.finish()
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            return try await results.value
        } catch {
            continuation.finish()
            await analyzer.cancelAndFinishNow()
            results.cancel()
            throw error
        }
    }
}

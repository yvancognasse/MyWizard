import AVFoundation
import Foundation
import Speech
import Testing
@testable import MyWizard

struct SpeakerIntegrationTests {
    // Explicit opt-in: uses two synthetic local audio fixtures and downloads the
    // diarization model once. Never captures the user's microphone or system audio.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MYWIZARD_SPEAKER_FIXTURES"] != nil))
    func syntheticTwoVoicePipeline() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["MYWIZARD_SPEAKER_FIXTURES"])
        let first = try loadSamples(path + "/speaker-one.aiff")
        let second = try loadSamples(path + "/speaker-two.aiff")
        let silence = [Float](repeating: 0, count: 16_000)
        let samples = first + silence + second + silence + first + silence
        let detector = SpeakerDetection()
        try await detector.prepare()
        var liveSnapshot: SpeakerSnapshot?
        for index in stride(from: 0, to: samples.count, by: 8_000) {
            if let snapshot = try await detector.process(Array(samples[index..<min(index + 8_000, samples.count)])) {
                liveSnapshot = snapshot
            }
        }
        let live = try #require(liveSnapshot)
        #expect(Set(live.intervals.map(\.slot)).count >= 2)
        var liveDocument = SpeakerTranscript()
        liveDocument.beginSession(detectsSpeakers: true, reservesOwnSpeaker: true)
        liveDocument.receive([TimedText(text: "First live voice", start: 2, end: 4),
            TimedText(text: "Second live voice", start: Double(first.count + silence.count) / 16000 + 2,
                      end: Double(first.count + silence.count) / 16000 + 4)], isFinal: false)
        #expect(liveDocument.paragraphs.allSatisfy { $0.speaker == nil })
        liveDocument.updateSpeakers(live)
        #expect(Set(liveDocument.paragraphs.compactMap(\.speaker)) == Set([1, 2]))
        print("LIVE SPEAKER CHECK: labels replaced before finalization: \(liveDocument.paragraphs.compactMap(\.speaker))")
        let snapshot = try await detector.finish()
        let firstWord = TimedText(text: "first", start: 2, end: Double(first.count) / 16_000 - 1)
        let secondStart = Double(first.count + silence.count) / 16_000
        let secondWord = TimedText(text: "second", start: secondStart + 2,
                                   end: secondStart + Double(second.count) / 16_000 - 1)
        let firstSlot = try #require(SpeakerTranscript.speakerSlot(for: firstWord, intervals: snapshot.intervals))
        let secondSlot = try #require(SpeakerTranscript.speakerSlot(for: secondWord, intervals: snapshot.intervals))
        #expect(firstSlot != secondSlot)
        let repeatStart = Double(first.count + second.count + silence.count * 2) / 16_000
        let repeated = TimedText(text: "repeat", start: repeatStart + 2,
                                 end: repeatStart + Double(first.count) / 16_000 - 1)
        #expect(SpeakerTranscript.speakerSlot(for: repeated, intervals: snapshot.intervals) == firstSlot)

        let transcriber = SpeechTranscriber(locale: Locale(identifier: "en-US"),
            transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
        if let installation = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await installation.downloadAndInstall()
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let format = try #require(await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]))
        let sourceFormat = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let appleConverter = MyWizard.AudioConverter(outputFormat: format)
        let (sequence, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let results = Task { () throws -> [TimedText] in
            var words: [TimedText] = []
            for try await result in transcriber.results {
                for run in result.text.runs {
                    let range = try #require(run.audioTimeRange)
                    words.append(TimedText(text: String(result.text[run.range].characters),
                                           start: range.start.seconds, end: range.end.seconds))
                }
            }
            return words
        }
        try await analyzer.prepareToAnalyze(in: format)
        try await analyzer.start(inputSequence: sequence)
        var sent: Int64 = 0
        for index in stride(from: 0, to: samples.count, by: 8_000) {
            let chunk = Array(samples[index..<min(index + 8_000, samples.count)])
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(chunk.count)))
            buffer.frameLength = buffer.frameCapacity
            chunk.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: chunk.count) }
            let converted = try appleConverter.convert(buffer)
            continuation.yield(AnalyzerInput(buffer: converted,
                bufferStartTime: CMTime(value: sent, timescale: CMTimeScale(format.sampleRate))))
            sent += Int64(converted.frameLength)
        }
        continuation.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        let words = try await results.value
        #expect(!words.isEmpty)
        var document = SpeakerTranscript()
        document.beginSession(detectsSpeakers: true)
        document.receive(words, isFinal: true)
        document.updateSpeakers(snapshot)
        let labels = Set(document.paragraphs.compactMap(\.speaker))
        #expect(labels.count == 2)
        print("Synthetic pipeline result:\n" + document.plainText(names: [:]))
    }

    // Real local model inference, with synthetic speech only. Exercises a fresh
    // detector session so this cannot pass by reusing diarizer slot numbers.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MYWIZARD_VOICE_FIXTURES"] != nil))
    @MainActor func voiceMemoryAcrossIndependentSessions() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["MYWIZARD_VOICE_FIXTURES"])
        let first = try loadSamples(path + "/speaker-one.aiff")
        let second = try loadSamples(path + "/speaker-two.aiff")
        let silence = [Float](repeating: 0, count: 32_000)
        let detector = SpeakerDetection()
        try await detector.prepare()
        let recording = first + first + silence + second + second + silence + first + first + silence
        for index in stride(from: 0, to: recording.count, by: 8_000) {
            _ = try await detector.process(Array(recording[index..<min(index + 8_000, recording.count)]))
        }
        let snapshot = try await detector.finish()
        #expect(snapshot.voiceMemoryWarning == nil)
        let firstSlot = try #require(SpeakerTranscript.speakerSlot(for: TimedText(text: "one", start: 3, end: 5), intervals: snapshot.intervals))
        let secondStart = Double(first.count * 2 + silence.count) / 16_000
        let secondSlot = try #require(SpeakerTranscript.speakerSlot(for: TimedText(text: "two", start: secondStart + 3, end: secondStart + 5), intervals: snapshot.intervals))
        #expect(firstSlot != secondSlot)
        let firstVectors = try #require(snapshot.voiceEmbeddings[firstSlot])
        let secondVectors = try #require(snapshot.voiceEmbeddings[secondSlot])
        try #require(firstVectors.count == 2)
        try #require(secondVectors.count == 2)
        print("VOICE MODEL similarity: same=\(VoiceMemory.similarity(firstVectors[0], firstVectors[1])), other=\(VoiceMemory.similarity(firstVectors[0], secondVectors[0]))")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("voices.json")
        let memory = VoiceMemory(url: url)
        #expect(try memory.remember(firstVectors, name: "First person") != nil)
        #expect(try memory.remember(secondVectors, name: "Second person") != nil)

        try await detector.prepare()
        // Reverse the order: the returning person has a new session/slot.
        let nextRecording = second + second + silence
        for index in stride(from: 0, to: nextRecording.count, by: 8_000) {
            _ = try await detector.process(Array(nextRecording[index..<min(index + 8_000, nextRecording.count)]))
        }
        let next = try await detector.finish()
        let returningSlot = try #require(SpeakerTranscript.speakerSlot(for: TimedText(text: "return", start: 3, end: 5), intervals: next.intervals))
        let returningVectors = try #require(next.voiceEmbeddings[returningSlot])
        #expect(VoiceMemory(url: url).match(returningVectors)?.name == "Second person")
    }

    private func loadSamples(_ path: String) throws -> [Float] {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let converted = try MyWizard.AudioConverter(outputFormat: format).convert(buffer)
        return Array(UnsafeBufferPointer(start: converted.floatChannelData![0], count: Int(converted.frameLength)))
    }
}

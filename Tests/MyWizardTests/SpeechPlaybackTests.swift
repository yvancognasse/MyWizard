import AVFoundation
import Testing
@testable import MyWizard

struct SpeechPlaybackTests {
    @Test func fastSynthesisDoesNotLoseBuffersWhileUIIsBusy() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 22050, channels: 1))
        let pcm = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 256))
        pcm.frameLength = 256
        let collector = SpeechPCMCollector()
        // A short phrase already produces >256 buffers. Simulate receiving an
        // entire long chunk before the main actor gets any time to consume it.
        for _ in 0..<3000 { try collector.append(SpeechPCM(copying: pcm)) }
        #expect(collector.buffers.count == 3000)
    }

    @Test func synthesisMemoryStillHasADurationLimit() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 100, channels: 1))
        let pcm = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 100))
        pcm.frameLength = 100
        let collector = SpeechPCMCollector()
        for _ in 0..<120 { try collector.append(SpeechPCM(copying: pcm)) }
        #expect(throws: ReadingError.self) { try collector.append(SpeechPCM(copying: pcm)) }
        #expect(collector.buffers.count == 120)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MYWIZARD_PLAYBACK_CHECK"] == "1"))
    @MainActor func realFrenchPlaybackFinishesEveryChunkAndSpeaker() async throws {
        let reader = TranscriptReader(playbackVolume: 0)
        let paragraphs = [
            TranscriptParagraph(id: 0, text: String(repeating: "Bonjour, ceci est la première partie de notre traduction. La lecture doit continuer sans interruption. ", count: 5), speaker: 1, hasSpeakerLabel: true),
            TranscriptParagraph(id: 1, text: "Voici maintenant la deuxième voix. Nous sommes arrivés à la fin du texte.", speaker: 2, hasSpeakerLabel: true)
        ]
        reader.read(paragraphs: paragraphs, language: "fr-FR")
        for _ in 0..<1200 {
            if !reader.isReading { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(reader.errorMessage == nil, "\(reader.errorMessage ?? "")")
        #expect(!reader.isReading)
        #expect(reader.completedChunks == paragraphs.reduce(0) { $0 + TranscriptReader.chunks($1.text).count })
        reader.stop()
    }

    @Test @MainActor func chunkingPreservesAllTextAndBoundsMemory() {
        for text in ["", "Bonjour ! Guten Tag. Hello. ", String(repeating: "é👋🏽", count: 500),
                     String(repeating: "Speaker text with spaces. ", count: 100)] {
            let chunks = TranscriptReader.chunks(text)
            #expect(chunks.joined() == text)
            #expect(chunks.allSatisfy { !$0.isEmpty && $0.count <= 400 })
        }
    }

    @Test func pcmCopyOwnsSamplesAndPreservesChannels() throws {
        for interleaved in [false, true] {
            for format in [AVAudioCommonFormat.pcmFormatFloat32, .pcmFormatInt16, .pcmFormatInt32] {
                let description = try #require(AVAudioFormat(commonFormat: format, sampleRate: 24000, channels: 2, interleaved: interleaved))
                let buffer = try #require(AVAudioPCMBuffer(pcmFormat: description, frameCapacity: 20))
                buffer.frameLength = 20
                for channel in 0..<2 {
                    for frame in 0..<20 {
                        let plane = interleaved ? 0 : channel
                        let index = interleaved ? frame * 2 + channel : frame
                        switch format {
                        case .pcmFormatInt16: buffer.int16ChannelData![plane][index] = channel == 0 ? 16384 : -16384
                        case .pcmFormatInt32: buffer.int32ChannelData![plane][index] = channel == 0 ? 1073741824 : -1073741824
                        default: buffer.floatChannelData![plane][index] = channel == 0 ? 0.5 : -0.5
                        }
                    }
                }
                let copy = try SpeechPCM(copying: buffer)
                for audio in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
                    memset(audio.mData!, 0, Int(audio.mDataByteSize))
                }
                let restored = try copy.makeBuffer()
                #expect(restored.frameLength == 20)
                #expect(restored.floatChannelData![0][19] == 0.5)
                #expect(restored.floatChannelData![1][19] == -0.5)
                #expect(copy.duration == 20.0 / 24000)
            }
        }
    }

    @Test @MainActor func cancelledOldSessionCannotStopNewReading() async throws {
        let reader = TranscriptReader()
        let paragraphs = [TranscriptParagraph(id: 0, text: String(repeating: "Hello. ", count: 50), speaker: 1, hasSpeakerLabel: true)]
        reader.read(paragraphs: paragraphs, language: "en-US")
        // Cancel before the rendering task gets to play any sound.
        reader.stop()
        reader.read(paragraphs: paragraphs, language: "en-US")
        await Task.yield()
        #expect(reader.isReading)
        reader.stop()
        await Task.yield()
        #expect(!reader.isReading)
        #expect(reader.errorMessage == nil)
    }
}

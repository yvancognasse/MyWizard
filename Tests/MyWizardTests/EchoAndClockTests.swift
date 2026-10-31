import AVFoundation
import CoreMedia
import Testing
@testable import MyWizard

struct EchoAndClockTests {
    @MainActor @Test func echoCancellationIsOptInAndPreservesSavedChoices() throws {
        let prefs = MemoryPreferences()
        let model = TranscriptionModel(preferences: prefs)
        #expect(!model.cancelsMicrophoneEcho)
        model.cancelsMicrophoneEcho = true
        #expect(TranscriptionModel(preferences: prefs).cancelsMicrophoneEcho)
        model.cancelsMicrophoneEcho = false
        #expect(!TranscriptionModel(preferences: prefs).cancelsMicrophoneEcho)
    }

    @Test func microphoneConversionDoesNotMixInOtherAggregateChannels() throws {
        let layout = try #require(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 5))
        let inputFormat = AVAudioFormat(standardFormatWithSampleRate: 48000, channelLayout: layout)
        let outputFormat = try #require(AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: 4800))
        buffer.frameLength = 4800
        for channel in 0..<5 { buffer.floatChannelData![channel].initialize(repeating: channel == 0 ? 0.1 : 0.9, count: 4800) }
        let converter = MyWizard.AudioConverter(outputFormat: outputFormat, inputChannel: 0)
        let result = try converter.convert(buffer)
        #expect(result.frameLength > 200)
        #expect(abs(result.floatChannelData![0][200] - 0.1) < 0.005)
    }

    @Test func sampleClocksNeverOverlapAcrossLongSessionsAndUnevenChunks() {
        for rate: CMTimeScale in [16_000, 44_100, 48_000] {
            var system = AnalyzerSampleClock(sampleRate: rate)
            var microphone = AnalyzerSampleClock(sampleRate: rate)
            var systemEnd = CMTime.zero
            var microphoneEnd = CMTime.zero
            for i in 0..<100_000 {
                let frames = UInt32([341, 342, 1024, 160, 511][i % 5])
                let systemTime = system.next(frameCount: frames)
                let microphoneTime = microphone.next(frameCount: frames + 1)
                #expect(CMTimeCompare(systemTime, systemEnd) == 0)
                #expect(CMTimeCompare(microphoneTime, microphoneEnd) == 0)
                systemEnd = CMTimeAdd(systemTime, CMTime(value: Int64(frames), timescale: rate))
                microphoneEnd = CMTimeAdd(microphoneTime, CMTime(value: Int64(frames + 1), timescale: rate))
            }
        }
    }

    @Test func copiedMicrophoneBufferDoesNotReuseBorrowedMemory() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
        let borrowed = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024))
        borrowed.frameLength = 1024
        borrowed.floatChannelData![0].initialize(repeating: 0.25, count: 1024)
        let copy = try MyWizard.AudioConverter.copyPCM(borrowed)
        borrowed.floatChannelData![0].update(repeating: 0, count: 1024)
        #expect(copy.floatChannelData![0][500] == 0.25)
    }
}

import AVFoundation
import CoreMedia
import Testing
@testable import MyWizard

struct AudioConverterTests {
    @Test
    func stereoSystemAudioConvertsToMonoWithoutRepeatingBuffers() throws {
        let sourceFormat = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let targetFormat = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let source = try #require(AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: 4800))
        source.frameLength = 4800
        for channel in 0..<2 {
            for frame in 0..<4800 {
                source.floatChannelData![channel][frame] = Float(sin(Double(frame) * 2 * .pi * 440 / 48_000)) * 0.1
            }
        }
        let converter = MyWizard.AudioConverter(outputFormat: targetFormat)
        var frames = 0
        for _ in 0..<10 {
            let result = try converter.convert(source)
            #expect(result.format == targetFormat)
            #expect(MyWizard.AudioConverter.level(result) > 0.1)
            frames += Int(result.frameLength)
        }
        #expect(abs(frames - 16_000) < 100)
    }

    @Test
    func copiedSampleBufferOwnsItsAudio() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let source = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480))
        source.frameLength = 480
        for channel in 0..<2 {
            source.floatChannelData![channel].update(repeating: 0.125, count: 480)
        }
        var description: CMAudioFormatDescription?
        #expect(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: format.streamDescription,
            layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
            extensions: nil, formatDescriptionOut: &description) == noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000), presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        #expect(CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: description, sampleCount: 480,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample) == noErr)
        let buffer = try #require(sample)
        #expect(CMSampleBufferSetDataBufferFromAudioBufferList(buffer, blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0, bufferList: source.audioBufferList) == noErr)
        let copy = try MyWizard.AudioConverter.copyPCM(from: buffer)
        #expect(copy.frameLength == 480)
        #expect(copy.floatChannelData![1][479] == 0.125)
        #expect(MyWizard.AudioConverter.level(copy) == 0.5)
        source.floatChannelData![1][479] = 0
        #expect(copy.floatChannelData![1][479] == 0.125)
    }
}

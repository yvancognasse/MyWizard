import AVFoundation
import CoreMedia

// One instance per capture session, used only on the serial audio queue.
final class AudioConverter {
    private let outputFormat: AVAudioFormat
    private var converter: AVAudioConverter?
    private let inputChannel: Int?

    init(outputFormat: AVAudioFormat, inputChannel: Int? = nil) {
        self.outputFormat = outputFormat
        self.inputChannel = inputChannel
    }

    static func copyPCM(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else {
            throw TranscriptionError.message("Cannot copy microphone audio.")
        }
        copy.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (source, destination) in zip(source, destination) {
            guard let input = source.mData, let output = destination.mData else { continue }
            memcpy(output, input, Int(source.mDataByteSize))
        }
        return copy
    }

    static func copyPCM(from buffer: CMSampleBuffer) throws -> AVAudioPCMBuffer {
        guard let description = buffer.formatDescription,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              let format = AVAudioFormat(streamDescription: asbd),
              let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(buffer.numSamples)) else {
            throw TranscriptionError.message("System audio is not in a valid PCM format.")
        }
        pcm.frameLength = pcm.frameCapacity
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(buffer, at: 0,
            frameCount: Int32(pcm.frameLength), into: pcm.mutableAudioBufferList)
        guard status == noErr else {
            throw TranscriptionError.message("Cannot read system audio (\(status)).")
        }
        return pcm
    }

    func convert(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        if buffer.format == outputFormat { return buffer }
        if converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: outputFormat)
            converter?.primeMethod = .none
            if let inputChannel {
                converter?.channelMap = Array(repeating: NSNumber(value: inputChannel), count: Int(outputFormat.channelCount))
            }
        }
        guard let converter else { throw TranscriptionError.message("Audio conversion is unavailable.") }
        let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * outputFormat.sampleRate / buffer.format.sampleRate))
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            throw TranscriptionError.message("Cannot allocate an audio buffer.")
        }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            guard !supplied else { inputStatus.pointee = .noDataNow; return nil }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        if let error { throw error }
        guard status != .error else { throw TranscriptionError.message("Audio conversion failed.") }
        return output
    }

    static func level(_ pcm: AVAudioPCMBuffer) -> Double {
        guard let channels = pcm.floatChannelData, pcm.frameLength > 0 else { return 0 }
        var peak: Float = 0
        for channel in 0..<Int(pcm.format.channelCount) {
            for frame in 0..<Int(pcm.frameLength) {
                let value = abs(channels[pcm.format.isInterleaved ? 0 : channel][pcm.format.isInterleaved ? frame * Int(pcm.format.channelCount) + channel : frame])
                peak = max(peak, value)
            }
        }
        return min(1, Double(peak) * 4)
    }
}

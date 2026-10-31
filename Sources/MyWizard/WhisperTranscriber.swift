import AVFoundation
import Foundation

struct WhisperConfiguration: Sendable {
    var executable = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("whisper.cpp/build/bin/whisper-cli")
    var model = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("whisper.cpp/models/ggml-large-v3-turbo.bin")
    var chunkSeconds = 600.0

    func validate() throws {
        guard FileManager.default.isExecutableFile(atPath: executable.path),
              FileManager.default.isReadableFile(atPath: model.path) else {
            throw TranscriptionError.message("Whisper large-v3-turbo is unavailable. Install the MyAssistant Whisper engine/model first. The recording has not been changed.")
        }
        guard chunkSeconds.isFinite, chunkSeconds >= 1, chunkSeconds <= 600 else {
            throw TranscriptionError.message("Invalid Whisper chunk duration.")
        }
    }
}

struct WhisperTranscriber: Sendable {
    var configuration = WhisperConfiguration()

    func transcribe(_ audio: URL, language: String, progress: @escaping @Sendable (Double) -> Void) async throws -> [TimedText] {
        try configuration.validate()
        let language = try Self.languageCode(language)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MyWizardWhisper-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = try AVAudioFile(forReading: audio)
        guard source.processingFormat.sampleRate == 16000, source.processingFormat.channelCount == 1 else {
            throw TranscriptionError.message("Whisper requires the prepared 16 kHz mono audio.")
        }
        guard try Self.hasSound(source) else { progress(1); return [] }
        source.framePosition = 0
        let chunkFrames = Int64(configuration.chunkSeconds * 16000)
        var words: [TimedText] = []
        progress(0)
        while source.framePosition < source.length {
            try Task.checkCancellation()
            let start = source.framePosition
            let count = min(chunkFrames, source.length - start)
            let wav = folder.appendingPathComponent("chunk.wav")
            let base = folder.appendingPathComponent("result-\(start)")
            try Self.copyChunk(source, to: wav, frames: count)
            let total = Double(source.length)
            try await ExportChildProcess().run(configuration.executable, arguments: [
                "-t", "8", "-m", configuration.model.path, "-f", wav.path,
                "-l", language, "-ojf", "-pp", "-of", base.path
            ]) { line in
                if let percent = Self.reportedPercent(line) {
                    progress((Double(start) + Double(count) * min(0.99, Double(percent) / 100)) / total)
                }
            }
            try Task.checkCancellation()
            let json = try Data(contentsOf: base.appendingPathExtension("json"))
            words += try WhisperAlignment.decode(json, offset: Double(start) / 16000,
                                                  duration: Double(count) / 16000)
            progress(Double(start + count) / total)
        }
        return words
    }

    static func languageCode(_ locale: String) throws -> String {
        let code = locale.lowercased().split(separator: "-").first.map(String.init) ?? ""
        guard ["en", "fr", "de", "auto"].contains(code) else {
            throw TranscriptionError.message("Unsupported Whisper language: \(locale)")
        }
        return code
    }

    private static func hasSound(_ file: AVAudioFile) throws -> Bool {
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8192)!
        while file.framePosition < file.length {
            try Task.checkCancellation()
            try file.read(into: buffer)
            if let samples = buffer.floatChannelData?[0], (0..<Int(buffer.frameLength)).contains(where: { abs(samples[$0]) > 0.0001 }) {
                return true
            }
        }
        return false
    }

    static func reportedPercent(_ line: String) -> Int? {
        guard let range = line.range(of: "progress ="), let end = line[range.upperBound...].firstIndex(of: "%") else { return nil }
        return Int(line[range.upperBound..<end].trimmingCharacters(in: .whitespaces)).map { max(0, min(100, $0)) }
    }

    private static func copyChunk(_ source: AVAudioFile, to url: URL, frames: Int64) throws {
        let output = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false])
        let buffer = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: 8192)!
        var remaining = frames
        while remaining > 0 {
            try Task.checkCancellation()
            try source.read(into: buffer, frameCount: AVAudioFrameCount(min(8192, remaining)))
            guard buffer.frameLength > 0 else { throw TranscriptionError.message("Incomplete recorded audio.") }
            try output.write(from: buffer)
            remaining -= Int64(buffer.frameLength)
        }
    }
}

enum WhisperAlignment {
    struct Offsets: Decodable { let from: Double; let to: Double }
    struct Token: Decodable { let text: String; let offsets: Offsets? }
    struct Segment: Decodable { let text: String; let offsets: Offsets; let tokens: [Token]? }
    struct Document: Decodable { let transcription: [Segment] }

    static func decode(_ data: Data, offset: Double, duration: Double) throws -> [TimedText] {
        let document = try JSONDecoder().decode(Document.self, from: data)
        let expression = try NSRegularExpression(pattern: #"\s*\S+"#)
        var result: [TimedText] = []
        for segment in document.transcription {
            guard segment.offsets.from.isFinite, segment.offsets.to.isFinite,
                  segment.offsets.to >= segment.offsets.from else {
                throw TranscriptionError.message("Whisper returned invalid timestamps.")
            }
            let start = max(0, min(duration, segment.offsets.from / 1000))
            let end = max(start + 0.001, min(duration, segment.offsets.to / 1000))
            let text = segment.text as NSString
            let matches = expression.matches(in: segment.text, range: NSRange(location: 0, length: text.length))
            let tokens = (segment.tokens ?? []).filter { !$0.text.hasPrefix("[_") }
            let aligned = tokens.map(\.text).joined() == segment.text
            var tokenRanges: [(NSRange, Offsets?)] = []
            var cursor = 0
            for token in tokens {
                let length = (token.text as NSString).length
                tokenRanges.append((NSRange(location: cursor, length: length), token.offsets))
                cursor += length
            }
            var previousStart = start
            for (index, match) in matches.enumerated() {
                var range = match.range
                if index == matches.count - 1 { range.length = text.length - range.location }
                let matching = aligned ? tokenRanges.filter { NSIntersectionRange($0.0, range).length > 0 }.compactMap(\.1) : []
                let valid = matching.filter { $0.from.isFinite && $0.to.isFinite && $0.to > $0.from }
                let fallbackStart = start + (end - start) * Double(index) / Double(matches.count)
                let fallbackEnd = start + (end - start) * Double(index + 1) / Double(matches.count)
                let wordStart = max(previousStart, min(end - 0.001, valid.map { $0.from / 1000 }.min() ?? fallbackStart))
                let wordEnd = max(wordStart + 0.001, min(end, valid.map { $0.to / 1000 }.max() ?? fallbackEnd))
                // Segment text is authoritative. Bad/zero-duration tokens affect
                // alignment only: never lose punctuation or recognized words.
                result.append(TimedText(text: text.substring(with: range), start: offset + wordStart, end: offset + wordEnd))
                previousStart = wordStart
            }
        }
        return result
    }
}

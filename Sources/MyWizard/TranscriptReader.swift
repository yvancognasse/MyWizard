import AVFoundation
import Combine
import Foundation

struct ReadingVoice: Sendable, Equatable {
    let identifier: String
    let name: String
    let language: String
    let quality: Int
}

struct ReadingPart: Sendable, Equatable {
    let text: String
    let voiceIdentifier: String
}

enum ReadingPlan {
    static func make(paragraphs: [TranscriptParagraph], language: String,
                     voices: [ReadingVoice], knownSpeakerIDs: [Int] = []) throws -> [ReadingPart] {
        let content = paragraphs.filter { $0.canReadAloud && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !content.isEmpty else { return [] }
        let prefix = ReadingTranslationPlan.baseLanguage(language)
        let selectedLocale = Locale.Language(identifier: language).maximalIdentifier
        let candidates = voices.filter {
            !ReadingTranslationPlan.requiresTranslation(from: $0.language, to: language)
        }
            .sorted {
                let leftExact = Locale.Language(identifier: $0.language).maximalIdentifier == selectedLocale
                let rightExact = Locale.Language(identifier: $1.language).maximalIdentifier == selectedLocale
                if leftExact != rightExact { return leftExact }
                if $0.quality != $1.quality { return $0.quality > $1.quality }
                // Prefer current natural voices over the classic Mac/Eloquence sets.
                let leftNatural = $0.identifier.hasPrefix("com.apple.voice.") || $0.identifier.hasPrefix("com.apple.ttsbundle.")
                let rightNatural = $1.identifier.hasPrefix("com.apple.voice.") || $1.identifier.hasPrefix("com.apple.ttsbundle.")
                if leftNatural != rightNatural { return leftNatural }
                let leftLegacy = $0.identifier.contains("eloquence")
                let rightLegacy = $1.identifier.contains("eloquence")
                if leftLegacy != rightLegacy { return !leftLegacy }
                return $0.identifier < $1.identifier
            }
        // Enhanced/compact variants of the same named voice do not count as
        // different speakers. Prefer the best available variant of each voice.
        var seenNames: Set<String> = []
        let unique = candidates.filter {
            let name = String($0.name.split(separator: "(").first ?? Substring($0.name))
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return seenNames.insert(name).inserted
        }
        var speakerIDs = knownSpeakerIDs
        for paragraph in content {
            if let speaker = paragraph.speaker, !speakerIDs.contains(speaker) { speakerIDs.append(speaker) }
        }
        guard !unique.isEmpty else {
            let name = Locale(identifier: "en").localizedString(forLanguageCode: prefix) ?? prefix
            throw ReadingError.noVoices(language: name)
        }
        // Reuse the available voices silently when speakers outnumber them.
        // Assign once per speaker, so returning speakers keep the same voice.
        let assigned = Dictionary(uniqueKeysWithValues: speakerIDs.enumerated().map {
            ($0.element, unique[$0.offset % unique.count].identifier)
        })
        let neutralVoice = unique[min(speakerIDs.count, unique.count - 1)].identifier
        return content.map { paragraph in
            // Deliberately use paragraph.text, never the exported transcript or
            // heading(names:). Labels and renamed speaker headings are not spoken.
            ReadingPart(text: paragraph.text.trimmingCharacters(in: .whitespacesAndNewlines),
                        voiceIdentifier: paragraph.speaker.flatMap { assigned[$0] } ?? neutralVoice)
        }
    }
}

enum ReadingError: LocalizedError {
    case noVoices(language: String)
    case unavailableVoice
    case playbackFailed

    var errorDescription: String? {
        switch self {
        case let .noVoices(language):
            return "No \(language) reading voice is available on this Mac. Add a voice in System Settings > Accessibility > Read & Speak, then try again."
        case .unavailableVoice:
            return "A selected reading voice is no longer available. Check the installed voices in System Settings > Accessibility."
        case .playbackFailed:
            return "Reading could not finish. Check the audio output and try again. Listening has not been stopped."
        }
    }
}

@MainActor
final class TranscriptReader: ObservableObject {
    var recording: MeetingRecording?
    @Published private(set) var isReading = false
    @Published var errorMessage: String?
    private var synthesizer: AVSpeechSynthesizer?
    private var audioEngine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var readingTask: Task<Void, Never>?
    private var sessionID: UUID?
    private let playbackVolume: Float
    private(set) var completedChunks = 0
    private(set) var lastPlaybackStartedAt: Date?
    var onFinished: ((Bool) -> Void)?
    private var speakerOrder: [Int] = []

    func resetVoiceAssignments() { speakerOrder = [] }

    init(playbackVolume: Float = 1) { self.playbackVolume = playbackVolume }

    private func trace(_ message: String) {
        if ProcessInfo.processInfo.environment["MYWIZARD_PLAYBACK_CHECK"] == "1" { print("Playback: \(message)") }
    }

    static func availableVoices() -> [ReadingVoice] {
        AVSpeechSynthesisVoice.speechVoices().filter {
            $0.identifier.hasPrefix("com.apple.") &&
            !$0.voiceTraits.contains(.isNoveltyVoice) && !$0.voiceTraits.contains(.isPersonalVoice)
        }.map {
            ReadingVoice(identifier: $0.identifier, name: $0.name,
                         language: $0.language, quality: $0.quality.rawValue)
        }
    }

    func read(paragraphs: [TranscriptParagraph], language: String, preservingVoiceAssignments: Bool = false) {
        let paragraphs = paragraphs.filter(\.canReadAloud)
        stop()
        errorMessage = nil
        completedChunks = 0
        lastPlaybackStartedAt = nil
        guard paragraphs.contains(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { return }
        do {
            if !preservingVoiceAssignments { resetVoiceAssignments() }
            for speaker in paragraphs.compactMap(\.speaker) where !speakerOrder.contains(speaker) { speakerOrder.append(speaker) }
            let parts = try ReadingPlan.make(paragraphs: paragraphs, language: language, voices: Self.availableVoices(), knownSpeakerIDs: speakerOrder)
            guard !parts.isEmpty else { return }
            let id = UUID()
            sessionID = id
            isReading = true
            // One queued batch. The model feeds the next batch after completion.
            readingTask = Task { [weak self] in
                guard let self else { return }
                do {
                    for part in parts {
                        for text in Self.chunks(part.text) {
                            try Task.checkCancellation()
                            self.trace("render start \(part.voiceIdentifier), \(text.count) characters")
                            let buffers = try await self.render(text, voiceID: part.voiceIdentifier)
                            self.trace("render complete: \(buffers.count) buffers, \(buffers.reduce(0) { $0 + $1.duration }) seconds")
                            try Task.checkCancellation()
                            try await self.play(buffers)
                            self.completedChunks += 1
                            self.trace("played chunk \(self.completedChunks)")
                        }
                    }
                    if self.sessionID == id { self.stop(); self.onFinished?(true) }
                } catch {
                    guard self.sessionID == id else { return }
                    self.trace("failed: \(error)")
                    self.stop()
                    if !(error is CancellationError) { self.errorMessage = error.localizedDescription; self.onFinished?(false) }
                }
            }
        } catch {
            errorMessage = error.localizedDescription
            onFinished?(false)
        }
    }

    func stop() {
        // Invalidate callbacks before stopping: a cancelled previous playback
        // must never advance or stop a newer reading session.
        sessionID = nil
        readingTask?.cancel()
        readingTask = nil
        synthesizer?.stopSpeaking(at: .immediate)
        synthesizer = nil
        player?.stop()
        audioEngine?.stop()
        player = nil
        audioEngine = nil
        isReading = false
    }

    // Bound synthesized audio in memory, preserving text and speaker assignment.
    static func chunks(_ text: String, limit: Int = 400) -> [String] {
        precondition(limit > 0)
        var remaining = text[...]
        var result: [String] = []
        // Never recount the entire remaining meeting for every small chunk.
        // Bounded index traversal keeps this linear, including Unicode text.
        while let end = remaining.index(remaining.startIndex, offsetBy: limit, limitedBy: remaining.endIndex),
              end != remaining.endIndex {
            let prefix = remaining[..<end]
            let split = prefix.lastIndex(where: { $0.isWhitespace })
                .map { remaining.index(after: $0) } ?? end
            result.append(String(remaining[..<split]))
            remaining = remaining[split...]
        }
        if !remaining.isEmpty { result.append(String(remaining)) }
        return result
    }

    private func render(_ text: String, voiceID: String) async throws -> [SpeechPCM] {
        guard let voice = AVSpeechSynthesisVoice(identifier: voiceID) else { throw ReadingError.unavailableVoice }
        let synthesizer = AVSpeechSynthesizer()
        self.synthesizer = synthesizer
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.postUtteranceDelay = 0.2
        let (stream, continuation) = AsyncThrowingStream<Void, Error>.makeStream()
        let collector = SpeechPCMCollector()
        let deadline = Task {
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            continuation.finish(throwing: ReadingError.playbackFailed)
        }
        defer { deadline.cancel(); synthesizer.stopSpeaking(at: .immediate) }
        // Explicitly Sendable: Apple may invoke this on its synthesis queue.
        // Copy samples before returning; never send Apple's mutable buffer across actors.
        synthesizer.write(utterance) { @Sendable buffer in
            guard let pcm = buffer as? AVAudioPCMBuffer else {
                continuation.finish(throwing: ReadingError.playbackFailed); return
            }
            guard pcm.frameLength > 0 else { continuation.finish(); return }
            do { try collector.append(SpeechPCM(copying: pcm)) }
            catch { continuation.finish(throwing: error) }
        }
        for try await _ in stream {
            try Task.checkCancellation()
        }
        try Task.checkCancellation()
        let buffers = collector.buffers
        guard !buffers.isEmpty else { throw ReadingError.playbackFailed }
        return buffers
    }

    private func play(_ buffers: [SpeechPCM]) async throws {
        let pcm = try buffers.map { try $0.makeBuffer() }
        guard let format = pcm.first?.format, pcm.allSatisfy({ $0.format == format }) else {
            trace("inconsistent formats: \(pcm.map { $0.format.description })")
            throw ReadingError.playbackFailed
        }
        // Output originates from MyWizard, not the speech service. The system
        // audio tap excludes MyWizard, keeping this voice audible and untranscribed.
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        audioEngine = engine
        self.player = player
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = playbackVolume
        if let recording {
            let outputFormat = engine.mainMixerNode.outputFormat(forBus: 0)
            engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: outputFormat) { @Sendable buffer, time in
                let host = time.isHostTimeValid ? time.hostTime : mach_absolute_time()
                do { try recording.append(buffer, track: .reading, time: AVAudioTime.seconds(forHostTime: host)) }
                catch { recording.fail("Cannot record playback reference: \(error.localizedDescription)") }
            }
        }
        let (completion, continuation) = AsyncStream<Bool>.makeStream()
        for (index, buffer) in pcm.enumerated() {
            if index == pcm.count - 1 {
                player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { @Sendable _ in
                    continuation.yield(true)
                    continuation.finish()
                }
            } else { player.scheduleBuffer(buffer, completionHandler: nil) }
        }
        let duration = buffers.reduce(0) { $0 + $1.duration }
        let deadline = Task {
            do { try await Task.sleep(for: .seconds(duration + 10)) } catch { return }
            continuation.yield(false)
            continuation.finish()
        }
        defer { deadline.cancel(); player.stop(); engine.stop() }
        try engine.start()
        player.play()
        lastPlaybackStartedAt = Date()
        var finished = false
        for await success in completion { finished = success }
        try Task.checkCancellation()
        guard finished else { throw ReadingError.playbackFailed }
    }
}

// Speech synthesis can deliver thousands of tiny buffers faster than the main
// actor can consume them, especially during live capture. Collect on the callback
// side and signal completion once; bound audio duration, not a 256-event queue.
final class SpeechPCMCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [SpeechPCM] = []
    private var duration = 0.0
    var buffers: [SpeechPCM] { lock.withLock { storage } }

    func append(_ buffer: SpeechPCM) throws {
        try lock.withLock {
            guard duration + buffer.duration <= 120, storage.count < 32768 else {
                throw ReadingError.playbackFailed
            }
            duration += buffer.duration
            storage.append(buffer)
        }
    }
}

// Value-only PCM representation for safe transfer from the speech callback.
struct SpeechPCM: Sendable {
    let sampleRate: Double
    let channels: [[Float]]
    var duration: Double { Double(channels.first?.count ?? 0) / sampleRate }

    init(copying pcm: AVAudioPCMBuffer) throws {
        guard [.pcmFormatFloat32, .pcmFormatInt16, .pcmFormatInt32].contains(pcm.format.commonFormat),
              pcm.format.sampleRate > 0 else {
            throw ReadingError.playbackFailed
        }
        sampleRate = pcm.format.sampleRate
        let count = Int(pcm.format.channelCount)
        channels = (0..<count).map { channel in
            (0..<Int(pcm.frameLength)).map { frame in
                let plane = pcm.format.isInterleaved ? 0 : channel
                let index = pcm.format.isInterleaved ? frame * count + channel : frame
                switch pcm.format.commonFormat {
                case .pcmFormatInt16: return Float(pcm.int16ChannelData![plane][index]) / 32768
                case .pcmFormatInt32: return Float(pcm.int32ChannelData![plane][index]) / 2147483648
                default: return pcm.floatChannelData![plane][index]
                }
            }
        }
    }

    func makeBuffer() throws -> AVAudioPCMBuffer {
        guard let frames = channels.first?.count, frames > 0,
              let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: AVAudioChannelCount(channels.count)),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else {
            throw ReadingError.playbackFailed
        }
        buffer.frameLength = buffer.frameCapacity
        for (channel, samples) in channels.enumerated() {
            samples.withUnsafeBufferPointer { buffer.floatChannelData![channel].update(from: $0.baseAddress!, count: frames) }
        }
        return buffer
    }
}

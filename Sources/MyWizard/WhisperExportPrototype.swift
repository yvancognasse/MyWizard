import AVFoundation
import Foundation
import CoreML
@preconcurrency import FluidAudio

struct ExportSpeakerAnchor: Codable, Sendable {
    let number: Int
    let start: Double
    let end: Double
}

struct WhisperExportParagraph: Codable, Sendable {
    let speaker: Int?
    var text: String
}

struct WhisperExportResult: Codable, Sendable {
    let engine: String
    let words: [TimedText]
    let intervals: [SpeakerInterval]
    let paragraphs: [WhisperExportParagraph]
    let elapsedSeconds: Double
    var microphoneSlots: Set<Int> = []

    func text(names: [Int: String] = [:]) -> String {
        paragraphs.map {
            let name = $0.speaker.map { SpeakerIdentity.heading($0, names: names) } ?? "Speaker unknown"
            return name + ":\n" + $0.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }.joined(separator: "\n\n") + "\n"
    }
}

enum WhisperSpeakerAlignment {
    // Keep trusted live labels only when temporal overlap is dominant and
    // unambiguous. Unmatched clusters get fresh IDs, never an inferred name.
    static func identities(intervals: [SpeakerInterval], anchors: [ExportSpeakerAnchor] = [], firstSpeakerNumber: Int = 1,
                           microphoneSlots: Set<Int> = []) -> [Int: Int] {
        var identities: [Int: Int] = [:]
        var used = Set<Int>()
        let anchors = anchors.filter { $0.number >= 1 }
        var next = max(firstSpeakerNumber, max(1, (anchors.map(\.number).max() ?? 0) + 1))
        let groups = Dictionary(grouping: intervals.filter { $0.start.isFinite && $0.end.isFinite && $0.end > $0.start }, by: \.slot)
        for slot in groups.keys.sorted(by: {
            let left = groups[$0]?.map(\.start).min() ?? 0, right = groups[$1]?.map(\.start).min() ?? 0
            return left == right ? $0 < $1 : left < right
        }) {
            if microphoneSlots.contains(slot) { identities[slot] = SpeakerIdentity.microphone; continue }
            let spans = groups[slot] ?? []
            let duration = spans.reduce(0) { $0 + max(0, $1.end - $1.start) }
            var votes: [Int: Double] = [:]
            for span in spans {
                for anchor in anchors where anchor.number > 0 && anchor.start.isFinite && anchor.end.isFinite && anchor.end > anchor.start {
                    votes[anchor.number, default: 0] += max(0, min(span.end, anchor.end) - max(span.start, anchor.start))
                }
            }
            let ranked = votes.sorted { $0.value > $1.value }
            if let best = ranked.first, best.value >= duration * 0.6,
               ranked.count == 1 || ranked[1].value < best.value * 0.5,
               !used.contains(best.key) {
                identities[slot] = best.key; used.insert(best.key)
            } else {
                identities[slot] = next; used.insert(next); next += 1
            }
        }
        return identities
    }

    static func paragraphs(words: [TimedText], intervals: [SpeakerInterval], anchors: [ExportSpeakerAnchor] = [],
                           firstSpeakerNumber: Int = 1, microphoneSlots: Set<Int> = []) -> [WhisperExportParagraph] {
        let identities = identities(intervals: intervals, anchors: anchors, firstSpeakerNumber: firstSpeakerNumber,
                                    microphoneSlots: microphoneSlots)
        // No text duplicate filter here: Whisper's single transcript is the
        // source of truth. Uncertain labels never justify deleting its words.
        var result: [WhisperExportParagraph] = []
        for (word, slot) in zip(words, speakerSlots(words: words, intervals: intervals)) {
            let speaker = word.source == .microphone ? SpeakerIdentity.microphone : slot.flatMap { identities[$0] }
            if !result.isEmpty, result[result.count - 1].speaker == speaker {
                result[result.count - 1].text += word.text
            } else { result.append(WhisperExportParagraph(speaker: speaker, text: word.text)) }
        }
        return result
    }

    static func speakerSlots(words: [TimedText], intervals: [SpeakerInterval]) -> [Int?] {
        let strict = SpeakerTranscript.speakerSlots(for: words, intervals: intervals)
        return zip(words, strict).map { word, slot in
            guard slot == nil, word.end > word.start, word.end - word.start <= 1 else { return slot }
            // Token timestamps can miss a VAD boundary by a few frames. Only
            // recover a nearby single voice; actual overlap stays unknown.
            let midpoint = (word.start + word.end) / 2
            let nearby = Set(intervals.filter {
                $0.end > $0.start && $0.start <= midpoint + 0.15 && $0.end >= midpoint - 0.15
            }.map(\.slot))
            let overlapping = Set(intervals.filter { $0.start < word.end && $0.end > word.start }.map(\.slot))
            return nearby.count == 1 && overlapping.count <= 1 ? nearby.first : nil
        }
    }
}

struct WhisperMeetingExporter: Sendable {
    var whisper = WhisperTranscriber()

    // One authoritative transcript, as in MyAssistant. Separate tracks are
    // retained only as acoustic evidence for microphone attribution, never
    // decoded into a second text stream that can duplicate/interleave words.
    func analyze(meeting: RecordedMeeting, anchors: [ExportSpeakerAnchor] = [], firstSpeakerNumber: Int = 1,
                 progress: @escaping @Sendable (Int) -> Void) async throws -> WhisperExportResult {
        let began = ContinuousClock.now
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("MyWizardWhisperTracks-\(UUID())")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: temporary) }
        try whisper.configuration.validate()
        let prepared = try WhisperAudioPreparation.prepare(meeting, in: temporary) { progress(Int($0 * 12)) }
        let mixed = try await analyze(audio: prepared.audio, language: meeting.manifest.language,
                                       anchors: anchors, firstSpeakerNumber: firstSpeakerNumber) {
            progress(12 + Int(Double($0) * 0.86))
        }
        try Task.checkCancellation()
        let microphoneSlots = prepared.evidence.microphoneSlots(intervals: mixed.intervals)
        let words = zip(mixed.words, WhisperSpeakerAlignment.speakerSlots(words: mixed.words, intervals: mixed.intervals)).map { word, slot in
            TimedText(text: word.text, start: word.start, end: word.end,
                source: slot.map { microphoneSlots.contains($0) } == true ? .microphone : .systemAudio)
        }
        let paragraphs = WhisperSpeakerAlignment.paragraphs(words: words, intervals: mixed.intervals, anchors: anchors,
            firstSpeakerNumber: firstSpeakerNumber, microphoneSlots: microphoneSlots)
        let duration = began.duration(to: .now).components
        let result = WhisperExportResult(engine: "whisper.cpp large-v3-turbo single mixed transcript + FluidAudio speakers",
            words: words, intervals: mixed.intervals, paragraphs: paragraphs,
            elapsedSeconds: Double(duration.seconds) + Double(duration.attoseconds) / 1e18, microphoneSlots: microphoneSlots)
        progress(100)
        return result
    }

    // Audio must already be a single synchronized 16 kHz mono reference. Both
    // engines analyze this exact file, so labels cannot drift between tracks.
    func analyze(audio: URL, language: String, anchors: [ExportSpeakerAnchor] = [], firstSpeakerNumber: Int = 1,
                 progress: @escaping @Sendable (Int) -> Void) async throws -> WhisperExportResult {
        let began = ContinuousClock.now
        let meter = ExportProgress(microphone: false, speakers: true, report: progress)
        meter.update(.models, fraction: 0)
        try Task.checkCancellation()
        try whisper.configuration.validate()
        meter.update(.models, fraction: 1)
        let words = try await whisper.transcribe(audio, language: language) { meter.update(.system, fraction: $0) }
        var intervals: [SpeakerInterval] = []
        if !words.isEmpty {
            func identify(_ units: MLComputeUnits) async throws -> [SpeakerInterval] {
                let diarizer = OfflineDiarizerManager()
                let configuration = MLModelConfiguration()
                configuration.computeUnits = units
                try await diarizer.prepareModels(configuration: configuration)
                try Task.checkCancellation()
                let diarized = try await diarizer.process(audio) { done, total in
                    if total > 0 { meter.update(.speakers, fraction: 0.8 * Double(done) / Double(total)) }
                }
                var slots: [String: Int] = [:]
                return diarized.segments.sorted(by: { $0.startTimeSeconds < $1.startTimeSeconds }).map { segment in
                    if slots[segment.speakerId] == nil { slots[segment.speakerId] = slots.count }
                    return SpeakerInterval(slot: slots[segment.speakerId]!, start: Double(segment.startTimeSeconds), end: Double(segment.endTimeSeconds))
                }
            }
            // GPU is much faster on long meetings. Retry without Metal if it
            // fails; never cancel speaker identification silently or retry a
            // user cancellation. The meter remains monotonic across retries.
            intervals = try await ExportInferenceRecovery.run(primary: { try await identify(.all) },
                fallback: { try await identify(.cpuAndNeuralEngine) })
        }
        try Task.checkCancellation()
        meter.update(.speakers, fraction: 1)
        let paragraphs = WhisperSpeakerAlignment.paragraphs(words: words, intervals: intervals, anchors: anchors,
                                                            firstSpeakerNumber: firstSpeakerNumber)
        let duration = began.duration(to: .now).components
        let result = WhisperExportResult(engine: "whisper.cpp large-v3-turbo + FluidAudio VBx", words: words,
            intervals: intervals, paragraphs: paragraphs, elapsedSeconds: Double(duration.seconds) + Double(duration.attoseconds) / 1e18)
        meter.update(.finalization, fraction: 1)
        meter.finish()
        return result
    }
}

enum ExportInferenceRecovery {
    static func run<T>(primary: () async throws -> T, fallback: () async throws -> T) async throws -> T {
        do { return try await primary() }
        catch is CancellationError { throw CancellationError() }
        catch {
            try Task.checkCancellation()
            return try await fallback()
        }
    }
}

enum WhisperAudioPreparation {
    struct Prepared {
        let audio: URL
        let evidence: MicrophoneSourceEvidence
    }
    // Work on private copies: even microphone-cleaned.caf must not overwrite
    // the derivative of a user's existing session during an A/B comparison.
    static func prepare(_ meeting: RecordedMeeting, in folder: URL, progress: @Sendable (Double) -> Void) throws -> Prepared {
        let copy = folder.appendingPathComponent(meeting.id.uuidString + ".mywizard")
        try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        for track in RecordedTrack.allCases where track != .microphone || meeting.manifest.microphone {
            try FileManager.default.copyItem(at: meeting.audio(track), to: copy.appendingPathComponent(track.rawValue + ".caf"))
        }
        let working = RecordedMeeting(directory: copy, manifest: meeting.manifest)
        let microphone = try meeting.manifest.microphone ? OfflineEchoReducer.reduce(working) { progress($0 * 0.8) }.audio : nil
        let output = folder.appendingPathComponent("reference.wav")
        try mix(system: working.audio(.system), microphone: microphone, output: output) { progress(0.8 + $0 * 0.2) }
        let evidence = try MicrophoneSourceEvidence.read(system: working.audio(.system), microphone: microphone)
        return Prepared(audio: output, evidence: evidence)
    }

    static func mix(system: URL, microphone: URL?, output: URL, progress: @Sendable (Double) -> Void = { _ in }) throws {
        let system = try AVAudioFile(forReading: system)
        let microphone = try microphone.map { try AVAudioFile(forReading: $0) }
        for file in [system, microphone].compactMap({ $0 }) {
            guard file.processingFormat.sampleRate == 16000, file.processingFormat.channelCount == 1 else {
                throw TranscriptionError.message("Mixed export requires synchronized 16 kHz mono tracks.")
            }
        }
        let output = try AVAudioFile(forWriting: output, settings: [AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false])
        let length = max(system.length, microphone?.length ?? 0)
        let mixed = AVAudioPCMBuffer(pcmFormat: MeetingRecording.format, frameCapacity: 8192)!
        let scratch = AVAudioPCMBuffer(pcmFormat: MeetingRecording.format, frameCapacity: 8192)!
        var position: Int64 = 0
        while position < length {
            try Task.checkCancellation()
            let count = AVAudioFrameCount(min(8192, length - position))
            mixed.frameLength = count
            mixed.floatChannelData![0].initialize(repeating: 0, count: Int(count))
            for file in [system, microphone].compactMap({ $0 }) where file.framePosition < file.length {
                try file.read(into: scratch, frameCount: count)
                for i in 0..<Int(scratch.frameLength) {
                    mixed.floatChannelData![0][i] += scratch.floatChannelData![0][i] * (microphone == nil ? 1 : 0.5)
                }
            }
            try output.write(from: mixed)
            position += Int64(count)
            progress(Double(position) / Double(length))
        }
    }
}

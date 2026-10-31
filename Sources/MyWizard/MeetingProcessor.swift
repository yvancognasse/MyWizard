import AVFoundation
import Speech
@preconcurrency import FluidAudio

struct MeetingAnalysis: Codable, Sendable {
    let system: [TimedText]
    let microphone: [TimedText]
    let intervals: [SpeakerInterval]
    var speakerNumbers: [Int: Int]? = nil
    var paragraphs: [WhisperExportParagraph]? = nil
    var liveSystemParagraphs: [TranscriptParagraph]? = nil
}

actor MeetingProcessor {
    private let exporter: WhisperMeetingExporter

    init(exporter: WhisperMeetingExporter = WhisperMeetingExporter()) {
        self.exporter = exporter
    }

    private enum TrackResult: Sendable {
        case system([TimedText], [SpeakerInterval])
        case microphone([TimedText])
    }

    // Normal export: never recognize system audio again or change a known speaker.
    func analyze(_ meeting: RecordedMeeting,
                 progress: @escaping @Sendable (Int) -> Void) async throws -> MeetingAnalysis {
        let clock = ContinuousClock()
        let began = clock.now
        var stageBegan = began
        var timings: [String] = []
        let reportsTiming = ProcessInfo.processInfo.environment["MYWIZARD_EXPORT_TIMING"] == "1"
        func mark(_ stage: String) {
            guard reportsTiming else { return }
            timings.append("\(stage)=\(stageBegan.duration(to: clock.now))")
            stageBegan = clock.now
        }
        defer {
            if reportsTiming {
                print("EXPORT TIMING: \(timings.joined(separator: ", ")), total=\(began.duration(to: clock.now))")
            }
        }
        try Task.checkCancellation()
        let snapshot = try meeting.loadLiveTranscript()
        let key = try ExportCheckpoint.inputKey(meeting)
        let snapshotKey = try ExportCheckpoint.digest(snapshot)
        var checkpoint = ExportCheckpoint.load(meeting, key: key)
        let meter = ExportProgress(microphone: meeting.manifest.microphone, speakers: false, report: progress)
        meter.update(percent: 0)
        try Task.checkCancellation()
        if checkpoint.snapshotKey == snapshotKey,
           checkpoint.assembledRevision == ExportCheckpoint.currentAssemblyRevision,
           let result = checkpoint.analysis {
            try JSONEncoder().encode(result).write(to: meeting.directory.appendingPathComponent("analysis.json"), options: .atomic)
            try Task.checkCancellation()
            meter.finish()
            mark("cached assembly")
            return result
        }
        mark("snapshot/checkpoint")
        var own: [TimedText] = []
        var echoEvidence: EchoReductionResult?
        if let cachedWords = checkpoint.microphone, let cleaned = checkpoint.echo(for: meeting) {
            own = cachedWords
            echoEvidence = cleaned
            meter.update(percent: 94)
        } else if meeting.manifest.microphone, try hasSound(meeting.audio(.microphone)) {
            let cleaned: EchoReductionResult
            if let cached = checkpoint.echo(for: meeting) { cleaned = cached; meter.update(percent: 20) }
            else {
                cleaned = try OfflineEchoReducer.reduce(meeting, collectingActivity: true) { meter.update(percent: Int($0 * 20)) }
                mark("echo reduction")
                checkpoint.cleanedStamp = try ExportCheckpoint.FileStamp.read(cleaned.audio)
                checkpoint.echoOnly = cleaned.echoOnly
                checkpoint.contextFrames = cleaned.contextFrames
                checkpoint.activity = cleaned.systemActivity
                checkpoint.microphone = nil
                checkpoint.analysis = nil
                try checkpoint.save(meeting)
            }
            echoEvidence = cleaned
            try Task.checkCancellation()
            if try hasSound(cleaned.audio) {
                own = try await transcribeSelectedMicrophone(cleaned.audio, language: meeting.manifest.language) {
                    meter.update(percent: 20 + Int(Double($0) * 0.74))
                }.map { TimedText(text: $0.text, start: $0.start, end: $0.end, source: .microphone) }
                mark("microphone recognition")
            }
            checkpoint.microphone = own
            try checkpoint.save(meeting)
        }
        try Task.checkCancellation()
        meter.update(percent: 95)
        var activity = echoEvidence?.systemActivity
        if activity == nil, snapshot.blocks.contains(where: { $0.speaker == nil }) {
            do { activity = try ExportAudioActivity.read(meeting.audio(.system)) }
            catch is CancellationError { throw CancellationError() }
            catch { /* Optional label evidence: preserve unknown labels if unavailable. */ }
        }
        let result = snapshot.addingMicrophone(own, echoEvidence: echoEvidence, systemActivity: activity)
        try JSONEncoder().encode(result).write(to: meeting.directory.appendingPathComponent("analysis.json"), options: .atomic)
        // Input files must still describe the same completed recording.
        guard try ExportCheckpoint.inputKey(meeting) == key else {
            throw TranscriptionError.message("Recording changed during export. Retry preparation; audio has been preserved.")
        }
        checkpoint.snapshotKey = snapshotKey
        checkpoint.assembledRevision = ExportCheckpoint.currentAssemblyRevision
        checkpoint.analysis = result
        try checkpoint.save(meeting)
        mark("assembly/persistence")
        try Task.checkCancellation()
        meter.finish()
        return result
    }

    nonisolated func transcribeSelectedMicrophone(_ url: URL, language: String,
        progress: @escaping @Sendable (Int) -> Void = { _ in }) async throws -> [TimedText] {
        let selection = try MicrophoneSpeechSelection.inspect(url)
        guard MicrophoneSpeechSelection.useful(selection.spans, duration: selection.duration) else {
            return try await transcribe(url, language: language, progress: progress)
        }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("MyWizardSpeech-\(UUID()).caf")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let mapping = try MicrophoneSpeechSelection.pack(url, spans: selection.spans, destination: temporary)
        let words = try await transcribe(temporary, language: language, progress: progress)
        if !words.isEmpty, let restored = MicrophoneSpeechSelection.restore(words, mapping: mapping) { return restored }
        // Safety fallback: no recognized words or a result straddling a cut.
        try Task.checkCancellation()
        return try await transcribe(url, language: language, preparesModel: false, progress: progress)
    }

    // Previous mixed-audio method retained for explicit comparison diagnostics only.
    func analyzeMixedForComparison(_ meeting: RecordedMeeting, anchors: [ExportSpeakerAnchor] = [], firstSpeakerNumber: Int = 1,
                 progress: @escaping @Sendable (Int) -> Void) async throws -> MeetingAnalysis {
        let meter = ExportProgress(microphone: false, speakers: false, report: progress)
        let export = try await exporter.analyze(meeting: meeting, anchors: anchors,
            firstSpeakerNumber: firstSpeakerNumber) { meter.update(percent: $0) }
        try Task.checkCancellation()
        let result = MeetingAnalysis(system: export.words.filter { $0.source == .systemAudio },
            microphone: export.words.filter { $0.source == .microphone }, intervals: export.intervals,
            speakerNumbers: WhisperSpeakerAlignment.identities(intervals: export.intervals, anchors: anchors,
                firstSpeakerNumber: firstSpeakerNumber, microphoneSlots: export.microphoneSlots), paragraphs: export.paragraphs)
        try JSONEncoder().encode(result).write(to: meeting.directory.appendingPathComponent("analysis.json"), options: .atomic)
        try Task.checkCancellation()
        meter.finish()
        return result
    }

    // Legacy full-recording Apple comparison only. Normal exports use the
    // frozen system snapshot and decode only the microphone above.
    func analyzeWithApple(_ meeting: RecordedMeeting, progress: @escaping @Sendable (Int) -> Void) async throws -> MeetingAnalysis {
        let meter = ExportProgress(microphone: meeting.manifest.microphone,
                                   speakers: meeting.manifest.detectSpeakers, report: progress)
        meter.update(.models, fraction: 0)
        try Task.checkCancellation()
        // Install once before starting concurrent analyzers, avoiding duplicate
        // asset requests. No capture devices are opened by either worker.
        try await prepareSpeechModel(language: meeting.manifest.language)
        meter.update(.models, fraction: 1)
        var system: [TimedText] = []
        var own: [TimedText] = []
        var intervals: [SpeakerInterval] = []
        try await withThrowingTaskGroup(of: TrackResult.self) { group in
            group.addTask { [self] in
                let words = try await transcribe(meeting.audio(.system), language: meeting.manifest.language,
                                                preparesModel: false) {
                    meter.update(.system, fraction: Double($0) / 100)
                }
                let speakers = try await identifySpeakers(meeting, hasSpeech: !words.isEmpty, meter: meter)
                return .system(words, speakers)
            }
            if meeting.manifest.microphone {
                group.addTask { [self] in .microphone(try await transcribeMicrophone(meeting, meter: meter)) }
            }
            for try await result in group {
                switch result {
                case .system(let words, let speakers): system = words; intervals = speakers
                case .microphone(let words): own = words
                }
            }
        }
        try Task.checkCancellation()
        let result = MeetingAnalysis(system: system, microphone: own, intervals: intervals)
        try JSONEncoder().encode(result).write(to: meeting.directory.appendingPathComponent("analysis.json"), options: .atomic)
        // The TXT uses the lossless tracks, never a derived MP4. Keep originals
        // for retries until a successful text save, without re-encoding them.
        try Task.checkCancellation()
        meter.update(.finalization, fraction: 1)
        meter.finish()
        return result
    }

    nonisolated private func transcribeMicrophone(_ meeting: RecordedMeeting, meter: ExportProgress) async throws -> [TimedText] {
        let cleaned = try OfflineEchoReducer.reduce(meeting) {
            meter.update(.echo, fraction: $0)
        }
        meter.update(.echo, fraction: 1)
        var own = try await transcribe(cleaned.audio, language: meeting.manifest.language, preparesModel: false, progress: {
            meter.update(.microphone, fraction: Double($0) / 100)
        }).map {
            TimedText(text: $0.text, start: $0.start, end: $0.end, source: .microphone)
        }
        own = cleaned.removingEchoArtifacts(from: own)
        // The reading reference is never a participant. A second textual
        // check catches residual synthesized speech after acoustic reduction.
        if !own.isEmpty, try hasSound(meeting.audio(.reading)) {
            let reading = try await transcribe(meeting.audio(.reading), language: meeting.manifest.language, preparesModel: false) {
                meter.update(.reading, fraction: Double($0) / 100)
            }
            own = MicrophoneDuplicateFilter.microphone(own, excludingEchoOf: reading)
        }
        meter.update(.reading, fraction: 1)
        return own
    }

    nonisolated private func identifySpeakers(_ meeting: RecordedMeeting, hasSpeech: Bool, meter: ExportProgress) async throws -> [SpeakerInterval] {
        var intervals: [SpeakerInterval] = []
        if meeting.manifest.detectSpeakers && hasSpeech {
            try Task.checkCancellation()
            let diarizer = OfflineDiarizerManager()
            try await diarizer.prepareModels()
            try Task.checkCancellation()
            meter.update(.speakers, fraction: 0.05)
            let result = try await diarizer.process(meeting.audio(.system)) { done, total in
                // FluidAudio reports segmentation chunks, not completion of
                // embeddings/clustering. Reserve the final 20% until return.
                if total > 0 { meter.update(.speakers, fraction: 0.05 + 0.75 * Double(done) / Double(total)) }
            }
            var slots: [String: Int] = [:]
            for segment in result.segments.sorted(by: { $0.startTimeSeconds < $1.startTimeSeconds }) {
                if slots[segment.speakerId] == nil { slots[segment.speakerId] = slots.count }
                intervals.append(SpeakerInterval(slot: slots[segment.speakerId]!,
                    start: Double(segment.startTimeSeconds), end: Double(segment.endTimeSeconds)))
            }
        }
        meter.update(.speakers, fraction: 1)
        return intervals
    }

    nonisolated private func prepareSpeechModel(language: String) async throws {
        let module = SpeechTranscriber(locale: Locale(identifier: language), transcriptionOptions: [],
            reportingOptions: [], attributeOptions: [.audioTimeRange])
        guard let lease = try await SpeechLocaleReservations.shared.acquire(Locale(identifier: language)) else { return }
        do {
            if await AssetInventory.status(forModules: [module]) != .installed,
               let install = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                try await install.downloadAndInstall()
            }
            try Task.checkCancellation()
            await SpeechLocaleReservations.shared.end(lease)
        } catch {
            await SpeechLocaleReservations.shared.end(lease)
            throw error
        }
    }

    nonisolated func transcribe(_ url: URL, language: String, preparesModel: Bool = true,
                    reportsConfidence: Bool = false,
                    progress: @escaping @Sendable (Int) -> Void = { _ in }) async throws -> [TimedText] {
        let file = try AVAudioFile(forReading: url)
        let meter = TranscriptionProgress(duration: Double(file.length) / file.processingFormat.sampleRate,
                                          report: progress)
        meter.update(processedSeconds: 0)
        guard try hasSound(url) else {
            meter.finish()
            return []
        }
        let module = SpeechTranscriber(locale: Locale(identifier: language), transcriptionOptions: [],
            reportingOptions: [], attributeOptions: reportsConfidence ? [.audioTimeRange, .transcriptionConfidence] : [.audioTimeRange])
        guard let lease = try await SpeechLocaleReservations.shared.acquire(Locale(identifier: language)) else { return [] }
        do {
            if preparesModel { try await prepareSpeechModel(language: language) }
            else if await AssetInventory.status(forModules: [module]) != .installed {
                try await prepareSpeechModel(language: language)
            }
            let analyzer = SpeechAnalyzer(modules: [module])
            // The analyzer's processed audio range advances even before finalized
            // words arrive. Do not use file.framePosition: read-ahead is not analysis.
            await analyzer.setVolatileRangeChangedHandler { range, _, _ in
                meter.update(processedSeconds: range.end.seconds)
            }
            let results = Task { () throws -> [TimedText] in
                var words: [TimedText] = []
                for try await result in module.results {
                    try Task.checkCancellation()
                    for run in result.text.runs {
                        let range = run.audioTimeRange ?? result.range
                        if reportsConfidence {
                            print("MIC CONFIDENCE \(range.start.seconds): \(run.transcriptionConfidence ?? -1) \(String(result.text[run.range].characters))")
                        }
                        words.append(TimedText(text: String(result.text[run.range].characters),
                            start: range.start.seconds, end: range.end.seconds))
                    }
                    meter.update(processedSeconds: result.range.end.seconds)
                }
                return words
            }
            do {
                return try await withTaskCancellationHandler {
                    try Task.checkCancellation()
                    _ = try await analyzer.analyzeSequence(from: file)
                    try await analyzer.finalizeAndFinishThroughEndOfInput()
                    let words = try await results.value
                    try Task.checkCancellation()
                    meter.finish()
                    await SpeechLocaleReservations.shared.end(lease)
                    return words
                } onCancel: {
                    results.cancel()
                    Task { await analyzer.cancelAndFinishNow() }
                }
            } catch {
                results.cancel()
                await analyzer.cancelAndFinishNow()
                throw error
            }
        } catch {
            await SpeechLocaleReservations.shared.end(lease)
            throw error
        }
    }

    nonisolated private func hasSound(_ url: URL) throws -> Bool {
        let file = try AVAudioFile(forReading: url)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8192)!
        while file.framePosition < file.length {
            try Task.checkCancellation()
            try file.read(into: buffer)
            if let data = buffer.floatChannelData?[0] {
                for i in 0..<Int(buffer.frameLength) where abs(data[i]) > 0.0001 { return true }
            }
        }
        return false
    }
}

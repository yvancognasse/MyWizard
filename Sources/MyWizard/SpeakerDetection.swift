import Foundation
@preconcurrency import FluidAudio

struct SpeakerInterval: Sendable, Equatable, Codable {
    let slot: Int
    let start: Double
    let end: Double
}

struct SpeakerSnapshot: Sendable {
    let intervals: [SpeakerInterval]
    let processedThrough: Double
    var voiceEmbeddings: [Int: [[Float]]] = [:]
    var voiceMemoryWarning: String? = nil
}

// All model state and inference stay on this actor, never on the audio callback
// or the main actor. Only copied Float samples and value-type results cross actors.
actor SpeakerDetection {
    private var voiceExtractor: EmbeddingExtractor?
    private var voiceSamples = VoiceSampleBuffer()
    private var voiceMemoryWarning: String?
    private var diarizer: SortformerDiarizer?
    private var preparation: Task<Void, Error>?

    func preload() async throws {
        if diarizer != nil { return }
        if let preparation { try await preparation.value; return }
        let task = Task { try await loadModel() }
        preparation = task
        defer { preparation = nil }
        try await task.value
    }

    func prepare() async throws {
        try await preload()
        try Task.checkCancellation()
        // Reuse the loaded weights, never a previous meeting's speaker state.
        diarizer?.reset()
        voiceSamples = VoiceSampleBuffer()
        voiceMemoryWarning = nil
        if voiceExtractor == nil {
            do {
                let models = try await DiarizerModels.load()
                voiceExtractor = EmbeddingExtractor(embeddingModel: models.embeddingModel)
            } catch {
                voiceMemoryWarning = "Voice memory is unavailable: \(error.localizedDescription). Speaker detection continues without remembering voices."
            }
        }
    }

    private func loadModel() async throws {
        let config = SortformerConfig.balancedV2_1
        let models = try await SortformerModels.loadFromHuggingFace(config: config)
        try Task.checkCancellation()
        var timelineConfig = DiarizerTimelineConfig.sortformerDefault
        timelineConfig.maxStoredFrames = 1_500
        let diarizer = SortformerDiarizer(config: config, timelineConfig: timelineConfig)
        diarizer.initialize(models: models)
        self.diarizer = diarizer
    }

    func process(_ samples: [Float]) throws -> SpeakerSnapshot? {
        try Task.checkCancellation()
        guard let diarizer else { throw TranscriptionError.message("Speaker detection is not ready.") }
        voiceSamples.append(samples)
        guard try diarizer.process(samples: samples, sourceSampleRate: 16_000) != nil else { return nil }
        return voiceSnapshot(diarizer)
    }

    func finish() throws -> SpeakerSnapshot {
        try Task.checkCancellation()
        guard let diarizer else { throw TranscriptionError.message("Speaker detection is not ready.") }
        _ = try diarizer.finalizeSession()
        return voiceSnapshot(diarizer)
    }

    private func voiceSnapshot(_ diarizer: SortformerDiarizer) -> SpeakerSnapshot {
        var result = snapshot(diarizer)
        if let voiceExtractor, voiceMemoryWarning == nil {
            do {
                try voiceSamples.extract(from: result) { audio in
                    try voiceExtractor.getEmbeddings(audio: audio, masks: [Array(repeating: Float(1), count: 589)]).first
                }
            } catch {
                voiceMemoryWarning = "Voice memory stopped: \(error.localizedDescription). Speaker detection continues."
            }
        }
        result.voiceEmbeddings = voiceSamples.embeddings
        result.voiceMemoryWarning = voiceMemoryWarning
        return result
    }

    private func snapshot(_ diarizer: SortformerDiarizer) -> SpeakerSnapshot {
        let timeline = diarizer.timeline
        var intervals: [SpeakerInterval] = []
        for (slot, speaker) in timeline.speakers {
            let segments = speaker.finalizedSegments + speaker.tentativeSegments
            for segment in segments {
                intervals.append(SpeakerInterval(slot: slot, start: Double(segment.startTime), end: Double(segment.endTime)))
            }
        }
        intervals.sort { $0.start == $1.start ? $0.slot < $1.slot : $0.start < $1.start }
        return SpeakerSnapshot(intervals: intervals, processedThrough: Double(timeline.finalizedDuration))
    }
}

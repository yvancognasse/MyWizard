import Foundation

struct RememberedVoice: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var name: String
    let embedding: [Float]
}

// A different model requires a new file/schema: vectors from different models
// must never be compared. No recording or transcript is stored in this file.
@MainActor
final class VoiceMemory {
    private struct Archive: Codable {
        let version: Int
        let model: String
        let voices: [RememberedVoice]
    }
    static let model = "fluidaudio-wespeaker-256-v1"
    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MyWizard/voices-v1.json")
    }
    private let url: URL
    private(set) var voices: [RememberedVoice] = []
    private(set) var loadError: String?

    init(url: URL = VoiceMemory.defaultURL) {
        self.url = url
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let archive = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: url))
            guard archive.version == 1, archive.model == Self.model,
                  Set(archive.voices.map(\.id)).count == archive.voices.count,
                  archive.voices.allSatisfy({ Self.normalized($0.embedding) != nil }) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            voices = archive.voices
        } catch { loadError = "Saved voices could not be loaded. Forget saved voices in Preferences to reset them." }
    }

    nonisolated static func normalized(_ vector: [Float]) -> [Float]? {
        guard vector.count == 256, vector.allSatisfy(\.isFinite) else { return nil }
        let norm = sqrt(vector.reduce(Float(0)) { $0 + $1 * $1 })
        guard norm.isFinite, norm > 0.000001 else { return nil }
        return vector.map { $0 / norm }
    }

    nonisolated static func similarity(_ a: [Float], _ b: [Float]) -> Float {
        guard let a = normalized(a), let b = normalized(b) else { return -1 }
        return zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
    }

    // Both independent excerpts must agree. A close runner-up keeps the speaker
    // anonymous, and automatic matches never train/update existing templates.
    func match(_ samples: [[Float]], excluding: Set<UUID> = []) -> RememberedVoice? {
        guard samples.count >= 2, samples.allSatisfy({ Self.normalized($0) != nil }) else { return nil }
        let ranked = voices.map { voice in
            (voice, samples.map { Self.similarity($0, voice.embedding) }.min() ?? -1)
        }.sorted { $0.1 > $1.1 }
        guard let best = ranked.first, !excluding.contains(best.0.id), best.1 >= 0.78,
              ranked.count == 1 || best.1 - ranked[1].1 >= 0.08 else { return nil }
        return best.0
    }

    func hasPlausibleMatch(_ samples: [[Float]]) -> Bool {
        voices.contains { voice in samples.contains { Self.similarity($0, voice.embedding) >= 0.65 } }
    }

    func remember(_ samples: [[Float]], name: String = "") throws -> RememberedVoice? {
        guard loadError == nil else { return nil } // Never overwrite an unreadable archive.
        guard samples.count >= 2, let first = Self.normalized(samples[0]),
              let second = Self.normalized(samples[1]), Self.similarity(first, second) >= 0.78,
              let embedding = Self.normalized(zip(first, second).map(+)) else { return nil }
        let voice = RememberedVoice(id: UUID(), name: name.trimmingCharacters(in: .whitespacesAndNewlines), embedding: embedding)
        try commit(voices + [voice])
        return voice
    }

    func rename(_ id: UUID, to name: String) throws {
        var updated = voices
        guard let index = updated.firstIndex(where: { $0.id == id }) else { return }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard updated[index].name != name else { return }
        updated[index].name = name
        try commit(updated)
    }

    func forget(_ id: UUID) throws {
        try commit(voices.filter { $0.id != id })
    }

    func forgetAll() throws {
        try commit([])
        loadError = nil
    }

    private func commit(_ updated: [RememberedVoice]) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(Archive(version: 1, model: Self.model, voices: updated))
        // Atomic replacement also keeps a failed write from changing in-memory state.
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        voices = updated
    }
}

// Only finalized, non-overlapping speech is used. Retain at most one minute of
// 16 kHz audio in RAM; independent excerpts never share samples.
struct VoiceSampleBuffer {
    private var audio: [Float] = []
    private var offset = 0
    private var usedThrough: [Int: Int] = [:]
    private(set) var embeddings: [Int: [[Float]]] = [:]
    private var lastAttempt = 0

    mutating func append(_ samples: [Float]) {
        audio.append(contentsOf: samples)
        let excess = max(0, audio.count - 960_000)
        if excess > 0 { audio.removeFirst(excess); offset += excess }
    }

    mutating func extract(from snapshot: SpeakerSnapshot, using extract: ([Float]) throws -> [Float]?) rethrows {
        let end = offset + audio.count
        guard end - lastAttempt >= 32_000 else { return }
        lastAttempt = end
        for interval in snapshot.intervals where (embeddings[interval.slot]?.count ?? 0) < 2 {
            let start = max(offset, usedThrough[interval.slot] ?? 0, Int((interval.start + 0.25) * 16_000))
            let stop = min(end, Int((min(interval.end, snapshot.processedThrough) - 0.25) * 16_000))
            guard stop - start >= 96_000 else { continue }
            let selectedEnd = start + min(128_000, stop - start)
            let overlaps = snapshot.intervals.contains {
                $0.slot != interval.slot && $0.start < Double(selectedEnd) / 16_000 && $0.end > Double(start) / 16_000
            }
            guard !overlaps else { continue }
            usedThrough[interval.slot] = selectedEnd
            let samples = Array(audio[(start - offset)..<(selectedEnd - offset)])
            guard let vector = try extract(samples), let normalized = VoiceMemory.normalized(vector) else { continue }
            embeddings[interval.slot, default: []].append(normalized)
        }
    }
}

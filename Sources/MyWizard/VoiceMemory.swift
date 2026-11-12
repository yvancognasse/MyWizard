import Foundation

struct RememberedVoice: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var name: String
    let embedding: [Float]
    var additionalEmbeddings: [[Float]]? = nil

    var templates: [[Float]] { [embedding] + (additionalEmbeddings ?? []) }
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
    private let url: URL?
    private(set) var voices: [RememberedVoice] = []
    private(set) var loadError: String?

    init(url: URL? = VoiceMemory.defaultURL) {
        self.url = url
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let archive = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: url))
            guard archive.version == 1, archive.model == Self.model,
                  Set(archive.voices.map(\.id)).count == archive.voices.count,
                  archive.voices.allSatisfy({ $0.templates.allSatisfy { Self.normalized($0) != nil } }) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let cleaned = Self.consolidated(archive.voices)
            if cleaned != archive.voices { try commit(cleaned) }
            else { voices = cleaned }
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

    nonisolated static func displayName(_ name: String) -> String {
        name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    nonisolated static func nameKey(_ name: String) -> String {
        displayName(name).folding(options: [.caseInsensitive, .diacriticInsensitive],
                                 locale: Locale(identifier: "en_US_POSIX"))
    }

    private nonisolated static func isNamed(_ name: String) -> Bool {
        !nameKey(name).isEmpty && nameKey(name) != "unnamed voice"
    }

    // A person can have several confirmed acoustic templates (different calls or
    // devices). These compete as ONE identity, never as duplicate runner-ups.
    // Two independent, mutually consistent excerpts must each beat every other
    // name. A bad early excerpt does not veto later evidence; conflicting pairs do.
    func match(_ samples: [[Float]], excluding: Set<UUID> = []) -> RememberedVoice? {
        guard samples.count >= 2, samples.allSatisfy({ Self.normalized($0) != nil }) else { return nil }
        let scores = voices.map { voice in
            samples.map { sample in voice.templates.map { Self.similarity(sample, $0) }.max() ?? -1 }
        }
        var candidates: [RememberedVoice] = []
        for (index, voice) in voices.enumerated() {
            let supported = samples.indices.filter { sample in
                let runnerUp = scores.indices.filter { $0 != index }.map { scores[$0][sample] }.max() ?? -1
                return scores[index][sample] >= 0.78 && scores[index][sample] - runnerUp >= 0.08
            }
            let agrees = supported.enumerated().contains { offset, first in
                supported.dropFirst(offset + 1).contains { second in
                    Self.similarity(samples[first], samples[second]) >= 0.78
                }
            }
            if agrees { candidates.append(voice) }
        }
        guard candidates.count == 1, let voice = candidates.first, !excluding.contains(voice.id) else { return nil }
        return voice
    }

    // Only a user-supplied name enrolls or updates a profile. Automatic guesses
    // must never train themselves. Keep distinct confirmed templates per name.
    func remember(_ samples: [[Float]], name: String) throws -> RememberedVoice? {
        guard loadError == nil, Self.isNamed(name) else { return nil }
        let valid = samples.compactMap(Self.normalized)
        var coherent: [Int] = []
        for seed in valid.indices {
            var group = [seed]
            for index in valid.indices where index != seed {
                if group.allSatisfy({ Self.similarity(valid[index], valid[$0]) >= 0.78 }) { group.append(index) }
            }
            if group.count > coherent.count { coherent = group }
        }
        guard coherent.count >= 2 else { return nil }
        // A second coherent voice in the same slot is conflicting evidence,
        // not another device variant to learn. Wait for fresh, cleaner excerpts.
        let remainder = valid.indices.filter { !coherent.contains($0) }
        guard !remainder.enumerated().contains(where: { offset, first in
            remainder.dropFirst(offset + 1).contains { Self.similarity(valid[first], valid[$0]) >= 0.78 }
        }) else { return nil }
        let name = Self.displayName(name)
        let existing = voices.first { Self.nameKey($0.name) == Self.nameKey(name) }
        let templates = Self.distinctTemplates((existing?.templates ?? []) + coherent.map { valid[$0] })
        let voice = RememberedVoice(id: existing?.id ?? UUID(), name: existing?.name ?? name,
            embedding: templates[0], additionalEmbeddings: Array(templates.dropFirst()))
        try commit(voices.filter { $0.id != voice.id } + [voice])
        return voices.first { $0.id == voice.id }
    }

    func rename(_ id: UUID, to name: String) throws {
        var updated = voices
        guard let index = updated.firstIndex(where: { $0.id == id }) else { return }
        updated[index].name = Self.displayName(name)
        try commit(updated)
    }

    private nonisolated static func distinctTemplates(_ samples: [[Float]]) -> [[Float]] {
        var result: [[Float]] = []
        for sample in samples {
            guard let normalized = normalized(sample),
                  !result.contains(where: { similarity($0, normalized) >= 0.995 }) else { continue }
            result.append(normalized)
        }
        // Bounded local storage. Retain the original plus recent confirmed variants.
        return result.count > 12 ? [result[0]] + Array(result.suffix(11)) : result
    }

    private nonisolated static func consolidated(_ input: [RememberedVoice]) -> [RememberedVoice] {
        var result: [RememberedVoice] = []
        for voice in input where isNamed(voice.name) {
            let name = displayName(voice.name)
            let index = result.firstIndex { nameKey($0.name) == nameKey(name) }
            let templates = distinctTemplates((index.map { result[$0].templates } ?? []) + voice.templates)
            guard let first = templates.first else { continue }
            let merged = RememberedVoice(id: index.map { result[$0].id } ?? voice.id,
                name: index.map { result[$0].name } ?? name,
                embedding: first, additionalEmbeddings: Array(templates.dropFirst()))
            if let index { result[index] = merged } else { result.append(merged) }
        }
        return result.sorted { nameKey($0.name) < nameKey($1.name) }
    }

    func forget(_ id: UUID) throws {
        try commit(voices.filter { $0.id != id })
    }

    func forgetAll() throws {
        try commit([])
        loadError = nil
    }

    private func commit(_ updated: [RememberedVoice]) throws {
        let updated = Self.consolidated(updated)
        guard let url else { voices = updated; return } // Isolated tests/diagnostics stay in memory.
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

// Only finalized, non-overlapping speech is used. Keep the last minute of
// 16 kHz source audio plus at most four pending seconds per speaker in RAM.
// Independent excerpts never share samples.
struct VoiceSampleBuffer {
    private var audio: [Float] = []
    private var offset = 0
    private var usedThrough: [Int: Int] = [:]
    private var pending: [Int: [Float]] = [:]
    private var lastEmbeddingEnd: [Int: Int] = [:]
    private(set) var embeddings: [Int: [[Float]]] = [:]
    private var lastAttempt = 0
    private static let excerptLength = 64_000 // Four seconds, possibly from several clean turns.

    mutating func append(_ samples: [Float]) {
        audio.append(contentsOf: samples)
        let excess = max(0, audio.count - 960_000)
        if excess > 0 { audio.removeFirst(excess); offset += excess }
    }

    mutating func extract(from snapshot: SpeakerSnapshot, force: Bool = false, using extract: ([Float]) throws -> [Float]?) rethrows {
        let end = offset + audio.count
        guard force || end - lastAttempt >= 32_000 else { return }
        lastAttempt = end
        var attempted: Set<Int> = []
        for interval in snapshot.intervals.sorted(by: { $0.start < $1.start }) {
            let slot = interval.slot
            guard !attempted.contains(slot) else { continue }
            // Continue trying with a rolling window of fresh evidence, at a
            // reduced rate after six excerpts instead of freezing the first two.
            if (embeddings[slot]?.count ?? 0) >= 6,
               end - (lastEmbeddingEnd[slot] ?? 0) < 240_000 { continue }
            let start = max(offset, usedThrough[slot] ?? 0, Int((interval.start + 0.25) * 16_000))
            let stop = min(end, Int((min(interval.end, snapshot.processedThrough) - 0.25) * 16_000))
            guard stop > start else { continue }
            var ranges = [start..<stop]
            for other in snapshot.intervals where other.slot != slot && other.start < Double(stop) / 16_000 && other.end > Double(start) / 16_000 {
                let blockedStart = Int((other.start - 0.15) * 16_000)
                let blockedEnd = Int((other.end + 0.15) * 16_000)
                ranges = ranges.flatMap { range -> [Range<Int>] in
                    guard blockedStart < range.upperBound, blockedEnd > range.lowerBound else { return [range] }
                    var safe: [Range<Int>] = []
                    if range.lowerBound < blockedStart { safe.append(range.lowerBound..<blockedStart) }
                    if blockedEnd < range.upperBound { safe.append(blockedEnd..<range.upperBound) }
                    return safe
                }
            }
            for range in ranges where range.count >= 16_000 {
                let take = min(Self.excerptLength - (pending[slot]?.count ?? 0), range.count)
                let selectedEnd = range.lowerBound + take
                let piece = Array(audio[(range.lowerBound - offset)..<(selectedEnd - offset)])
                usedThrough[slot] = selectedEnd
                // Do not enroll silence, including zero-filled capture gaps.
                let energy = piece.reduce(Float(0)) { $0 + $1 * $1 } / Float(piece.count)
                guard energy.isFinite, energy > 0.00000001 else { continue }
                pending[slot, default: []].append(contentsOf: piece)
                guard (pending[slot]?.count ?? 0) >= Self.excerptLength else { continue }
                let excerpt = pending.removeValue(forKey: slot) ?? []
                attempted.insert(slot)
                lastEmbeddingEnd[slot] = end
                if let vector = try extract(excerpt), let normalized = VoiceMemory.normalized(vector) {
                    embeddings[slot, default: []].append(normalized)
                    embeddings[slot] = Array((embeddings[slot] ?? []).suffix(6))
                }
                break
            }
        }
    }
}

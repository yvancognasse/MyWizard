import Foundation
import Testing
@testable import MyWizard

@MainActor
struct VoiceMemoryTests {
    private func vector(_ index: Int) -> [Float] {
        var result = [Float](repeating: 0, count: 256)
        result[index] = 1
        return result
    }

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("voices.json")
    }

    @Test func diagnosticModelsHaveIsolatedVoiceMemoryByDefault() {
        let model = TranscriptionModel(preferences: MemoryPreferences())
        #expect(model.rememberedVoices.isEmpty)
        model.receiveSpeakerSnapshot(snapshot([vector(0), vector(0)]))
        model.speakerNames[1] = "Test person"
        #expect(model.rememberedVoices.count == 1)
        #expect(TranscriptionModel(preferences: MemoryPreferences()).rememberedVoices.isEmpty)
    }

    @Test func onlyNamedVoicesAreSavedAndNamesSurviveLaunches() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let memory = VoiceMemory(url: url)
        let samples = [vector(0), vector(0)]
        #expect(try memory.remember(samples, name: "  ") == nil)
        #expect(try memory.remember(samples, name: "Unnamed voice") == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        let voice = try #require(try memory.remember(samples, name: "  Justin   Smith  "))
        #expect(voice.name == "Justin Smith")
        let reloaded = VoiceMemory(url: url)
        #expect(reloaded.match(samples)?.name == "Justin Smith")
        #expect(reloaded.match([vector(1), vector(1)]) == nil)
        #expect(reloaded.match([vector(0)]) == nil)
        #expect(reloaded.match([vector(0), vector(1)]) == nil)
        #expect(reloaded.match(samples, excluding: [voice.id]) == nil)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        try reloaded.forget(voice.id)
        #expect(VoiceMemory(url: url).voices.isEmpty)
        _ = try reloaded.remember(samples, name: "Again")
        try reloaded.forgetAll()
        #expect(VoiceMemory(url: url).voices.isEmpty)
    }

    @Test func legacyDuplicatesMergeWithoutCompetingAndAnonymousProfilesAreDeleted() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let id = UUID()
        let legacy: [[String: Any]] = [
            ["id": id.uuidString, "name": "  Jérôme  Smith ", "embedding": vector(0)],
            ["id": UUID().uuidString, "name": "JEROME\nSMITH", "embedding": vector(1)],
            ["id": UUID().uuidString, "name": "Other", "embedding": vector(2)],
            ["id": UUID().uuidString, "name": "", "embedding": vector(0)],
            ["id": UUID().uuidString, "name": "Unnamed voice", "embedding": vector(0)]
        ]
        try JSONSerialization.data(withJSONObject: ["version": 1, "model": VoiceMemory.model, "voices": legacy]).write(to: url)
        let memory = VoiceMemory(url: url)
        #expect(memory.loadError == nil)
        #expect(memory.voices.count == 2)
        #expect(memory.match([vector(0), vector(0)])?.id == id)
        #expect(memory.match([vector(1), vector(1)])?.id == id)
        let reloaded = VoiceMemory(url: url)
        #expect(reloaded.voices.count == 2)
        #expect(reloaded.voices.first { $0.id == id }?.templates.count == 2)
        #expect(reloaded.match([vector(1), vector(1)])?.name == "Jérôme Smith")
        // Explicit confirmation on another call adds a variant to the same name.
        let saved = try #require(try reloaded.remember([vector(3), vector(3)], name: "jerome smith"))
        #expect(saved.id == id)
        #expect(reloaded.voices.count == 2)
        #expect(reloaded.match([vector(3), vector(3)])?.id == id)
        // Renaming into an existing name also merges profiles atomically.
        let other = try #require(reloaded.voices.first { $0.name == "Other" })
        try reloaded.rename(other.id, to: "Jérôme Smith")
        #expect(reloaded.voices.count == 1)
        #expect(VoiceMemory(url: url).match([vector(2), vector(2)])?.name == "Jérôme Smith")
    }

    @Test func ambiguousInvalidAndInconsistentVoicesNeverReceiveAName() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let memory = VoiceMemory(url: url)
        _ = try memory.remember([vector(0), vector(0)], name: "One")
        _ = try memory.remember([vector(0), vector(0)], name: "Similar")
        #expect(memory.match([vector(0), vector(0)]) == nil)
        #expect(try memory.remember([vector(0), vector(1)], name: "Noisy") == nil)
        #expect(try memory.remember([vector(0), vector(0), vector(1), vector(1)], name: "Mixed") == nil)
        #expect(VoiceMemory.normalized([Float](repeating: 0, count: 256)) == nil)
        #expect(VoiceMemory.normalized([Float](repeating: .nan, count: 256)) == nil)
        #expect(VoiceMemory.normalized([1, 2]) == nil)
    }

    @Test func freshEvidenceCanRecoverFromBadEarlyExcerptsButConflictingPairsStayUnknown() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let memory = VoiceMemory(url: url)
        _ = try memory.remember([vector(0), vector(0)], name: "One")
        _ = try memory.remember([vector(1), vector(1)], name: "Two")
        #expect(memory.match([vector(2), vector(0)]) == nil)
        #expect(memory.match([vector(2), vector(0), vector(0)])?.name == "One")
        #expect(memory.match([vector(0), vector(0), vector(1), vector(1)]) == nil)
    }

    @Test func corruptMemoryIsPreservedUntilExplicitlyForgotten() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("invalid".utf8).write(to: url)
        let memory = VoiceMemory(url: url)
        #expect(memory.loadError != nil)
        #expect(try memory.remember([vector(0), vector(0)], name: "One") == nil)
        #expect(try String(contentsOf: url, encoding: .utf8) == "invalid")
        try memory.forgetAll()
        #expect(memory.loadError == nil)
        #expect(try memory.remember([vector(0), vector(0)], name: "One") != nil)
    }

    private func snapshot(_ samples: [[Float]], slot: Int = 0, start: Double = 0) -> SpeakerSnapshot {
        SpeakerSnapshot(intervals: [SpeakerInterval(slot: slot, start: start, end: start + 20)],
            processedThrough: start + 20, voiceEmbeddings: [slot: samples])
    }

    @Test func modelLearnsNameAfterAudioOrBeforeItAndRecognizesAfterRelaunch() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let model = TranscriptionModel(preferences: MemoryPreferences(), voiceMemoryURL: url)
        let input = snapshot([vector(0), vector(0)])
        model.receiveSpeakerSnapshot(input)
        #expect(model.rememberedVoices.isEmpty)
        model.speakerNames[1] = "Justin"
        #expect(VoiceMemory(url: url).voices.first?.name == "Justin")
        model.clear()
        model.receiveSpeakerSnapshot(input)
        #expect(model.speakerNames[1] == "Justin")
        let reloaded = TranscriptionModel(preferences: MemoryPreferences(), voiceMemoryURL: url)
        reloaded.receiveSpeakerSnapshot(input)
        #expect(reloaded.speakerNames[1] == "Justin")
        let newInput = snapshot([vector(1), vector(1)], slot: 1)
        reloaded.receiveSpeakerSnapshot(SpeakerSnapshot(intervals: newInput.intervals, processedThrough: 20))
        reloaded.speakerNames[2] = "Michael"
        reloaded.receiveSpeakerSnapshot(newInput)
        #expect(reloaded.rememberedVoices.count == 2)
        #expect(VoiceMemory(url: url).match([vector(1), vector(1)])?.name == "Michael")
        // A manual correction preserves the original identity, and never duplicates a name.
        model.speakerNames[1] = "Michael"
        #expect(model.rememberedVoices.count == 2)
        #expect(Set(model.rememberedVoices.map(\.name)) == ["Justin", "Michael"])
        model.forgetSavedVoices()
        model.receiveSpeakerSnapshot(input)
        #expect(model.rememberedVoices.isEmpty)
        #expect(model.speakerNames[1] == "Michael")
        model.clear()
        model.receiveSpeakerSnapshot(input)
        #expect(model.rememberedVoices.isEmpty) // Never relearn anonymous profiles.
    }

    @Test func correctingNewlyEnteredNameReplacesDraftProfileWithoutLeavingCompetingAliases() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let model = TranscriptionModel(preferences: MemoryPreferences(), voiceMemoryURL: url)
        model.receiveSpeakerSnapshot(snapshot([vector(0), vector(0)]))
        model.speakerNames[1] = "Justin"
        model.speakerNames[1] = "Justin Smith"
        #expect(model.rememberedVoices.count == 1)
        #expect(VoiceMemory(url: url).match([vector(0), vector(0)])?.name == "Justin Smith")
    }

    @Test func modelRetriesUnknownVoiceAndSharesIdentityAcrossNonOverlappingSlots() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let memory = VoiceMemory(url: url)
        _ = try memory.remember([vector(0), vector(0)], name: "Justin")
        let model = TranscriptionModel(preferences: MemoryPreferences(), voiceMemoryURL: url)
        model.receiveSpeakerSnapshot(snapshot([vector(1), vector(0)]))
        #expect(model.speakerNames[1] == nil)
        model.receiveSpeakerSnapshot(snapshot([vector(1), vector(0), vector(0)]))
        #expect(model.speakerNames[1] == "Justin")
        let next = SpeakerSnapshot(intervals: [SpeakerInterval(slot: 0, start: 0, end: 20),
            SpeakerInterval(slot: 1, start: 21, end: 40), SpeakerInterval(slot: 2, start: 21, end: 40)],
            processedThrough: 40, voiceEmbeddings: [0: [vector(0), vector(0)],
                1: [vector(0), vector(0)], 2: [vector(0), vector(0)]])
        model.receiveSpeakerSnapshot(next)
        #expect(model.speakerNames[2] == "Justin")
        #expect(model.speakerNames[3] == nil) // Impossible simultaneous reuse stays unknown.
        #expect(model.rememberedVoices.count == 1)
        // Matching never adds templates or retrains profiles from its own guesses.
        #expect(VoiceMemory(url: url).voices == memory.voices)
        model.speakerNames[2] = ""
        model.receiveSpeakerSnapshot(next)
        #expect(model.speakerNames[2] == "")
        #expect(model.rememberedVoices.allSatisfy { !$0.name.isEmpty })
    }

    @Test func forgettingSingleVoicePreservesTranscriptWithoutImmediateRelearning() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let model = TranscriptionModel(preferences: MemoryPreferences(), voiceMemoryURL: url)
        model.receiveSpeakerSnapshot(snapshot([vector(0), vector(0)]))
        model.speakerNames[1] = "Justin"
        let id = try #require(model.rememberedVoices.first?.id)
        model.forgetSavedVoice(id)
        model.receiveSpeakerSnapshot(snapshot([vector(0), vector(0), vector(0)]))
        #expect(model.speakerNames[1] == "Justin")
        #expect(model.rememberedVoices.isEmpty)
        #expect(VoiceMemory(url: url).voices.isEmpty)
    }

    @Test func sampleBufferRejectsOverlapTentativeAndSilenceAndKeepsRetrying() throws {
        var buffer = VoiceSampleBuffer()
        buffer.append(Array(repeating: Float(0.1), count: 640_000))
        let overlap = SpeakerSnapshot(intervals: [
            SpeakerInterval(slot: 0, start: 0, end: 40), SpeakerInterval(slot: 1, start: 0, end: 40)
        ], processedThrough: 40)
        var extracted: [[Float]] = []
        buffer.extract(from: overlap) { samples in extracted.append(samples); return vector(0) }
        #expect(extracted.isEmpty)
        buffer.append(Array(repeating: Float(0.2), count: 32_000))
        buffer.extract(from: snapshot([], start: 0).withProcessedThrough(3)) {
            samples in extracted.append(samples); return vector(0)
        }
        #expect(extracted.isEmpty)
        let finalized = SpeakerSnapshot(intervals: [SpeakerInterval(slot: 0, start: 0, end: 100)], processedThrough: 100)
        for _ in 0..<10 {
            buffer.append(Array(repeating: Float(0.3), count: 240_000))
            buffer.extract(from: finalized) { samples in extracted.append(samples); return vector(0) }
        }
        #expect(extracted.count > 6)
        #expect(buffer.embeddings[0]?.count == 6)
        #expect(extracted.allSatisfy { $0.count == 64_000 })
        var silence = VoiceSampleBuffer()
        silence.append(Array(repeating: 0, count: 640_000))
        silence.extract(from: finalized) { _ in Issue.record("Silence must not reach the voice model"); return vector(0) }
    }

    @Test func finalizationRechecksNewlyConfirmedSpeechWithoutMoreAudio() {
        var buffer = VoiceSampleBuffer()
        buffer.append(Array(repeating: Float(0.1), count: 160_000))
        buffer.extract(from: snapshot([]).withProcessedThrough(2)) { _ in
            Issue.record("Tentative speech must not reach extraction")
            return vector(0)
        }
        var calls = 0
        buffer.extract(from: snapshot([]).withProcessedThrough(10), force: true) { _ in
            calls += 1
            return vector(0)
        }
        #expect(calls == 1)
    }

    @Test func shortTurnsAccumulateIntoIndependentExcerptsWithoutReusingAudio() {
        var buffer = VoiceSampleBuffer()
        // Each clean turn is below the old six-second minimum. Sample values
        // identify time so concatenation and independence can be checked exactly.
        buffer.append((0..<640_000).map { Float($0 + 1) / 640_000 })
        let input = SpeakerSnapshot(intervals: stride(from: 0.0, to: 36.0, by: 4).map {
            SpeakerInterval(slot: 0, start: $0, end: $0 + 3)
        }, processedThrough: 40)
        var extracted: [[Float]] = []
        for _ in 0..<3 {
            buffer.extract(from: input) { samples in extracted.append(samples); return vector(0) }
            buffer.append(Array(repeating: Float(1), count: 32_000))
        }
        #expect(extracted.count == 3)
        #expect(extracted.allSatisfy { $0.count == 64_000 })
        #expect(zip(extracted, extracted.dropFirst()).allSatisfy { $0.last! < $1.first! })
    }
}

private extension SpeakerSnapshot {
    func withProcessedThrough(_ value: Double) -> SpeakerSnapshot {
        SpeakerSnapshot(intervals: intervals, processedThrough: value, voiceEmbeddings: voiceEmbeddings)
    }
}

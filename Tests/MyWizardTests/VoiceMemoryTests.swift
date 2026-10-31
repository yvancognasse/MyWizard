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

    @Test func automaticallyStoresAnonymousVoicesThenKeepsNamesAcrossLaunches() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("voices.json")
        let memory = VoiceMemory(url: url)
        let samples = [vector(0), vector(0)]
        let voice = try #require(try memory.remember(samples))
        #expect(voice.name.isEmpty)
        try memory.rename(voice.id, to: "Justin")
        let reloaded = VoiceMemory(url: url)
        #expect(reloaded.match(samples)?.name == "Justin")
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

    @Test func ambiguousInvalidAndInconsistentVoicesNeverReceiveAName() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let memory = VoiceMemory(url: directory.appendingPathComponent("voices.json"))
        _ = try memory.remember([vector(0), vector(0)], name: "One")
        _ = try memory.remember([vector(0), vector(0)], name: "Similar")
        #expect(memory.match([vector(0), vector(0)]) == nil)
        #expect(memory.hasPlausibleMatch([vector(0), vector(0)]))
        #expect(try memory.remember([vector(0), vector(1)]) == nil)
        #expect(VoiceMemory.normalized([Float](repeating: 0, count: 256)) == nil)
        #expect(VoiceMemory.normalized([Float](repeating: .nan, count: 256)) == nil)
        #expect(VoiceMemory.normalized([1, 2]) == nil)
    }

    @Test func corruptMemoryIsPreservedUntilExplicitlyForgotten() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("voices.json")
        try Data("invalid".utf8).write(to: url)
        let memory = VoiceMemory(url: url)
        #expect(memory.loadError != nil)
        #expect(try memory.remember([vector(0), vector(0)]) == nil)
        #expect(try String(contentsOf: url, encoding: .utf8) == "invalid")
        try memory.forgetAll()
        #expect(memory.loadError == nil)
        #expect(try memory.remember([vector(0), vector(0)]) != nil)
    }

    @Test func modelRecognizesNamesAfterClearAndDoesNotRelearnAfterForget() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("voices.json")
        let model = TranscriptionModel(preferences: MemoryPreferences(), voiceMemoryURL: url)
        let snapshot = SpeakerSnapshot(intervals: [SpeakerInterval(slot: 0, start: 0, end: 20)],
            processedThrough: 20, voiceEmbeddings: [0: [vector(0), vector(0)]])
        model.receiveSpeakerSnapshot(snapshot)
        #expect(model.rememberedVoices.count == 1)
        model.speakerNames[1] = "Justin"
        #expect(VoiceMemory(url: url).voices.first?.name == "Justin")
        model.clear()
        model.receiveSpeakerSnapshot(snapshot)
        #expect(model.speakerNames[1] == "Justin")
        var document = SpeakerTranscript()
        document.beginSession(detectsSpeakers: true)
        document.updateSpeakers(snapshot)
        document.receive([TimedText(text: "Hello", start: 1, end: 2)], isFinal: true)
        #expect(document.plainText(names: model.speakerNames).contains("Justin"))
        // Correcting an automatic match keeps the original profile intact.
        model.speakerNames[1] = "Michael"
        #expect(VoiceMemory(url: url).voices.contains { $0.name == "Justin" })
        #expect(VoiceMemory(url: url).voices.contains { $0.name == "Michael" })
        model.forgetSavedVoices()
        model.receiveSpeakerSnapshot(snapshot)
        #expect(model.rememberedVoices.isEmpty)
        #expect(model.speakerNames[1] == "Michael")
        model.clear()
        model.receiveSpeakerSnapshot(snapshot)
        #expect(model.rememberedVoices.count == 1)
    }

    @Test func sampleBufferRejectsOverlapsTentativeAndShortSpeechAndUsesIndependentExcerpts() throws {
        var buffer = VoiceSampleBuffer()
        buffer.append(Array(repeating: Float(0.1), count: 480_000))
        let overlapped = SpeakerSnapshot(intervals: [
            SpeakerInterval(slot: 0, start: 0, end: 20), SpeakerInterval(slot: 1, start: 0, end: 20)
        ], processedThrough: 20)
        var extracted: [[Float]] = []
        buffer.extract(from: overlapped) { samples in extracted.append(samples); return vector(0) }
        #expect(extracted.isEmpty)
        buffer.append(Array(repeating: Float(0.2), count: 32_000))
        buffer.extract(from: SpeakerSnapshot(intervals: [SpeakerInterval(slot: 0, start: 0, end: 20)], processedThrough: 3)) {
            samples in extracted.append(samples); return vector(0)
        }
        #expect(extracted.isEmpty)
        buffer.append(Array(repeating: Float(0.3), count: 32_000))
        let finalized = SpeakerSnapshot(intervals: [SpeakerInterval(slot: 0, start: 0, end: 20)], processedThrough: 20)
        buffer.extract(from: finalized) { samples in extracted.append(samples); return vector(0) }
        #expect(extracted.count == 1)
        buffer.append(Array(repeating: Float(0.4), count: 32_000))
        buffer.extract(from: finalized) { samples in extracted.append(samples); return vector(0) }
        #expect(extracted.count == 2)
        #expect(buffer.embeddings[0]?.count == 2)
        #expect(extracted.allSatisfy { $0.count <= 128_000 && $0.count >= 96_000 })
    }
}

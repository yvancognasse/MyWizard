import AVFoundation
import Foundation
import Testing
import SwiftUI
@testable import MyWizard

struct TranscriptReaderTests {
    @Test func readingPrefersSelectedRegionAndRejectsIncompatibleScripts() throws {
        let paragraph = TranscriptParagraph(id: 0, text: "Hello", speaker: 1, hasSpeakerLabel: true)
        let voices = [
            ReadingVoice(identifier: "us", name: "US voice", language: "en-US", quality: 2),
            ReadingVoice(identifier: "uk", name: "UK voice", language: "en-GB", quality: 1)
        ]
        let plan = try ReadingPlan.make(paragraphs: [paragraph], language: "en-GB", voices: voices)
        #expect(plan.first?.voiceIdentifier == "uk")
        let simplified = [ReadingVoice(identifier: "simplified", name: "Chinese voice", language: "zh-CN", quality: 2)]
        #expect(throws: (any Error).self) {
            try ReadingPlan.make(paragraphs: [paragraph], language: "zh-TW", voices: simplified)
        }
    }

    @Test @MainActor func stopButtonStaysRedInInactiveWindow() throws {
        let content = Button("Stop") { }
            .buttonStyle(CaptureButtonStyle(isCapturing: true))
            .environment(\.controlActiveState, .inactive)
            .frame(width: 100, height: 40)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 1
        let image = try #require(renderer.cgImage)
        let bitmap = NSBitmapImageRep(cgImage: image)
        var redPixels = 0
        for x in 0..<bitmap.pixelsWide {
            for y in 0..<bitmap.pixelsHigh {
                if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                   color.alphaComponent > 0.8, color.redComponent > 0.6,
                   color.greenComponent < 0.3, color.blueComponent < 0.35 {
                    redPixels += 1
                }
            }
        }
        #expect(redPixels > 400, "The inactive Stop button must still have a red background")
        if let folder = ProcessInfo.processInfo.environment["MYWIZARD_UI_ARTIFACTS"] {
            try bitmap.representation(using: .png, properties: [:])?.write(
                to: URL(fileURLWithPath: folder).appendingPathComponent("stop-button.png"))
        }
    }

    private let voices = [
        ReadingVoice(identifier: "fr1", name: "Voice A", language: "fr-FR", quality: 1),
        ReadingVoice(identifier: "fr2", name: "Voice B", language: "fr-FR", quality: 1),
        ReadingVoice(identifier: "en1", name: "Voice C", language: "en-US", quality: 1),
        ReadingVoice(identifier: "en2", name: "Voice D", language: "en-GB", quality: 1)
    ]

    @Test func readsOnlyContentAndReusesReturningSpeakersVoice() throws {
        let paragraphs = [
            TranscriptParagraph(id: 0, text: "Bonjour.", speaker: 1, hasSpeakerLabel: true),
            TranscriptParagraph(id: 1, text: "Salut !", speaker: 2, hasSpeakerLabel: true),
            TranscriptParagraph(id: 2, text: "À bientôt.", speaker: 1, hasSpeakerLabel: true)
        ]
        let renamedExport = SpeakerTranscript.plainText(paragraphs: paragraphs, names: [1: "Alice", 2: "Bob"])
        #expect(renamedExport.contains("Alice"))
        let plan = try ReadingPlan.make(paragraphs: paragraphs, language: "fr-FR", voices: voices)
        #expect(plan.map(\.text) == ["Bonjour.", "Salut !", "À bientôt."])
        #expect(plan.map(\.voiceIdentifier) == ["fr1", "fr2", "fr1"])
    }

    @Test func usesSelectedLanguageIncludingRegionalVoices() throws {
        let paragraphs = (1...2).map { TranscriptParagraph(id: $0, text: "Hello", speaker: $0, hasSpeakerLabel: true) }
        let plan = try ReadingPlan.make(paragraphs: paragraphs, language: "en-US", voices: voices)
        #expect(plan.map(\.voiceIdentifier) == ["en1", "en2"])
    }

    @Test func reusesVoicesWithoutChangingLanguageOrReturningSpeakersVoice() throws {
        let paragraphs = [1, 2, 3, 4, 5, 2].enumerated().map {
            TranscriptParagraph(id: $0.offset, text: "Hello", speaker: $0.element, hasSpeakerLabel: true)
        }
        let plan = try ReadingPlan.make(paragraphs: paragraphs, language: "en-US", voices: voices)
        #expect(plan.map(\.voiceIdentifier) == ["en1", "en2", "en1", "en2", "en1", "en2"])
    }

    @Test func germanAndSwissGermanReuseGermanVoices() throws {
        let german = ReadingVoice(identifier: "de1", name: "Anna", language: "de-DE", quality: 1)
        let paragraphs = [1, 2, 1].enumerated().map {
            TranscriptParagraph(id: $0.offset, text: "Guten Tag.", speaker: $0.element, hasSpeakerLabel: true)
        }
        for language in ["de-DE", "de-CH"] {
            let plan = try ReadingPlan.make(paragraphs: paragraphs, language: language, voices: voices + [german])
            #expect(plan.map(\.voiceIdentifier) == ["de1", "de1", "de1"])
            #expect(plan.allSatisfy { $0.text == "Guten Tag." })
        }
    }

    @Test func missingGermanVoiceHasGermanError() {
        let paragraphs = [TranscriptParagraph(id: 0, text: "Hallo", speaker: 1, hasSpeakerLabel: true)]
        do {
            _ = try ReadingPlan.make(paragraphs: paragraphs, language: "de-CH", voices: voices)
            Issue.record("Expected missing German voice")
        } catch {
            #expect(error.localizedDescription.contains("German"))
        }
    }

    @Test func oneVoiceCanReadAllSpeakers() throws {
        let paragraphs = (1...4).map { TranscriptParagraph(id: $0, text: "Bonjour", speaker: $0, hasSpeakerLabel: true) }
        let plan = try ReadingPlan.make(paragraphs: paragraphs, language: "fr-FR", voices: [voices[0]])
        #expect(plan.count == 4)
        #expect(plan.allSatisfy { $0.voiceIdentifier == "fr1" })
    }

    @Test func noVoiceInSelectedLanguageDoesNotUseWrongLanguage() {
        let paragraphs = [TranscriptParagraph(id: 0, text: "Hello", speaker: 1, hasSpeakerLabel: true)]
        #expect(throws: ReadingError.self) {
            try ReadingPlan.make(paragraphs: paragraphs, language: "en-US", voices: [voices[0]])
        }
        #expect(throws: ReadingError.self) {
            try ReadingPlan.make(paragraphs: paragraphs, language: "en-US", voices: [])
        }
    }

    @Test func ignoresEmptyParagraphsAndKeepsNamesActuallySpokenInContent() throws {
        let paragraphs = [
            TranscriptParagraph(id: 0, text: " \n", speaker: 9, hasSpeakerLabel: true),
            TranscriptParagraph(id: 1, text: "Alice mentioned Speaker 1.", speaker: nil, hasSpeakerLabel: true)
        ]
        let plan = try ReadingPlan.make(paragraphs: paragraphs, language: "en-US", voices: voices)
        #expect(plan.map(\.text) == ["Alice mentioned Speaker 1."])
        #expect(try ReadingPlan.make(paragraphs: [], language: "en-US", voices: []).isEmpty)
    }

    @Test func sameVoiceQualityVariantsReuseBestVariant() throws {
        let duplicate = ReadingVoice(identifier: "frEnhanced", name: "Voice A (Enhanced)", language: "fr-FR", quality: 2)
        let paragraphs = (1...2).map { TranscriptParagraph(id: $0, text: "Bonjour", speaker: $0, hasSpeakerLabel: true) }
        let plan = try ReadingPlan.make(paragraphs: paragraphs, language: "fr-FR", voices: [voices[0], duplicate])
        #expect(plan.map(\.voiceIdentifier) == ["frEnhanced", "frEnhanced"])
    }

    @Test @MainActor func stopAndEmptyReadRemainIdle() {
        let reader = TranscriptReader()
        reader.stop()
        reader.read(paragraphs: [], language: "fr-FR")
        #expect(!reader.isReading)
        #expect(reader.errorMessage == nil)
    }

    // Opt-in synthesis smoke test: renders buffers in memory, without playing
    // audio or capturing the user's microphone/system audio.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MYWIZARD_READING_SMOKE"] == "1"))
    @MainActor func synthesizesFourDistinctVoicesInEachLanguage() async throws {
        let available = TranscriptReader.availableVoices()
        for language in TranscriptionLanguage.allCases.map(\.rawValue) {
            let text = language.hasPrefix("de") ? "Guten Tag, dies ist ein Lesetest." :
                (language == "fr-FR" ? "Bonjour, ceci est un test de lecture." : "Hello, this is a reading test.")
            let paragraphs = (1...4).map { TranscriptParagraph(id: $0, text: text, speaker: $0, hasSpeakerLabel: true) }
            let plan = try ReadingPlan.make(paragraphs: paragraphs, language: language, voices: available)
            #expect(Set(plan.map(\.voiceIdentifier)).count == 4)
            for part in plan {
                let voice = try #require(AVSpeechSynthesisVoice(identifier: part.voiceIdentifier))
                let engine = AVSpeechSynthesizer()
                let utterance = AVSpeechUtterance(string: part.text)
                utterance.voice = voice
                let (frames, continuation) = AsyncStream<UInt32>.makeStream()
                let deadline = Task {
                    do { try await Task.sleep(for: .seconds(20)) } catch { return }
                    continuation.finish()
                }
                engine.write(utterance) { @Sendable buffer in
                    let count = (buffer as? AVAudioPCMBuffer)?.frameLength ?? 0
                    continuation.yield(count)
                    if count == 0 { continuation.finish() }
                }
                var total: UInt64 = 0
                var ended = false
                for await count in frames { total += UInt64(count); ended = ended || count == 0 }
                deadline.cancel()
                engine.stopSpeaking(at: .immediate)
                #expect(ended, "Synthesis timed out for \(voice.name)")
                #expect(total > 0, "No audio generated for \(voice.name)")
                print("Reading smoke test: \(language) / \(voice.name) / \(total) frames")
            }
        }
    }
}

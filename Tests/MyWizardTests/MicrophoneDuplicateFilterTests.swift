import Foundation
import Testing
@testable import MyWizard

struct MicrophoneDuplicateFilterTests {
    @Test func compactExportEchoAllowsMissingArticlesButRetainsRealReplies() {
        let system = words("tu veux une partie deux en commentaire et propose tes films préférés")
        let indexes = [0, 1, 2, 3, 4, 6, 8]
        let texts = ["tu", "veux", "une", "partie", "de", "commentaire", "propose"]
        let echo = zip(texts, indexes).map { text, index in
            TimedText(text: text + " ", start: system[index].start + 0.1,
                end: system[index].end + 0.1, source: .microphone)
        }
        #expect(!MicrophoneDuplicateFilter.microphone(echo, excludingEchoOf: system).isEmpty)
        #expect(MicrophoneDuplicateFilter.microphone(echo, excludingEchoOf: system, matchesCompactPassages: true).isEmpty)
        for text in ["oui", "non", "100%", "Ok intéressant", "1 2 3 voici mon avis"] {
            let reply = words(text, start: 4, source: .microphone)
            let result = MicrophoneDuplicateFilter.microphone(echo + reply, excludingEchoOf: system, matchesCompactPassages: true)
            if text == "non" {
                // A nearby objection deliberately protects the ambiguous echo
                // too: never weaken that safeguard merely to remove more text.
                #expect(Array(result.suffix(reply.count)) == reply)
            } else { #expect(result.map(\.text).joined() == reply.map(\.text).joined()) }
        }
        let later = echo.map { TimedText(text: $0.text, start: $0.start + 20, end: $0.end + 20, source: .microphone) }
        #expect(MicrophoneDuplicateFilter.microphone(later, excludingEchoOf: system, matchesCompactPassages: true) == later)
    }

    @Test func shortIndependentRepliesNumbersAndObjectionsSurviveInsideEcho() {
        let system = words("we discuss the architecture and review the design before we share our results today")
        for reply in ["Yes", "oui", "123", "42", "not", "non"] {
            var own = system.map { TimedText(text: $0.text, start: $0.start + 0.1, end: $0.end + 0.1, source: .microphone) }
            own.insert(.init(text: reply + " ", start: 1.85, end: 1.9, source: .microphone), at: 6)
            let result = MicrophoneDuplicateFilter.microphone(own, excludingEchoOf: system)
            #expect(result.contains { $0.text == reply + " " })
        }
    }

    @Test func alignedTruncatedRemoteWordDoesNotBecomeAnOwnIntervention() {
        let system = words("préentraîné mais on peut ensuite affiner le modèle pour toute nouvelle utilisation")
        let own = words("îné et on peut ensuite affiner le modèle pour toute nouvelle utilisation", start: 0.1, source: .microphone)
        #expect(MicrophoneDuplicateFilter.microphone(own, excludingEchoOf: system).isEmpty)
        let later = words("îné et on peut ensuite affiner le modèle pour toute nouvelle utilisation", start: 10, source: .microphone)
        #expect(MicrophoneDuplicateFilter.microphone(later, excludingEchoOf: system) == later)
    }

    @Test func sustainedFragmentedEchoRemovesAnchorsButPreservesUnmatchedReply() {
        let system = words("growth equals more pipeline and faster execution with strong customer demand today")
        var own = words("growth equals our pipeline and past execution with wrong customer demand today", start: 0.1, source: .microphone)
        let reply = words("Yes", start: 4, source: .microphone)
        own += reply
        let result = MicrophoneDuplicateFilter.microphone(own, excludingEchoOf: system).map(\.text).joined()
        #expect(result == "Yes ")
    }

    private func words(_ text: String, start: Double = 0, source: TranscriptSource = .systemAudio) -> [TimedText] {
        text.split(separator: " ").enumerated().map {
            TimedText(text: String($0.element) + " ", start: start + Double($0.offset) * 0.3,
                end: start + Double($0.offset + 1) * 0.3, source: source)
        }
    }

    @Test func screenshotPhraseAppearsOnlyOnSystemTrack() {
        let text = "And this is what enterprise operations can look like"
        let system = words(text)
        let microphone = words(text, start: 0.12, source: .microphone)
        #expect(MicrophoneDuplicateFilter.microphone(microphone, excludingEchoOf: system).isEmpty)
    }

    @Test func keepsDifferentOverlappingSpeechAndLaterRepetition() {
        let system = words("The project is ready for Friday")
        let own = words("No I disagree please wait", start: 0.1, source: .microphone)
        #expect(MicrophoneDuplicateFilter.microphone(own, excludingEchoOf: system) == own)
        let repeated = words("The project is ready for Friday", start: 5, source: .microphone)
        #expect(MicrophoneDuplicateFilter.microphone(repeated, excludingEchoOf: system) == repeated)
    }

    @Test func preservesShortAnswersAndNegationInsidePartiallyMatchingSpeech() {
        let short = words("Yes thank you", source: .microphone)
        #expect(MicrophoneDuplicateFilter.microphone(short, excludingEchoOf: words("Yes thank you")) == short)
        let system = words("The project is ready for Friday")
        let own = words("The project is NOT ready for Friday", start: 0.1, source: .microphone)
        let filtered = MicrophoneDuplicateFilter.microphone(own, excludingEchoOf: system)
        #expect(filtered == own)
    }

    @Test func preservesOwnContinuationAfterEchoAndNormalizesPunctuation() {
        let system = words("And this is what enterprise operations can look like.")
        let echo = words("and THIS is what enterprise operations can look like!", start: 0.1, source: .microphone)
        let reply = words("I have a different opinion.", start: 3.5, source: .microphone)
        let filtered = MicrophoneDuplicateFilter.microphone(echo + reply, excludingEchoOf: system)
        #expect(filtered.map(\.text).joined() == reply.map(\.text).joined())
    }

    @Test func wholePhraseTimestampsAndClearAndArchivesRemainReversible() {
        var document = SpeakerTranscript()
        document.beginSession(detectsSpeakers: false, reservesOwnSpeaker: true)
        let phrase = "This is what enterprise operations can look like."
        document.receive([TimedText(text: phrase, start: 0.1, end: 3.1)], isFinal: true, source: .microphone)
        #expect(document.deduplicatedParagraphs.contains { $0.source == .microphone })
        document.receive([TimedText(text: phrase, start: 0, end: 3)], isFinal: true)
        #expect(document.deduplicatedParagraphs.allSatisfy { $0.source == .systemAudio })
        #expect(document.paragraphs.contains { $0.source == .microphone })
        document.beginSession(detectsSpeakers: true, reservesOwnSpeaker: true)
        #expect(document.deduplicatedParagraphs.allSatisfy { $0.source == .systemAudio })
        #expect(document.paragraphs.contains { $0.source == .microphone })
        document.clear()
        #expect(document.deduplicatedParagraphs.isEmpty)
        #expect(document.paragraphs.isEmpty)
    }

    @Test func systemRevisionsRestoreRejectedMatchesWithoutChangingOriginal() {
        var document = SpeakerTranscript()
        let own = words("I have a different opinion", source: .microphone)
        document.receive(own, isFinal: true, source: .microphone)
        document.receive(words("I have a different opinion"), isFinal: false)
        #expect(!document.deduplicatedParagraphs.contains { $0.source == .microphone })
        document.receive(words("We will review the budget"), isFinal: true)
        #expect(document.deduplicatedParagraphs.contains { $0.source == .microphone })
        #expect(document.paragraphs.filter { $0.source == .microphone }.map(\.text).joined().contains("different opinion"))
    }

    @MainActor @Test func filteringAlwaysAppliesToDisplayAndExportDespiteLegacyDisabledPreference() throws {
        let defaults = MemoryPreferences()
        defaults.set(false, forKey: "suppressesMicrophoneDuplicates")
        let model = TranscriptionModel(preferences: defaults)
        #expect(model.suppressesMicrophoneDuplicates)
        #expect(defaults.object(forKey: "suppressesMicrophoneDuplicates") == nil)
        model.receiveTranscript(words("And this is what enterprise operations can look like"), isFinal: true)
        model.receiveTranscript(words("And this is what enterprise operations can look like", start: 0.1, source: .microphone), isFinal: true, source: .microphone)
        #expect(!model.paragraphs.contains { $0.source == .microphone })
        #expect(model.unfilteredParagraphs.contains { $0.source == .microphone })
        #expect(model.transcript.components(separatedBy: "And this is").count == 2)
        #expect(TranscriptionModel(preferences: defaults).suppressesMicrophoneDuplicates)
    }
}

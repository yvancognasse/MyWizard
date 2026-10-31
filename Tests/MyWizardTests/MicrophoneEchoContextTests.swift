import Foundation
import Testing
@testable import MyWizard

struct MicrophoneEchoContextTests {
    private let phrase = "the presentation explains the architecture for the project today"

    private func words(_ text: String, start: Double = 0) -> [TimedText] {
        text.split(separator: " ").enumerated().map {
            .init(text: String($0.element) + " ", start: start + Double($0.offset) * 0.3,
                  end: start + Double($0.offset + 1) * 0.3, source: .microphone)
        }
    }

    private func frames(correlation: Double = 0.7, residual: Double = 0.2, power: Double = 0.01) -> [MicrophoneEchoFrame] {
        (0..<10).map { .init(start: Double($0), end: Double($0 + 1), correlation: correlation,
                             residualRatio: residual, referencePower: power) }
    }

    @Test func phraseRangeUncertaintyCanSupportOrphansOnlyWithAcousticEvidence() {
        let raw = words(phrase)
        let reference = [TimedText(text: phrase, start: 0, end: 5)]
        let orphan = [raw[4]]
        #expect(MicrophoneEchoContext.filter(orphan, recognition: raw, reference: reference, frames: frames()).isEmpty)
        #expect(MicrophoneEchoContext.filter(orphan, recognition: raw, reference: reference, frames: []) == orphan)
        #expect(MicrophoneEchoContext.filter(orphan, recognition: raw, reference: reference,
            frames: frames(correlation: 0.1)) == orphan)
        #expect(MicrophoneEchoContext.filter(orphan, recognition: raw, reference: reference,
            frames: frames(residual: 0.95)) == orphan)
        #expect(MicrophoneEchoContext.filter(orphan, recognition: raw, reference: reference,
            frames: frames(power: 0)) == orphan)
        #expect(MicrophoneEchoContext.filter(orphan, recognition: raw, reference: [], frames: frames()) == orphan)
    }

    @Test func shortRepliesAndNumbersSurviveEvenWhenEchoDominates() {
        let raw = words(phrase)
        let reference = [TimedText(text: phrase, start: 0, end: 5)]
        for reply in ["oui", "non", "yes", "no", "merci", "123", "100%"] {
            let own = words(reply, start: 1.5)
            #expect(MicrophoneEchoContext.filter(own, recognition: raw + own, reference: reference,
                frames: frames()) == own)
        }
    }

    @Test func unmatchedObjectionProtectsAccompanyingWords() {
        let raw = words("the presentation is not ready today")
        let reference = [TimedText(text: "the presentation is ready today", start: 0, end: 5)]
        #expect(MicrophoneEchoContext.filter(raw, recognition: raw, reference: reference, frames: frames()) == raw)
    }

    @Test func laterIndependentRepetitionSurvives() {
        let raw = words(phrase, start: 7)
        let reference = [TimedText(text: phrase, start: 0, end: 3)]
        #expect(MicrophoneEchoContext.filter(raw, recognition: raw, reference: reference, frames: frames()) == raw)
    }

    @Test func briefCancellationLapseNeedsExactTextAndSurroundingAudio() {
        let raw = words(phrase, start: 3)
        let reference = [TimedText(text: phrase, start: 3, end: 8)]
        let orphan = [raw[7]]
        func gap(_ correlation: Double, _ power: Double = 0.01) -> [MicrophoneEchoFrame] {
            frames().map {
                $0.start == 5 ? .init(start: 5, end: 6, correlation: correlation,
                                     residualRatio: 1, referencePower: power) : $0
            }
        }
        #expect(MicrophoneEchoContext.filter(orphan, recognition: raw, reference: reference, frames: gap(0.12)).isEmpty)
        #expect(MicrophoneEchoContext.filter(orphan, recognition: raw, reference: reference, frames: gap(0)) == orphan)
        #expect(MicrophoneEchoContext.filter(orphan, recognition: raw, reference: reference, frames: gap(0.12, 0)) == orphan)
        let own = words("perhaps", start: 5.1)
        #expect(MicrophoneEchoContext.filter(own, recognition: raw + own, reference: reference, frames: gap(0.12)) == own)
    }

    @Test func independentPhraseSurvivesResidualLocalEnergy() {
        let raw = words(phrase)
        let own = words("please wait another moment", start: 3)
        let reference = [TimedText(text: phrase, start: 0, end: 5)]
        // Echo is present too, but a substantial residual remains. Matching
        // words elsewhere cannot justify deleting this different sentence.
        #expect(MicrophoneEchoContext.filter(own, recognition: raw + own, reference: reference,
            frames: frames(residual: 0.7)) == own)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MYWIZARD_PERFORMANCE_CHECK"] == "1"))
    func boundedContextOnOneHourOfRepeatedWords() {
        let vocabulary = phrase.split(separator: " ")
        let input = (0..<12_000).map {
            TimedText(text: String(vocabulary[$0 % vocabulary.count]) + " ",
                      start: Double($0) * 0.3, end: Double($0 + 1) * 0.3, source: .microphone)
        }
        let evidence = (0..<3600).map {
            MicrophoneEchoFrame(start: Double($0), end: Double($0 + 1), correlation: 0.7,
                                residualRatio: 0.2, referencePower: 0.01)
        }
        var retained = 0
        let duration = ContinuousClock().measure {
            retained = MicrophoneEchoContext.filter(input, recognition: input, reference: input, frames: evidence).count
        }
        #expect(retained == 0)
        print("PERFORMANCE export echo context: 12,000 words, 1 hour = \(duration)")
    }
}

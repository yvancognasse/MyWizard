import Foundation
import Testing
@testable import MyWizard

struct EchoEvidenceTests {
    private func noise(_ count: Int, seed: UInt64) -> [Float] {
        var state = seed
        return (0..<count).map { _ in
            state = state &* 6364136223846793005 &+ 1
            return Float(Int64(bitPattern: state) >> 40) / Float(1 << 23) * 0.1
        }
    }

    @Test func delayedEchoIsSilencedIncludingAcrossChunkBoundaries() {
        let reference = noise(48000, seed: 17)
        let delay = 6407 // Beyond 400 ms, and not aligned to the former lag grid.
        let microphone = reference.indices.map { $0 >= delay ? reference[$0 - delay] * 0.3 : 0 }
        var reducer = OfflineEchoReducer()
        var output: [Float] = []
        for start in stride(from: 0, to: reference.count, by: 16000) {
            output += reducer.process(microphone: Array(microphone[start..<start + 16000]),
                                      reference: Array(reference[start..<start + 16000]))
        }
        #expect(output.allSatisfy { $0 == 0 })
        #expect(!reducer.echoOnlyFrames.isEmpty)
        _ = reducer.process(microphone: [0], reference: [0])
        #expect(reducer.echoOnlyFrames.isEmpty)
    }

    @Test func reverberationIsSilencedAfterFilterConverges() {
        let reference = noise(48000, seed: 91)
        let microphone = reference.indices.map { i -> Float in
            (i >= 320 ? reference[i - 320] * 0.4 : 0)
            + (i >= 390 ? reference[i - 390] * 0.1 : 0)
        }
        var reducer = OfflineEchoReducer()
        var output: [Float] = []
        for start in stride(from: 0, to: reference.count, by: 16000) {
            output += reducer.process(microphone: Array(microphone[start..<start + 16000]),
                                      reference: Array(reference[start..<start + 16000]))
        }
        #expect(output[16000...].allSatisfy { $0 == 0 })
    }

    @Test func quietIndependentSpeechAndShortInterruptionSurviveEchoGate() {
        let reference = noise(48000, seed: 19)
        let near = noise(48000, seed: 80).map { $0 * 0.05 }
        let microphone = reference.indices.map { i -> Float in
            reference[i] * 0.5 + ((16000..<19200).contains(i) || i >= 32000 ? near[i] : 0)
        }
        var reducer = OfflineEchoReducer()
        var output: [Float] = []
        for start in stride(from: 0, to: reference.count, by: 16000) {
            output += reducer.process(microphone: Array(microphone[start..<start + 16000]),
                                      reference: Array(reference[start..<start + 16000]))
        }
        for range in [16000..<19200, 32000..<48000] {
            let actual = range.reduce(Float(0)) { $0 + output[$1] * output[$1] }
            let expected = range.reduce(Float(0)) { $0 + near[$1] * near[$1] }
            #expect(actual > expected * 0.7)
        }
    }

    @Test func onlyWordsCoveredByEchoEvidenceAreRemoved() {
        let result = EchoReductionResult(audio: URL(fileURLWithPath: "/unused"),
            echoOnly: [.init(start: 0, end: 1), .init(start: 2, end: 3)])
        let words = [TimedText(text: "misheard echo ", start: 0, end: 1, source: .microphone),
                     TimedText(text: "Yes ", start: 1, end: 1.4, source: .microphone),
                     TimedText(text: "overlapping answer ", start: 2.9, end: 3.5, source: .microphone),
                     TimedText(text: "later reply", start: 5, end: 6, source: .microphone)]
        #expect(result.removingEchoArtifacts(from: words).map(\.text).joined() == "Yes overlapping answer later reply")
        let empty = EchoReductionResult(audio: result.audio, echoOnly: [])
        #expect(empty.removingEchoArtifacts(from: words) == words)
    }

    @Test func localSpeechDuringReferencePausesCannotDestabilizeFilter() {
        let signal = noise(48000, seed: 913)
        let near = noise(48000, seed: 158)
        let reference = signal.indices.map { ($0 / 800) % 2 == 0 ? signal[$0] : signal[$0] * 0.0001 }
        let microphone = signal.indices.map { reference[$0] * 0.4 + near[$0] }
        var reducer = OfflineEchoReducer()
        for start in stride(from: 0, to: signal.count, by: 16000) {
            let own = Array(microphone[start..<start + 16000])
            let clean = reducer.process(microphone: own, reference: Array(reference[start..<start + 16000]))
            for offset in stride(from: 0, to: clean.count, by: 1600) {
                let range = offset..<offset + 1600
                let inputEnergy = range.reduce(Float(0)) { $0 + own[$1] * own[$1] }
                let outputEnergy = range.reduce(Float(0)) { $0 + clean[$1] * clean[$1] }
                #expect(outputEnergy <= inputEnergy * 1.251)
            }
        }
    }
}

import Foundation
import Testing
@testable import MyWizard

@MainActor
struct TranscriptionPerformanceTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MYWIZARD_PERFORMANCE_CHECK"] == "1"))
    func duplicateFilteringOnLongMeeting() {
        var document = SpeakerTranscript()
        let words = (0..<10_000).map {
            TimedText(text: "meeting\($0) ", start: Double($0) * 0.3, end: Double($0 + 1) * 0.3)
        }
        document.receive(words, isFinal: true)
        document.receive(words.map { TimedText(text: $0.text, start: $0.start + 0.1, end: $0.end + 0.1) }, isFinal: true, source: .microphone)
        var count = 0
        let duration = ContinuousClock().measure {
            for _ in 0..<20 { count += document.deduplicatedParagraphs.count }
        }
        #expect(count == 20)
        print("PERFORMANCE duplicate filtering: 20 x 10,000 words per track = \(duration)")
    }

    @Test func longUnicodeTranscriptChunksAreLossless() {
        let text = String(repeating: "Bonjour à tous 👨‍👩‍👧‍👦. Voici notre réunion à Zürich. ", count: 200)
        for limit in [1, 17, 400, 2000] {
            let chunks = TranscriptReader.chunks(text, limit: limit)
            #expect(chunks.joined() == text)
            #expect(chunks.allSatisfy { !$0.isEmpty && $0.count <= limit })
        }
    }

    // Opt-in reproducible CPU benchmark; no recognition, playback or networking.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MYWIZARD_PERFORMANCE_CHECK"] == "1"))
    func longMeetingTextProcessing() {
        let text = String(repeating: "The project is on schedule and the next meeting is on Friday. ", count: 2000)
        let clock = ContinuousClock()
        var count = 0
        let elapsed = clock.measure {
            for _ in 0..<20 { count += TranscriptReader.chunks(text).count }
        }
        #expect(count > 0)
        print("PERFORMANCE chunks: 20 x \(text.count) characters = \(elapsed)")
        let display = DisplayTranslation()
        let paragraph = TranscriptParagraph(id: 0, text: text, speaker: 2, hasSpeakerLabel: true, language: "en-US")
        display.update([paragraph], source: "en-US", target: .french)
        display.startNextJob()
        while let job = display.job {
            display.completed(id: job.id, result: .success(job.texts.map { "FR " + $0 }))
            if display.isPending { display.startNextJob() }
        }
        let updates = clock.measure {
            for index in 0..<20 {
                var revision = paragraph
                revision.text += " Revision \(index)"
                display.update([revision], source: "en-US", target: .french)
            }
        }
        print("PERFORMANCE translated display: 20 long-meeting revisions = \(updates)")
        display.reset()
    }
}

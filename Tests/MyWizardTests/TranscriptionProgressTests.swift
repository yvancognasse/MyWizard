import Foundation
import Testing
@testable import MyWizard

struct TranscriptionProgressTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MYWIZARD_RECORDED_FIXTURES"] != nil))
    func realAudioReportsIntermediateProgressAndFinalCompletion() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["MYWIZARD_RECORDED_FIXTURES"])
        let values = ProgressValues()
        let words = try await MeetingProcessor().transcribe(
            URL(fileURLWithPath: path).appendingPathComponent("speaker-one.aiff"), language: "en-US") {
                values.append($0)
            }
        #expect(!words.isEmpty)
        let percentages = values.values
        #expect(percentages.first == 0)
        #expect(percentages.last == 100)
        #expect(percentages.contains { $0 > 0 && $0 < 100 })
        #expect(percentages == percentages.sorted())
        print("TRANSCRIPTION PROGRESS CHECK: \(percentages)")
    }

    @Test func percentageIsMonotonicBoundedAndOnlyCompletesAfterFinalization() {
        let values = ProgressValues()
        let progress = TranscriptionProgress(duration: 200) { values.append($0) }
        for seconds in [0.0, 50, 50.1, 20, 100, 200, 250, .nan, .infinity] {
            progress.update(processedSeconds: seconds)
        }
        #expect(values.values == [0, 25, 50, 99])
        progress.finish()
        progress.update(processedSeconds: 50)
        progress.finish()
        #expect(values.values == [0, 25, 50, 99, 100])
    }

    @Test func silentOrInvalidDurationCanFinishWithoutDivisionErrors() {
        for duration in [0.0, -1, .nan, .infinity] {
            let values = ProgressValues()
            let progress = TranscriptionProgress(duration: duration) { values.append($0) }
            progress.update(processedSeconds: 0)
            progress.update(processedSeconds: 20)
            progress.finish()
            #expect(values.values == [0, 100])
        }
    }
}

private final class ProgressValues: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Int] = []
    func append(_ value: Int) { lock.withLock { stored.append(value) } }
    var values: [Int] { lock.withLock { stored } }
}

import Foundation
import Testing
@testable import MyWizard

final class ExportProgressValues: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Int] = []
    func append(_ value: Int) { lock.withLock { stored.append(value) } }
    var values: [Int] { lock.withLock { stored } }
}

struct ExportProgressTests {
    @Test func totalNeverRestartsAndOnlyFinishesExplicitly() {
        let values = ExportProgressValues()
        let meter = ExportProgress(microphone: true, speakers: true) { values.append($0) }
        meter.update(.models, fraction: 0)
        meter.update(.models, fraction: 1)
        meter.update(.system, fraction: 1)
        meter.update(.microphone, fraction: 0)
        meter.update(.microphone, fraction: 0.5)
        meter.update(.microphone, fraction: 0.2)
        meter.update(.echo, fraction: .nan)
        meter.update(.echo, fraction: .infinity)
        #expect(values.values == [0, 2, 34, 48])
        for stage in [ExportProgress.Stage.echo, .microphone, .reading, .speakers, .finalization] {
            meter.update(stage, fraction: 1)
        }
        #expect(values.values.last == 99)
        #expect(!values.values.contains(100))
        meter.finish()
        meter.finish()
        meter.update(.system, fraction: 0)
        #expect(values.values.last == 100)
        #expect(values.values.filter { $0 == 100 }.count == 1)
        #expect(values.values == values.values.sorted())
    }

    @Test func missingMicrophoneOrSpeakersDoNotHoldBackTheTotal() {
        for microphone in [false, true] {
            for speakers in [false, true] {
                let values = ExportProgressValues()
                let meter = ExportProgress(microphone: microphone, speakers: speakers) { values.append($0) }
                meter.update(.models, fraction: 0)
                for stage in [ExportProgress.Stage.models, .system, .echo, .microphone, .reading, .speakers, .finalization] {
                    meter.update(stage, fraction: 1)
                }
                #expect(values.values.first == 0)
                #expect(values.values.last == 99)
                meter.finish()
                #expect(values.values.last == 100)
            }
        }
    }

    @Test func concurrentAndLateCallbacksCannotDecreaseProgress() async {
        let values = ExportProgressValues()
        let meter = ExportProgress(microphone: true, speakers: true) { values.append($0) }
        meter.update(.models, fraction: 0)
        await withTaskGroup(of: Void.self) { group in
            for stage in [ExportProgress.Stage.models, .system, .echo, .microphone, .reading, .speakers, .finalization] {
                group.addTask {
                    for step in 0...100 { meter.update(stage, fraction: Double(step) / 100) }
                    meter.update(stage, fraction: 0)
                }
            }
        }
        meter.finish()
        #expect(values.values == values.values.sorted())
        #expect(values.values.first == 0)
        #expect(values.values.last == 100)
        #expect(values.values.count <= 101)
    }
}

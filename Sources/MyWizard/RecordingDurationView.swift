import SwiftUI

enum RecordingDuration {
    static func text(startedAt: Date, now: Date) -> String {
        let elapsed = now.timeIntervalSince(startedAt)
        guard elapsed.isFinite, elapsed > 0 else { return "00:00:00" }
        let seconds = Int(min(elapsed, Double(Int.max / 2)))
        // Elapsed duration, not a clock time: hours must not wrap at midnight.
        return String(format: "%02ld:%02ld:%02ld", seconds / 3600, (seconds / 60) % 60, seconds % 60)
    }
}

struct RecordingDurationView: View {
    let startedAt: Date

    var body: some View {
        // Only this small label has a timeline; no published per-second state
        // or transcript-wide refresh is needed for an hh:mm:ss counter.
        TimelineView(.periodic(from: startedAt, by: 1)) { context in
            Text(RecordingDuration.text(startedAt: startedAt, now: context.date))
                .font(.system(.caption, design: .monospaced).weight(.medium))
                .foregroundStyle(.secondary)
                .fixedSize()
                .accessibilityLabel("Recording duration")
                .accessibilityValue(RecordingDuration.text(startedAt: startedAt, now: context.date))
                .help("Current recording duration (hours:minutes:seconds). Continues when the microphone is off.")
        }
    }
}

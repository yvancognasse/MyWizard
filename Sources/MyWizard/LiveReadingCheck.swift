import SwiftUI

// Explicit signed-app diagnostic: synthetic English text, real Apple translation
// and muted French playback. Does not capture user audio or change saved settings.
struct LiveReadingCheck: View {
    @StateObject private var model: TranscriptionModel

    init() {
        _model = StateObject(wrappedValue: TranscriptionModel(preferences: MemoryPreferences(), reader: TranscriptReader(playbackVolume: 0)))
    }

    var body: some View {
        Text("Testing continuous translation and playback…")
            .padding(24)
            .background {
                if let job = model.translationJob {
                    ReadingTranslationTask(job: job, complete: model.translationCompleted).id(job.id)
                }
            }
            .task {
                model.language = "en-US"
                model.readingLanguage = .french
                model.receiveTranscript([TimedText(text: "Old history must not be spoken.", start: 0, end: 0.2)], isFinal: true)
                model.receiveTranscript([TimedText(text: "Hello, the current passage is being translated.", start: 0.3, end: 1)], isFinal: false)
                let clickedAt = Date()
                model.beginReading(followCapture: true)
                do {
                    // Deliberately withhold the final recognition result. The
                    // first sound must not depend on Speech deciding to finalize.
                    for _ in 0..<100 {
                        if model.reader.lastPlaybackStartedAt != nil { break }
                        if model.reader.errorMessage != nil { throw ReadingError.playbackFailed }
                        try await Task.sleep(for: .milliseconds(100))
                    }
                    guard let firstSound = model.reader.lastPlaybackStartedAt else { throw ReadingError.playbackFailed }
                    print("FIRST PLAYBACK: \(firstSound.timeIntervalSince(clickedAt)) seconds from click, before any final result")
                    try await waitForBatches(1)
                    model.receiveTranscript([TimedText(text: "Hello, the current passage is being translated.", start: 0.3, end: 1)], isFinal: true)
                    guard model.translationJob == nil, !model.reader.isReading else { throw ReadingError.playbackFailed }
                    try await Task.sleep(for: .seconds(1))
                    guard model.isReadingEnabled else { throw ReadingError.playbackFailed }
                    model.receiveTranscript([TimedText(text: "This is my microphone and must stay silent.", start: 1, end: 2)], isFinal: true, source: .microphone)
                    guard model.translationJob == nil, !model.reader.isReading else { throw ReadingError.playbackFailed }
                    model.receiveTranscript([TimedText(text: "After the pause, reading resumes automatically.", start: 2, end: 3)], isFinal: true)
                    try await Task.sleep(for: .milliseconds(200))
                    model.receiveTranscript([TimedText(text: "A third sentence arrived while the second was being processed.", start: 4, end: 5)], isFinal: true)
                    try await waitForBatches(3)
                    guard model.isReadingEnabled else { throw ReadingError.playbackFailed }
                    model.stopReading()
                    model.receiveTranscript([TimedText(text: "This must not be read after stop.", start: 6, end: 7)], isFinal: true)
                    guard model.translationJob == nil, !model.reader.isReading else { throw ReadingError.playbackFailed }
                    print("LIVE READING CHECK PASS: low-latency provisional start, no final replay, 3 translated batches, microphone exclusion, idle resume, queued arrival and explicit stop")
                    exit(EXIT_SUCCESS)
                } catch {
                    print("LIVE READING CHECK FAILED: \(error); reader=\(model.reader.errorMessage ?? "none")")
                    model.stopReading()
                    exit(EXIT_FAILURE)
                }
            }
    }

    @MainActor private func waitForBatches(_ count: Int) async throws {
        for _ in 0..<600 {
            if model.completedReadingBatches >= count { return }
            if model.reader.errorMessage != nil { throw ReadingError.playbackFailed }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw ReadingError.playbackFailed
    }
}

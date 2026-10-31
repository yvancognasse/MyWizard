import SwiftUI

// Explicit signed-app diagnostic. Uses isolated preferences and an external
// synthetic speech fixture; logs timings/counts, never recognized user text.
// Audio is not saved. Its temporary text export is removed after verification.
struct PipelineCheck: View {
    @StateObject private var model: TranscriptionModel
    private let suite: String
    private let preferences: MemoryPreferences

    init() {
        let suite = "MyWizard.PipelineCheck.\(UUID())"
        self.suite = suite
        let preferences = MemoryPreferences()
        self.preferences = preferences
        _model = StateObject(wrappedValue: TranscriptionModel(preferences: preferences,
            recordingRoot: FileManager.default.temporaryDirectory.appendingPathComponent(suite)))
    }

    var body: some View {
        Text("Checking capture, transcription, translation and text export…")
            .padding(24)
            .background { PipelineTranslationHost(display: model.displayTranslation) }
            .task {
                // A stalled external service must not leave the test recording.
                let timeout = Task { @MainActor in
                    do { try await Task.sleep(for: .seconds(600)) } catch { return }
                    await model.shutDown()
                    print("PIPELINE CHECK FAILED: timeout")
                    exit(EXIT_FAILURE)
                }
                do {
                    try await run()
                    timeout.cancel()
                    await model.shutDown()
                    print("PIPELINE CHECK PASS: requested capture modes, local recognition, translated display, finalization and UTF-8 export")
                    exit(EXIT_SUCCESS)
                } catch {
                    timeout.cancel()
                    await model.shutDown()
                    print("PIPELINE CHECK FAILED: \(error)")
                    exit(EXIT_FAILURE)
                }
            }
    }

    @MainActor private func run() async throws {
        guard let fixture = ProcessInfo.processInfo.environment["MYWIZARD_PIPELINE_FIXTURE"] else {
            throw TranscriptionError.message("Set MYWIZARD_PIPELINE_FIXTURE to synthetic English speech containing 'project' and 'Friday'.")
        }
        let recordingRoot = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { try? FileManager.default.removeItem(at: recordingRoot) }
        let exporter = TranscriptExporter(preferences: preferences)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MyWizard-Pipeline-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        try exporter.setDefaultDirectory(directory)
        model.language = "en-US"
        model.displayLanguage = .french
        let duplicatesOnly = ProcessInfo.processInfo.environment["MYWIZARD_PIPELINE_DUPLICATES"] == "1"
        let modes = duplicatesOnly ? [(true, false)] : [(false, false), (true, false)]
        for (microphone, echo) in modes {
            model.clear()
            await model.setMicrophoneEnabled(microphone)
            model.cancelsMicrophoneEcho = echo
            let startup = Date()
            await model.toggleCapture()
            guard model.isCapturing else { throw TranscriptionError.message(model.errorMessage ?? "Capture failed to start") }
            let startupSeconds = Date().timeIntervalSince(startup)
            let playback = Process()
            playback.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
            playback.arguments = [fixture]
            try playback.run()
            defer { if playback.isRunning { playback.terminate() } }
            let started = Date()
            var firstText: Double?
            var firstTranslation: Double?
            while playback.isRunning {
                if firstText == nil, model.paragraphs.contains(where: { $0.source == .systemAudio && !$0.text.isEmpty }) {
                    firstText = Date().timeIntervalSince(started)
                }
                if firstTranslation == nil, model.displayTranslation.paragraphs.contains(where: { $0.source == .systemAudio && !$0.text.isEmpty }) {
                    firstTranslation = Date().timeIntervalSince(started)
                }
                if let error = model.errorMessage ?? model.displayTranslation.errorMessage {
                    throw TranscriptionError.message(error)
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            guard playback.terminationStatus == 0 else { throw TranscriptionError.message("Fixture playback failed") }
            let counts = model.capturedFrameCounts
            guard model.paragraphs.allSatisfy({ $0.source == .systemAudio }) else {
                throw TranscriptionError.message("Microphone was transcribed during live capture")
            }
            let liveBeforeStop = model.paragraphs
            let stopping = Date()
            await model.toggleCapture()
            let stopSeconds = Date().timeIntervalSince(stopping)
            guard model.needsProcessing, await model.prepareExport() else {
                throw TranscriptionError.message(model.errorMessage ?? "Recorded meeting analysis failed")
            }
            let processingSeconds = Date().timeIntervalSince(stopping) - stopSeconds
            guard model.paragraphs == liveBeforeStop else {
                throw TranscriptionError.message("Export changed the live system text or speaker labels")
            }
            guard !model.isCapturing, model.errorMessage == nil, counts.system > 0,
                  microphone ? counts.microphone > 0 : counts.microphone == 0 else {
                throw TranscriptionError.message(model.errorMessage ?? "Invalid capture frame counts")
            }
            let systemText = model.paragraphs.filter { $0.source == .systemAudio }.map(\.text).joined().lowercased()
            let raw = model.unfilteredParagraphs
            let rawMicrophoneCount = raw.filter { $0.source == .microphone }.map(\.text).joined().count
            let filteredMicrophoneCount = model.exportParagraphs.filter { $0.source == .microphone }.map(\.text).joined().count
            guard model.paragraphs.allSatisfy({ $0.source == .systemAudio }) else {
                throw TranscriptionError.message("Microphone text leaked into the display after offline analysis")
            }
            guard raw.filter({ $0.source == .systemAudio }).map(\.text).joined().lowercased() == systemText else {
                throw TranscriptionError.message("Duplicate filtering changed system speech")
            }
            print("DUPLICATE CHECK: mic=\(microphone) echo=\(echo) microphone characters raw=\(rawMicrophoneCount) exported=\(filteredMicrophoneCount)")
            if duplicatesOnly {
                guard filteredMicrophoneCount == 0 else {
                    throw TranscriptionError.message("Remote-only playback left microphone words in the export")
                }
            }
            guard systemText.contains("project"), systemText.contains("friday") else {
                throw TranscriptionError.message("Synthetic speech keywords missing from finalized system transcript")
            }
            if !microphone, model.exportParagraphs.contains(where: { $0.source == .microphone }) {
                throw TranscriptionError.message("Microphone text present while microphone is disabled")
            }
            for _ in 0..<400 where model.displayTranslation.isPending && model.displayTranslation.errorMessage == nil {
                try await Task.sleep(for: .milliseconds(50))
            }
            let translated = model.displayTranslation.paragraphs
            guard !model.displayTranslation.isPending, model.displayTranslation.errorMessage == nil,
                  translated.count == model.paragraphs.count,
                  translated.allSatisfy({ $0.language == "fr-FR" }),
                  translated.map(\.text) != model.paragraphs.map(\.text),
                  translated.map(\.speaker) == model.paragraphs.map(\.speaker),
                  firstText != nil, firstTranslation != nil else {
                throw TranscriptionError.message(model.displayTranslation.errorMessage ?? "Live translation did not complete correctly")
            }
            let export = directory.appendingPathComponent(TranscriptExporter.defaultFilename())
            try exporter.write(model.transcript, to: export)
            guard try String(contentsOf: export, encoding: .utf8) == model.transcript,
                  exporter.suggestedDirectory?.standardizedFileURL == directory.standardizedFileURL else {
                throw TranscriptionError.message("Text export round trip failed")
            }
            print("PIPELINE mic=\(microphone) speakers=\(model.detectsSpeakers): startup=\(startupSeconds)s firstText=\(firstText!)s firstTranslation=\(firstTranslation!)s stop=\(stopSeconds)s offline=\(processingSeconds)s frames=\(counts) paragraphs=\(model.paragraphs.count)")
        }
    }
}

private struct PipelineTranslationHost: View {
    @ObservedObject var display: DisplayTranslation
    var body: some View {
        if let job = display.job {
            ReadingTranslationTask(job: job, complete: display.completed).id(job.id)
        }
    }
}

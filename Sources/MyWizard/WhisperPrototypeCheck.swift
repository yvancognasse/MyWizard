import AVFoundation
import Foundation

// Explicit opt-in comparison tool. Never starts devices or modifies the input,
// the normal app's preferences, or its current recording/transcript.
enum WhisperPrototypeCheck {
    static func run() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let inputPath = environment["MYWIZARD_WHISPER_PREVIEW_AUDIO"],
              let destinationPath = environment["MYWIZARD_WHISPER_PREVIEW_OUTPUT"] else {
            throw TranscriptionError.message("Set preview audio and output folder paths.")
        }
        let input = URL(fileURLWithPath: inputPath)
        guard FileManager.default.fileExists(atPath: input.path) else { throw TranscriptionError.message("Preview input is missing.") }
        let language = environment["MYWIZARD_WHISPER_PREVIEW_LANGUAGE"] ?? "en-US"
        _ = try WhisperTranscriber.languageCode(language)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("MyWizardComparison-\(UUID())")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: temporary) }
        let destination = URL(fileURLWithPath: destinationPath).appendingPathComponent("Whisper comparison \(UUID())")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let meeting: RecordedMeeting
        if input.pathExtension == "mywizard" {
            let original = try RecordedMeeting.load(input)
            let copy = temporary.appendingPathComponent(original.id.uuidString + ".mywizard")
            try FileManager.default.copyItem(at: original.directory, to: copy)
            meeting = try RecordedMeeting.load(copy)
        } else {
            let asset = AVURLAsset(url: input)
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            let separate = environment["MYWIZARD_WHISPER_PREVIEW_LAYOUT"] == "system-microphone"
            guard tracks.count == 1 || (tracks.count == 2 && separate) else {
                throw TranscriptionError.message("Multitrack audio needs an explicit system-microphone layout. No track will be silently ignored.")
            }
            let manifest = RecordingManifest(id: UUID(), created: Date(), language: language,
                microphone: separate && tracks.count == 2, detectSpeakers: true, state: "recorded")
            let folder = temporary.appendingPathComponent(manifest.id.uuidString + ".mywizard")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            meeting = RecordedMeeting(directory: folder, manifest: manifest)
            try meeting.saveManifest()
            let ffmpeg = try ffmpegPath()
            for (index, track) in [(0, RecordedTrack.system), (1, RecordedTrack.microphone)] where index == 0 || manifest.microphone {
                try await ExportChildProcess().run(ffmpeg, arguments: ["-nostdin", "-hide_banner", "-loglevel", "error",
                    "-i", input.path, "-map", "0:a:\(index)", "-vn", "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", meeting.audio(track).path])
            }
            _ = try MeetingRecording.makeFile(meeting.audio(.reading))
        }
        print("COMPARISON: private working copy ready; normal app unchanged")
        let names = [SpeakerIdentity.microphone: UserDefaults.standard.string(forKey: "ownSpeakerName") ?? "Yvan Cognasse"]
        if environment["MYWIZARD_WHISPER_COMPARE_APPLE"] == "1" {
            let appleBegan = ContinuousClock.now
            let apple = try await MeetingProcessor().analyzeWithApple(meeting) { print("APPLE EXPORT: \($0)%") }
            var document = SpeakerTranscript()
            document.beginSession(detectsSpeakers: true, language: language, reservesOwnSpeaker: true)
            document.replaceCurrentSession(with: apple)
            try write(SpeakerTranscript.plainText(paragraphs: document.deduplicatedParagraphs, names: names),
                      to: destination.appendingPathComponent("01-MyWizard-current.txt"))
            print("APPLE ELAPSED: \(appleBegan.duration(to: .now))")
        }
        let whisperBegan = ContinuousClock.now
        let finalAnalysis = try await MeetingProcessor().analyzeMixedForComparison(meeting) { print("LEGACY MIXED EXPORT: \($0)%") }
        let whisperDuration = whisperBegan.duration(to: .now).components
        var finalDocument = SpeakerTranscript()
        finalDocument.beginSession(detectsSpeakers: true, language: language, reservesOwnSpeaker: true)
        finalDocument.replaceCurrentSession(with: finalAnalysis)
        let prototype = WhisperExportResult(engine: "MyWizard production Whisper export", words:
            (finalAnalysis.system + finalAnalysis.microphone).sorted { $0.start < $1.start },
            intervals: finalAnalysis.intervals, paragraphs: finalAnalysis.paragraphs ?? [],
            elapsedSeconds: Double(whisperDuration.seconds) + Double(whisperDuration.attoseconds) / 1e18)
        try write(finalDocument.plainText(names: names), to: destination.appendingPathComponent("05-Production-export.txt"))
        try write(prototype.text(names: names), to: destination.appendingPathComponent("03-Whisper-speakers.txt"))
        try write(prototype.words.map(\.text).joined() + "\n", to: destination.appendingPathComponent("02-Whisper-text.txt"))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(prototype).write(to: destination.appendingPathComponent("alignment.json"), options: .withoutOverwriting)
        if meeting.manifest.microphone {
            // A view of the single transcript, not a second ASR stream.
            let words = prototype.words.filter { $0.source == .systemAudio }
            try write(words.map(\.text).joined() + "\n", to: destination.appendingPathComponent("04-Whisper-remote-voices.txt"))
        }
        print("WHISPER ELAPSED: \(prototype.elapsedSeconds) seconds")
        print("COMPARISON SAVED: \(destination.path)")
    }

    private static func write(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url, options: .withoutOverwriting)
    }

    private static func print(_ message: String) {
        FileHandle.standardOutput.write(Data((message + "\n").utf8))
    }

    private static func ffmpegPath() throws -> URL {
        for path in ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"] where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        throw TranscriptionError.message("ffmpeg is required to import the comparison MP4.")
    }
}

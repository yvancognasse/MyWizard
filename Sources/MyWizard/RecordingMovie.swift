@preconcurrency import AVFoundation

// MP4 with distinct AAC tracks, never a mixed-down audio export. The lossless
// synchronized CAF originals remain the analysis/recovery source of truth.
enum RecordingMovie {
    static func write(_ meeting: RecordedMeeting) async throws {
        let url = meeting.directory.appendingPathComponent("meeting.mp4")
        if FileManager.default.fileExists(atPath: url.path) { return }
        let temporary = meeting.directory.appendingPathComponent("movie-\(UUID()).mp4")
        let writer = try AVAssetWriter(outputURL: temporary, fileType: .mp4)
        var inputs: [(AVAssetWriterInput, AVAssetReader, AVAssetReaderTrackOutput)] = []
        for source in RecordedTrack.allCases where source != .microphone || meeting.manifest.microphone {
            let asset = AVURLAsset(url: meeting.audio(source))
            guard let track = try await asset.loadTracks(withMediaType: .audio).first,
                  try await asset.load(.duration).seconds > 0 else { continue }
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMIsFloatKey: true, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsNonInterleaved: false])
            reader.add(output)
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64000])
            let title = AVMutableMetadataItem()
            title.identifier = .commonIdentifierTitle
            title.value = source.rawValue as NSString
            input.metadata = [title]
            guard writer.canAdd(input) else { throw TranscriptionError.message("Cannot create a separate MP4 audio track.") }
            writer.add(input)
            inputs.append((input, reader, output))
        }
        guard !inputs.isEmpty, writer.startWriting() else {
            throw writer.error ?? TranscriptionError.message("Cannot create the MP4 archive.")
        }
        writer.startSession(atSourceTime: .zero)
        do {
            for (_, reader, _) in inputs where !reader.startReading() {
                throw reader.error ?? TranscriptionError.message("Cannot read a recorded audio track.")
            }
            var finished = Set<Int>()
            var lastProgress = Date()
            while finished.count < inputs.count {
                try Task.checkCancellation()
                var progressed = false
                for (index, item) in inputs.enumerated() where !finished.contains(index) {
                    let (input, reader, output) = item
                    guard input.isReadyForMoreMediaData else { continue }
                    if let buffer = output.copyNextSampleBuffer() {
                        guard input.append(buffer) else { throw writer.error ?? TranscriptionError.message("MP4 encoding failed.") }
                    } else {
                        guard reader.status == .completed else { throw reader.error ?? TranscriptionError.message("A recorded track could not be read completely.") }
                        input.markAsFinished(); finished.insert(index)
                    }
                    progressed = true
                }
                if progressed { lastProgress = Date() }
                else {
                    guard writer.status == .writing, Date().timeIntervalSince(lastProgress) < 30 else {
                        throw writer.error ?? TranscriptionError.message("MP4 encoding stalled. The original tracks are preserved.")
                    }
                    try await Task.sleep(for: .milliseconds(5))
                }
            }
            await writer.finishWriting()
            guard writer.status == .completed else { throw writer.error ?? TranscriptionError.message("MP4 finalization failed.") }
            try FileManager.default.moveItem(at: temporary, to: url)
        } catch {
            writer.cancelWriting()
            for (_, reader, _) in inputs { reader.cancelReading() }
            // Only this invocation's incomplete derived file is disposable.
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }
}

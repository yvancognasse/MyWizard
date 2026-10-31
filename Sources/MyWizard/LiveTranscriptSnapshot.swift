import Foundation

struct LiveTranscriptBlock: Codable, Sendable {
    var text: String
    let speaker: Int?
    let start: Double
    var end: Double
}

struct LiveTranscriptSnapshot: Codable, Sendable {
    let words: [TimedText]
    let blocks: [LiveTranscriptBlock]
    let display: [TranscriptParagraph]
    let intervals: [SpeakerInterval]
    let speakerNumbers: [Int: Int]
    let names: [Int: String]
    var calendarMeeting: CalendarMeeting? = nil
    var codexProject: CodexProject? = nil

    func addingMicrophone(_ words: [TimedText], echoEvidence: EchoReductionResult? = nil,
                          systemActivity: ExportAudioActivity? = nil) -> MeetingAnalysis {
        // Match complete recognition phrases BEFORE the acoustic evidence removes
        // individual tokens. Otherwise those gaps destroy matching anchors and
        // leave remote-word fragments attributed to the microphone owner.
        // Only the microphone is filtered. The live system text is immutable.
        let withoutTextEcho = MicrophoneDuplicateFilter.microphone(words, excludingEchoOf: self.words,
            matchesCompactPassages: true)
        let acousticFiltered = echoEvidence?.removingEchoArtifacts(from: withoutTextEcho, reference: self.words) ?? withoutTextEcho
        let own = MicrophoneEchoContext.filter(acousticFiltered, recognition: words, reference: self.words,
            frames: echoEvidence?.contextFrames ?? [])
        var microphoneBlocks: [LiveTranscriptBlock] = []
        for word in own.sorted(by: { $0.start < $1.start }) {
            let previous = microphoneBlocks.last
            let sentenceEnded = previous?.text.trimmingCharacters(in: .whitespacesAndNewlines).last
                .map { ".!?…".contains($0) } ?? false
            if let previous, word.start - previous.end < 0.8, !sentenceEnded {
                microphoneBlocks[microphoneBlocks.count - 1].text += word.text
                microphoneBlocks[microphoneBlocks.count - 1].end = max(previous.end, word.end)
            } else {
                microphoneBlocks.append(.init(text: word.text, speaker: SpeakerIdentity.microphone,
                    start: word.start, end: word.end))
            }
        }
        // Stable ordering: retain the original order for tied timestamps, with
        // the live system block first. Overlap never deletes an intervention.
        let systemBlocks = ExportParagraphPolish.resolve(blocks, intervals: intervals, numbers: speakerNumbers, activity: systemActivity)
        let merged = (systemBlocks + microphoneBlocks).enumerated().sorted {
            $0.element.start == $1.element.start ? $0.offset < $1.offset : $0.element.start < $1.element.start
        }.map(\.element)
        return MeetingAnalysis(system: self.words, microphone: own, intervals: intervals,
            speakerNumbers: speakerNumbers, paragraphs: ExportParagraphPolish.coalesce(merged), liveSystemParagraphs: display)
    }
}

extension RecordedMeeting {
    func saveLiveTranscript(_ snapshot: LiveTranscriptSnapshot) throws {
        try JSONEncoder().encode(snapshot).write(to: directory.appendingPathComponent("live-transcript.json"), options: .atomic)
    }

    func loadLiveTranscript() throws -> LiveTranscriptSnapshot {
        let url = directory.appendingPathComponent("live-transcript.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw TranscriptionError.message("This recording has no saved live transcript. It cannot use live-text export; the original audio has been preserved.")
        }
        return try JSONDecoder().decode(LiveTranscriptSnapshot.self, from: Data(contentsOf: url))
    }
}

import Foundation

// Playback-only voice choice. Never writes inferred identities into the live
// transcript, saved snapshot, or export.
struct ReadingVoiceContinuity {
    private(set) var lastKnownSpeaker: Int?

    mutating func prepare(_ paragraph: TranscriptParagraph,
                          next: TranscriptParagraph?) -> TranscriptParagraph {
        guard paragraph.source == .systemAudio else { return paragraph }
        if let speaker = paragraph.speaker {
            lastKnownSpeaker = speaker
            return paragraph
        }
        let text = paragraph.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 28,
              text.split(whereSeparator: \.isWhitespace).count <= 3 else { return paragraph }
        let following = next?.speaker
        // When the queue already shows a speaker change, leave the fragment
        // neutral: a short reply may belong to either person.
        guard following == nil || lastKnownSpeaker == nil || following == lastKnownSpeaker,
              let voice = following ?? lastKnownSpeaker else { return paragraph }
        return TranscriptParagraph(id: paragraph.id, text: paragraph.text,
            speaker: voice, hasSpeakerLabel: paragraph.hasSpeakerLabel,
            language: paragraph.language, source: paragraph.source)
    }
}

enum LiveSpeakerPresentation {
    static func smooth(_ paragraphs: [TranscriptParagraph]) -> [TranscriptParagraph] {
        guard paragraphs.count >= 3 else { return paragraphs }
        var result = paragraphs
        for index in 1..<(paragraphs.count - 1) {
            let fragment = paragraphs[index]
            guard fragment.source == .systemAudio, fragment.speaker == nil,
                  let speaker = paragraphs[index - 1].speaker,
                  speaker == paragraphs[index + 1].speaker,
                  paragraphs[index - 1].source == .systemAudio,
                  paragraphs[index + 1].source == .systemAudio else { continue }
            let text = fragment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, text.count <= 28,
                  text.split(whereSeparator: \.isWhitespace).count <= 3 else { continue }
            result[index] = TranscriptParagraph(id: fragment.id, text: fragment.text,
                speaker: speaker, hasSpeakerLabel: fragment.hasSpeakerLabel,
                language: fragment.language, source: fragment.source)
        }
        return result
    }
}

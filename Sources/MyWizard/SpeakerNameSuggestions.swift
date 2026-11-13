import Foundation

// Match names, never infer attendance or train a profile from an invitation.
// Both directions must have a unique best match; two people with the same first
// name therefore do not acquire an arbitrary voice profile.
struct ParticipantVoiceLinks {
    let participantByVoiceID: [UUID: String]
    let voiceIDByParticipantKey: [String: UUID]

    init(participants: [String], voices: [RememberedVoice]) {
        let participants = CalendarMeeting.names(participants)
        let scores = participants.map { participant in
            voices.map { Self.score(participant, $0.name) }
        }
        var names: [UUID: String] = [:]
        var ids: [String: UUID] = [:]
        for (person, participant) in participants.enumerated() {
            guard let best = scores[person].max(), best > 0 else { continue }
            let candidates = voices.indices.filter { scores[person][$0] == best }
            guard candidates.count == 1, let voice = candidates.first else { continue }
            let competing = participants.indices.filter { scores[$0][voice] >= best }
            guard competing.count == 1 else { continue }
            names[voices[voice].id] = participant
            ids[VoiceMemory.nameKey(participant)] = voices[voice].id
        }
        participantByVoiceID = names
        voiceIDByParticipantKey = ids
    }

    private static func score(_ a: String, _ b: String) -> Int {
        let a = VoiceMemory.nameKey(a), b = VoiceMemory.nameKey(b)
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        if a == b { return 3 }
        // Email addresses only match exactly, never through their local part.
        guard !a.contains("@"), !b.contains("@") else { return 0 }
        let first = a.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        let second = b.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        guard !first.isEmpty, !second.isEmpty else { return 0 }
        if first.sorted() == second.sorted() { return 2 } // Surname, given name.
        let short = first.count < second.count ? first : second
        let long = first.count < second.count ? second : first
        if short.count < long.count, short.allSatisfy({ $0.count >= 3 }), Set(short).isSubset(of: Set(long)) { return 1 }
        return 0
    }
}

enum SpeakerNameSuggestions {
    static func completion(for prefix: String, names: [String]) -> String? {
        guard !prefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return CalendarMeeting.names(names).first {
            $0.range(of: prefix, options: [.anchored, .caseInsensitive, .diacriticInsensitive]) != nil
        }
    }
}

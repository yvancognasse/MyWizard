import Foundation

// Serialize background disk writes; a late periodic snapshot can never replace
// the authoritative Stop snapshot. Each recording owns a separate writer.
actor TranscriptAutosave {
    let directory: URL
    private var closed = false
    private var savedRevision: Revision?

    private struct Revision: Equatable {
        let document: UInt64
        let metadata: UInt64
    }

    init(directory: URL) { self.directory = directory }

    func save(_ snapshot: LiveTranscriptSnapshot) throws {
        guard !closed else { return }
        try write(snapshot)
        savedRevision = nil
    }

    // Build expensive paragraph/block snapshots here, away from MainActor.
    // Mark a revision saved only after a successful write, so disk errors retry.
    func save(document: SpeakerTranscript, names: [Int: String], calendarMeeting: CalendarMeeting?,
              codexProject: CodexProject?, metadataRevision: UInt64) throws {
        guard !closed else { return }
        let revision = Revision(document: document.revision, metadata: metadataRevision)
        guard savedRevision != revision else { return }
        var snapshot = document.liveSnapshot(names: names)
        snapshot.calendarMeeting = calendarMeeting
        snapshot.codexProject = codexProject
        try write(snapshot)
        savedRevision = revision
    }

    func finish(_ snapshot: LiveTranscriptSnapshot) throws {
        closed = true
        try write(snapshot)
    }

    private func write(_ snapshot: LiveTranscriptSnapshot) throws {
        try JSONEncoder().encode(snapshot).write(to: directory.appendingPathComponent("live-transcript.json"), options: .atomic)
    }
}

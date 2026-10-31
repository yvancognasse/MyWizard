import Foundation

enum RecordingCleanup {
    struct Result {
        var removed = Set<UUID>()
        var failures: [String] = []
    }

    // Called only after a successful TXT write. Snapshot the exported sessions,
    // validate each exact folder, and never sweep the library or a parent folder.
    static func afterExport(_ recordings: [RecordedMeeting],
                            remove: (URL) throws -> Void = {
                                try FileManager.default.trashItem(at: $0, resultingItemURL: nil)
                            }) -> Result {
        var result = Result()
        for recording in recordings where !result.removed.contains(recording.id) {
            do {
                let validated = try RecordedMeeting.load(recording.directory)
                guard validated.id == recording.id else {
                    throw TranscriptionError.message("Recording identity changed.")
                }
                try remove(validated.directory)
                result.removed.insert(validated.id)
            } catch {
                result.failures.append("\(recording.directory.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return result
    }
}

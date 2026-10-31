import Foundation
import CryptoKit
import Darwin

struct ExportCheckpoint: Codable {
    // Increment when recognition, echo reduction or assembly behavior changes.
    static let revision = 3
    static let currentAssemblyRevision = 2
    let key: String
    var cleanedStamp: FileStamp?
    var echoOnly: [AudioEchoInterval]?
    var contextFrames: [MicrophoneEchoFrame]?
    var activity: ExportAudioActivity?
    var microphone: [TimedText]?
    var snapshotKey: String?
    var assembledRevision: Int?
    var analysis: MeetingAnalysis?

    struct FileStamp: Codable, Equatable {
        let size: UInt64
        let modified: Date
        let created: Date
        let inode: UInt64
        let changedSeconds: Int64
        let changedNanoseconds: Int64

        static func read(_ url: URL) throws -> FileStamp? {
            let attributes: [FileAttributeKey: Any]
            do { attributes = try FileManager.default.attributesOfItem(atPath: url.path) }
            catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                throw TranscriptionError.message("Export checkpoint files must be regular files.")
            }
            var info = stat()
            guard lstat(url.path, &info) == 0 else { throw TranscriptionError.message("Cannot validate export inputs.") }
            return FileStamp(size: (attributes[.size] as? NSNumber)?.uint64Value ?? 0,
                modified: attributes[.modificationDate] as? Date ?? .distantPast,
                created: attributes[.creationDate] as? Date ?? .distantPast,
                inode: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0,
                changedSeconds: Int64(info.st_ctimespec.tv_sec), changedNanoseconds: Int64(info.st_ctimespec.tv_nsec))
        }
    }

    private struct Inputs: Encodable {
        let revision: Int
        let id: UUID
        let language: String
        let microphone: Bool
        let muteEvents: [AudioMuteEvent]
        let tracks: [FileStamp?]
    }

    static func digest<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(value)).map { String(format: "%02x", $0) }.joined()
    }

    static func inputKey(_ meeting: RecordedMeeting) throws -> String {
        try digest(Inputs(revision: revision, id: meeting.id, language: meeting.manifest.language,
            microphone: meeting.manifest.microphone, muteEvents: meeting.manifest.mutedSystem,
            tracks: try RecordedTrack.allCases.map { try FileStamp.read(meeting.audio($0)) }))
    }

    static func load(_ meeting: RecordedMeeting, key: String) -> ExportCheckpoint {
        let url = meeting.directory.appendingPathComponent("export-checkpoint.json")
        guard (try? FileStamp.read(url)) != nil,
              let data = try? Data(contentsOf: url), let cached = try? JSONDecoder().decode(Self.self, from: data),
              cached.key == key else { return ExportCheckpoint(key: key) }
        return cached
    }

    func echo(for meeting: RecordedMeeting) -> EchoReductionResult? {
        let url = meeting.directory.appendingPathComponent("microphone-cleaned.caf")
        guard let cleanedStamp, let echoOnly, (try? FileStamp.read(url)) == cleanedStamp else { return nil }
        return EchoReductionResult(audio: url, echoOnly: echoOnly, systemActivity: activity, contextFrames: contextFrames ?? [])
    }

    func save(_ meeting: RecordedMeeting) throws {
        let url = meeting.directory.appendingPathComponent("export-checkpoint.json")
        _ = try Self.FileStamp.read(url) // Reject a substituted symlink before writing.
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}

import Foundation
import Testing
@testable import MyWizard

struct TranscriptExporterTests {
    @Test @MainActor func openFolderUsesConfiguredDestinationAndReportsMissingFolderOrFinderFailure() throws {
        let suite = "MyWizardTests.OpenFolder.\(UUID())"
        let preferences = MemoryPreferences()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let chosen = root.appendingPathComponent("Chosen")
        try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        preferences.set(root.path, forKey: "lastTranscriptDirectory")
        let exporter = TranscriptExporter(preferences: preferences)
        try exporter.setDefaultDirectory(chosen)
        var opened: URL?
        exporter.openExportDirectory { opened = $0; return true }
        #expect(opened?.path == chosen.path)
        #expect(exporter.errorMessage == nil)
        exporter.openExportDirectory { _ in false }
        #expect(exporter.errorMessage != nil)
        try FileManager.default.removeItem(at: chosen)
        opened = nil
        exporter.openExportDirectory { opened = $0; return true }
        #expect(opened == nil)
        #expect(exporter.errorMessage != nil)
        try exporter.setDefaultDirectory(nil)
        exporter.openExportDirectory { opened = $0; return true }
        #expect(opened?.path == root.path)
        #expect(exporter.errorMessage == nil)
    }

    @Test @MainActor func completionUsesOnlyTextFilesInExportFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MyWizard.Completion.\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["Meeting Alpha.txt", "Meeting Beta.TXT", "Équipe.txt", "image.png", ".hidden.txt"] {
            try Data("fixture".utf8).write(to: root.appendingPathComponent(name))
        }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Folder.txt"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Link.txt"), withDestinationURL: root.appendingPathComponent("Meeting Alpha.txt"))
        let names = try TranscriptExporter.existingFilenames(in: root)
        #expect(Set(names) == Set(["Meeting Alpha.txt", "Meeting Beta.TXT", "Équipe.txt"]))
        #expect(TranscriptSavePrompt.completion(for: "meeting a", filenames: names) == "Meeting Alpha.txt")
        #expect(TranscriptSavePrompt.completion(for: "Equ", filenames: names) == "Équipe.txt")
        #expect(TranscriptSavePrompt.completion(for: "New", filenames: names) == nil)
        #expect(TranscriptSavePrompt.completion(for: "", filenames: names) == nil)
    }

    @Test @MainActor func filenameStaysInsideExportFolderAndAddsTextExtension() throws {
        #expect(try TranscriptExporter.validatedFilename("  New meeting  ") == "New meeting.txt")
        #expect(try TranscriptExporter.validatedFilename("Existing.TXT") == "Existing.TXT")
        for name in ["", " ", ".", "..", "../notes", "/tmp/notes", "sub/file", "bad:name", ".hidden", "bad\nname"] {
            #expect(throws: (any Error).self) { try TranscriptExporter.validatedFilename(name) }
        }
    }

    @Test @MainActor func configuredFolderPersistsAndOverridesOneOffSaveLocation() throws {
        let suite = "MyWizardTests.ExportFolder.\(UUID())"
        let prefs = MemoryPreferences()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        let chosen = root.appendingPathComponent("Chosen", isDirectory: true)
        let other = root.appendingPathComponent("Other", isDirectory: true)
        try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let exporter = TranscriptExporter(preferences: prefs)
        try exporter.setDefaultDirectory(chosen)
        try exporter.write("Meeting notes", to: other.appendingPathComponent("notes.txt"))
        let restored = TranscriptExporter(preferences: prefs)
        #expect(restored.suggestedDirectory?.path == chosen.path)
        #expect(restored.lastDirectory?.path == other.path)
        #expect(throws: (any Error).self) { try restored.setDefaultDirectory(root.appendingPathComponent("missing")) }
        #expect(restored.defaultDirectoryPath == chosen.path)
        try FileManager.default.removeItem(at: chosen)
        restored.save("Preserved transcript")
        #expect(restored.errorMessage != nil)
        #expect(!restored.isPresenting)
        try restored.setDefaultDirectory(nil)
        #expect(TranscriptExporter(preferences: prefs).defaultDirectoryPath == nil)
        #expect(restored.suggestedDirectory?.path == other.path)
    }

    @Test @MainActor func filenameUsesEnglishMonthAndLocal24HourTime() throws {
        let date = try #require(ISO8601DateFormatter().date(from: "2026-09-30T21:24:34Z"))
        let paris = try #require(TimeZone(identifier: "Europe/Paris"))
        #expect(TranscriptExporter.defaultFilename(for: date, timeZone: paris)
            == "Meeting Notes on 30 September 2026 23h24.txt")
        let winter = try #require(ISO8601DateFormatter().date(from: "2026-01-03T08:04:59Z"))
        #expect(TranscriptExporter.defaultFilename(for: winter, timeZone: paris)
            == "Meeting Notes on 3 January 2026 09h04.txt")
    }

    @Test @MainActor
    func writesUTF8AndRestoresLastSuccessfulDirectory() throws {
        let suite = "MyWizardTests.Export.\(UUID().uuidString)"
        let preferences = MemoryPreferences()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(suite, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let exporter = TranscriptExporter(preferences: preferences)
        #expect(exporter.lastDirectory == nil)
        let text = "Texte transcrit : français, été, cœur.\nEnglish text. 🪄"
        let file = directory.appendingPathComponent("transcription.txt")
        try exporter.write(text, to: file)
        #expect(try String(contentsOf: file, encoding: .utf8) == text)
        let restored = TranscriptExporter(preferences: preferences)
        #expect(restored.lastDirectory?.path == directory.path)
        #expect(throws: (any Error).self) {
            try restored.write(text, to: directory.appendingPathComponent("missing/file.txt"))
        }
        #expect(restored.lastDirectory?.path == directory.path)
        preferences.set(directory.appendingPathComponent("removed").path,
                        forKey: "lastTranscriptDirectory")
        #expect(restored.lastDirectory == nil)
    }
}

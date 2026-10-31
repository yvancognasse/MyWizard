import Foundation
import Testing
@testable import MyWizard

struct CodexProjectTests {
    @Test func catalogUsesProjectIdentityAndFirstRoot() throws {
        let data = Data(#"{"local-projects":{"b":{"name":"Zoo","rootPaths":[]},"a":{"name":"Alpha","rootPaths":["/tmp/one","/tmp/two"]},"bad":42},"unrelated":"ignored"}"#.utf8)
        let projects = try CodexProjectCatalog.parse(data)
        #expect(projects.map(\.id) == ["a", "b"])
        #expect(projects[0].path == "/tmp/one")
        #expect(projects[1].directory == nil)
        #expect(throws: (any Error).self) { try CodexProjectCatalog.parse(Data("{}".utf8)) }
    }

    @Test @MainActor func copiesWithoutChangingOriginalOrReplacingNotes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Meeting.txt")
        let projectRoot = root.appendingPathComponent("Project")
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: false)
        try "Original speech é 中文".write(to: source, atomically: true, encoding: .utf8)
        let project = CodexProject(id: "p", name: "Project", path: projectRoot.path)
        let first = try CodexProjectExport.copy(source, to: project)
        let second = try CodexProjectExport.copy(source, to: project)
        #expect(first.lastPathComponent == "Meeting.txt")
        #expect(second.lastPathComponent == "Meeting (2).txt")
        #expect(try Data(contentsOf: first) == Data(contentsOf: source))
        #expect(try Data(contentsOf: second) == Data(contentsOf: source))
        // Primary export may itself already be inside the selected Notes folder.
        #expect(try CodexProjectExport.copy(first, to: project) == first)
        #expect(try FileManager.default.contentsOfDirectory(atPath: first.deletingLastPathComponent().path).count == 2)
    }

    @Test @MainActor func failedCopyKeepsPrimaryAndCanRetry() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Meeting.txt")
        try "Keep me".write(to: source, atomically: true, encoding: .utf8)
        let projectRoot = root.appendingPathComponent("Offline")
        let export = CodexProjectExport()
        export.add(source, to: CodexProject(id: "p", name: "Offline", path: projectRoot.path))
        #expect(export.pendingSource == source)
        #expect(export.completedProject == nil)
        export.dismissCompletedCopy()
        #expect(export.pendingSource == source)
        #expect(export.pendingProject?.id == "p")
        #expect(export.summary == "Project copy failed: Offline")
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(!FileManager.default.fileExists(atPath: projectRoot.path))
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: false)
        export.retry()
        #expect(export.pendingSource == nil)
        #expect(try String(contentsOf: projectRoot.appendingPathComponent("Notes/Meeting.txt"), encoding: .utf8) == "Keep me")
        #expect(export.summary == "Export copied to Offline")
        #expect(export.completedProject?.id == "p")
        #expect(export.pendingProject == nil)
        export.dismissCompletedCopy()
        #expect(export.message == nil)
        #expect(export.summary == nil)
        #expect(export.pendingProject == nil)
        #expect(export.completedProject == nil)
    }

    @Test @MainActor func rejectsNotesLinkOutsideProject() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("Project")
        let outside = root.appendingPathComponent("Outside")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: project.appendingPathComponent("Notes"), withDestinationURL: outside)
        let source = root.appendingPathComponent("a.txt")
        try "text".write(to: source, atomically: true, encoding: .utf8)
        #expect(throws: (any Error).self) {
            try CodexProjectExport.copy(source, to: CodexProject(id: "p", name: "p", path: project.path))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    @Test func snapshotSupportsOldAndNewProjectSelection() throws {
        let old = Data(#"{"words":[],"blocks":[],"display":[],"intervals":[],"speakerNumbers":{},"names":{}}"#.utf8)
        var snapshot = try JSONDecoder().decode(LiveTranscriptSnapshot.self, from: old)
        #expect(snapshot.codexProject == nil)
        snapshot.codexProject = CodexProject(id: "p", name: "Project", path: "/tmp/project")
        let loaded = try JSONDecoder().decode(LiveTranscriptSnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(loaded.codexProject == snapshot.codexProject)
    }

    @Test func englishHelpLoadsAndFindsProjectWorkflow() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("App/Help/guide.json")
        let guide = try JSONDecoder().decode(HelpGuide.self, from: Data(contentsOf: url))
        let appInfo = try #require(PropertyListSerialization.propertyList(
            from: Data(contentsOf: url.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Info.plist")), format: nil) as? [String: Any])
        #expect(guide.reviewedVersion == appInfo["CFBundleShortVersionString"] as? String)
        #expect(guide.sections.contains { $0.id == "export" && $0.matches("codex project") })
        #expect(guide.sections.contains { $0.matches("Retry project copy") })
        #expect(guide.sections.contains { $0.id == "export" && $0.matches("Open in Codex") })
    }

    @Test func registrationUsesDesktopCatalogAndEncodesFolderSafely() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MyWizard registration # & é " + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try CodexProjectRegistration.deepLink(for: root)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.scheme == "codex")
        #expect(components.host == "new")
        #expect(components.queryItems == [URLQueryItem(name: "path", value: root.standardizedFileURL.path)])
        // An app-server-only project cannot be reported as desktop-registered.
        #expect(CodexProjectRegistration.registeredProject(for: root, catalog: []) == nil)
        let desktopProject = CodexProject(id: "desktop-id", name: "Folder name", path: root.path)
        #expect(CodexProjectRegistration.registeredProject(for: root, catalog: [desktopProject]) == desktopProject)
        let openLink = try CodexProjectRegistration.deepLink(for: desktopProject)
        let openComponents = try #require(URLComponents(url: openLink, resolvingAgainstBaseURL: false))
        #expect(openComponents.host == "new")
        #expect(openComponents.queryItems == [URLQueryItem(name: "path", value: root.standardizedFileURL.path),
                                              URLQueryItem(name: "projectId", value: desktopProject.id)])
        #expect(!openComponents.queryItems!.contains { $0.name == "prompt" })
        #expect(throws: (any Error).self) {
            try CodexProjectRegistration.deepLink(for: root.appendingPathComponent("missing"))
        }
    }
}

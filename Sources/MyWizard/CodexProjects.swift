import Foundation
import SwiftUI

struct CodexProject: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let path: String?

    var directory: URL? {
        guard let path, path.hasPrefix("/"), !path.contains("/.chatgpt-projects/") else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    var isAvailable: Bool {
        guard let directory else { return false }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}

enum CodexProjectCatalog {
    static var stateURL: URL {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
        return home.appendingPathComponent(".codex-global-state.json")
    }

    static func load(from url: URL = stateURL) throws -> [CodexProject] {
        try parse(Data(contentsOf: url))
    }

    static func parse(_ data: Data) throws -> [CodexProject] {
        // Read only the desktop's local project catalog. Never modify Codex state.
        guard let state = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let local = state["local-projects"] as? [String: Any] else {
            throw TranscriptionError.message("Codex's local project list could not be read. Open Codex and refresh. Its storage format may have changed.")
        }
        return local.compactMap { id, value -> CodexProject? in
            guard let project = value as? [String: Any], let name = project["name"] as? String,
                  !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return CodexProject(id: id, name: name, path: (project["rootPaths"] as? [String])?.first)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

@MainActor
final class CodexProjectExport: ObservableObject {
    @Published private(set) var pendingSource: URL?
    @Published private(set) var pendingProject: CodexProject?
    @Published private(set) var message: String?
    @Published private(set) var summary: String?
    @Published private(set) var completedProject: CodexProject?

    func add(_ source: URL, to project: CodexProject) {
        completedProject = nil
        pendingSource = source
        pendingProject = project
        retry()
    }

    func retry() {
        guard let source = pendingSource, let project = pendingProject else { return }
        do {
            let destination = try Self.copy(source, to: project)
            message = "Also saved to \(project.name): \(destination.lastPathComponent)"
            summary = "Export copied to \(project.name)"
            completedProject = project
            pendingSource = nil
            pendingProject = nil
        } catch {
            message = "TXT saved in your export folder. Copy to \(project.name) failed: \(error.localizedDescription)"
            summary = "Project copy failed: \(project.name)"
        }
    }

    func dismiss() { pendingSource = nil; pendingProject = nil; message = nil; summary = nil; completedProject = nil }

    func dismissCompletedCopy() {
        guard pendingSource == nil else { return }
        dismiss()
    }

    static func copy(_ source: URL, to project: CodexProject) throws -> URL {
        guard project.isAvailable, let root = project.directory else {
            throw TranscriptionError.message("The project folder is unavailable. Reconnect it and retry.")
        }
        let folder = root.appendingPathComponent("Notes", isDirectory: true)
        // Do not follow an existing Notes link outside the selected project.
        guard folder.resolvingSymlinksInPath().deletingLastPathComponent() == root.resolvingSymlinksInPath() else {
            throw TranscriptionError.message("The project's Notes folder points outside the project. Choose a regular Notes folder.")
        }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw TranscriptionError.message("The project already contains a file named Notes. Use a Notes folder, then retry.")
            }
        } else {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        }
        let stem = source.deletingPathExtension().lastPathComponent
        for index in 1...10_000 {
            let name = index == 1 ? source.lastPathComponent : "\(stem) (\(index)).\(source.pathExtension)"
            let destination = folder.appendingPathComponent(name)
            if destination.resolvingSymlinksInPath() == source.resolvingSymlinksInPath() { return source }
            do {
                // copyItem fails if the destination exists; it never replaces a note.
                try FileManager.default.copyItem(at: source, to: destination)
                return destination
            } catch CocoaError.fileWriteFileExists { continue }
        }
        throw TranscriptionError.message("Too many notes share this filename. Rename the export and retry.")
    }
}

struct CodexProjectPicker: View {
    @ObservedObject var model: TranscriptionModel
    @Environment(\.dismiss) private var dismiss
    @State private var projects: [CodexProject] = []
    @State private var query = ""
    @State private var error: String?
    @State private var refreshID = UUID()
    @State private var isLoading = true
    @State private var showsAddProject = false
    private let projectColors: [Color] = [.blue, .teal, .purple, .orange, .pink, .indigo]

    private var visibleProjects: [(offset: Int, element: CodexProject)] {
        Array(projects.enumerated()).filter { query.isEmpty || $0.element.name.localizedStandardContains(query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Choose a Codex project").font(.headline).accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Add project…") { showsAddProject = true }.disabled(isLoading)
                Button("Refresh") { refreshID = UUID() }.disabled(isLoading)
            }
            Text("Keep your usual TXT export and add a copy to the selected project's Notes folder. Local projects on this Mac only; no chat is created.")
                .font(.caption).foregroundStyle(.secondary)
            TextField("Search projects", text: $query).textFieldStyle(.roundedBorder)
            if isLoading { ProgressView("Reading Codex projects…") }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(visibleProjects, id: \.element.id) { index, project in
                        let color = projectColors[index % projectColors.count]
                        Button {
                            model.codexProject = project
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Label(project.name, systemImage: model.codexProject?.id == project.id ? "checkmark.circle.fill" : "folder")
                                Text(project.path ?? "No local folder attached")
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                if !project.isAvailable { Text("Folder unavailable").font(.caption).foregroundStyle(.secondary) }
                            }
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12).padding(.leading, 6)
                            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                            .overlay {
                                RoundedRectangle(cornerRadius: 8).strokeBorder(color.opacity(0.35), lineWidth: 1)
                            }
                            .overlay(alignment: .leading) {
                                Capsule().fill(color).frame(width: 4).padding(.vertical, 10).padding(.leading, 7)
                                    .accessibilityHidden(true)
                            }
                        }.buttonStyle(.plain).disabled(!project.isAvailable)
                    }
                    if !isLoading && projects.isEmpty && error == nil {
                        Text("No local projects found. Add a project folder in Codex, then refresh.")
                    }
                }
            }
            HStack {
                if model.codexProject != nil {
                    Button("Remove project") { model.codexProject = nil; dismiss() }
                }
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }.padding(20).frame(width: 560, height: 480)
        .sheet(isPresented: $showsAddProject) {
            AddCodexProject { project in
                model.codexProject = project
                projects.removeAll { $0.id == project.id }
                projects.append(project)
                projects.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                query = project.name
            }
        }
        .task(id: refreshID) {
            isLoading = true
            defer { isLoading = false }
            do {
                projects = try await Task.detached(priority: .userInitiated) { try CodexProjectCatalog.load() }.value
                error = nil
            } catch {
                projects = []
                self.error = "Cannot read Codex projects: \(error.localizedDescription)"
            }
        }
    }
}

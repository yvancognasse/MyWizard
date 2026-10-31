import AppKit
import SwiftUI
import Foundation

// Registration must go through the desktop application: app-server project/create
// alone does not update the desktop's project cache or folder-consent workflow.
enum CodexProjectRegistration {
    static func deepLink(for project: CodexProject) throws -> URL {
        guard let directory = project.directory else {
            throw TranscriptionError.message("The project folder is unavailable. Reconnect it and try again.")
        }
        let folderLink = try deepLink(for: directory)
        guard var link = URLComponents(url: folderLink, resolvingAgainstBaseURL: false) else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        link.queryItems?.append(URLQueryItem(name: "projectId", value: project.id))
        guard let url = link.url else { throw CocoaError(.fileReadInvalidFileName) }
        return url
    }

    static func deepLink(for directory: URL) throws -> URL {
        guard directory.isFileURL,
              CodexProject(id: "", name: "", path: directory.path).isAvailable else {
            throw TranscriptionError.message("Choose an available local folder for the project.")
        }
        var link = URLComponents()
        link.scheme = "codex"
        link.host = "new"
        link.queryItems = [URLQueryItem(name: "path", value: directory.standardizedFileURL.path)]
        guard let url = link.url else { throw CocoaError(.fileReadInvalidFileName) }
        return url
    }

    static func registeredProject(for directory: URL, catalog: [CodexProject]) -> CodexProject? {
        catalog.first {
            $0.directory?.resolvingSymlinksInPath().path == directory.resolvingSymlinksInPath().path
        }
    }
}

struct AddCodexProject: View {
    let onAdded: (CodexProject) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var directory: URL?
    @State private var hasOpenedCodex = false
    @State private var isChecking = false
    @State private var error: String?

    private func checkRegistration() async {
        guard hasOpenedCodex, !isChecking, let directory else { return }
        isChecking = true
        defer { isChecking = false }
        do {
            let catalog = try await Task.detached(priority: .userInitiated) { try CodexProjectCatalog.load() }.value
            if let project = CodexProjectRegistration.registeredProject(for: directory, catalog: catalog) {
                onAdded(project)
                dismiss()
            } else {
                error = "The folder is not registered in Codex yet. Complete the folder access dialog in Codex, then choose Check again."
            }
        } catch { self.error = "Cannot verify Codex registration: \(error.localizedDescription)" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add a Codex project").font(.headline).accessibilityAddTraits(.isHeader)
            Text(directory?.path ?? "Choose a folder for the project.")
                .font(.caption).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Button("Choose Folder…") {
                let panel = NSOpenPanel()
                panel.title = "Codex project folder"
                panel.prompt = "Choose Folder"
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.allowsMultipleSelection = false
                panel.canCreateDirectories = true
                panel.begin { response in
                    guard response == .OK, let url = panel.url else { return }
                    directory = url
                    hasOpenedCodex = false
                    error = nil
                }
            }.disabled(isChecking)
            Text("Use New Folder in the chooser if needed. Codex opens to register the folder and may ask for folder access. The project takes the folder's name; rename it in Codex if needed. An existing project using this folder is reused.")
                .font(.caption).foregroundStyle(.secondary)
            if hasOpenedCodex {
                Text("Finish in Codex, then return here. MyWizard selects the project only after it appears in Codex's desktop project list.")
                    .font(.callout)
                Button("Check again") { Task { await checkRegistration() } }.disabled(isChecking)
            }
            if let error { Text(error).foregroundStyle(.red).font(.caption).textSelection(.enabled) }
            if isChecking { ProgressView("Checking Codex registration…") }
            HStack {
                Button(hasOpenedCodex ? "Close" : "Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(hasOpenedCodex ? "Open Codex again" : "Add in Codex") {
                    guard let directory else { return }
                    do {
                        let catalog = try CodexProjectCatalog.load()
                        if let project = CodexProjectRegistration.registeredProject(for: directory, catalog: catalog) {
                            onAdded(project)
                            dismiss()
                            return
                        }
                        let link = try CodexProjectRegistration.deepLink(for: directory)
                        guard NSWorkspace.shared.open(link) else {
                            throw TranscriptionError.message("Codex could not be opened. Open or install Codex on this Mac and try again.")
                        }
                        hasOpenedCodex = true
                        error = nil
                    } catch { self.error = error.localizedDescription }
                }.buttonStyle(.borderedProminent).disabled(isChecking || directory == nil)
            }
        }.padding(20).frame(width: 480)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await checkRegistration() }
        }
    }
}

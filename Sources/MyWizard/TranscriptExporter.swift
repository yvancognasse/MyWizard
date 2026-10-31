import AppKit
import Combine

@MainActor
final class TranscriptExporter: ObservableObject {
    @Published private(set) var isPresenting = false
    @Published var errorMessage: String?
    @Published private(set) var defaultDirectoryPath: String?

    private let preferences: any PreferenceStore
    private let directoryKey = "lastTranscriptDirectory"
    private let defaultDirectoryKey = "defaultTranscriptDirectory"
    private var savePrompt: TranscriptSavePrompt?
    private var onSaved: ((URL) -> Void)?

    init(preferences: any PreferenceStore = UserDefaults.standard) {
        self.preferences = preferences
        defaultDirectoryPath = preferences.string(forKey: "defaultTranscriptDirectory")
    }

    var suggestedDirectory: URL? {
        if let path = defaultDirectoryPath, Self.isDirectory(path) {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return lastDirectory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    }

    func setDefaultDirectory(_ url: URL?) throws {
        if let url {
            guard url.isFileURL, Self.isDirectory(url.path) else {
                throw TranscriptionError.message("Choose an existing folder for text exports.")
            }
            let path = url.standardizedFileURL.path
            preferences.set(path, forKey: defaultDirectoryKey)
            defaultDirectoryPath = path
        } else {
            preferences.removeObject(forKey: defaultDirectoryKey)
            defaultDirectoryPath = nil
        }
    }

    func chooseDefaultDirectory() {
        guard !isPresenting else { return }
        let panel = NSOpenPanel()
        panel.title = "Default text export folder"
        panel.prompt = "Choose Folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = suggestedDirectory
        isPresenting = true
        NSApplication.shared.activate()
        panel.begin { [self] response in
            isPresenting = false
            guard response == .OK, let url = panel.url else { return }
            do { try setDefaultDirectory(url) }
            catch { errorMessage = error.localizedDescription }
        }
    }

    func openExportDirectory(open: (URL) -> Bool = { NSWorkspace.shared.open($0) }) {
        // Match the save destination; do not silently open a fallback when a
        // configured external/cloud folder is temporarily unavailable.
        if let path = defaultDirectoryPath, !Self.isDirectory(path) {
            errorMessage = "The default export folder is unavailable. Reconnect it or choose another folder in Preferences → Text exports."
            return
        }
        guard let directory = suggestedDirectory, Self.isDirectory(directory.path) else {
            errorMessage = "Choose an existing export folder in Preferences → Text exports."
            return
        }
        guard open(directory) else {
            errorMessage = "Cannot open the export folder in Finder: \(directory.path)"
            return
        }
        errorMessage = nil
    }

    private static func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    var lastDirectory: URL? {
        guard let path = preferences.string(forKey: directoryKey) else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    func save(_ text: String, recordingStartedAt: Date? = nil, meetingTitle: String? = nil, onSaved: ((URL) -> Void)? = nil) {
        guard !text.isEmpty, !isPresenting else { return }
        if let path = defaultDirectoryPath, !Self.isDirectory(path) {
            errorMessage = "The default export folder is unavailable. Reconnect it or choose another folder in Preferences → Text exports."
            return
        }
        guard let directory = suggestedDirectory else {
            errorMessage = "Choose an export folder in Preferences → Text exports."
            return
        }
        isPresenting = true
        self.onSaved = onSaved
        NSApplication.shared.activate()
        // Freeze the text, destination and recording date for the entire prompt.
        let window = NSApplication.shared.windows.first { $0 is TranscriptPanel }
            ?? NSApplication.shared.keyWindow
        presentName(text: text, directory: directory,
                    filename: Self.defaultFilename(for: recordingStartedAt ?? Date(), title: meetingTitle), window: window)
    }

    private func presentName(text: String, directory: URL, filename: String, window: NSWindow?, message: String? = nil) {
        do {
            let prompt = TranscriptSavePrompt(filename: filename, filenames: try Self.existingFilenames(in: directory), message: message)
            savePrompt = prompt
            prompt.begin(on: window) { [self] name in
                savePrompt = nil
                guard let name else { isPresenting = false; onSaved = nil; return }
                do {
                    let url = directory.appendingPathComponent(try Self.validatedFilename(name))
                    let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                    guard values?.isSymbolicLink != true else {
                        throw TranscriptionError.message("Choose a different name; this name is a symbolic link.")
                    }
                    if FileManager.default.fileExists(atPath: url.path) {
                        guard values?.isRegularFile == true else {
                            throw TranscriptionError.message("This name is already used by a folder or another non-text item.")
                        }
                        confirmReplacement(text: text, url: url, window: window)
                    } else {
                        // Do not overwrite a file created after the existence check.
                        try Data(text.utf8).write(to: url, options: .withoutOverwriting)
                        preferences.set(directory.path, forKey: directoryKey)
                        isPresenting = false
                        saved(url)
                    }
                } catch {
                    presentName(text: text, directory: directory, filename: name, window: window, message: error.localizedDescription)
                }
            }
        } catch {
            isPresenting = false
            errorMessage = "Cannot open the export folder. \(error.localizedDescription)"
        }
    }

    private func confirmReplacement(text: String, url: URL, window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = "Replace \(url.lastPathComponent)?"
        alert.informativeText = "A file with this name already exists in the export folder. Replacing it will overwrite its contents."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Replace")
        let completion: (NSApplication.ModalResponse) -> Void = { [self] response in
            guard response == .alertSecondButtonReturn else {
                presentName(text: text, directory: url.deletingLastPathComponent(), filename: url.lastPathComponent, window: window)
                return
            }
            do {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else {
                    throw TranscriptionError.message("The destination changed. Choose another filename.")
                }
                try write(text, to: url)
                isPresenting = false
                saved(url)
            } catch {
                presentName(text: text, directory: url.deletingLastPathComponent(), filename: url.lastPathComponent, window: window, message: error.localizedDescription)
            }
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: completion) }
        else { completion(alert.runModal()) }
    }

    static func existingFilenames(in directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
            .filter {
                guard $0.pathExtension.lowercased() == "txt",
                      let values = try? $0.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return false }
                return values.isRegularFile == true && values.isSymbolicLink != true
            }
            .map(\.lastPathComponent)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private func saved(_ url: URL) {
        let completion = onSaved
        onSaved = nil
        completion?(url)
    }

    static func validatedFilename(_ name: String) throws -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != "..", !name.hasPrefix("."),
              !name.contains("/"), !name.contains(":"),
              name.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw TranscriptionError.message("Enter a file name, without folders, slashes or control characters.")
        }
        return name.lowercased().hasSuffix(".txt") ? name : name + ".txt"
    }

    static func defaultFilename(for date: Date = Date(), timeZone: TimeZone = .current, title: String? = nil) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "d MMMM yyyy HH'h'mm"
        let invalid = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/:"))
        let cleanTitle = (title ?? "").components(separatedBy: invalid).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        let prefix = cleanTitle.isEmpty ? "Meeting Notes" : String(cleanTitle.prefix(150))
        return "\(prefix) on \(formatter.string(from: date)).txt"
    }

    func write(_ text: String, to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
        // A cancellation or a failed write must not replace the last good directory.
        preferences.set(url.deletingLastPathComponent().path, forKey: directoryKey)
    }
}

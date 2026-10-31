import AppKit

// Native inline completion selects the suggested suffix, so typing continues
// to replace it normally. Only regular .txt files in the export folder qualify.
@MainActor
final class TranscriptSavePrompt: NSObject, NSComboBoxDataSource {
    private let filenames: [String]
    private let field = NSComboBox(frame: NSRect(x: 0, y: 0, width: 400, height: 26))
    private let alert = NSAlert()

    init(filename: String, filenames: [String], message: String? = nil) {
        self.filenames = filenames
        super.init()
        alert.messageText = "Save transcript"
        alert.informativeText = message ?? "File name"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        field.usesDataSource = true
        field.dataSource = self
        field.completes = true
        field.numberOfVisibleItems = 7
        field.stringValue = filename
        field.setAccessibilityLabel("Export file name")
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
    }

    func begin(on window: NSWindow?, completion: @escaping (String?) -> Void) {
        let handler: (NSApplication.ModalResponse) -> Void = { [self] response in
            completion(response == .alertFirstButtonReturn ? field.stringValue : nil)
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: handler) }
        else { handler(alert.runModal()) }
    }

    func numberOfItems(in comboBox: NSComboBox) -> Int { filenames.count }

    func comboBox(_ comboBox: NSComboBox, objectValueForItemAt index: Int) -> Any? {
        filenames.indices.contains(index) ? filenames[index] : nil
    }

    func comboBox(_ comboBox: NSComboBox, completedString string: String) -> String? {
        Self.completion(for: string, filenames: filenames)
    }

    static func completion(for prefix: String, filenames: [String]) -> String? {
        guard !prefix.isEmpty else { return nil }
        return filenames.first {
            $0.range(of: prefix, options: [.anchored, .caseInsensitive, .diacriticInsensitive]) != nil
        }
    }
}

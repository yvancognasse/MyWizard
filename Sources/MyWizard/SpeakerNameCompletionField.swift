import AppKit
import SwiftUI

// A text field with a selected inline suffix, without a saved-voice drop-down.
// Deletion, cursor edits and marked text must never trigger completion.
struct SpeakerNameCompletionField: NSViewRepresentable {
    @Binding var text: String
    let names: [String]
    let submit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = FocusedSpeakerNameField()
        field.placeholderString = "Name"
        field.setAccessibilityLabel("Speaker name")
        field.setAccessibilityHelp("Type the beginning of a saved voice name to complete it. Keep typing to replace the selected suffix, or enter a new name.")
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.delegate = context.coordinator
        field.stringValue = text
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SpeakerNameCompletionField
        private var isDeleting = false

        init(_ parent: SpeakerNameCompletionField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            let typed = field.stringValue
            defer { isDeleting = false }
            if !isDeleting, let editor = field.currentEditor() as? NSTextView,
               !editor.hasMarkedText(), editor.selectedRange().length == 0,
               editor.selectedRange().location == typed.utf16.count,
               let completion = SpeakerNameSuggestions.completion(for: typed, names: parent.names),
               let prefix = completion.range(of: typed, options: [.anchored, .caseInsensitive, .diacriticInsensitive]),
               prefix.upperBound < completion.endIndex {
                let suffixStart = NSRange(prefix, in: completion).upperBound
                field.stringValue = completion
                editor.string = completion
                editor.setSelectedRange(NSRange(location: suffixStart, length: completion.utf16.count - suffixStart))
                parent.text = completion
            } else {
                parent.text = typed
            }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                parent.submit()
                return true
            }
            isDeleting = NSStringFromSelector(commandSelector).hasPrefix("delete")
            return false
        }
    }
}

private final class FocusedSpeakerNameField: NSTextField {
    private var hasFocused = false
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, !hasFocused else { return }
        hasFocused = true
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self)
        }
    }
}

// Opt-in component preview: no calendar access, meeting data, audio or disk writes.
struct SpeakerNamingPreview: View {
    @State private var calendarParticipants = true
    @State private var saved = ""
    @State private var showsEditor = true
    var body: some View {
        VStack(spacing: 20) {
            Toggle("Calendar participants", isOn: $calendarParticipants)
            Button("Edit speaker name") { showsEditor = true }
            Text("Saved name: \(saved)").textSelection(.enabled)
        }
        .padding(30).frame(width: 360)
        .sheet(isPresented: $showsEditor) {
            SpeakerNameEditor(speaker: 1, currentName: saved,
                suggestions: calendarParticipants ? ["Alice Smith", "Bob Martin"] : [],
                savedNames: ["Alice Smith", "Bob Martin", "Jérôme Dupont"]) { saved = $0 }
        }
    }
}

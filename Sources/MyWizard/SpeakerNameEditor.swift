import SwiftUI

struct SpeakerNameEditor: View {
    let suggestions: [String]
    let speaker: Int
    let save: (String) -> Void
    @State private var name: String
    @FocusState private var nameIsFocused: Bool
    @Environment(\.dismiss) private var dismiss

    init(speaker: Int, currentName: String, suggestions: [String] = [], save: @escaping (String) -> Void) {
        self.suggestions = suggestions
        self.speaker = speaker
        self.save = save
        _name = State(initialValue: currentName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename \(SpeakerIdentity.heading(speaker))").font(.headline)
            if !suggestions.isEmpty {
                Menu("Choose an invited person") {
                    ForEach(suggestions, id: \.self) { person in
                        Button(person) { name = person }
                    }
                }
            }
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($nameIsFocused)
                .onSubmit { commit() }
            Text("Applies to this speaker and saved text. With enough clear speech, the name is remembered automatically on this Mac for future meetings. Leave empty to restore \(SpeakerIdentity.heading(speaker)).")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { commit() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 320)
        .onAppear { nameIsFocused = true }
    }

    private func commit() {
        save(name.trimmingCharacters(in: .whitespacesAndNewlines))
        dismiss()
    }
}

import Foundation
import SwiftUI

struct HelpGuide: Decodable {
    let reviewedVersion: String
    let sections: [Section]

    struct Section: Decodable, Identifiable {
        let id: String
        let title: String
        let paragraphs: [String]

        func matches(_ query: String) -> Bool {
            ([title] + paragraphs).joined(separator: " ").folding(
                options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en")
            ).contains(query.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en")))
        }
    }

    static func load(bundle: Bundle = .main) throws -> HelpGuide {
        guard let url = bundle.url(forResource: "guide", withExtension: "json", subdirectory: "Help") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try JSONDecoder().decode(HelpGuide.self, from: Data(contentsOf: url))
    }
}

struct HelpView: View {
    let guide: HelpGuide
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    private var visibleSections: [HelpGuide.Section] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return search.isEmpty ? guide.sections : guide.sections.filter { $0.matches(search) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text("MyWizard Help").font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
                Text("Your guide to recording, understanding and saving meetings.")
                    .foregroundStyle(.secondary)
                TextField("Search help", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Search MyWizard Help")
                    .focused($searchFocused)
                HStack {
                    Text("Reviewed for version \(guide.reviewedVersion) · Available offline")
                    Spacer()
                    Button("Find", systemImage: "magnifyingglass") { searchFocused = true }
                        .keyboardShortcut("f", modifiers: .command)
                        .labelStyle(.iconOnly)
                        .help("Search help (⌘F)")
                }.font(.caption).foregroundStyle(.secondary)
            }.padding(24)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        if visibleSections.isEmpty {
                            ContentUnavailableView.search(text: query)
                        } else {
                            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Contents").font(.headline).accessibilityAddTraits(.isHeader)
                                    ForEach(guide.sections) { section in
                                        Button(section.title) { proxy.scrollTo(section.id, anchor: .top) }
                                            .buttonStyle(.link)
                                    }
                                }
                                Divider()
                            }
                            ForEach(visibleSections) { section in
                                VStack(alignment: .leading, spacing: 10) {
                                    Text(section.title).font(.title2.bold())
                                        .accessibilityAddTraits(.isHeader)
                                    ForEach(Array(section.paragraphs.enumerated()), id: \.offset) { _, paragraph in
                                        Text(.init(paragraph))
                                            .textSelection(.enabled)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }.id(section.id)
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(24)
                }
                .onChange(of: query) {
                    if let first = visibleSections.first { proxy.scrollTo(first.id, anchor: .top) }
                }
            }
        }.frame(minWidth: 480, minHeight: 380)
    }
}

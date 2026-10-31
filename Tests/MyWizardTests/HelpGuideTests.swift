import Foundation
import Testing
@testable import MyWizard

struct HelpGuideTests {
    @Test func bundledGuideLoadsOfflineAndSearchesUpdatedWorkflows() throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MyWizardHelp-\(UUID()).bundle")
        defer { try? FileManager.default.removeItem(at: root) }
        let resources = root.appendingPathComponent("Contents/Resources/Help")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: repository.appendingPathComponent("App/Help/guide.json"),
                                        to: resources.appendingPathComponent("guide.json"))
        let info = ["CFBundleIdentifier": "MyWizard.HelpTest.\(UUID())", "CFBundlePackageType": "BNDL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: root.appendingPathComponent("Contents/Info.plist"))
        let guide = try HelpGuide.load(bundle: #require(Bundle(url: root)))
        let appInfo = try #require(PropertyListSerialization.propertyList(
            from: Data(contentsOf: repository.appendingPathComponent("App/Info.plist")),
            format: nil) as? [String: Any])
        #expect(guide.reviewedVersion == appInfo["CFBundleShortVersionString"] as? String)
        #expect(guide.sections.contains { $0.id == "navigation" && $0.matches("OUTSIDE THE VISIBLE AREA") })
        #expect(guide.sections.contains { $0.id == "troubleshooting" && $0.matches("five seconds") })
        #expect(guide.sections.contains { $0.matches("⇧⌘H") })
        #expect(guide.sections.contains { $0.id == "export" && $0.matches("successful copy notice") })
        #expect(guide.sections.contains { $0.id == "microphone" && $0.matches("Forget saved voices") && $0.matches("remembered automatically") })
        #expect(guide.sections.contains { $0.id == "permissions" && $0.matches("unused language reservation") })
        #expect(!guide.sections.contains { $0.matches("unfindable-search-123456") })
        #expect(Set(guide.sections.map(\.id)).count == guide.sections.count)
    }
}

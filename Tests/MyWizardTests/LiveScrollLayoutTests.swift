import AppKit
import SwiftUI
import Testing
@testable import MyWizard

// Opt-in AppKit integration test, using synthetic text and an independent window.
// Never starts capture or touches the running meeting or saved preferences.
@MainActor
struct LiveScrollLayoutTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MYWIZARD_SCROLL_LAYOUT_CHECK"] == "1"))
    func liveFollowingSurvivesRepeatedGrowthAndCorrections() async throws {
        _ = NSApplication.shared
        let preferences = MemoryPreferences()
        let model = TranscriptionModel(preferences: preferences)
        let host = NSHostingView(rootView: OverlayView(model: model, preferences: preferences))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1140, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        window.orderBack(nil)
        defer { window.close() }

        // Recognition can revise a large provisional passage into a short one.
        // Repeat without restarting the document, including width/height changes.
        for iteration in 0..<16 {
            let count = iteration.isMultiple(of: 2) ? 500 : 18
            model.receiveTranscript([.init(text: String(repeating: "Visible meeting words. ", count: count),
                                           start: 1, end: 10)], isFinal: false)
            if iteration == 6 { window.setContentSize(NSSize(width: 1000, height: 350)) }
            if iteration == 12 { window.setContentSize(NSSize(width: 1140, height: 300)) }
            // The test runner has no NSApplication event loop. Explicitly run
            // AppKit layout/display, then allow SwiftUI geometry to settle.
            for _ in 0..<3 {
                host.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                try await Task.sleep(for: .milliseconds(80))
            }
            let scroll = try #require(findScrollView(in: host))
            let document = try #require(scroll.documentView)
            let visible = scroll.documentVisibleRect
            #expect(visible.intersects(document.bounds), "Viewport left the transcript at revision \(iteration)")
            let expectedOffset = max(0, document.bounds.height - visible.height)
            #expect(abs(visible.minY - expectedOffset) < 5,
                    "Live following lost the bottom at revision \(iteration): \(visible) / \(document.bounds)")
            #expect(!model.displayTranslation.paragraphs.isEmpty)
        }
        model.clear()
        await model.shutDown()
    }

    private func findScrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for child in view.subviews {
            if let scroll = findScrollView(in: child) { return scroll }
        }
        return nil
    }
}

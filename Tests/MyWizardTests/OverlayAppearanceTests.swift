import AppKit
import SwiftUI
import Testing

@testable import MyWizard

// An independent, synthetic window: no capture, model downloads or user settings.
@MainActor
struct OverlayAppearanceTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MYWIZARD_APPEARANCE_CHECK"] == "1"))
    func fullViewKeepsTranscriptVisibleAndBackgroundTransparent() async throws {
        _ = NSApplication.shared
        let suite = "MyWizard.AppearanceCheck.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removeVolatileDomain(forName: UserDefaults.argumentDomain) }
        let model = TranscriptionModel(preferences: MemoryPreferences())
        model.receiveTranscript(
            [
                TimedText(text: "We should confirm the scope before the next workshop.", start: 1, end: 4),
                TimedText(text: "The updated proposal will be ready for Friday.", start: 8, end: 11),
            ], isFinal: true)
        let host = NSHostingView(
            rootView: OverlayView(model: model)
                .defaultAppStorage(defaults).id(-1))
        let window = DragCheckingWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 620),
            styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isMovableByWindowBackground = true
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        window.orderBack(nil)
        defer { window.close() }

        for (index, transparency) in [0.0, 0.65, 1.0].enumerated() {
            defaults.setVolatileDomain(["overlayTransparency": transparency, "overlayFontSize": 19.0], forName: UserDefaults.argumentDomain)
            #expect(defaults.double(forKey: "overlayTransparency") == transparency)
            // Rebuild the host to load the independent volatile settings for this case.
            host.rootView = OverlayView(model: model).defaultAppStorage(defaults).id(index)
            for size in [NSSize(width: 900, height: 360), NSSize(width: 1100, height: 620)] {
                window.setContentSize(size)
                for _ in 0..<3 {
                    host.layoutSubtreeIfNeeded()
                    window.displayIfNeeded()
                    try await Task.sleep(for: .milliseconds(100))
                }
                let scroll = try #require(findScrollView(in: host))
                #expect(scroll.bounds.height > 80, "Chrome must leave readable transcript space at \(size)")
                #expect(scroll.frame.width <= host.bounds.width)
                let drag = try #require(findDragHandle(in: host))
                #expect(drag.bounds.width > 150)
                #expect(drag.bounds.height >= 32)
                let dragFrame = host.convert(drag.bounds, from: drag)
                #expect(!dragFrame.intersects(host.convert(scroll.bounds, from: scroll)),
                        "The drag target must not intercept transcript selection or scrolling")
                for x in [CGFloat(10), drag.bounds.midX, drag.bounds.maxX - 10] {
                    // hitTest takes the receiver's superview coordinates, which
                    // differ from the flipped SwiftUI hosting view coordinates.
                    let point = drag.convert(NSPoint(x: x, y: drag.bounds.midY), to: host.superview)
                    let target = try #require(host.hitTest(point))
                    let hitsDrag = target === drag
                    #expect(hitsDrag, "Title and empty header must receive drag events")
                    let event = try #require(NSEvent.mouseEvent(
                        with: .leftMouseDown, location: drag.convert(NSPoint(x: x, y: drag.bounds.midY), to: nil),
                        modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                        context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
                    let previous = window.dragCount
                    target.mouseDown(with: event)
                    #expect(window.dragCount == previous + 1)
                }
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                // An empty area of the transcript must fade with the background.
                let pixel = try #require(
                    bitmap.colorAt(
                        x: bitmap.pixelsWide - 40,
                        y: bitmap.pixelsHigh / 2))
                #expect(
                    abs(pixel.alphaComponent - (1 - transparency)) < 0.08,
                    "Only background opacity should follow the stored transparency: \(pixel)")
                if let output = ProcessInfo.processInfo.environment["MYWIZARD_APPEARANCE_OUTPUT"] {
                    let url = URL(fileURLWithPath: output).appendingPathComponent("full-view-\(index)-\(Int(size.width)).png")
                    try bitmap.representation(using: .png, properties: [:])?.write(to: url)
                }
            }
        }
        await model.shutDown()
    }

    private func findScrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.lazy.compactMap { findScrollView(in: $0) }.first
    }

    private func findDragHandle(in view: NSView) -> WindowDragHandleView? {
        if let handle = view as? WindowDragHandleView { return handle }
        return view.subviews.lazy.compactMap { findDragHandle(in: $0) }.first
    }
}

@MainActor
private final class DragCheckingWindow: NSWindow {
    var dragCount = 0

    override func performDrag(with event: NSEvent) {
        dragCount += 1
    }
}

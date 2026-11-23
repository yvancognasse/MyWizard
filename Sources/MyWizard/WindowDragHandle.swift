import AppKit
import SwiftUI

/// A native drag target, independent of SwiftUI's background hit testing.
/// Keep it over the title and unused header space, away from controls and text selection.
struct WindowDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowDragHandleView { WindowDragHandleView() }
    func updateNSView(_ nsView: WindowDragHandleView, context: Context) {}
}

final class WindowDragHandleView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        toolTip = "Drag to move the window"
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { super.init(coder: coder) }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

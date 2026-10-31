import AppKit
import SwiftUI

struct WindowResizeHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> ResizeHandleView { ResizeHandleView() }
    func updateNSView(_ nsView: ResizeHandleView, context: Context) {}
}

final class ResizeHandleView: NSView {
    private var initialMouse = NSPoint.zero
    private var initialFrame = NSRect.zero

    override init(frame: NSRect) {
        super.init(frame: frame)
        toolTip = "Drag to resize the window"
        setAccessibilityLabel("Resize window")
    }

    required init?(coder: NSCoder) { super.init(coder: coder) }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.secondaryLabelColor.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1.5
        path.lineCapStyle = .round
        for offset in [CGFloat(4), 9, 14] {
            path.move(to: NSPoint(x: offset, y: 3))
            path.line(to: NSPoint(x: 17, y: 20 - offset))
        }
        path.stroke()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        initialMouse = NSEvent.mouseLocation
        initialFrame = window.frame
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window else { return }
        let mouse = NSEvent.mouseLocation
        let width = max(window.minSize.width, initialFrame.width + mouse.x - initialMouse.x)
        let height = max(window.minSize.height, initialFrame.height - mouse.y + initialMouse.y)
        window.setFrame(NSRect(x: initialFrame.minX, y: initialFrame.maxY - height,
                               width: width, height: height), display: true)
    }

    override func mouseUp(with event: NSEvent) {
        window?.saveFrame(usingName: "MyWizardOverlay")
    }
}

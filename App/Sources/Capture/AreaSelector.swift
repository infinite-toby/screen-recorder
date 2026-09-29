import AppKit

/// Full-screen overlay on every display; drag a rectangle to choose a recording area. Esc cancels.
@MainActor
final class AreaSelector {
    private var windows: [NSWindow] = []
    private var continuation: CheckedContinuation<CaptureSource?, Never>?

    func select() async -> CaptureSource? {
        await withCheckedContinuation { cont in
            continuation = cont
            for screen in NSScreen.screens {
                let window = OverlayWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
                window.level = .screenSaver
                window.isOpaque = false
                window.backgroundColor = .clear
                window.ignoresMouseEvents = false
                window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
                let view = SelectionView(frame: CGRect(origin: .zero, size: screen.frame.size))
                view.onFinish = { [weak self] rect in self?.finish(rect: rect, screen: screen) }
                window.contentView = view
                window.makeKeyAndOrderFront(nil)
                windows.append(window)
            }
            NSApp.activate(ignoringOtherApps: true)
            NSCursor.crosshair.push()
        }
    }

    private func finish(rect: CGRect?, screen: NSScreen) {
        NSCursor.pop()
        windows.forEach { $0.orderOut(nil) }
        windows = []
        guard let rect, rect.width >= 40, rect.height >= 40, let id = screen.displayID else {
            continuation?.resume(returning: nil)
            continuation = nil
            return
        }
        // View coords are bottom-left within the screen; convert to global top-left and snap to whole points.
        let top = screen.topLeftFrame
        let global = CGRect(x: top.minX + rect.minX, y: top.minY + (screen.frame.height - rect.maxY),
                            width: rect.width, height: rect.height).integral
        continuation?.resume(returning: .area(id, global))
        continuation = nil
    }
}

private final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

private final class SelectionView: NSView {
    var onFinish: ((CGRect?) -> Void)?
    private var start: CGPoint?
    private var current: CGPoint?

    override var acceptsFirstResponder: Bool { true }
    override func viewDidMoveToWindow() { window?.makeFirstResponder(self) }

    private var selection: CGRect? {
        guard let start, let current else { return nil }
        return CGRect(x: min(start.x, current.x), y: min(start.y, current.y),
                      width: abs(current.x - start.x), height: abs(current.y - start.y))
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.35).setFill()
        bounds.fill()
        if let r = selection {
            NSColor.clear.setFill()
            r.fill(using: .copy)
            NSColor.white.setStroke()
            let path = NSBezierPath(rect: r.insetBy(dx: -0.5, dy: -0.5))
            path.lineWidth = 1
            path.stroke()
            let label = "\(Int(r.width)) × \(Int(r.height))" as NSString
            label.draw(at: CGPoint(x: r.minX + 6, y: r.maxY + 6),
                       withAttributes: [.foregroundColor: NSColor.white, .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)])
        } else {
            let hint = "Drag to select an area to record. Esc to cancel." as NSString
            let attrs: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 18, weight: .medium)]
            let size = hint.size(withAttributes: attrs)
            hint.draw(at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY), withAttributes: attrs)
        }
    }

    override func mouseDown(with event: NSEvent) {
        start = convert(event.locationInWindow, from: nil)
        current = start
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil)
        onFinish?(selection)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onFinish?(nil) } // Esc
    }
}

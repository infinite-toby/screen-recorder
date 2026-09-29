import AppKit
import ScreenCaptureKit

/// What to record, resolved to a ScreenCaptureKit filter plus the pixel size and global rect it covers.
enum CaptureSource: Equatable {
    case display(CGDirectDisplayID)
    case window(CGWindowID)
    /// Rect in global display coordinates (points, top-left origin) on one display.
    case area(CGDirectDisplayID, CGRect)

    var label: String {
        switch self {
        case .display: "Display"
        case .window: "Window"
        case .area: "Area"
        }
    }
}

struct ResolvedSource {
    let filter: SCContentFilter
    /// Region to crop from the display, in display-local points; nil for the whole content.
    let sourceRect: CGRect?
    let pixelSize: CGSize
    /// Captured region in global display coordinates (points, top-left origin).
    let globalRect: CGRect
}

enum CaptureError: LocalizedError {
    case sourceGone
    case noScreenPermission

    var errorDescription: String? {
        switch self {
        case .sourceGone: "The selected display or window is no longer available."
        case .noScreenPermission:
            "Screen Recording permission is needed. Enable it in System Settings > Privacy & Security > Screen & System Audio Recording, then reopen the app."
        }
    }
}

enum SourceResolver {
    static func shareableContent() async throws -> SCShareableContent {
        do {
            return try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        } catch {
            throw CaptureError.noScreenPermission
        }
    }

    static func resolve(_ source: CaptureSource) async throws -> ResolvedSource {
        let content = try await shareableContent()
        let me = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        switch source {
        case let .display(id):
            guard let display = content.displays.first(where: { $0.displayID == id }) else { throw CaptureError.sourceGone }
            // Our own windows (controls, camera preview) never appear in the recording.
            let filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])
            return ResolvedSource(filter: filter, sourceRect: nil, pixelSize: pixels(filter.contentRect.size, filter.pointPixelScale),
                                  globalRect: display.frame)
        case let .window(id):
            guard let window = content.windows.first(where: { $0.windowID == id }) else { throw CaptureError.sourceGone }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            return ResolvedSource(filter: filter, sourceRect: nil, pixelSize: pixels(filter.contentRect.size, filter.pointPixelScale),
                                  globalRect: window.frame)
        case let .area(id, rect):
            guard let display = content.displays.first(where: { $0.displayID == id }) else { throw CaptureError.sourceGone }
            let filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])
            let local = rect.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
            return ResolvedSource(filter: filter, sourceRect: local, pixelSize: pixels(rect.size, filter.pointPixelScale),
                                  globalRect: rect)
        }
    }

    /// Even pixel dimensions, which video encoders require.
    private static func pixels(_ size: CGSize, _ scale: Float) -> CGSize {
        let s = CGFloat(scale)
        return CGSize(width: (Int(size.width * s) / 2) * 2, height: (Int(size.height * s) / 2) * 2)
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    /// Frame in global display coordinates with a top-left origin (the space ScreenCaptureKit uses).
    var topLeftFrame: CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? frame.height
        return CGRect(x: frame.minX, y: primaryHeight - frame.maxY, width: frame.width, height: frame.height)
    }
}

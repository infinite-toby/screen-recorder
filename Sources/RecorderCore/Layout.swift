import CoreGraphics
import Foundation

// All rects here are in output pixels with a top-left origin.

/// Where the camera is drawn at one instant. `nil` frame means hidden.
public struct CameraState: Interpolatable, Equatable {
    public var rect: CGRect
    public var cornerRadius: CGFloat
    public var opacity: Double

    public static let hidden = CameraState(rect: .null, cornerRadius: 0, opacity: 0)
    public var isHidden: Bool { rect.isNull || opacity <= 0.001 }

    public static func interpolate(_ a: CameraState, _ b: CameraState, _ t: Double) -> CameraState {
        switch (a.rect.isNull, b.rect.isNull) {
        case (true, true): return .hidden
        // Appearing or disappearing: grow from / shrink to 85% while fading.
        case (true, false): return b.shrunk(by: 1 - t)
        case (false, true): return a.shrunk(by: t)
        case (false, false):
            return CameraState(rect: lerp(a.rect, b.rect, t),
                               cornerRadius: lerp(a.cornerRadius, b.cornerRadius, t),
                               opacity: lerp(a.opacity, b.opacity, t))
        }
    }

    private func shrunk(by amount: Double) -> CameraState {
        let s = 1 - 0.15 * amount
        let w = rect.width * s, h = rect.height * s
        return CameraState(rect: CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h),
                           cornerRadius: cornerRadius * s, opacity: opacity * (1 - amount))
    }
}

public enum CameraLayoutResolver {
    public static func state(for layout: CameraLayout, output: CGSize, style: FrameStyle) -> CameraState {
        let base = min(output.width, output.height)
        let margin = base * 0.035
        let rect: CGRect
        switch layout {
        case .hidden:
            return .hidden
        case let .corner(corner, shape, size):
            let long = base * (size == .small ? 0.32 : 0.5)
            let s: CGSize = switch shape {
            case .landscape: CGSize(width: long, height: long * 9 / 16)
            case .portrait: CGSize(width: long * 3 / 4, height: long)
            case .square: CGSize(width: long * 0.8, height: long * 0.8)
            }
            let x = (corner == .topLeft || corner == .bottomLeft) ? margin : output.width - margin - s.width
            let y = (corner == .topLeft || corner == .topRight) ? margin : output.height - margin - s.height
            rect = CGRect(origin: CGPoint(x: x, y: y), size: s)
        case let .centre(coverage):
            var w = output.width * min(max(coverage, 0.2), 1)
            var h = w * 9 / 16
            if h > output.height * 0.9 {
                h = output.height * 0.9
                w = h * 16 / 9
            }
            rect = CGRect(x: (output.width - w) / 2, y: (output.height - h) / 2, width: w, height: h)
        }
        let radius = min(rect.width, rect.height) * style.cameraCornerRadius
        return CameraState(rect: rect, cornerRadius: radius, opacity: 1)
    }
}

/// How one clip's screen content sits in the output frame.
public struct ScreenGeometry: Equatable {
    public var output: CGSize
    /// Screen content placed in the output at zoom 1 (inside the padding).
    public var contentRect: CGRect
    /// Largest output-aspect rect inside `contentRect`: the view at "zoom 1, edge to edge".
    public var fullBleedSize: CGSize
    /// True when the content is much wider/taller than the output (e.g. 16:9 screen in a 9:16 export),
    /// so the un-zoomed view crops the screen and follows the cursor instead of showing all of it.
    public var followsCursor: Bool

    public init(contentSize: CGSize, output: CGSize, style: FrameStyle) {
        self.output = output
        let base = min(output.width, output.height)
        let inset = base * style.effectivePadding
        let avail = CGSize(width: output.width - 2 * inset, height: output.height - 2 * inset)
        let c = contentSize.width > 0 && contentSize.height > 0 ? contentSize : output
        // Full screen fills the frame (cropping a sliver if aspects differ); otherwise fit inside the padding.
        let fit = style.fullScreen ? max(avail.width / c.width, avail.height / c.height)
            : min(avail.width / c.width, avail.height / c.height)
        let size = CGSize(width: c.width * fit, height: c.height * fit)
        contentRect = CGRect(x: (output.width - size.width) / 2, y: (output.height - size.height) / 2,
                             width: size.width, height: size.height)
        let outAspect = output.width / output.height
        let contentAspect = size.width / size.height
        fullBleedSize = contentAspect > outAspect
            ? CGSize(width: size.height * outAspect, height: size.height)
            : CGSize(width: size.width, height: size.width / outAspect)
        let mismatch = max(contentAspect / outAspect, outAspect / contentAspect)
        followsCursor = mismatch > 1.4
    }

    public var fullView: CGRect { CGRect(origin: .zero, size: output) }

    /// View rect for a zoom of `scale` centred as close to `focus` (content-normalised) as the content allows.
    public func zoomedView(scale: Double, focus: CGPoint) -> CGRect {
        let s = max(scale, 1)
        let w = fullBleedSize.width / s, h = fullBleedSize.height / s
        let cx = contentRect.minX + focus.x * contentRect.width
        let cy = contentRect.minY + focus.y * contentRect.height
        let x = min(max(cx - w / 2, contentRect.minX), contentRect.maxX - w)
        let y = min(max(cy - h / 2, contentRect.minY), contentRect.maxY - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }
}

/// The part of the output canvas that fills the frame. Always the output's aspect ratio.
public struct ViewRect: Interpolatable, Equatable {
    public var rect: CGRect

    public init(_ rect: CGRect) { self.rect = rect }

    public static func interpolate(_ a: ViewRect, _ b: ViewRect, _ t: Double) -> ViewRect {
        // Width in log space keeps zoom speed perceptually even; the centre moves linearly.
        let w = exp(lerp(log(a.rect.width), log(b.rect.width), t))
        let h = w * a.rect.height / a.rect.width
        let cx = lerp(a.rect.midX, b.rect.midX, t)
        let cy = lerp(a.rect.midY, b.rect.midY, t)
        return ViewRect(CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h))
    }
}

func lerp(_ a: CGFloat, _ b: CGFloat, _ t: Double) -> CGFloat { a + (b - a) * CGFloat(t) }
func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
func lerp(_ a: CGRect, _ b: CGRect, _ t: Double) -> CGRect {
    CGRect(x: lerp(a.minX, b.minX, t), y: lerp(a.minY, b.minY, t),
           width: lerp(a.width, b.width, t), height: lerp(a.height, b.height, t))
}

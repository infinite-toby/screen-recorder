import CoreGraphics
import Foundation

/// Cursor positions on the edited timeline, resampled and smoothed so a following crop glides rather than jitters.
public struct CursorTrack {
    public static let rate = 30.0
    /// Smoothed positions at `rate` Hz from t = 0, content-normalised.
    private var points: [CGPoint]
    /// Clicks on the timeline, content-normalised.
    public private(set) var clicks: [(t: Double, point: CGPoint)]

    public init(project: Project, logs: [UUID: CursorLog], smoothing tau: Double = 0.45) {
        var raw: [(t: Double, p: CGPoint)] = []
        var clicks: [(Double, CGPoint)] = []
        // Map each clip's samples onto the edited timeline; samples in cut ranges are dropped.
        for (i, clip) in project.clips.enumerated() {
            guard let log = logs[clip.id] else { continue }
            for s in log.samples where s.t >= 0 && s.t <= clip.duration {
                if let e = project.editedTime(clipIndex: i, local: s.t) { raw.append((e, CGPoint(x: s.x, y: s.y))) }
            }
            for c in log.clicks where c.t >= 0 && c.t <= clip.duration && (0...1).contains(c.x) && (0...1).contains(c.y) {
                if let e = project.editedTime(clipIndex: i, local: c.t) { clicks.append((e, CGPoint(x: c.x, y: c.y))) }
            }
        }
        raw.sort { $0.t < $1.t }
        self.clicks = clicks.sorted { $0.0 < $1.0 }

        let n = Int((project.duration * Self.rate).rounded(.up)) + 1
        guard !raw.isEmpty, n > 0 else {
            points = []
            return
        }
        // Resample (hold/linear), clamping to the content so the crop never chases an off-screen cursor.
        var resampled: [CGPoint] = []
        resampled.reserveCapacity(n)
        var j = 0
        for i in 0 ..< n {
            let t = Double(i) / Self.rate
            while j + 1 < raw.count && raw[j + 1].t <= t { j += 1 }
            var p = raw[j].p
            if j + 1 < raw.count, raw[j].t <= t {
                let a = raw[j], b = raw[j + 1]
                let f = (t - a.t) / max(b.t - a.t, 1e-6)
                p = CGPoint(x: lerp(a.p.x, b.p.x, f), y: lerp(a.p.y, b.p.y, f))
            }
            resampled.append(CGPoint(x: min(max(p.x, 0), 1), y: min(max(p.y, 0), 1)))
        }
        // Zero-phase exponential smoothing: forward then backward pass, so no lag.
        let alpha = 1 - exp(-1 / (Self.rate * tau))
        for i in 1 ..< resampled.count {
            resampled[i].x += (resampled[i - 1].x - resampled[i].x) * (1 - alpha)
            resampled[i].y += (resampled[i - 1].y - resampled[i].y) * (1 - alpha)
        }
        for i in stride(from: resampled.count - 2, through: 0, by: -1) {
            resampled[i].x += (resampled[i + 1].x - resampled[i].x) * (1 - alpha)
            resampled[i].y += (resampled[i + 1].y - resampled[i].y) * (1 - alpha)
        }
        points = resampled
    }

    public var isEmpty: Bool { points.isEmpty }

    public func position(at t: Double) -> CGPoint? {
        guard !points.isEmpty else { return nil }
        let f = max(t, 0) * Self.rate
        let i = min(Int(f), points.count - 1)
        let k = min(i + 1, points.count - 1)
        let frac = f - Double(i)
        return CGPoint(x: lerp(points[i].x, points[k].x, frac), y: lerp(points[i].y, points[k].y, frac))
    }
}

public enum AutoZoom {
    /// Proposes zoom blocks around clusters of clicks.
    public static func suggest(clicks: [(t: Double, point: CGPoint)], duration: Double,
                               scale: Double = 2, maxGap: Double = 2.5, maxDistance: Double = 0.3) -> [ZoomBlock] {
        var clusters: [[(t: Double, point: CGPoint)]] = []
        for click in clicks.sorted(by: { $0.t < $1.t }) {
            if var last = clusters.last, let prev = last.last, click.t - prev.t <= maxGap,
               distance(centroid(last), click.point) <= maxDistance {
                last.append(click)
                clusters[clusters.count - 1] = last
            } else {
                clusters.append([click])
            }
        }
        var blocks: [ZoomBlock] = []
        for cluster in clusters {
            var start = max(cluster.first!.t - 0.8, 0)
            var end = min(max(cluster.last!.t + 1.8, start + 2.5), duration)
            if let prev = blocks.last, start < prev.end + 0.5 {
                // Too close to the previous zoom to zoom out and back in: start right after it.
                start = prev.end
            }
            end = max(end, start)
            guard end - start >= 1 else { continue }
            blocks.append(ZoomBlock(start: start, end: end, scale: scale, focus: centroid(cluster), isAuto: true))
        }
        return blocks
    }

    private static func centroid(_ c: [(t: Double, point: CGPoint)]) -> CGPoint {
        let n = CGFloat(c.count)
        return CGPoint(x: c.reduce(0) { $0 + $1.point.x } / n, y: c.reduce(0) { $0 + $1.point.y } / n)
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
}

/// Everything the compositor needs to know about one instant of the edited video, for one output size.
public struct RenderScene {
    public let project: Project
    public let output: CGSize
    public let cursor: CursorTrack
    public let geometries: [ScreenGeometry]
    private let clipStarts: [Double]
    private let camera: SegmentTimeline<CameraState>
    private var zoom: SegmentTimeline<ViewRect>!

    public init(project: Project, output: CGSize, cursor: CursorTrack) {
        self.project = project
        self.output = output
        self.cursor = cursor
        clipStarts = project.clipStarts
        let geometries = project.clips.map { ScreenGeometry(contentSize: $0.screenPixelSize, output: output, style: project.style) }
        self.geometries = geometries
        let style = project.style
        let duration = project.duration

        func cameraState(_ layout: CameraLayout) -> CameraState {
            CameraLayoutResolver.state(for: layout, output: output, style: style)
        }
        let defaultState = cameraState(project.defaultCamera)
        camera = SegmentTimeline(
            blocks: project.cameraBlocks.map { b in
                let s = cameraState(b.layout)
                return (b.start, b.end, AnyHashable(b.layout), { _ in s })
            },
            gapKey: AnyHashable(project.defaultCamera), gap: { _ in defaultState },
            duration: duration, transition: style.transitionDuration)

        let starts = clipStarts
        let fallback = ScreenGeometry(contentSize: output, output: output, style: style)
        let geometryAt: (Double) -> ScreenGeometry = { t in
            let i = starts.lastIndex { $0 <= t } ?? 0
            return i < geometries.count ? geometries[i] : fallback
        }
        let cursorTrack = cursor
        zoom = SegmentTimeline(
            blocks: project.zoomBlocks.map { b in
                (b.start, b.end, AnyHashable(b.id), { t in ViewRect(geometryAt(t).zoomedView(scale: b.scale, focus: b.focus)) })
            },
            gapKey: AnyHashable("none"),
            gap: { t in
                let g = geometryAt(t)
                guard g.followsCursor else { return ViewRect(g.fullView) }
                let p = cursorTrack.position(at: t) ?? CGPoint(x: 0.5, y: 0.5)
                return ViewRect(g.zoomedView(scale: 1, focus: p))
            },
            duration: duration, transition: style.zoomTransitionDuration)
    }

    public func clipIndex(at t: Double) -> Int { clipStarts.lastIndex { $0 <= t } ?? 0 }

    public func geometry(at t: Double) -> ScreenGeometry {
        let i = clipIndex(at: t)
        return i < geometries.count ? geometries[i] : ScreenGeometry(contentSize: output, output: output, style: project.style)
    }

    public func cameraState(at t: Double) -> CameraState { camera.value(at: t) }

    public func view(at t: Double) -> CGRect { zoom.value(at: t).rect }

    /// View rects to average for motion blur: one when still; when zooming, enough samples spread over the
    /// shutter that neighbouring copies overlap (a smear, not visible ghosts).
    public func viewSamples(at t: Double) -> [CGRect] {
        let now = view(at: t)
        let shutter = project.style.motionBlurAmount / 60
        guard project.style.motionBlur, shutter > 0 else { return [now] }
        let before = view(at: t - shutter)
        // Largest on-screen displacement of any content point over the shutter, in output pixels.
        let k = output.width / now.width
        let edges = [abs(now.minX - before.minX), abs(now.maxX - before.maxX),
                     abs(now.minY - before.minY), abs(now.maxY - before.maxY)]
        let spread = (edges.max() ?? 0) * k
        guard spread > 1.5 else { return [now] }
        let count = min(max(Int((spread / 2.5).rounded(.up)), 3), 24)
        return (0 ..< count).map { view(at: t - shutter * Double($0) / Double(count - 1)) }
    }
}

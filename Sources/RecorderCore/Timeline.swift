import Foundation

public protocol Interpolatable {
    static func interpolate(_ a: Self, _ b: Self, _ t: Double) -> Self
}

public enum Easing {
    /// Ease-in-out cubic: gentle start and settle, which reads as "camera move" rather than "slide".
    public static func inOut(_ x: Double) -> Double {
        let x = min(max(x, 0), 1)
        return x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2
    }
}

/// A timeline split into contiguous segments. Each segment eases in from whatever was on screen
/// at its start, over `transition` seconds, so chains of short blocks stay continuous.
public struct SegmentTimeline<Value: Interpolatable> {
    public struct Segment {
        public var start: Double
        public var end: Double
        /// Identity used to skip transitions between identical neighbours.
        public var key: AnyHashable
        public var value: (Double) -> Value
    }

    public private(set) var segments: [Segment]
    public var transition: Double

    /// Builds segments from blocks; gaps are filled with `gap`. Overlapping blocks are cut where the later one starts.
    public init(blocks: [(start: Double, end: Double, key: AnyHashable, value: (Double) -> Value)],
                gapKey: AnyHashable, gap: @escaping (Double) -> Value, duration: Double, transition: Double) {
        self.transition = transition
        var out: [Segment] = []
        var cursor = 0.0
        let sorted = blocks.filter { $0.end > $0.start }.sorted { $0.start < $1.start }
        for (i, b) in sorted.enumerated() {
            let start = max(b.start, cursor)
            let nextStart = i + 1 < sorted.count ? sorted[i + 1].start : .infinity
            let end = min(b.end, nextStart, max(duration, start))
            guard end > start else { continue }
            if start > cursor { out.append(Segment(start: cursor, end: start, key: gapKey, value: gap)) }
            out.append(Segment(start: start, end: end, key: b.key, value: b.value))
            cursor = end
        }
        if cursor < duration || out.isEmpty {
            out.append(Segment(start: cursor, end: max(duration, cursor), key: gapKey, value: gap))
        }
        segments = out
    }

    public func segmentIndex(at t: Double) -> Int {
        // Few segments per project, so a linear scan is plenty.
        segments.lastIndex { $0.start <= t } ?? 0
    }

    public func value(at t: Double) -> Value {
        value(index: segmentIndex(at: t), t: t)
    }

    private func value(index i: Int, t: Double) -> Value {
        let seg = segments[i]
        let target = seg.value(t)
        guard i > 0, transition > 0, segments[i - 1].key != seg.key else { return target }
        let progress = (t - seg.start) / transition
        guard progress < 1 else { return target }
        let from = value(index: i - 1, t: t)
        return Value.interpolate(from, target, Easing.inOut(progress))
    }
}

import Foundation

/// A removed range of one clip, in that clip's own seconds.
public struct Cut: Codable, Equatable, Identifiable {
    public var id: UUID
    public var clipID: UUID
    public var start: Double
    public var end: Double

    public init(id: UUID = UUID(), clipID: UUID, start: Double, end: Double) {
        self.id = id
        self.clipID = clipID
        self.start = start
        self.end = end
    }
}

/// A split point inside a take, in that take's own seconds.
public struct Split: Codable, Equatable {
    public var clipID: UUID
    public var time: Double
    public init(clipID: UUID, time: Double) {
        self.clipID = clipID
        self.time = time
    }
}

/// A kept piece of a clip and where it lands on the edited timeline.
public struct Segment: Equatable {
    public var clipIndex: Int
    public var sourceStart: Double
    public var sourceEnd: Double
    public var editedStart: Double
    public var duration: Double { sourceEnd - sourceStart }
    public var editedEnd: Double { editedStart + duration }
}

extension Project {
    /// Kept pieces shorter than this are dropped (they'd be a flash frame).
    static let minSegment = 1.0 / 60

    /// Cuts for one clip, merged and sorted.
    func cuts(forClip id: UUID, duration: Double) -> [(Double, Double)] {
        let ranges = cuts.filter { $0.clipID == id }
            .map { (max($0.start, 0), min($0.end, duration)) }
            .filter { $0.1 > $0.0 }
            .sorted { $0.0 < $1.0 }
        var merged: [(Double, Double)] = []
        for r in ranges {
            if let last = merged.last, r.0 <= last.1 {
                merged[merged.count - 1].1 = max(last.1, r.1)
            } else {
                merged.append(r)
            }
        }
        return merged
    }

    /// The edited timeline: every kept piece of every clip, in order. Split points divide pieces without removing time.
    public var segments: [Segment] {
        var out: [Segment] = []
        var t = 0.0
        for (i, clip) in clips.enumerated() {
            let splitTimes = splits.filter { $0.clipID == clip.id }.map(\.time).sorted()
            var cursor = 0.0
            for (a, b) in cuts(forClip: clip.id, duration: clip.duration) + [(clip.duration, clip.duration)] {
                var pieceStart = cursor
                for s in splitTimes where s > pieceStart + Self.minSegment && s < a - Self.minSegment {
                    out.append(Segment(clipIndex: i, sourceStart: pieceStart, sourceEnd: s, editedStart: t))
                    t += s - pieceStart
                    pieceStart = s
                }
                if a - pieceStart >= Self.minSegment {
                    out.append(Segment(clipIndex: i, sourceStart: pieceStart, sourceEnd: a, editedStart: t))
                    t += a - pieceStart
                }
                cursor = max(cursor, b)
            }
        }
        return out
    }

    /// Splits whichever section is under an edited-timeline moment.
    public mutating func split(at t: Double) {
        // Only inside a section, not right on its edge.
        guard let (ci, local) = sourceTime(edited: t),
              segments.contains(where: { $0.clipIndex == ci && local > $0.sourceStart + 0.05 && local < $0.sourceEnd - 0.05 })
        else { return }
        splits.append(Split(clipID: clips[ci].id, time: local))
    }

    /// Moves a section's start or end (clip-local), cutting or restoring the difference. Blocks follow.
    public mutating func trim(segment seg: Segment, newStart: Double? = nil, newEnd: Double? = nil) {
        let ci = seg.clipIndex, id = clips[ci].id
        if let ns = newStart {
            let s = min(max(ns, 0), seg.sourceEnd - 0.1)
            if s > seg.sourceStart { removeSource(clipIndex: ci, from: seg.sourceStart, to: s) } else if s < seg.sourceStart { restore(clipID: id, from: s, to: seg.sourceStart) }
        }
        if let ne = newEnd {
            let start = newStart.map { min(max($0, 0), seg.sourceEnd - 0.1) } ?? seg.sourceStart
            let e = max(min(ne, clips[ci].duration), start + 0.1)
            if e < seg.sourceEnd { removeSource(clipIndex: ci, from: e, to: seg.sourceEnd) } else if e > seg.sourceEnd { restore(clipID: id, from: seg.sourceEnd, to: e) }
        }
    }

    /// Removes one section entirely.
    public mutating func delete(segment seg: Segment) {
        removeTime(from: seg.editedStart, to: seg.editedEnd)
    }

    /// Edited length.
    public var duration: Double { segments.last?.editedEnd ?? 0 }

    /// Edited-timeline start of each clip (a fully cut clip starts where the next one does).
    public var clipStarts: [Double] {
        let segs = segments
        var starts = [Double](repeating: 0, count: clips.count)
        var next = duration
        for i in clips.indices.reversed() {
            if let first = segs.first(where: { $0.clipIndex == i }) { next = first.editedStart }
            starts[i] = next
        }
        return starts
    }

    /// Edited length of each clip.
    public var clipEditedDurations: [Double] {
        let segs = segments
        return clips.indices.map { i in segs.filter { $0.clipIndex == i }.reduce(0) { $0 + $1.duration } }
    }

    /// Where a moment of a clip lands on the edited timeline; nil if it's been cut.
    public func editedTime(clipIndex: Int, local: Double) -> Double? {
        for s in segments where s.clipIndex == clipIndex && local >= s.sourceStart && local <= s.sourceEnd {
            return s.editedStart + (local - s.sourceStart)
        }
        return nil
    }

    /// Edited position of a clip-local time, snapping cut moments to the join where they were removed.
    public func editedPosition(clipIndex: Int, local: Double) -> Double {
        if let e = editedTime(clipIndex: clipIndex, local: local) { return e }
        let segs = segments
        if let next = segs.first(where: { ($0.clipIndex == clipIndex && $0.sourceStart >= local) || $0.clipIndex > clipIndex }) {
            return next.editedStart
        }
        return duration
    }

    /// Which clip and clip-local time an edited-timeline moment shows.
    public func sourceTime(edited t: Double) -> (clipIndex: Int, local: Double)? {
        let segs = segments
        guard let s = segs.last(where: { $0.editedStart <= t }) ?? segs.first else { return nil }
        return (s.clipIndex, s.sourceStart + min(max(t - s.editedStart, 0), s.duration))
    }

    /// Removes an edited-timeline range: records cuts in each affected clip and shifts/trims blocks to match.
    public mutating func removeTime(from a: Double, to b: Double) {
        let a = max(a, 0), b = min(b, duration)
        guard b - a > 1e-6 else { return }
        for s in segments where s.editedEnd > a && s.editedStart < b {
            let lo = s.sourceStart + max(a - s.editedStart, 0)
            let hi = s.sourceStart + min(b - s.editedStart, s.duration)
            cuts.append(Cut(clipID: clips[s.clipIndex].id, start: lo, end: hi))
        }
        normaliseCuts()
        let len = b - a
        func remap(_ start: Double, _ end: Double) -> (Double, Double)? {
            if end <= a { return (start, end) }
            if start >= b { return (start - len, end - len) }
            let ns = start < a ? start : a
            let ne = end > b ? end - len : a
            return ne - ns >= 0.1 ? (ns, ne) : nil
        }
        cameraBlocks = cameraBlocks.compactMap { blk in remap(blk.start, blk.end).map { var blk = blk; (blk.start, blk.end) = $0; return blk } }
        zoomBlocks = zoomBlocks.compactMap { blk in remap(blk.start, blk.end).map { var blk = blk; (blk.start, blk.end) = $0; return blk } }
    }

    /// Removes a clip-local range (whatever of it is still kept).
    public mutating func removeSource(clipIndex: Int, from a: Double, to b: Double) {
        let ea = editedPosition(clipIndex: clipIndex, local: a)
        let eb = editedPosition(clipIndex: clipIndex, local: b)
        removeTime(from: ea, to: eb)
    }

    /// Puts back a clip-local range that was cut; blocks after the join move later to make room.
    public mutating func restore(clipID: UUID, from a: Double, to b: Double) {
        guard let ci = clips.firstIndex(where: { $0.id == clipID }) else { return }
        let before = duration
        let join = editedPosition(clipIndex: ci, local: a)
        var kept: [Cut] = []
        for c in cuts {
            guard c.clipID == clipID, c.end > a, c.start < b else {
                kept.append(c)
                continue
            }
            if c.start < a { kept.append(Cut(clipID: clipID, start: c.start, end: a)) }
            if c.end > b { kept.append(Cut(clipID: clipID, start: b, end: c.end)) }
        }
        cuts = kept
        let len = duration - before
        guard len > 1e-6 else { return }
        func remap(_ start: Double, _ end: Double) -> (Double, Double) {
            if start >= join { return (start + len, end + len) }
            if end > join { return (start, end + len) }
            return (start, end)
        }
        for i in cameraBlocks.indices { (cameraBlocks[i].start, cameraBlocks[i].end) = remap(cameraBlocks[i].start, cameraBlocks[i].end) }
        for i in zoomBlocks.indices { (zoomBlocks[i].start, zoomBlocks[i].end) = remap(zoomBlocks[i].start, zoomBlocks[i].end) }
    }

    /// Merges overlapping cuts per clip so the list stays small and restore works on whole ranges.
    mutating func normaliseCuts() {
        var out: [Cut] = []
        for clip in clips {
            for (a, b) in cuts(forClip: clip.id, duration: clip.duration) {
                out.append(Cut(clipID: clip.id, start: a, end: b))
            }
        }
        cuts = out
    }

    /// Whether a clip-local moment has been cut.
    public func isCut(clipID: UUID, local: Double) -> Bool {
        cuts.contains { $0.clipID == clipID && local >= $0.start && local < $0.end }
    }
}

extension Project {
    /// Cuts a run of consecutive words from one clip: from just before the first word to just before the next
    /// word (taking the pause after the run too), so the remaining speech joins naturally.
    public mutating func removeWords(clipIndex: Int, words: [Word], first: Int, last: Int) {
        guard words.indices.contains(first), words.indices.contains(last), first <= last else { return }
        let prevEnd = first > 0 ? words[first - 1].end : 0
        let start = max(words[first].start - 0.03, (prevEnd + words[first].start) / 2)
        var end: Double
        if last + 1 < words.count {
            let next = words[last + 1]
            end = next.start - words[last].end < 1.0 ? next.start - 0.03 : words[last].end + 0.25
        } else {
            end = min(words[last].end + 0.12, clips[clipIndex].duration)
        }
        removeSource(clipIndex: clipIndex, from: start, to: max(end, start))
    }
}

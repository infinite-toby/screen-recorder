import Foundation

/// One recognised word, in its clip's own seconds.
public struct Word: Codable, Equatable {
    public var text: String
    public var start: Double
    public var end: Double
    /// Removed from subtitles only (the video isn't cut).
    public var hidden: Bool?

    public init(text: String, start: Double, end: Double) {
        self.text = text
        self.start = start
        self.end = end
    }
}

public struct Transcript: Codable, Equatable {
    public var locale: String
    public var words: [Word]

    public init(locale: String, words: [Word]) {
        self.locale = locale
        self.words = words
    }
}

public struct SubtitleSettings: Codable, Equatable {
    public enum Position: String, Codable, CaseIterable { case bottom, top }

    /// Draw captions into the video (preview and export).
    public var burnIn = false
    public var position: Position = .bottom
    /// Text height as a fraction of the output's shorter side.
    public var size = 0.045
    /// Highlight the word being spoken.
    public var highlightWord = true
    public var maxCharacters = 48

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SubtitleSettings()
        burnIn = try c.decodeIfPresent(Bool.self, forKey: .burnIn) ?? d.burnIn
        position = try c.decodeIfPresent(Position.self, forKey: .position) ?? d.position
        size = try c.decodeIfPresent(Double.self, forKey: .size) ?? d.size
        highlightWord = try c.decodeIfPresent(Bool.self, forKey: .highlightWord) ?? d.highlightWord
        maxCharacters = try c.decodeIfPresent(Int.self, forKey: .maxCharacters) ?? d.maxCharacters
    }
}

/// A caption on the edited timeline.
public struct Caption: Equatable {
    public struct TimedWord: Equatable {
        public var text: String
        public var start: Double
        public var end: Double
        /// Source word, for editing subtitles.
        public var clipIndex: Int = 0
        public var wordIndex: Int = 0
    }

    public var start: Double
    public var end: Double
    public var words: [TimedWord]
    public var text: String { words.map(\.text).joined(separator: " ") }

    /// Index of the word being spoken at `t` (the last one started), for highlighting.
    public func wordIndex(at t: Double) -> Int? {
        words.lastIndex { $0.start <= t }
    }
}

public enum CaptionBuilder {
    /// Groups the words that survive editing into readable captions on the edited timeline.
    public static func captions(project: Project, transcripts: [UUID: Transcript], maxCharacters: Int) -> [Caption] {
        var timed: [Caption.TimedWord] = []
        for (i, clip) in project.clips.enumerated() {
            guard let t = transcripts[clip.id] else { continue }
            for (wi, w) in t.words.enumerated() where w.hidden != true {
                // A word stays if its middle wasn't cut.
                guard let s = project.editedTime(clipIndex: i, local: (w.start + w.end) / 2) else { continue }
                let half = (w.end - w.start) / 2
                timed.append(.init(text: w.text, start: max(s - half, 0), end: s + half, clipIndex: i, wordIndex: wi))
            }
        }
        timed.sort { $0.start < $1.start }

        var out: [Caption] = []
        var current: [Caption.TimedWord] = []
        func flush() {
            guard let first = current.first, let last = current.last else { return }
            out.append(Caption(start: first.start, end: last.end, words: current))
            current = []
        }
        for w in timed {
            if let last = current.last {
                let chars = current.reduce(0) { $0 + $1.text.count + 1 } + w.text.count
                let endsSentence = last.text.last.map { ".?!".contains($0) } ?? false
                if chars > maxCharacters || w.start - last.end > 0.7 || (endsSentence && current.count >= 3) {
                    flush()
                }
            }
            current.append(w)
        }
        flush()

        // Fold a one- or two-word leftover into the caption before it when they're close in time
        // (the renderer wraps long captions onto two lines), rather than flashing up a lonely word.
        var merged: [Caption] = []
        for c in out {
            let lastEndsSentence = merged.last?.words.last?.text.last.map { ".?!".contains($0) } ?? true
            if let last = merged.last, !lastEndsSentence, c.words.count <= 2, c.start - last.end < 0.4,
               last.text.count + 1 + c.text.count <= maxCharacters + 16 {
                merged[merged.count - 1].words += c.words
                merged[merged.count - 1].end = c.end
            } else {
                merged.append(c)
            }
        }
        out = merged

        // Hold each caption a little past its last word (without overlapping the next), with a minimum on screen.
        for i in out.indices {
            let next = i + 1 < out.count ? out[i + 1].start : .infinity
            out[i].end = min(max(out[i].end + 0.3, out[i].start + 0.8), next)
        }
        return out
    }

    public static func caption(at t: Double, in captions: [Caption]) -> Caption? {
        captions.last { $0.start <= t && t < $0.end }
    }
}

public enum SRT {
    public static func make(_ captions: [Caption]) -> String {
        captions.enumerated().map { i, c in
            "\(i + 1)\n\(stamp(c.start)) --> \(stamp(c.end))\n\(c.text)\n"
        }.joined(separator: "\n")
    }

    static func stamp(_ t: Double) -> String {
        let ms = Int((max(t, 0) * 1000).rounded())
        return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, ms / 60000 % 60, ms / 1000 % 60, ms % 1000)
    }
}

public enum SubtitleEdit {
    /// Applies retyped caption text to the caption's words without touching the video: unchanged words keep their
    /// timing, retyped words take the new text, deleted words are hidden from subtitles, and added words join the
    /// word before them (or the next one, at the start).
    public static func apply(_ newText: String, to words: [Word]) -> [Word] {
        let old = words.map(\.text)
        let new = newText.split(whereSeparator: \.isWhitespace).map(String.init)
        let diff = new.difference(from: old)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in diff {
            switch change {
            case let .remove(offset, _, _): removed.insert(offset)
            case let .insert(offset, _, _): inserted.insert(offset)
            }
        }
        var out = words
        var i = 0, j = 0
        var pending: [String] = []
        var lastVisible: Int?
        func attach(_ extra: [String], before index: Int?) {
            guard !extra.isEmpty else { return }
            if let v = lastVisible {
                out[v].text += " " + extra.joined(separator: " ")
            } else if let n = index {
                out[n].text = extra.joined(separator: " ") + " " + out[n].text
            }
        }
        while i < old.count || j < new.count {
            if j < new.count, inserted.contains(j) {
                pending.append(new[j])
                j += 1
            } else if i < old.count, removed.contains(i) {
                if pending.isEmpty {
                    out[i].hidden = true
                } else {
                    // Removed and retyped at the same spot: a replacement.
                    out[i].text = pending.joined(separator: " ")
                    out[i].hidden = nil
                    pending = []
                    lastVisible = i
                }
                i += 1
            } else if i < old.count {
                attach(pending, before: i)
                pending = []
                out[i].hidden = nil
                lastVisible = i
                i += 1
                j += 1
            } else {
                break
            }
        }
        if !pending.isEmpty {
            if let v = lastVisible {
                attach(pending, before: nil)
            } else if let first = out.indices.first {
                out[first].text = pending.joined(separator: " ")
                out[first].hidden = nil
            }
        }
        return out
    }
}

import CoreGraphics
import Foundation

/// A project is a folder bundle: `project.json` plus one folder per clip holding raw tracks.
/// Block times (camera, zoom) are seconds on the *edited* timeline: clips back-to-back with cuts removed.
/// Cuts and transcripts are in each clip's own (source) time, so they never move.
public struct Project: Codable, Equatable {
    public var version = 1
    public var name: String
    public var createdAt: Date
    public var clips: [Clip]
    public var cameraBlocks: [CameraBlock]
    public var zoomBlocks: [ZoomBlock]
    /// Camera layout used wherever no camera block covers the timeline.
    public var defaultCamera: CameraLayout
    public var style: FrameStyle
    public var export: ExportSettings
    /// Removed ranges, in clip-local seconds.
    public var cuts: [Cut]
    /// Points (clip-local) where a take is split into separately trimmable/deletable sections.
    public var splits: [Split]
    public var subtitles: SubtitleSettings
    /// 0 mutes; 1 is as recorded.
    public var micVolume: Double
    public var screenAudioVolume: Double

    public init(name: String, createdAt: Date = Date()) {
        self.name = name
        self.createdAt = createdAt
        clips = []
        cameraBlocks = []
        zoomBlocks = []
        defaultCamera = .corner(.bottomRight, .square, .small)
        style = FrameStyle()
        export = ExportSettings()
        cuts = []
        splits = []
        subtitles = SubtitleSettings()
        micVolume = 1
        screenAudioVolume = 1
    }

    /// Missing keys fall back to defaults, so older projects still open.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Project(name: "")
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        name = try c.decode(String.self, forKey: .name)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        clips = try c.decodeIfPresent([Clip].self, forKey: .clips) ?? []
        cameraBlocks = try c.decodeIfPresent([CameraBlock].self, forKey: .cameraBlocks) ?? []
        zoomBlocks = try c.decodeIfPresent([ZoomBlock].self, forKey: .zoomBlocks) ?? []
        defaultCamera = try c.decodeIfPresent(CameraLayout.self, forKey: .defaultCamera) ?? d.defaultCamera
        style = try c.decodeIfPresent(FrameStyle.self, forKey: .style) ?? d.style
        export = try c.decodeIfPresent(ExportSettings.self, forKey: .export) ?? d.export
        cuts = try c.decodeIfPresent([Cut].self, forKey: .cuts) ?? []
        subtitles = try c.decodeIfPresent(SubtitleSettings.self, forKey: .subtitles) ?? d.subtitles
        splits = try c.decodeIfPresent([Split].self, forKey: .splits) ?? []
        micVolume = try c.decodeIfPresent(Double.self, forKey: .micVolume) ?? 1
        screenAudioVolume = try c.decodeIfPresent(Double.self, forKey: .screenAudioVolume) ?? 1
    }

    public var hasCamera: Bool { clips.contains { $0.cameraFile != nil } }
}

public struct Clip: Codable, Equatable, Identifiable {
    public var id: UUID
    /// Paths relative to the project bundle.
    public var screenFile: String
    public var cameraFile: String?
    public var micFile: String?
    /// Audio from the recorded screen (apps/system), or an imported video's soundtrack.
    public var screenAudioFile: String?
    public var cursorFile: String?
    /// Word-timed transcript of the mic track, if transcribed.
    public var transcriptFile: String?
    /// Bad single camera frames to hide (clip-local); nil until the camera track has been scanned.
    public var cameraGlitches: [TimeSpan]?
    /// Full recorded length (before cuts).
    public var duration: Double
    /// Pixel size of the recorded screen video.
    public var screenPixelSize: CGSize
    /// Captured region in global display coordinates (points, top-left origin), used to map cursor positions.
    public var captureRect: CGRect

    public init(id: UUID = UUID(), screenFile: String, cameraFile: String? = nil, micFile: String? = nil,
                cursorFile: String? = nil, duration: Double, screenPixelSize: CGSize, captureRect: CGRect) {
        self.id = id
        self.screenFile = screenFile
        self.cameraFile = cameraFile
        self.micFile = micFile
        self.cursorFile = cursorFile
        self.duration = duration
        self.screenPixelSize = screenPixelSize
        self.captureRect = captureRect
    }
}

// MARK: - Camera

public enum Corner: String, Codable, CaseIterable {
    case topLeft, topRight, bottomLeft, bottomRight
}

public enum CameraShape: String, Codable, CaseIterable {
    case landscape, portrait, square
}

public enum CameraSize: String, Codable, CaseIterable {
    case small, large
}

/// Layouts are semantic (anchor, shape, size), not pixels, so one timeline renders to any output aspect.
public enum CameraLayout: Codable, Equatable, Hashable {
    case hidden
    case corner(Corner, CameraShape, CameraSize)
    /// Large landscape camera centred in frame; `coverage` is its width as a fraction of the output width.
    case centre(coverage: Double)
}

public struct CameraBlock: Codable, Equatable, Identifiable {
    public var id: UUID
    public var start: Double
    public var end: Double
    public var layout: CameraLayout

    public init(id: UUID = UUID(), start: Double, end: Double, layout: CameraLayout) {
        self.id = id
        self.start = start
        self.end = end
        self.layout = layout
    }
}

// MARK: - Zoom

public struct ZoomBlock: Codable, Equatable, Identifiable {
    public var id: UUID
    public var start: Double
    public var end: Double
    /// 1 = screen fills the frame edge to edge; 2 = twice that.
    public var scale: Double
    /// Focal point in screen-content coordinates (0...1, top-left origin).
    public var focus: CGPoint
    /// True when created by auto-zoom and not yet touched by hand.
    public var isAuto: Bool

    public init(id: UUID = UUID(), start: Double, end: Double, scale: Double = 2, focus: CGPoint = CGPoint(x: 0.5, y: 0.5),
                isAuto: Bool = false) {
        self.id = id
        self.start = start
        self.end = end
        self.scale = scale
        self.focus = focus
        self.isAuto = isAuto
    }
}

// MARK: - Style & export

public struct RGBA: Codable, Equatable, Hashable {
    public var r, g, b, a: Double
    public init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }
}

public struct FrameStyle: Codable, Equatable {
    public var backgroundTop = RGBA(0.36, 0.30, 0.85)
    public var backgroundBottom = RGBA(0.92, 0.45, 0.62)
    /// Background image, relative to the project bundle; replaces the gradient when set.
    public var backgroundImage: String?
    /// Screen fills the frame: no padding, rounded corners or shadow.
    public var fullScreen = false
    /// Padding around the screen as a fraction of the output's shorter side.
    public var padding = 0.06
    /// Screen corner radius as a fraction of the output's shorter side.
    public var screenCornerRadius = 0.018
    public var shadow = 0.5
    /// Camera corner radius as a fraction of the camera's shorter side.
    public var cameraCornerRadius = 0.14
    public var mirrorCamera = true
    /// Camera background blur strength, 0 (off) ... 1.
    public var cameraBackgroundBlur = 0.0
    public var motionBlur = true
    /// 0...1; 1 = a full 1/60 s shutter.
    public var motionBlurAmount = 0.4
    /// Seconds for camera layout transitions.
    public var transitionDuration = 0.6
    /// Seconds for zoom in/out.
    public var zoomTransitionDuration = 1.0

    public init() {}

    public var effectivePadding: Double { fullScreen ? 0 : padding }
    public var effectiveScreenCornerRadius: Double { fullScreen ? 0 : screenCornerRadius }
    public var effectiveShadow: Double { fullScreen ? 0 : shadow }

    /// Missing keys fall back to defaults, so projects saved before a setting existed still open.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = FrameStyle()
        backgroundTop = try c.decodeIfPresent(RGBA.self, forKey: .backgroundTop) ?? d.backgroundTop
        backgroundBottom = try c.decodeIfPresent(RGBA.self, forKey: .backgroundBottom) ?? d.backgroundBottom
        backgroundImage = try c.decodeIfPresent(String.self, forKey: .backgroundImage)
        fullScreen = try c.decodeIfPresent(Bool.self, forKey: .fullScreen) ?? d.fullScreen
        padding = try c.decodeIfPresent(Double.self, forKey: .padding) ?? d.padding
        screenCornerRadius = try c.decodeIfPresent(Double.self, forKey: .screenCornerRadius) ?? d.screenCornerRadius
        shadow = try c.decodeIfPresent(Double.self, forKey: .shadow) ?? d.shadow
        cameraCornerRadius = try c.decodeIfPresent(Double.self, forKey: .cameraCornerRadius) ?? d.cameraCornerRadius
        mirrorCamera = try c.decodeIfPresent(Bool.self, forKey: .mirrorCamera) ?? d.mirrorCamera
        cameraBackgroundBlur = try c.decodeIfPresent(Double.self, forKey: .cameraBackgroundBlur) ?? d.cameraBackgroundBlur
        motionBlur = try c.decodeIfPresent(Bool.self, forKey: .motionBlur) ?? d.motionBlur
        motionBlurAmount = try c.decodeIfPresent(Double.self, forKey: .motionBlurAmount) ?? d.motionBlurAmount
        transitionDuration = try c.decodeIfPresent(Double.self, forKey: .transitionDuration) ?? d.transitionDuration
        zoomTransitionDuration = try c.decodeIfPresent(Double.self, forKey: .zoomTransitionDuration) ?? d.zoomTransitionDuration
    }
}

public enum OutputAspect: String, Codable, CaseIterable {
    case landscape16x9 = "16:9"
    case portrait9x16 = "9:16"
    case square1x1 = "1:1"

    /// Output size whose shorter side is `shortSide` pixels.
    public func size(shortSide: Int) -> CGSize {
        switch self {
        case .landscape16x9: CGSize(width: shortSide * 16 / 9, height: shortSide)
        case .portrait9x16: CGSize(width: shortSide, height: shortSide * 16 / 9)
        case .square1x1: CGSize(width: shortSide, height: shortSide)
        }
    }
}

public enum OutputResolution: Int, Codable, CaseIterable {
    case p1080 = 1080, p1440 = 1440, p2160 = 2160

    public var label: String {
        switch self {
        case .p1080: "1080p"
        case .p1440: "1440p"
        case .p2160: "4K"
        }
    }
}

public struct ExportSettings: Codable, Equatable {
    public var aspect: OutputAspect = .landscape16x9
    public var resolution: OutputResolution = .p2160
    public var fps = 60
    public var hevc = true

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ExportSettings()
        aspect = try c.decodeIfPresent(OutputAspect.self, forKey: .aspect) ?? d.aspect
        resolution = try c.decodeIfPresent(OutputResolution.self, forKey: .resolution) ?? d.resolution
        fps = try c.decodeIfPresent(Int.self, forKey: .fps) ?? d.fps
        hevc = try c.decodeIfPresent(Bool.self, forKey: .hevc) ?? d.hevc
    }

    public var renderSize: CGSize { aspect.size(shortSide: resolution.rawValue) }
}

// MARK: - Cursor log

/// Cursor samples for one clip. Positions are normalised to the clip's capture rect (top-left origin);
/// values outside 0...1 mean the cursor was outside the captured area.
public struct CursorLog: Codable, Equatable {
    public struct Sample: Codable, Equatable {
        public var t: Double
        public var x: Double
        public var y: Double
        public init(t: Double, x: Double, y: Double) { self.t = t; self.x = x; self.y = y }
    }

    public var samples: [Sample]
    public var clicks: [Sample]

    public init(samples: [Sample] = [], clicks: [Sample] = []) {
        self.samples = samples
        self.clicks = clicks
    }
}

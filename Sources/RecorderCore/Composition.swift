import AVFoundation
import CoreImage
import Foundation

/// Shared, mutable render inputs read by the compositor on AVFoundation's threads.
/// Editing swaps in a new project; the compositor picks it up on the next frame it draws.
public final class RenderState: @unchecked Sendable {
    private let lock = NSLock()
    private var project: Project
    private var cursor: CursorTrack
    private var options = FrameRenderer.Options()
    private var sceneCache: (size: CGSize, scene: RenderScene)?

    public init(project: Project, cursor: CursorTrack) {
        self.project = project
        self.cursor = cursor
    }

    public func update(project: Project, cursor: CursorTrack? = nil) {
        lock.withLock {
            self.project = project
            if let cursor { self.cursor = cursor }
            sceneCache = nil
        }
    }

    /// Updates preview/export flags; the background image and captions are kept.
    public func update(options: FrameRenderer.Options) {
        lock.withLock {
            let bg = self.options.backgroundImage, captions = self.options.captions
            self.options = options
            self.options.backgroundImage = bg
            self.options.captions = captions
        }
    }

    public func update(captions: [Caption]) {
        lock.withLock { options.captions = captions }
    }

    public func update(backgroundImage: CIImage?) {
        lock.withLock { options.backgroundImage = backgroundImage }
    }

    func snapshot(size: CGSize) -> (RenderScene, FrameRenderer.Options) {
        lock.withLock {
            if let c = sceneCache, c.size == size { return (c.scene, options) }
            let scene = RenderScene(project: project, output: size, cursor: cursor)
            sceneCache = (size, scene)
            return (scene, options)
        }
    }
}

final class ProjectInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid
    let screenTrackID: CMPersistentTrackID
    let cameraTrackID: CMPersistentTrackID
    let state: RenderState

    init(timeRange: CMTimeRange, screenTrackID: CMPersistentTrackID, cameraTrackID: CMPersistentTrackID, state: RenderState) {
        self.timeRange = timeRange
        self.screenTrackID = screenTrackID
        self.cameraTrackID = cameraTrackID
        self.state = state
        requiredSourceTrackIDs = [screenTrackID, cameraTrackID]
            .filter { $0 != kCMPersistentTrackID_Invalid }
            .map { NSNumber(value: $0) }
    }
}

final class ProjectCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    static let renderer = FrameRenderer()

    let sourcePixelBufferAttributes: [String: any Sendable]? = [
        kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA],
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
    ]
    let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA],
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
    ]

    private let queue = DispatchQueue(label: "compositor", qos: .userInitiated)
    private var renderContext: AVVideoCompositionRenderContext?
    /// Screen captures only deliver frames when something changes; hold the last one across tiny gaps.
    private var lastScreen: (time: Double, image: CIImage)?
    /// Last good camera frame, shown in place of a known glitch frame.
    private var lastCamera: (time: Double, image: CIImage)?

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
        queue.sync { renderContext = newRenderContext }
    }

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        queue.async { [self] in
            guard let instruction = request.videoCompositionInstruction as? ProjectInstruction,
                  let out = renderContext?.newPixelBuffer() else {
                request.finish(with: NSError(domain: "Compositor", code: 1))
                return
            }
            let t = request.compositionTime.seconds
            var screen = request.sourceFrame(byTrackID: instruction.screenTrackID).map { CIImage(cvPixelBuffer: $0) }
            if let screen {
                lastScreen = (t, screen)
            } else if let last = lastScreen, abs(t - last.time) < 0.5 {
                screen = last.image
            }
            let size = CGSize(width: CVPixelBufferGetWidth(out), height: CVPixelBufferGetHeight(out))
            let (scene, options) = instruction.state.snapshot(size: size)
            // Past the end of a take's camera file AVFoundation keeps handing back its last frame, so the
            // take itself decides whether there is a camera.
            let clips = scene.project.clips
            let clipIndex = scene.clipIndex(at: t)
            let takeHasCamera = clipIndex < clips.count && clips[clipIndex].cameraFile != nil
            var camera = !takeHasCamera || instruction.cameraTrackID == kCMPersistentTrackID_Invalid ? nil
                : request.sourceFrame(byTrackID: instruction.cameraTrackID).map { CIImage(cvPixelBuffer: $0) }
            if let current = camera {
                let glitches = clipIndex < clips.count ? clips[clipIndex].cameraGlitches ?? [] : []
                let local = scene.project.sourceTime(edited: t)?.local ?? t
                if glitches.contains(where: { $0.contains(local) }), let last = lastCamera, abs(t - last.time) < 0.3 {
                    camera = last.image
                } else {
                    lastCamera = (t, current)
                }
            }
            let image = Self.renderer.render(scene: scene, time: t, screen: screen, camera: camera, options: options)
            Self.renderer.context.render(image, to: out, bounds: CGRect(origin: .zero, size: size),
                                         colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            request.finish(withComposedVideoFrame: out)
        }
    }

    func cancelAllPendingVideoCompositionRequests() {}
}

/// Builds the playable/exportable timeline: all clips back-to-back, screen + camera video, mic audio.
public enum CompositionBuilder {
    public struct Result {
        public let composition: AVComposition
        public let videoComposition: AVVideoComposition
        /// Short fades at every join so cuts don't click.
        public let audioMix: AVAudioMix?
    }

    public static func build(project: Project, bundle: ProjectBundle, state: RenderState,
                             renderSize: CGSize, fps: Int) async throws -> Result {
        let comp = AVMutableComposition()
        guard let screenTrack = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let cameraTrack = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let micTrack = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid),
              let screenAudioTrack = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw NSError(domain: "Composition", code: 1) }

        // Load each clip's source tracks once. The assets must outlive the inserts (a track doesn't retain its asset).
        var assets: [AVURLAsset] = []
        func track(_ file: String?, _ type: AVMediaType) async throws -> AVAssetTrack? {
            guard let file else { return nil }
            let asset = AVURLAsset(url: bundle.file(file))
            assets.append(asset)
            return try await asset.loadTracks(withMediaType: type).first
        }
        typealias Sources = (screen: AVAssetTrack?, camera: AVAssetTrack?, mic: AVAssetTrack?, screenAudio: AVAssetTrack?)
        var sources: [Int: Sources] = [:]
        for (i, clip) in project.clips.enumerated() {
            sources[i] = (try await track(clip.screenFile, .video), try await track(clip.cameraFile, .video),
                          try await track(clip.micFile, .audio), try await track(clip.screenAudioFile, .audio))
        }

        let scale: CMTimeScale = 600
        var cursor = CMTime.zero
        var joins: [CMTime] = []
        var previous: Segment?
        for seg in project.segments {
            let src = sources[seg.clipIndex]!
            let from = CMTime(seconds: seg.sourceStart, preferredTimescale: scale)
            let len = CMTime(seconds: seg.duration, preferredTimescale: scale)
            try await insert(src.screen, from: from, duration: len, into: screenTrack, at: cursor)
            try await insert(src.camera, from: from, duration: len, into: cameraTrack, at: cursor)
            try await insert(src.mic, from: from, duration: len, into: micTrack, at: cursor)
            try await insert(src.screenAudio, from: from, duration: len, into: screenAudioTrack, at: cursor)
            // Fade only where the sound actually jumps (a cut or a new take), not at a plain split.
            if let p = previous, p.clipIndex != seg.clipIndex || abs(p.sourceEnd - seg.sourceStart) > 0.001 { joins.append(cursor) }
            previous = seg
            cursor = cursor + len
        }

        // A track with no media at all (e.g. no camera in any take) would make the composition invalid.
        var cameraID = cameraTrack.trackID
        if cameraTrack.segments.allSatisfy(\.isEmpty) {
            comp.removeTrack(cameraTrack)
            cameraID = kCMPersistentTrackID_Invalid
        }
        var params: [AVAudioMixInputParameters] = []
        let fade = CMTime(value: 12, timescale: 1000)
        for (track, volume) in [(micTrack, project.micVolume), (screenAudioTrack, project.screenAudioVolume)] {
            if track.segments.allSatisfy(\.isEmpty) {
                comp.removeTrack(track)
                continue
            }
            let p = AVMutableAudioMixInputParameters(track: track)
            let v = Float(max(volume, 0))
            p.setVolume(v, at: .zero)
            for j in joins where v > 0 {
                p.setVolumeRamp(fromStartVolume: v, toEndVolume: 0, timeRange: CMTimeRange(start: j - fade, duration: fade))
                p.setVolumeRamp(fromStartVolume: 0, toEndVolume: v, timeRange: CMTimeRange(start: j, duration: fade))
            }
            params.append(p)
        }
        var audioMix: AVAudioMix?
        if !params.isEmpty {
            let mix = AVMutableAudioMix()
            mix.inputParameters = params
            audioMix = mix
        }

        withExtendedLifetime(assets) {}
        let total = CMTimeRange(start: .zero, duration: cursor)
        let vc = AVMutableVideoComposition()
        vc.customVideoCompositorClass = ProjectCompositor.self
        vc.renderSize = renderSize
        vc.frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
        vc.instructions = [ProjectInstruction(timeRange: total, screenTrackID: screenTrack.trackID,
                                              cameraTrackID: cameraID, state: state)]
        return Result(composition: comp, videoComposition: vc, audioMix: audioMix)
    }

    /// Inserts `duration` of `source` starting at `from`, padding with empty time where the source runs short.
    private static func insert(_ source: AVAssetTrack?, from: CMTime, duration: CMTime, into track: AVMutableCompositionTrack,
                               at start: CMTime) async throws {
        var used = CMTime.zero
        if let source {
            let range = try await source.load(.timeRange)
            let begin = range.start + from
            let len = CMTimeMinimum(range.end - begin, duration)
            if len > .zero {
                try track.insertTimeRange(CMTimeRange(start: begin, duration: len), of: source, at: start)
                used = len
            }
        }
        if used < duration {
            track.insertEmptyTimeRange(CMTimeRange(start: start + used, duration: duration - used))
        }
    }
}

public enum Exporter {
    /// Renders the project to a movie file at the project's export settings, reporting progress 0...1.
    public static func export(project: Project, bundle: ProjectBundle, cursor: CursorTrack, captions: [Caption] = [], to url: URL,
                              progress: @escaping @Sendable (Double) -> Void) async throws {
        let settings = project.export
        let state = RenderState(project: project, cursor: cursor)
        state.update(options: FrameRenderer.Options(accurateSegmentation: true))
        state.update(backgroundImage: bundle.backgroundImage(for: project))
        state.update(captions: captions)
        let built = try await CompositionBuilder.build(project: project, bundle: bundle, state: state,
                                                       renderSize: settings.renderSize, fps: settings.fps)
        let preset = settings.hevc ? AVAssetExportPresetHEVCHighestQuality : AVAssetExportPresetHighestQuality
        guard let session = AVAssetExportSession(asset: built.composition, presetName: preset) else {
            throw NSError(domain: "Export", code: 1, userInfo: [NSLocalizedDescriptionKey: "Export preset unavailable"])
        }
        session.videoComposition = built.videoComposition
        session.audioMix = built.audioMix
        try? FileManager.default.removeItem(at: url)
        let type: AVFileType = url.pathExtension.lowercased() == "mov" ? .mov : .mp4
        let watcher = Task {
            for await s in session.states(updateInterval: 0.2) {
                if case let .exporting(p) = s { progress(p.fractionCompleted) }
            }
        }
        defer { watcher.cancel() }
        try await session.export(to: url, as: type)
        progress(1)
    }
}

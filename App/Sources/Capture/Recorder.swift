import AppKit
import AVFoundation
import RecorderCore
import ScreenCaptureKit

/// Records screen, camera and mic into separate files per take, all aligned on the host clock.
/// Pause ends the current take; resume starts a new one. Every sample is handled on one serial queue.
final class Recorder: NSObject, @unchecked Sendable {
    struct Settings {
        var source: CaptureSource
        var cameraID: String?
        var micID: String?
        var fps = 60
        /// Also record what the screen is playing (apps/system audio, not this app).
        var screenAudio = true
    }

    private let settings: Settings
    private let bundle: ProjectBundle
    private let queue = DispatchQueue(label: "recorder.samples", qos: .userInteractive)
    private let hostClock = CMClockGetHostTimeClock()

    private var resolved: ResolvedSource?
    private var stream: SCStream?
    private var session: AVCaptureSession?
    private var take: TakeWriter?
    /// Latest mic level in dB, measured from the recorded samples.
    let micLevel = LevelBox()
    private let cursor = CursorLogger()
    /// Camera + mic session; also feeds the preview bubble shown while recording.
    private(set) var captureSession: AVCaptureSession?

    init(settings: Settings, bundle: ProjectBundle) {
        self.settings = settings
        self.bundle = bundle
    }

    // MARK: - Lifecycle

    /// Starts capture devices (without writing) so the first take begins instantly.
    func prepare() async throws {
        let resolved = try await SourceResolver.resolve(settings.source)
        self.resolved = resolved

        let config = SCStreamConfiguration()
        config.width = Int(resolved.pixelSize.width)
        config.height = Int(resolved.pixelSize.height)
        if let r = resolved.sourceRect { config.sourceRect = r }
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(settings.fps))
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.showsCursor = true
        config.queueDepth = 8
        config.capturesAudio = settings.screenAudio
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48000
        config.channelCount = 2
        let stream = SCStream(filter: resolved.filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if settings.screenAudio { try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue) }
        try await stream.startCapture()
        self.stream = stream

        if settings.cameraID != nil || settings.micID != nil {
            let session = AVCaptureSession()
            session.beginConfiguration()
            if let id = settings.cameraID, let device = AVCaptureDevice(uniqueID: id) {
                let input = try AVCaptureDeviceInput(device: device)
                if session.canAddInput(input) { session.addInput(input) }
                let out = AVCaptureVideoDataOutput()
                out.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                out.alwaysDiscardsLateVideoFrames = true
                out.setSampleBufferDelegate(self, queue: queue)
                if session.canAddOutput(out) { session.addOutput(out) }
            }
            if let id = settings.micID, let device = AVCaptureDevice(uniqueID: id) {
                let input = try AVCaptureDeviceInput(device: device)
                if session.canAddInput(input) { session.addInput(input) }
                let out = AVCaptureAudioDataOutput()
                out.setSampleBufferDelegate(self, queue: queue)
                if session.canAddOutput(out) { session.addOutput(out) }
            }
            session.commitConfiguration()
            session.startRunning()
            captureSession = session
        }
    }

    func startTake() throws {
        guard let resolved else { return }
        let id = UUID()
        let (dir, rel) = try bundle.makeClipFolder(id: id)
        let writer = try TakeWriter(id: id, dir: dir, relative: rel, screenSize: resolved.pixelSize,
                                    fps: settings.fps, hasCamera: hasCameraOutput, hasMic: hasMicOutput,
                                    hasScreenAudio: settings.screenAudio)
        queue.sync { take = writer }
        cursor.start(globalRect: resolved.globalRect)
    }

    /// Ends the current take and returns its clip (nil if nothing was captured).
    func endTake() async -> Clip? {
        let stopTime = CMClockGetTime(hostClock)
        let writer: TakeWriter? = queue.sync {
            let w = take
            take = nil
            return w
        }
        let log = cursor.stop()
        guard let writer, let resolved else { return nil }
        return await writer.finish(at: stopTime, captureRect: resolved.globalRect, cursor: log)
    }

    func shutdown() async {
        if let stream { try? await stream.stopCapture() }
        stream = nil
        captureSession?.stopRunning()
        captureSession = nil
    }

    private var hasCameraOutput: Bool { captureSession?.outputs.contains { $0 is AVCaptureVideoDataOutput } ?? false }
    private var hasMicOutput: Bool { captureSession?.outputs.contains { $0 is AVCaptureAudioDataOutput } ?? false }

    /// Capture devices may run on their own clock; rebase sample times onto the host clock the screen uses.
    fileprivate func hostTimed(_ sample: CMSampleBuffer) -> CMSampleBuffer? {
        guard let clock = captureSession?.synchronizationClock, !CFEqual(clock, hostClock) else { return sample }
        let pts = CMSyncConvertTime(CMSampleBufferGetPresentationTimeStamp(sample), from: clock, to: hostClock)
        var timing = CMSampleTimingInfo(duration: CMSampleBufferGetDuration(sample), presentationTimeStamp: pts,
                                        decodeTimeStamp: .invalid)
        var out: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sample, sampleTimingEntryCount: 1,
                                              sampleTimingArray: &timing, sampleBufferOut: &out)
        return out
    }
}

extension Recorder: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sample.isValid, let take else { return }
        if type == .audio {
            take.appendScreenAudio(sample)
            return
        }
        guard type == .screen else { return }
        // Only complete frames carry new pixels; idle/blank frames are skipped.
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete else { return }
        take.appendScreen(sample)
    }
}

extension Recorder: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sample: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let take, let sample = hostTimed(sample) else { return }
        if output is AVCaptureVideoDataOutput {
            take.appendCamera(sample)
        } else {
            micLevel.store(MicLevel.rms(of: sample))
            take.appendMic(sample)
        }
    }
}

// MARK: - Take writer

/// Writers for one take. The take starts at its first screen frame; camera/mic samples before that are dropped.
private final class TakeWriter {
    let id: UUID
    let relative: String
    let screenSize: CGSize
    private let screen: AVAssetWriter
    private let screenInput: AVAssetWriterInput
    private let camera: AVAssetWriter?
    private var cameraInput: AVAssetWriterInput?
    private let mic: AudioTrackWriter?
    private let screenAudio: AudioTrackWriter?
    private let fps: Int
    private(set) var startTime: CMTime?
    private var lastScreen: CMSampleBuffer?
    private var cameraStarted = false
    /// Webcam frames are held one frame so a single bad frame (some USB cameras send them) can be spotted and dropped.
    private var pendingCamera: (sample: CMSampleBuffer, thumb: [Float])?
    private var previousCameraThumb: [Float]?

    init(id: UUID, dir: URL, relative: String, screenSize: CGSize, fps: Int, hasCamera: Bool, hasMic: Bool,
         hasScreenAudio: Bool) throws {
        self.id = id
        self.relative = relative
        self.screenSize = screenSize
        self.fps = fps
        screen = try AVAssetWriter(outputURL: dir.appendingPathComponent("screen.mov"), fileType: .mov)
        screenInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: screenSize.width, AVVideoHeightKey: screenSize.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoQualityKey: 0.85,
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoAllowFrameReorderingKey: false,
            ],
        ])
        screenInput.expectsMediaDataInRealTime = true
        screen.add(screenInput)
        camera = hasCamera ? try AVAssetWriter(outputURL: dir.appendingPathComponent("camera.mov"), fileType: .mov) : nil
        mic = hasMic ? try AudioTrackWriter(url: dir.appendingPathComponent("mic.m4a"), channels: 1) : nil
        screenAudio = hasScreenAudio ? try AudioTrackWriter(url: dir.appendingPathComponent("screen-audio.m4a"), channels: 2) : nil
    }

    func appendScreen(_ sample: CMSampleBuffer) {
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        if startTime == nil {
            guard screen.startWriting() else { return }
            screen.startSession(atSourceTime: pts)
            startTime = pts
        }
        if screenInput.isReadyForMoreMediaData { screenInput.append(sample) }
        lastScreen = sample
    }

    func appendCamera(_ sample: CMSampleBuffer) {
        guard let start = startTime, camera != nil, CMSampleBufferGetPresentationTimeStamp(sample) >= start,
              let pb = CMSampleBufferGetImageBuffer(sample) else { return }
        let thumb = CameraGlitchDetector.thumbnail(pb)
        if let pending = pendingCamera {
            if let prev = previousCameraThumb, CameraGlitchDetector.isGlitch(previous: prev, frame: pending.thumb, next: thumb) {
                // Drop it; the frame before simply stays on screen a little longer.
            } else {
                writeCamera(pending.sample)
                previousCameraThumb = pending.thumb
            }
        }
        pendingCamera = (sample, thumb)
    }

    private func writeCamera(_ sample: CMSampleBuffer) {
        guard let start = startTime, let camera else { return }
        if !cameraStarted {
            // Size the camera file from the first frame the device actually delivers.
            guard let fmt = CMSampleBufferGetFormatDescription(sample) else { return }
            let dims = CMVideoFormatDescriptionGetDimensions(fmt)
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: dims.width, AVVideoHeightKey: dims.height,
                AVVideoCompressionPropertiesKey: [AVVideoQualityKey: 0.8],
            ])
            input.expectsMediaDataInRealTime = true
            camera.add(input)
            guard camera.startWriting() else { return }
            camera.startSession(atSourceTime: start)
            cameraInput = input
            cameraStarted = true
        }
        if let input = cameraInput, input.isReadyForMoreMediaData { input.append(sample) }
    }

    func appendMic(_ sample: CMSampleBuffer) {
        guard let start = startTime else { return }
        mic?.append(sample, start: start)
    }

    func appendScreenAudio(_ sample: CMSampleBuffer) {
        guard let start = startTime else { return }
        screenAudio?.append(sample, start: start)
    }

    func finish(at stop: CMTime, captureRect: CGRect, cursor: CursorLogger.Result) async -> Clip? {
        guard let start = startTime, stop > start else {
            screen.cancelWriting()
            camera?.cancelWriting()
            mic?.cancel()
            screenAudio?.cancel()
            return nil
        }
        if let pending = pendingCamera { writeCamera(pending.sample) }
        // The screen only sends frames on change; repeat the last one at the end so the track spans the take.
        if let last = lastScreen, let buffer = CMSampleBufferGetImageBuffer(last) {
            let endPTS = CMTimeSubtract(stop, CMTime(value: 1, timescale: CMTimeScale(fps)))
            if endPTS > CMSampleBufferGetPresentationTimeStamp(last) {
                var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: endPTS, decodeTimeStamp: .invalid)
                var fmt: CMVideoFormatDescription?
                CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: buffer, formatDescriptionOut: &fmt)
                var copy: CMSampleBuffer?
                if let fmt {
                    CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: buffer, formatDescription: fmt,
                                                             sampleTiming: &timing, sampleBufferOut: &copy)
                }
                if let copy, screenInput.isReadyForMoreMediaData { screenInput.append(copy) }
            }
        }
        let micDone = await mic?.finish(at: stop) ?? false
        let screenAudioDone = await screenAudio?.finish(at: stop) ?? false
        for (writer, input) in [(screen, screenInput as AVAssetWriterInput?), (camera, cameraInput)] {
            guard let writer, writer.status == .writing else {
                writer?.cancelWriting()
                continue
            }
            input?.markAsFinished()
            writer.endSession(atSourceTime: stop)
            await writer.finishWriting()
        }
        guard screen.status == .completed else { return nil }

        let startSeconds = start.seconds
        let log = CursorLog(
            samples: cursor.samples.map { .init(t: $0.t - startSeconds, x: $0.x, y: $0.y) },
            clicks: cursor.clicks.map { .init(t: $0.t - startSeconds, x: $0.x, y: $0.y) })
        let cursorRel = "\(relative)/cursor.json"
        let cursorURL = screen.outputURL.deletingLastPathComponent().appendingPathComponent("cursor.json")
        try? JSONEncoder().encode(log).write(to: cursorURL)

        return Clip(id: id, screenFile: "\(relative)/screen.mov",
                    cameraFile: camera?.status == .completed ? "\(relative)/camera.mov" : nil,
                    micFile: micDone ? "\(relative)/mic.m4a" : nil,
                    cursorFile: cursorRel, duration: (stop - start).seconds,
                    screenPixelSize: screenSize, captureRect: captureRect)
            .withScreenAudio(screenAudioDone ? "\(relative)/screen-audio.m4a" : nil)
    }
}

// MARK: - Cursor

/// Samples the mouse at 60 Hz and records clicks, in host-clock seconds, normalised to the captured rect.
final class CursorLogger {
    struct Result {
        var samples: [CursorLog.Sample] = []
        var clicks: [CursorLog.Sample] = []
    }

    private var result = Result()
    private var rect = CGRect.zero
    private var timer: Timer?
    private var monitors: [Any] = []

    func start(globalRect: CGRect) {
        rect = globalRect
        result = Result()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.sample(into: \.samples) }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            self?.sample(into: \.clicks)
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.sample(into: \.clicks)
            return event
        }) { monitors.append(local) }
    }

    func stop() -> Result {
        timer?.invalidate()
        timer = nil
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        return result
    }

    private func sample(into keyPath: WritableKeyPath<Result, [CursorLog.Sample]>) {
        let p = NSEvent.mouseLocation
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let x = (p.x - rect.minX) / max(rect.width, 1)
        let y = (primaryHeight - p.y - rect.minY) / max(rect.height, 1)
        let t = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        result[keyPath: keyPath].append(.init(t: t, x: x, y: y))
    }
}

/// Lock-free-enough holder for the latest mic level (written on the capture queue, read by the UI).
final class LevelBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Float = -160
    func store(_ v: Float) { lock.withLock { value = v } }
    func load() -> Float { lock.withLock { value } }
}

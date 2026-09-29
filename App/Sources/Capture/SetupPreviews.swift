import AVFoundation
import ScreenCaptureKit
import SwiftUI

/// Periodically grabs a still of the source that's about to be recorded.
@MainActor
final class ScreenPreviewModel: ObservableObject {
    @Published private(set) var image: CGImage?
    @Published private(set) var error: String?
    private var task: Task<Void, Never>?

    func watch(_ source: CaptureSource?) {
        task?.cancel()
        image = nil
        error = nil
        guard let source else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.capture(source)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func capture(_ source: CaptureSource) async {
        do {
            let resolved = try await SourceResolver.resolve(source)
            let config = SCStreamConfiguration()
            // A preview doesn't need full resolution; cap the long side.
            let scale = min(1, 1400 / max(resolved.pixelSize.width, resolved.pixelSize.height))
            config.width = max(Int(resolved.pixelSize.width * scale), 2)
            config.height = max(Int(resolved.pixelSize.height * scale), 2)
            if let r = resolved.sourceRect { config.sourceRect = r }
            config.showsCursor = false
            let cg = try await SCScreenshotManager.captureImage(contentFilter: resolved.filter, configuration: config)
            guard !Task.isCancelled else { return }
            image = cg
            error = nil
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }
}

/// Live camera feed for the setup screen. Stopped before recording starts so the recorder can take the camera.
@MainActor
final class CameraPreviewModel: ObservableObject {
    @Published private(set) var session: AVCaptureSession?
    private var deviceID: String?

    func show(cameraID: String?) {
        guard cameraID != deviceID || session == nil else { return }
        stop()
        deviceID = cameraID
        guard let cameraID, let device = AVCaptureDevice(uniqueID: cameraID) else { return }
        Task {
            guard await AVCaptureDevice.requestAccess(for: .video), deviceID == cameraID,
                  let input = try? AVCaptureDeviceInput(device: device) else { return }
            let s = AVCaptureSession()
            if s.canAddInput(input) { s.addInput(input) }
            // startRunning blocks; keep it off the main thread.
            await Task.detached { s.startRunning() }.value
            guard deviceID == cameraID else {
                s.stopRunning()
                return
            }
            session = s
        }
    }

    func stop() {
        if let s = session { Task.detached { s.stopRunning() } }
        session = nil
        deviceID = nil
    }
}

struct SetupPreviews: View {
    @ObservedObject var screen: ScreenPreviewModel
    @ObservedObject var camera: CameraPreviewModel
    @ObservedObject var mic: MicPreviewModel
    let hasCamera: Bool
    let micName: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            previews
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: micName == nil ? "mic.slash" : "mic.fill").foregroundStyle(.secondary)
                    Text(micName ?? "No microphone selected").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                }
                if micName != nil { MicMeter(level: mic.level).frame(maxWidth: .infinity) }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
        }
    }

    private var previews: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Screen").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.85))
                    if let img = screen.image {
                        Image(decorative: img, scale: 1).resizable().aspectRatio(contentMode: .fit).padding(4)
                    } else if let err = screen.error {
                        Text(err).font(.caption).foregroundStyle(.white.opacity(0.8)).multilineTextAlignment(.center).padding()
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                .frame(height: 190)
            }
            .frame(maxWidth: .infinity)

            if hasCamera {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Camera").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    ZStack {
                        RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color.black.opacity(0.85))
                        if let session = camera.session {
                            CameraPreview(session: session)
                                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    }
                    .frame(width: 190, height: 190)
                }
            }
        }
    }
}

/// Live input level for the selected microphone on the setup screen, measured from the audio itself.
@MainActor
final class MicPreviewModel: NSObject, ObservableObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    /// Level in dB (about -160 silent ... 0 max), smoothed for display.
    @Published private(set) var level: Float = -160
    private var session: AVCaptureSession?
    private var deviceID: String?
    private var timer: Timer?
    private let queue = DispatchQueue(label: "mic.preview")
    private let latest = LevelBox()

    func show(micID: String?) {
        guard micID != deviceID || session == nil else { return }
        stop()
        deviceID = micID
        guard let micID, let device = AVCaptureDevice(uniqueID: micID) else { return }
        Task {
            guard await AVCaptureDevice.requestAccess(for: .audio), deviceID == micID,
                  let input = try? AVCaptureDeviceInput(device: device) else { return }
            let s = AVCaptureSession()
            let out = AVCaptureAudioDataOutput()
            out.setSampleBufferDelegate(self, queue: queue)
            if s.canAddInput(input) { s.addInput(input) }
            if s.canAddOutput(out) { s.addOutput(out) }
            await Task.detached { s.startRunning() }.value
            guard deviceID == micID else {
                s.stopRunning()
                return
            }
            session = s
            let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.poll() }
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
    }

    private func poll() {
        // Rise instantly, fall gently, like a real meter.
        let v = latest.load()
        level = v > level ? v : max(v, level - 3)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let s = session { Task.detached { s.stopRunning() } }
        session = nil
        deviceID = nil
        level = -160
    }

    nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        latest.store(MicLevel.rms(of: sampleBuffer))
    }
}

enum MicLevel {
    /// RMS level of an audio sample buffer in dB, across all channels.
    static func rms(of sample: CMSampleBuffer) -> Float {
        guard let desc = CMSampleBufferGetFormatDescription(sample),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc),
              let format = AVAudioFormat(streamDescription: asbd) else { return -160 }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sample))
        guard frames > 0, let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return -160 }
        buf.frameLength = frames
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(frames),
                                                           into: buf.mutableAudioBufferList) == noErr else { return -160 }
        var sum: Double = 0
        var n = 0
        let channels = Int(format.channelCount)
        let stride = format.isInterleaved ? channels : 1
        let planes = format.isInterleaved ? 1 : channels
        for c in 0 ..< planes {
            for i in 0 ..< Int(frames) * stride {
                let v: Double
                if let f = buf.floatChannelData { v = Double(f[c][i]) }
                else if let s16 = buf.int16ChannelData { v = Double(s16[c][i]) / 32768 }
                else if let s32 = buf.int32ChannelData { v = Double(s32[c][i]) / 2_147_483_648 }
                else { return -160 }
                sum += v * v
                n += 1
            }
        }
        guard n > 0, sum > 0 else { return -160 }
        return Float(10 * log10(sum / Double(n)))
    }
}

/// Horizontal level bar: green, then amber, then red near clipping. Flags a mic that's delivering silence.
struct MicMeter: View {
    let level: Float
    var showHint = true

    private var fraction: CGFloat { CGFloat(min(max((level + 60) / 60, 0), 1)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.12))
                    Capsule()
                        .fill(LinearGradient(colors: [.green, .green, .yellow, .red], startPoint: .leading, endPoint: .trailing))
                        .frame(width: geo.size.width)
                        .mask(alignment: .leading) { Capsule().frame(width: geo.size.width * fraction) }
                }
            }
            .frame(height: 6)
            .animation(.linear(duration: 0.1), value: fraction)
            if showHint {
                Text(level < -70 ? "No sound from this mic. Is it switched on, unmuted and connected?" : "Speak to check your level.")
                    .font(.caption)
                    .foregroundStyle(level < -70 ? Color.orange : Color.secondary)
            }
        }
    }
}

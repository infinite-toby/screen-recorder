import AVFoundation
import RecorderCore
import SwiftUI

/// Drives one recording session (one or more takes) and its floating control panel.
@MainActor
final class RecordingController: ObservableObject {
    enum Phase: Equatable {
        case preparing
        case countdown(Int)
        case recording
        case paused
        case finishing
    }

    @Published private(set) var phase: Phase = .preparing
    /// Seconds recorded in finished takes plus the running take.
    @Published private(set) var elapsed: Double = 0
    /// Live mic level (dB) while recording.
    @Published private(set) var micLevel: Float = -160
    /// Set after stopping if any take's microphone recorded silence.
    private(set) var silenceWarning: String?
    var hasMic: Bool { settings.micID != nil }

    let settings: Recorder.Settings
    private var editor: EditorModel?
    private var bundle: ProjectBundle?
    private var project: Project?
    private var recorder: Recorder?
    private var panel: NSPanel?
    private var takeStartedAt: Date?
    private var finishedSeconds = 0.0
    private var ticker: Timer?
    private var terminationDisabled = false
    /// Windows minimised for the recording, brought back (with the editor) when it stops.
    private(set) var minimised: [NSWindow] = []
    private let onFinish: (Result<EditorModel?, Error>) -> Void

    var captureSession: AVCaptureSession? { recorder?.captureSession }
    var hasCamera: Bool { settings.cameraID != nil }

    init(settings: Recorder.Settings, editor: EditorModel?, onFinish: @escaping (Result<EditorModel?, Error>) -> Void) {
        self.settings = settings
        self.editor = editor
        self.onFinish = onFinish
    }

    func start() {
        Task {
            do {
                if let editor {
                    bundle = editor.bundle
                    project = editor.project
                } else {
                    let f = DateFormatter()
                    f.dateFormat = "yyyy-MM-dd HH.mm"
                    let (b, p) = try ProjectBundle.create(name: "Recording \(f.string(from: Date()))")
                    bundle = b
                    project = p
                }
                let recorder = Recorder(settings: settings, bundle: bundle!)
                self.recorder = recorder
                try await recorder.prepare()
                // Keep macOS from quitting or suspending us while no app window is visible.
                ProcessInfo.processInfo.disableAutomaticTermination("Recording")
                ProcessInfo.processInfo.disableSuddenTermination()
                terminationDisabled = true
                showPanel()
                // Minimise (not close) the main window; our windows are excluded from the capture anyway.
                minimised = NSApp.windows.filter { !($0 is NSPanel) && $0.isVisible }
                minimised.forEach { $0.miniaturize(nil) }
                for n in stride(from: 3, through: 1, by: -1) {
                    phase = .countdown(n)
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                }
                try beginTake()
            } catch {
                await recorder?.shutdown()
                cleanUpEmptyNewProject()
                closePanel()
                onFinish(.failure(error))
            }
        }
    }

    func togglePause() {
        switch phase {
        case .recording:
            phase = .finishing
            Task {
                await endTake()
                phase = .paused
            }
        case .paused:
            try? beginTake()
        default: break
        }
    }

    func stop() {
        guard phase == .recording || phase == .paused else { return }
        let wasRecording = phase == .recording
        phase = .finishing
        Task {
            if wasRecording { await endTake() }
            await recorder?.shutdown()
            closePanel()
            guard let bundle, let project, !project.clips.isEmpty else {
                cleanUpEmptyNewProject()
                onFinish(.success(editor))
                return
            }
            // Catch a dead mic now rather than when transcription finds nothing.
            let silent: [Int] = await Task.detached {
                project.clips.enumerated().compactMap { i, clip in
                    clip.micFile.map { AudioCheck.isSilent(bundle.file($0)) } == true ? i + 1 : nil
                }
            }.value.filter { i in !(self.editor?.project.clips.contains { $0.id == project.clips[i - 1].id } ?? false) }
            if !silent.isEmpty {
                let mic = settings.micID.flatMap { AVCaptureDevice(uniqueID: $0)?.localizedName } ?? "The microphone"
                silenceWarning = "\(mic) recorded silence in take \(silent.map(String.init).joined(separator: ", ")). "
                    + "Check it's switched on, unmuted and connected (watch the level meter on the setup screen), then record again."
            }
            do {
                try bundle.save(project)
                if let editor {
                    editor.appendRecordedClips(from: project)
                } else {
                    editor = EditorModel(bundle: bundle, project: project)
                }
                onFinish(.success(editor))
            } catch {
                onFinish(.failure(error))
            }
        }
    }

    private func beginTake() throws {
        try recorder?.startTake()
        takeStartedAt = Date()
        phase = .recording
        ticker?.invalidate()
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    private func tick() {
        let v = recorder?.micLevel.load() ?? -160
        micLevel = v > micLevel ? v : max(v, micLevel - 3)
        guard let takeStartedAt else { return }
        elapsed = finishedSeconds + Date().timeIntervalSince(takeStartedAt)
    }

    private func endTake() async {
        ticker?.invalidate()
        takeStartedAt = nil
        guard let clip = await recorder?.endTake() else { return }
        project?.clips.append(clip)
        finishedSeconds += clip.duration
        elapsed = finishedSeconds
        if let bundle, let project { try? bundle.save(project) }
    }

    private func cleanUpEmptyNewProject() {
        guard editor == nil, let bundle, (project?.clips.isEmpty ?? true) else { return }
        try? FileManager.default.removeItem(at: bundle.url)
    }

    // MARK: - Panel

    private func showPanel() {
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 300, height: hasCamera ? 250 : 64),
                            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let host = NSHostingView(rootView: RecordingPanelView(controller: self))
        panel.contentView = host
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            panel.setFrameOrigin(CGPoint(x: f.midX - 150, y: f.minY + 24))
        }
        panel.orderFrontRegardless()
        self.panel = panel
    }

    private func closePanel() {
        panel?.orderOut(nil)
        panel = nil
        if terminationDisabled {
            ProcessInfo.processInfo.enableAutomaticTermination("Recording")
            ProcessInfo.processInfo.enableSuddenTermination()
            terminationDisabled = false
        }
    }
}

struct RecordingPanelView: View {
    @ObservedObject var controller: RecordingController

    var body: some View {
        VStack(spacing: 10) {
            if controller.hasCamera, let session = controller.captureSession {
                CameraPreview(session: session)
                    .frame(height: 170)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            HStack(spacing: 12) {
                statusView
                if controller.hasMic {
                    MicMeter(level: controller.micLevel, showHint: false)
                        .frame(width: 60)
                        .help("Microphone level")
                }
                Spacer()
                Button {
                    controller.togglePause()
                } label: {
                    Image(systemName: controller.phase == .paused ? "record.circle" : "pause.fill")
                        .frame(width: 22, height: 22)
                }
                .help(controller.phase == .paused ? "Record next take" : "Pause (ends this take)")
                .disabled(controller.phase != .recording && controller.phase != .paused)
                Button {
                    controller.stop()
                } label: {
                    Image(systemName: "stop.fill").frame(width: 22, height: 22)
                }
                .help("Stop and edit")
                .disabled(controller.phase != .recording && controller.phase != .paused)
            }
            .buttonStyle(.borderless)
            .font(.system(size: 16, weight: .semibold))
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder private var statusView: some View {
        switch controller.phase {
        case .preparing:
            Text("Preparing…")
        case let .countdown(n):
            Text("Starting in \(n)…").monospacedDigit()
        case .recording:
            HStack(spacing: 6) {
                Circle().fill(.red).frame(width: 10, height: 10)
                Text(format(controller.elapsed)).monospacedDigit()
            }
        case .paused:
            Text("Paused · \(format(controller.elapsed))").monospacedDigit()
        case .finishing:
            Text("Saving…")
        }
    }

    private func format(_ s: Double) -> String {
        String(format: "%d:%02d", Int(s) / 60, Int(s) % 60)
    }
}

struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        // Setting mirroring on a connection that doesn't support it raises an exception.
        if let c = layer.connection, c.isVideoMirroringSupported {
            c.automaticallyAdjustsVideoMirroring = false
            c.isVideoMirrored = true
        }
        view.layer = layer
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

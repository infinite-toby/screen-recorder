import AVFoundation
import ScreenCaptureKit
import SwiftUI

struct RecordSetupView: View {
    @EnvironmentObject var model: AppModel
    let appendTo: EditorModel?

    enum Kind: String, CaseIterable { case display = "Display", window = "Window", area = "Area" }

    @AppStorage("setup.kind") private var kind: Kind = .display
    @AppStorage("setup.camera") private var cameraID = ""
    @AppStorage("setup.mic") private var micID = ""
    @AppStorage("setup.fps") private var fps = 60
    @AppStorage("setup.screenAudio") private var screenAudio = true
    @State private var displayID: CGDirectDisplayID?
    @State private var windowID: CGWindowID?
    @State private var area: CaptureSource?
    @State private var windows: [SCWindow] = []
    @State private var loadError: String?
    @StateObject private var screenPreview = ScreenPreviewModel()
    @StateObject private var cameraPreview = CameraPreviewModel()
    @StateObject private var micPreview = MicPreviewModel()

    private var cameras: [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
                                         mediaType: .video, position: .unspecified).devices
    }

    private var mics: [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    model.screen = appendTo.map { .editor($0) } ?? .home
                } label: { Label("Back", systemImage: "chevron.left") }
                Spacer()
                Text(appendTo == nil ? "New Recording" : "Record Another Take").font(.headline)
                Spacer()
                Color.clear.frame(width: 60, height: 1)
            }
            .padding(14)
            Divider()

            SetupPreviews(screen: screenPreview, camera: cameraPreview, mic: micPreview, hasCamera: !cameraID.isEmpty,
                          micName: mics.first { $0.uniqueID == micID }?.localizedName)
                .frame(maxWidth: 620)
                .padding(.horizontal, 20)
                .padding(.top, 16)
            Form {
                Section("Record") {
                    Picker("Source", selection: $kind) {
                        ForEach(Kind.allCases, id: \.self) { Text($0.rawValue) }
                    }
                    .pickerStyle(.segmented)

                    switch kind {
                    case .display:
                        Picker("Display", selection: $displayID) {
                            ForEach(NSScreen.screens, id: \.displayID) { screen in
                                Text("\(screen.localizedName) (\(Int(screen.frame.width))×\(Int(screen.frame.height)))")
                                    .tag(screen.displayID)
                            }
                        }
                    case .window:
                        if let loadError {
                            Text(loadError).foregroundStyle(.red)
                        }
                        Picker("Window", selection: $windowID) {
                            Text("Choose a window…").tag(CGWindowID?.none)
                            ForEach(windows, id: \.windowID) { w in
                                Text("\(w.owningApplication?.applicationName ?? "?") - \(w.title ?? "Untitled")").tag(Optional(w.windowID))
                            }
                        }
                        Button("Refresh window list") { Task { await loadWindows() } }
                    case .area:
                        HStack {
                            if case let .area(_, r) = area {
                                Text("\(Int(r.width)) × \(Int(r.height)) at \(Int(r.minX)), \(Int(r.minY))")
                            } else {
                                Text("No area selected").foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Select Area…") {
                                Task { @MainActor in
                                    if let picked = await AreaSelector().select() { area = picked }
                                }
                            }
                        }
                    }
                    Picker("Frame rate", selection: $fps) {
                        Text("30 fps").tag(30)
                        Text("60 fps").tag(60)
                    }
                }
                Section("Camera & microphone") {
                    Picker("Camera", selection: $cameraID) {
                        Text("No camera").tag("")
                        ForEach(cameras, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
                    }
                    Picker("Microphone", selection: $micID) {
                        Text("No microphone").tag("")
                        ForEach(mics, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
                    }
                    Toggle("Record screen audio (sound from apps)", isOn: $screenAudio)
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: 620)

            Spacer(minLength: 0)
            Button {
                Task { await record() }
            } label: {
                Label("Start Recording", systemImage: "record.circle.fill").frame(minWidth: 200)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.extraLarge)
            .disabled(source == nil)
            .keyboardShortcut(.return)
            .padding(24)
        }
        .onChange(of: previewKey, initial: true) { screenPreview.watch(source) }
        .onChange(of: cameraID, initial: true) { cameraPreview.show(cameraID: cameraID.isEmpty ? nil : cameraID) }
        .onChange(of: micID, initial: true) { micPreview.show(micID: micID.isEmpty ? nil : micID) }
        .onDisappear {
            screenPreview.stop()
            cameraPreview.stop()
            micPreview.stop()
        }
        .task {
            if displayID == nil { displayID = NSScreen.main?.displayID }
            await loadWindows()
            if !cameras.contains(where: { $0.uniqueID == cameraID }) { cameraID = cameras.first?.uniqueID ?? "" }
            if !mics.contains(where: { $0.uniqueID == micID }) { micID = AVCaptureDevice.default(for: .audio)?.uniqueID ?? "" }
        }
    }

    private var source: CaptureSource? {
        switch kind {
        case .display: displayID.map { .display($0) }
        case .window: windowID.map { .window($0) }
        case .area: area
        }
    }

    private func loadWindows() async {
        do {
            let content = try await SourceResolver.shareableContent()
            let myPID = ProcessInfo.processInfo.processIdentifier
            windows = content.windows
                .filter { $0.windowLayer == 0 && $0.frame.width > 120 && $0.frame.height > 80 && $0.owningApplication?.processID != myPID }
                .sorted { ($0.owningApplication?.applicationName ?? "") < ($1.owningApplication?.applicationName ?? "") }
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// Changes whenever the previewed source does.
    private var previewKey: String {
        switch source {
        case let .display(id): "d\(id)"
        case let .window(id): "w\(id)"
        case let .area(id, r): "a\(id)\(r)"
        case nil: "none"
        }
    }

    private func record() async {
        guard let source else { return }
        // Release the camera and stop screenshots so the recorder gets clean access.
        screenPreview.stop()
        cameraPreview.stop()
        micPreview.stop()
        if !cameraID.isEmpty, !(await AVCaptureDevice.requestAccess(for: .video)) {
            model.error = "Camera access was denied. Enable it in System Settings > Privacy & Security > Camera."
            return
        }
        if !micID.isEmpty, !(await AVCaptureDevice.requestAccess(for: .audio)) {
            model.error = "Microphone access was denied. Enable it in System Settings > Privacy & Security > Microphone."
            return
        }
        let settings = Recorder.Settings(source: source, cameraID: cameraID.isEmpty ? nil : cameraID,
                                         micID: micID.isEmpty ? nil : micID, fps: fps, screenAudio: screenAudio)
        model.startRecording(settings: settings, appendTo: appendTo)
    }
}

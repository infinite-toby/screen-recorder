import AVFoundation
import RecorderCore
import SwiftUI

struct EditorView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var editor: EditorModel
    @State private var showExport = false

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                VStack(spacing: 0) {
                    PreviewArea(editor: editor)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(16)
                    TransportBar(editor: editor)
                }
                .frame(minWidth: 560)
                SidePanel(editor: editor)
                    .frame(minWidth: 280, idealWidth: 320, maxWidth: 420)
            }
            Divider()
            TimelineView(editor: editor)
                .frame(height: 168)
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    editor.close()
                    model.screen = .home
                } label: { Label("Projects", systemImage: "chevron.left") }
            }
            ToolbarItem(placement: .principal) {
                Picker("Aspect", selection: $editor.project.export.aspect) {
                    ForEach(OutputAspect.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .help("Output aspect ratio (preview and export)")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { editor.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                    .disabled(!editor.canUndo).help("Undo (⌘Z)")
                Button { editor.redo() } label: { Label("Redo", systemImage: "arrow.uturn.forward") }
                    .disabled(!editor.canRedo).help("Redo (⇧⌘Z)")
                Button {
                    importInto(editor)
                } label: { Label("Add Clip", systemImage: "film.stack") }
                    .help("Add a pre-recorded video to the end of this project")
                Button {
                    editor.autoZoom()
                } label: { Label("Auto Zoom", systemImage: "wand.and.stars") }
                    .help(editor.hasClicks ? "Suggest zooms from your clicks (keeps zooms you've edited)" : "No clicks were recorded")
                    .disabled(!editor.hasClicks)
                Button {
                    editor.close()
                    model.screen = .setup(appendTo: editor)
                } label: { Label("Record Take", systemImage: "plus.circle") }
                    .help("Record another take onto the end of this project")
                Button {
                    editor.player.pause()
                    showExport = true
                } label: { Label("Export", systemImage: "square.and.arrow.up") }
                    .buttonStyle(.borderedProminent)
            }
        }
        .navigationTitle(editor.project.name)
        .onDrop(of: [.movie, .fileURL], isTargeted: nil) { providers in
            Task { @MainActor in
                var urls: [URL] = []
                for p in providers {
                    if let url = try? await p.loadItem(forTypeIdentifier: "public.file-url") as? Data,
                       let u = URL(dataRepresentation: url, relativeTo: nil) { urls.append(u) }
                }
                await editor.importClips(urls)
            }
            return true
        }
        .sheet(isPresented: $showExport) { ExportSheet(editor: editor) }
        .background {
            // Keyboard shortcuts without visible buttons.
            Button("") { editor.deleteSelection() }.keyboardShortcut(.delete, modifiers: []).hidden()
                .disabled(editor.isEditingText)
            Button("") { editor.togglePlay() }.keyboardShortcut(.space, modifiers: []).hidden()
                .disabled(editor.isEditingText)
            Button("") { editor.splitAtPlayhead() }.keyboardShortcut("b", modifiers: .command).hidden()
            Button("") { editor.undo() }.keyboardShortcut("z", modifiers: .command).hidden()
            Button("") { editor.redo() }.keyboardShortcut("z", modifiers: [.command, .shift]).hidden()
        }
    }
}

// MARK: - Preview

struct PreviewArea: View {
    @ObservedObject var editor: EditorModel

    var body: some View {
        let size = editor.previewSize
        PlayerView(player: editor.player)
            .aspectRatio(size, contentMode: .fit)
            .overlay {
                if let still = editor.stillImage, !editor.isPlaying {
                    Image(nsImage: still).resizable().interpolation(.high).allowsHitTesting(false)
                }
            }
            .overlay {
                GeometryReader { geo in
                    if editor.isEditingZoomFocus, case let .zoom(id) = editor.selection,
                       let block = editor.project.zoomBlocks.first(where: { $0.id == id }) {
                        ZoomFocusOverlay(editor: editor, block: block, viewSize: geo.size)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
    }
}

/// Box showing what a zoom will frame. Drag it (or click anywhere) to aim the zoom.
struct ZoomFocusOverlay: View {
    @ObservedObject var editor: EditorModel
    let block: ZoomBlock
    let viewSize: CGSize
    @State private var dragStartCenter: CGPoint?

    private var geometry: ScreenGeometry {
        let project = editor.project
        let i = project.clipStarts.lastIndex { $0 <= block.start } ?? 0
        let content = project.clips.indices.contains(i) ? project.clips[i].screenPixelSize : editor.previewSize
        return ScreenGeometry(contentSize: content, output: editor.previewSize, style: project.style)
    }

    private var k: CGFloat { viewSize.width / editor.previewSize.width }

    var body: some View {
        let g = geometry
        let r = g.zoomedView(scale: block.scale, focus: block.focus)
        let rect = CGRect(x: r.minX * k, y: r.minY * k, width: r.width * k, height: r.height * k)
        ZStack(alignment: .topLeading) {
            Path { p in
                p.addRect(CGRect(origin: .zero, size: viewSize))
                p.addRect(rect)
            }
            .fill(Color.black.opacity(0.45), style: FillStyle(eoFill: true))
            .contentShape(Rectangle())
            .onTapGesture(coordinateSpace: .local) { location in
                setFocus(center: CGPoint(x: location.x / k, y: location.y / k), geometry: g)
            }
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(Color.white, lineWidth: 2)
                .background(Color.white.opacity(0.001))
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
                .gesture(DragGesture(coordinateSpace: .global)
                    .onChanged { v in
                        let start = dragStartCenter ?? CGPoint(x: r.midX, y: r.midY)
                        if dragStartCenter == nil { dragStartCenter = start }
                        setFocus(center: CGPoint(x: start.x + v.translation.width / k, y: start.y + v.translation.height / k),
                                 geometry: g)
                    }
                    .onEnded { _ in dragStartCenter = nil })
            Text("Zoom \(String(format: "%.1f", block.scale))×  ·  drag to aim")
                .font(.caption.weight(.medium))
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(.black.opacity(0.6), in: Capsule())
                .foregroundStyle(.white)
                .offset(x: rect.minX + 6, y: max(rect.minY - 24, 4))
                .allowsHitTesting(false)
        }
    }

    private func setFocus(center: CGPoint, geometry g: ScreenGeometry) {
        let c = g.contentRect
        editor.updateZoom(block.id, focus: CGPoint(x: (center.x - c.minX) / c.width, y: (center.y - c.minY) / c.height))
    }
}

struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = NSColor.black.cgColor
        view.layer = layer
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct TransportBar: View {
    @ObservedObject var editor: EditorModel

    var body: some View {
        HStack(spacing: 14) {
            Button {
                editor.togglePlay()
            } label: {
                Image(systemName: editor.isPlaying ? "pause.fill" : "play.fill").frame(width: 20)
            }
            .buttonStyle(.borderless)
            .font(.title3)
            Text("\(format(editor.time)) / \(format(editor.duration))")
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Spacer()
            Text(hint).font(.callout).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    private var hint: String {
        switch editor.selection {
        case .zoom: "Drag the box to aim the zoom. Deselect to preview it."
        case .camera: "Choose a layout on the right."
        case .section: "Delete removes this section. Drag its edges to trim."
        case nil: editor.wordSelection != nil ? "Delete cuts the selected words. ⌘Z undoes."
            : "Double-click a track to add a block. Space plays."
        }
    }
}

func format(_ s: Double) -> String {
    let s = max(s, 0)
    return String(format: "%d:%02d.%d", Int(s) / 60, Int(s) % 60, Int((s * 10).truncatingRemainder(dividingBy: 10)))
}

// MARK: - Export

struct ExportSheet: View {
    @ObservedObject var editor: EditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    @State private var done: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Export").font(.title2.weight(.semibold))
            Form {
                Picker("Aspect ratio", selection: $editor.project.export.aspect) {
                    ForEach(OutputAspect.allCases, id: \.self) { Text($0.rawValue) }
                }
                Picker("Resolution", selection: $editor.project.export.resolution) {
                    ForEach(OutputResolution.allCases, id: \.self) { Text($0.label) }
                }
                Picker("Frame rate", selection: $editor.project.export.fps) {
                    Text("30 fps").tag(30)
                    Text("60 fps").tag(60)
                }
                Picker("Codec", selection: $editor.project.export.hevc) {
                    Text("HEVC (smaller)").tag(true)
                    Text("H.264 (most compatible)").tag(false)
                }
                if !editor.captions.isEmpty {
                    Toggle("Burn in subtitles", isOn: $editor.project.subtitles.burnIn)
                }
                LabeledContent("Output size") {
                    let s = editor.project.export.renderSize
                    Text("\(Int(s.width)) × \(Int(s.height))").monospacedDigit()
                }
            }
            .disabled(editor.exportProgress != nil)
            if let p = editor.exportProgress {
                ProgressView(value: p) { Text("Exporting… \(Int(p * 100))%").monospacedDigit() }
            }
            if let error { Text(error).foregroundStyle(.red) }
            if let done {
                HStack {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Exported \(done.lastPathComponent)")
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([done]) }
                }
            }
            HStack {
                Spacer()
                Button(done == nil ? "Cancel" : "Close") { dismiss() }
                    .disabled(editor.exportProgress != nil)
                Button("Export…") { chooseAndExport() }
                    .buttonStyle(.borderedProminent)
                    .disabled(editor.exportProgress != nil)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func chooseAndExport() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        let aspect = editor.project.export.aspect.rawValue.replacingOccurrences(of: ":", with: "x")
        panel.nameFieldStringValue = "\(editor.project.name) \(aspect).mp4"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        error = nil
        done = nil
        Task {
            do {
                try await editor.export(to: url)
                done = url
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// Asks for video files and adds them to an editor as new takes.
@MainActor
func importInto(_ editor: EditorModel) {
    guard let urls = chooseVideos() else { return }
    Task { await editor.importClips(urls) }
}

@MainActor
func chooseVideos() -> [URL]? {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.movie]
    panel.allowsMultipleSelection = true
    panel.message = "Choose videos to add. They're copied into the project."
    return panel.runModal() == .OK && !panel.urls.isEmpty ? panel.urls : nil
}

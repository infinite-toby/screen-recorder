import RecorderCore
import SwiftUI

struct InspectorView: View {
    @ObservedObject var editor: EditorModel
    @State private var confirmDeleteTake = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                switch editor.selection {
                case let .camera(id):
                    if let block = editor.project.cameraBlocks.first(where: { $0.id == id }) {
                        section("Camera block") {
                            Text("\(format(block.start)) - \(format(block.end))").font(.caption).foregroundStyle(.secondary)
                            LayoutPicker(layout: Binding(get: { block.layout }, set: { editor.updateCamera(id, layout: $0) }))
                        }
                        deleteButton("Delete block")
                    }
                case let .zoom(id):
                    if let block = editor.project.zoomBlocks.first(where: { $0.id == id }) {
                        section("Zoom block") {
                            Text("\(format(block.start)) - \(format(block.end))").font(.caption).foregroundStyle(.secondary)
                            LabeledContent("Zoom") {
                                Text("\(String(format: "%.1f", block.scale))×").monospacedDigit()
                            }
                            Slider(value: Binding(get: { block.scale }, set: { editor.updateZoom(id, scale: $0) }), in: 1 ... 4)
                            Text("1.0× fills the frame with the screen (full screen) for this section.")
                                .font(.caption).foregroundStyle(.secondary)
                            Text("Drag the box in the preview to choose what the zoom frames. Click outside a block on the timeline to preview it.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        deleteButton("Delete zoom")
                    }
                case .section:
                    if let seg = editor.selectedSection {
                        let clip = editor.project.clips[seg.clipIndex]
                        section("Take \(seg.clipIndex + 1) section") {
                            LabeledContent("From", value: format(seg.sourceStart))
                            LabeledContent("To", value: format(seg.sourceEnd))
                            LabeledContent("Length", value: format(seg.duration))
                            Text("Drag the section's edges on the timeline to trim it. Split with ✂︎ at the playhead.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Button("Delete this section", role: .destructive) { editor.deleteSelectedSection() }
                            .help("Removes just this part of the take (Delete key). ⌘Z undoes.")
                        section("Take \(seg.clipIndex + 1)") {
                            LabeledContent("Recorded length", value: format(clip.duration))
                            LabeledContent("Screen", value: "\(Int(clip.screenPixelSize.width)) × \(Int(clip.screenPixelSize.height))")
                            LabeledContent("Camera", value: clip.cameraFile == nil ? "None" : "Yes")
                            LabeledContent("Microphone", value: clip.micFile == nil ? "None" : "Yes")
                            LabeledContent("Screen audio", value: clip.screenAudioFile == nil ? "None" : "Yes")
                        }
                        Button("Delete whole take…", role: .destructive) { confirmDeleteTake = true }
                            .confirmationDialog("Delete take \(seg.clipIndex + 1)? It's removed when you close the project (⌘Z undoes until then).",
                                                isPresented: $confirmDeleteTake) {
                                Button("Delete take", role: .destructive) { editor.deleteClip(clip.id) }
                            }
                    }
                case nil:
                    section("Camera (default)") {
                        Text("Used wherever no camera block is set.").font(.caption).foregroundStyle(.secondary)
                        LayoutPicker(layout: $editor.project.defaultCamera)
                        Toggle("Mirror camera", isOn: $editor.project.style.mirrorCamera)
                        slider(editor.project.style.cameraBackgroundBlur < 0.01 ? "Background blur (off)"
                               : "Background blur (\(Int(editor.project.style.cameraBackgroundBlur * 100))%)",
                               $editor.project.style.cameraBackgroundBlur, 0 ... 1)
                        slider("Corner rounding", $editor.project.style.cameraCornerRadius, 0 ... 0.5)
                    }
                    AudioSection(editor: editor)
                    BackgroundSection(editor: editor)
                    StyleSection(style: $editor.project.style)
                }
            }
            .padding(16)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func section<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            content()
        }
    }

    private func deleteButton(_ title: String) -> some View {
        Button(title, role: .destructive) { editor.deleteSelection() }
    }
}

func slider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
    VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.callout)
        Slider(value: value, in: range)
    }
}

struct StyleSection: View {
    @Binding var style: FrameStyle

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Frame").font(.headline)
            Toggle("Full screen (no padding or background)", isOn: $style.fullScreen)
            if !style.fullScreen {
                if style.backgroundImage == nil {
                    HStack {
                        ColorPicker("Gradient", selection: color(\.backgroundTop))
                        ColorPicker("", selection: color(\.backgroundBottom)).labelsHidden()
                    }
                }
                slider("Padding", $style.padding, 0 ... 0.15)
                slider("Screen corner rounding", $style.screenCornerRadius, 0 ... 0.05)
                slider("Shadow", $style.shadow, 0 ... 1)
            }
            Text("Motion").font(.headline).padding(.top, 6)
            Toggle("Motion blur on zooms", isOn: $style.motionBlur)
            if style.motionBlur { slider("Blur amount", $style.motionBlurAmount, 0.1 ... 1) }
            slider("Zoom speed (\(String(format: "%.1f", style.zoomTransitionDuration))s)", $style.zoomTransitionDuration, 0.3 ... 2)
            slider("Camera move speed (\(String(format: "%.1f", style.transitionDuration))s)", $style.transitionDuration, 0.2 ... 1.5)
        }
    }

    private func color(_ kp: WritableKeyPath<FrameStyle, RGBA>) -> Binding<Color> {
        Binding(
            get: {
                let c = style[keyPath: kp]
                return Color(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: c.a)
            },
            set: { new in
                guard let ns = NSColor(new).usingColorSpace(.sRGB) else { return }
                style[keyPath: kp] = RGBA(ns.redComponent, ns.greenComponent, ns.blueComponent, ns.alphaComponent)
            })
    }
}

/// Position (4 corners, centre, hidden) + shape + size, drawn as a tiny frame you click into.
struct LayoutPicker: View {
    @Binding var layout: CameraLayout

    private enum Position: Hashable { case corner(Corner), centre, hidden }

    private var position: Position {
        switch layout {
        case .hidden: .hidden
        case .centre: .centre
        case let .corner(c, _, _): .corner(c)
        }
    }

    // Shape/size carried over when switching corners.
    private var shape: CameraShape { if case let .corner(_, s, _) = layout { s } else { .square } }
    private var size: CameraSize { if case let .corner(_, _, z) = layout { z } else { .small } }
    private var coverage: Double { if case let .centre(c) = layout { c } else { 0.6 } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.08))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.2)))
                GeometryReader { geo in
                    let w = geo.size.width, h = geo.size.height
                    ForEach(Corner.allCases, id: \.self) { c in
                        let x = (c == .topLeft || c == .bottomLeft) ? w * 0.2 : w * 0.8
                        let y = (c == .topLeft || c == .topRight) ? h * 0.24 : h * 0.76
                        zoneButton(.corner(c), width: w * 0.24, height: h * 0.3).position(x: x, y: y)
                    }
                    zoneButton(.centre, width: w * 0.36, height: h * 0.4).position(x: w / 2, y: h / 2)
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)

            Toggle("Hide camera", isOn: Binding(get: { position == .hidden }, set: { hide in
                layout = hide ? .hidden : .corner(.bottomRight, shape, size)
            }))

            switch position {
            case .corner(let c):
                Picker("Shape", selection: Binding(get: { shape }, set: { layout = .corner(c, $0, size) })) {
                    Text("Landscape").tag(CameraShape.landscape)
                    Text("Portrait").tag(CameraShape.portrait)
                    Text("Square").tag(CameraShape.square)
                }
                .pickerStyle(.segmented)
                Picker("Size", selection: Binding(get: { size }, set: { layout = .corner(c, shape, $0) })) {
                    Text("Small").tag(CameraSize.small)
                    Text("Large").tag(CameraSize.large)
                }
                .pickerStyle(.segmented)
            case .centre:
                slider("Size (\(Int(coverage * 100))% of width)", Binding(get: { coverage }, set: { layout = .centre(coverage: $0) }), 0.3 ... 1)
            case .hidden:
                EmptyView()
            }
        }
    }

    private func zoneButton(_ p: Position, width: CGFloat, height: CGFloat) -> some View {
        let selected = position == p
        return Button {
            switch p {
            case let .corner(c): layout = .corner(c, shape, size)
            case .centre: layout = .centre(coverage: coverage)
            case .hidden: layout = .hidden
            }
        } label: {
            RoundedRectangle(cornerRadius: 4)
                .fill(selected ? Color.accentColor : Color.primary.opacity(0.18))
                .frame(width: width, height: height)
        }
        .buttonStyle(.plain)
        .help(p == .centre ? "Centre, large" : "Corner")
    }
}

/// Gradient plus every image in the shared background library. Added images are available to all projects.
struct BackgroundSection: View {
    @ObservedObject var editor: EditorModel
    @State private var library: [URL] = BackgroundLibrary.list()

    private let columns = [GridItem(.adaptive(minimum: 72), spacing: 8)]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Background").font(.headline)
                Spacer()
                Button("Add image…", action: addImages)
            }
            LazyVGrid(columns: columns, spacing: 8) {
                tile(selected: editor.project.style.backgroundImage == nil) {
                    let s = editor.project.style
                    LinearGradient(colors: [color(s.backgroundTop), color(s.backgroundBottom)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                } action: { editor.useGradientBackground() }
                    .help("Gradient")
                ForEach(library, id: \.self) { url in
                    tile(selected: editor.project.style.backgroundImage == "backgrounds/\(url.lastPathComponent)") {
                        Thumbnail(url: url)
                    } action: { editor.useBackground(url) }
                        .help(url.deletingPathExtension().lastPathComponent)
                        .contextMenu {
                            Button("Remove from library") {
                                try? BackgroundLibrary.remove(url)
                                library = BackgroundLibrary.list()
                            }
                        }
                }
            }
            .disabled(editor.project.style.fullScreen)
            if editor.project.style.fullScreen {
                Text("Hidden while Full screen is on.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear { library = BackgroundLibrary.list() }
    }

    private func tile<C: View>(selected: Bool, @ViewBuilder content: () -> C, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            content()
                .frame(height: 44)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.15),
                                                                          lineWidth: selected ? 3 : 1))
        }
        .buttonStyle(.plain)
    }

    private func color(_ c: RGBA) -> Color { Color(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: c.a) }

    private func addImages() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.message = "Images are added to your background library for use in any project."
        guard panel.runModal() == .OK else { return }
        editor.addToLibrary(panel.urls)
        library = BackgroundLibrary.list()
    }
}

struct Thumbnail: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Color.primary.opacity(0.08)
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            }
        }
        .task(id: url) {
            let url = url
            image = await Task.detached {
                guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                          kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 240,
                      ] as CFDictionary) else { return nil }
                return NSImage(cgImage: cg, size: .zero)
            }.value
        }
    }
}

/// Mic and screen-audio levels; 0 mutes. Changes apply to preview and export, the recordings are untouched.
struct AudioSection: View {
    @ObservedObject var editor: EditorModel

    var body: some View {
        let p = editor.project
        let hasMic = p.clips.contains { $0.micFile != nil }
        let hasScreenAudio = p.clips.contains { $0.screenAudioFile != nil }
        if hasMic || hasScreenAudio {
            VStack(alignment: .leading, spacing: 8) {
                Text("Audio").font(.headline)
                if hasMic { row("Microphone", icon: "mic.fill", value: $editor.project.micVolume) }
                if hasScreenAudio { row("Screen audio", icon: "speaker.wave.2.fill", value: $editor.project.screenAudioVolume) }
            }
        }
    }

    private func row(_ title: String, icon: String, value: Binding<Double>) -> some View {
        HStack {
            Button {
                value.wrappedValue = value.wrappedValue > 0 ? 0 : 1
            } label: {
                Image(systemName: value.wrappedValue > 0 ? icon : "speaker.slash.fill").frame(width: 18)
            }
            .buttonStyle(.borderless)
            .help(value.wrappedValue > 0 ? "Mute \(title.lowercased())" : "Unmute")
            VStack(alignment: .leading, spacing: 0) {
                Text(value.wrappedValue > 0 ? "\(title) \(Int(value.wrappedValue * 100))%" : "\(title) muted").font(.callout)
                Slider(value: value, in: 0 ... 1.5)
            }
        }
    }
}

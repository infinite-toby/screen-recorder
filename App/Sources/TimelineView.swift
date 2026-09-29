import RecorderCore
import SwiftUI

struct TimelineView: View {
    @ObservedObject var editor: EditorModel
    private let labelWidth: CGFloat = 84
    private let rowHeight: CGFloat = 34

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Color.clear.frame(height: 20)
                HStack(spacing: 4) {
                    Text("Clips").font(.callout.weight(.medium)).foregroundStyle(.secondary)
                    Spacer()
                    Button { editor.splitAtPlayhead() } label: { Image(systemName: "scissors") }
                        .buttonStyle(.borderless)
                        .help("Split the clip at the playhead (⌘B)")
                }
                .frame(height: rowHeight)
                .padding(.trailing, 8)
                rowLabel("Camera") { editor.addCameraBlock(at: editor.time) }
                rowLabel("Zoom") { editor.addZoomBlock(at: editor.time) }
            }
            .frame(width: labelWidth)
            .padding(.leading, 10)

            GeometryReader { geo in
                let pps = geo.size.width / max(editor.duration, 0.1)
                ZStack(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: 6) {
                        Ruler(duration: editor.duration, pps: pps)
                            .frame(height: 20)
                            .contentShape(Rectangle())
                            .gesture(scrub(pps: pps))
                        takesRow(pps: pps)
                        track(pps: pps, add: editor.addCameraBlock) {
                            ForEach(editor.project.cameraBlocks) { b in
                                BlockView(label: label(for: b.layout), color: .blue, start: b.start, end: b.end, pps: pps,
                                          selected: editor.selection == .camera(b.id),
                                          select: { editor.selection = .camera(b.id) },
                                          setRange: { editor.setCameraBlockRange(b.id, start: $0, end: $1) })
                            }
                        }
                        track(pps: pps, add: editor.addZoomBlock) {
                            ForEach(editor.project.zoomBlocks) { b in
                                BlockView(label: "\(String(format: "%.1f", b.scale))×\(b.isAuto ? " auto" : "")", color: .orange,
                                          start: b.start, end: b.end, pps: pps,
                                          selected: editor.selection == .zoom(b.id),
                                          select: { editor.selection = .zoom(b.id) },
                                          setRange: { editor.setZoomBlockRange(b.id, start: $0, end: $1) })
                            }
                        }
                    }
                    // Playhead
                    Rectangle()
                        .fill(Color.red)
                        .frame(width: 2)
                        .offset(x: editor.time * pps - 1)
                        .allowsHitTesting(false)
                }
            }
            .padding(.trailing, 14)
        }
        .padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func rowLabel(_ title: String, add: (() -> Void)?) -> some View {
        HStack(spacing: 4) {
            Text(title).font(.callout.weight(.medium)).foregroundStyle(.secondary)
            Spacer()
            if let add {
                Button(action: add) { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
                    .help("Add \(title.lowercased()) block at the playhead")
            }
        }
        .frame(height: rowHeight)
        .padding(.trailing, 8)
    }

    private func scrub(pps: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0).onChanged { v in editor.seek(to: v.location.x / pps) }
    }

    private func takesRow(pps: CGFloat) -> some View {
        let segs = editor.project.segments
        let clips = editor.project.clips
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05))
            ForEach(Array(segs.enumerated()), id: \.offset) { i, seg in
                let firstOfTake = i == 0 || segs[i - 1].clipIndex != seg.clipIndex
                let selected = editor.selectedSection == seg
                SectionChip(label: firstOfTake ? "Take \(seg.clipIndex + 1)" : "", segment: seg, pps: pps, height: rowHeight,
                            selected: selected, clipDuration: clips[seg.clipIndex].duration,
                            select: { editor.select(section: seg) },
                            trim: { start, end in editor.trim(seg, newStart: start, newEnd: end) })
            }
        }
        .frame(height: rowHeight)
    }

    private func track<Content: View>(pps: CGFloat, add: @escaping (Double) -> Void, @ViewBuilder content: () -> Content) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05))
                .contentShape(Rectangle())
                .gesture(SpatialTapGesture(count: 2).onEnded { v in add(v.location.x / pps) }
                    .exclusively(before: SpatialTapGesture().onEnded { v in
                        editor.selection = nil
                        editor.seek(to: v.location.x / pps)
                    }))
            content()
        }
        .frame(height: rowHeight)
    }

    private func label(for layout: CameraLayout) -> String {
        switch layout {
        case .hidden: "Hidden"
        case let .centre(c): "Centre \(Int(c * 100))%"
        case let .corner(corner, shape, size):
            "\(corner.short) \(shape.rawValue.capitalized) \(size == .small ? "S" : "L")"
        }
    }
}

extension Corner {
    var short: String {
        switch self {
        case .topLeft: "↖"
        case .topRight: "↗"
        case .bottomLeft: "↙"
        case .bottomRight: "↘"
        }
    }
}

/// A block on a track: drag the middle to move, the edges to trim.
struct BlockView: View {
    let label: String
    let color: Color
    let start: Double
    let end: Double
    let pps: CGFloat
    let selected: Bool
    let select: () -> Void
    let setRange: (Double, Double) -> Void

    @State private var origin: (Double, Double)?

    var body: some View {
        let width = max((end - start) * pps, 6)
        RoundedRectangle(cornerRadius: 6)
            .fill(color.opacity(selected ? 0.85 : 0.55))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(selected ? Color.white : .clear, lineWidth: 2))
            .overlay(alignment: .leading) {
                Text(label).font(.caption.weight(.semibold)).foregroundStyle(.white).lineLimit(1).padding(.leading, 10)
            }
            .overlay(alignment: .leading) { handle(edge: .leading) }
            .overlay(alignment: .trailing) { handle(edge: .trailing) }
            .frame(width: width, height: 34)
            .offset(x: start * pps)
            .onTapGesture { select() }
            .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .global)
                .onChanged { v in
                    if origin == nil {
                        origin = (start, end)
                        select()
                    }
                    let dt = v.translation.width / pps
                    setRange(origin!.0 + dt, origin!.1 + dt)
                }
                .onEnded { _ in origin = nil })
    }

    private func handle(edge: HorizontalEdge) -> some View {
        Rectangle()
            .fill(Color.white.opacity(selected ? 0.5 : 0.001))
            .frame(width: 6)
            .padding(.vertical, 8)
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { v in
                    if origin == nil {
                        origin = (start, end)
                        select()
                    }
                    let dt = v.translation.width / pps
                    if edge == .leading {
                        setRange(origin!.0 + dt, origin!.1)
                    } else {
                        setRange(origin!.0, origin!.1 + dt)
                    }
                }
                .onEnded { _ in origin = nil })
    }
}

struct Ruler: View {
    let duration: Double
    let pps: CGFloat

    var body: some View {
        Canvas { ctx, size in
            let steps: [Double] = [0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300]
            let step = steps.first { $0 * pps >= 70 } ?? 600
            var t = 0.0
            while t <= duration + 0.001 {
                let x = t * pps
                ctx.fill(Path(CGRect(x: x, y: size.height - 6, width: 1, height: 6)), with: .color(.secondary))
                ctx.draw(Text(rulerLabel(t)).font(.caption2).foregroundColor(.secondary),
                         at: CGPoint(x: x + 3, y: 5), anchor: .topLeading)
                t += step
            }
        }
    }

    private func rulerLabel(_ t: Double) -> String {
        t < 60 && t.truncatingRemainder(dividingBy: 1) != 0 ? String(format: "%.1fs", t) : String(format: "%d:%02d", Int(t) / 60, Int(t) % 60)
    }
}

/// A section of a take on the Clips row. Click to select; drag either edge to trim (dragging outwards
/// brings back footage that was trimmed or cut).
struct SectionChip: View {
    let label: String
    let segment: Segment
    let pps: CGFloat
    let height: CGFloat
    let selected: Bool
    let clipDuration: Double
    let select: () -> Void
    let trim: (_ newStart: Double?, _ newEnd: Double?) -> Void

    @State private var dragStart: Double = 0
    @State private var dragEnd: Double = 0

    var body: some View {
        // Live preview of a trim in progress, applied on release.
        let start = segment.editedStart + dragStart
        let width = max((segment.duration - dragStart + dragEnd) * pps - 2, 4)
        RoundedRectangle(cornerRadius: 6)
            .fill(Color.gray.opacity(selected ? 0.6 : 0.32))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(selected ? Color.white : Color.clear, lineWidth: 2))
            .overlay(alignment: .leading) {
                Text(label).font(.caption.weight(.medium)).padding(.leading, 10).lineLimit(1)
            }
            .overlay(alignment: .leading) { handle(leading: true) }
            .overlay(alignment: .trailing) { handle(leading: false) }
            .frame(width: width, height: height)
            .offset(x: start * pps + 1)
            .onTapGesture(perform: select)
    }

    private func handle(leading: Bool) -> some View {
        Rectangle()
            .fill(Color.white.opacity(selected ? 0.6 : 0.25))
            .frame(width: 5)
            .padding(.vertical, 7)
            .contentShape(Rectangle().inset(by: -4))
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { v in
                    let dt = v.translation.width / pps
                    if leading {
                        dragStart = min(max(dt, -segment.sourceStart), segment.duration - 0.1)
                    } else {
                        dragEnd = max(min(dt, clipDuration - segment.sourceEnd), -(segment.duration - 0.1))
                    }
                }
                .onEnded { _ in
                    let ds = dragStart, de = dragEnd
                    dragStart = 0
                    dragEnd = 0
                    if leading, abs(ds) > 0.01 { trim(segment.sourceStart + ds, nil) }
                    if !leading, abs(de) > 0.01 { trim(nil, segment.sourceEnd + de) }
                })
            .help(leading ? "Drag to trim the start" : "Drag to trim the end")
    }
}

import AVFoundation
import Combine
import RecorderCore
import SwiftUI

@MainActor
final class EditorModel: ObservableObject {
    enum Selection: Equatable {
        case camera(UUID)
        case zoom(UUID)
        /// A section of a take (between splits/cuts), identified by its take and where it starts in that take.
        case section(clipID: UUID, start: Double)
    }

    let bundle: ProjectBundle
    @Published var project: Project {
        didSet { projectChanged(from: oldValue) }
    }

    @Published var selection: Selection? {
        didSet {
            if selection != nil { wordSelection = nil }
            updateRenderOptions()
        }
    }

    @Published private(set) var time: Double = 0
    @Published private(set) var isPlaying = false
    /// Full-resolution render of the paused frame, shown over the 720p player so still frames are sharp.
    @Published private(set) var stillImage: NSImage?
    @Published var exportProgress: Double?
    /// Word-timed transcripts by clip.
    @Published var transcripts: [UUID: Transcript] = [:]
    /// Captions for the current edit, rebuilt when the project or transcripts change.
    @Published var captions: [Caption] = []
    /// Selected words, as a range of indices into `words`.
    @Published var wordSelection: ClosedRange<Int>?
    @Published var transcribeProgress: Double?
    @Published var transcribeError: String?
    /// Takes whose microphone recorded silence (checked when a transcript comes back empty).
    @Published var silentMicTakes: [Int] = []
    /// Every transcribed word in timeline order, with where it sits after editing.
    @Published var words: [TranscriptWord] = []
    /// True while a text field has focus, so single-key shortcuts (Space, Delete) don't steal typing.
    @Published var isEditingText = false
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    var undoStack: [Project] = []
    var redoStack: [Project] = []
    var isRestoringHistory = false
    private var lastChangeAt = Date.distantPast
    private var glitchScan: Task<Void, Never>?

    let player = AVPlayer()
    let renderState: RenderState
    private var cursorLogs: [UUID: CursorLog] = [:]
    private(set) var cursorTrack: CursorTrack
    private var timeObserver: Any?
    private var saveTask: Task<Void, Never>?
    private var endObserver: AnyCancellable?
    private var built: CompositionBuilder.Result?
    private var stillTask: Task<Void, Never>?

    static let minBlock = 0.3

    init(bundle: ProjectBundle, project: Project) {
        self.bundle = bundle
        self.project = project
        cursorLogs = bundle.loadCursorLogs(for: project)
        cursorTrack = CursorTrack(project: project, logs: cursorLogs)
        renderState = RenderState(project: project, cursor: cursorTrack)
        renderState.update(backgroundImage: bundle.backgroundImage(for: project))
        transcripts = Self.loadTranscripts(bundle: bundle, project: project)
        refreshWordsAndCaptions()
        scanCameraGlitches()
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.time = t.seconds
                self.isPlaying = self.player.rate != 0
            }
        }
        endObserver = NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.isPlaying = false
                self?.scheduleStill()
            }
        Task { await rebuild() }
    }

    var duration: Double { project.duration }
    var previewSize: CGSize { project.export.aspect.size(shortSide: 720) }

    // MARK: - Playback

    func rebuild() async {
        do {
            let built = try await CompositionBuilder.build(project: project, bundle: bundle, state: renderState,
                                                           renderSize: previewSize, fps: 30)
            let item = AVPlayerItem(asset: built.composition)
            item.videoComposition = built.videoComposition
            self.built = built
            let resume = time
            player.replaceCurrentItem(with: item)
            await player.seek(to: CMTime(seconds: min(resume, max(duration - 0.05, 0)), preferredTimescale: 600),
                              toleranceBefore: .zero, toleranceAfter: .zero)
            stillImage = nil
            scheduleStill()
        } catch {
            NSLog("Composition failed: \(error)")
        }
    }

    func togglePlay() {
        if player.rate != 0 {
            player.pause()
            isPlaying = false
        } else {
            if time >= duration - 0.05 { seek(to: 0) }
            stillTask?.cancel()
            stillImage = nil
            player.play()
            isPlaying = true
        }
        updateRenderOptions()
    }

    func seek(to t: Double) {
        let clamped = min(max(t, 0), duration)
        time = clamped
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        // Show the live frame while scrubbing; the sharp still returns once the playhead settles.
        stillImage = nil
        scheduleStill()
    }

    /// Re-renders the current frame after an edit when paused (playing picks up changes on the next frame).
    private func refreshFrame() {
        guard player.rate == 0, let item = player.currentItem,
              let vc = item.videoComposition?.mutableCopy() as? AVMutableVideoComposition else { return }
        item.videoComposition = vc
        scheduleStill()
    }

    /// Renders the current paused frame at up to 1440p (never above the export size), shortly after the last change.
    /// The previous still stays up meanwhile, so edits don't flicker between sharp and soft.
    private func scheduleStill() {
        stillTask?.cancel()
        guard !isPlaying, let built else { return }
        let short = min(1440, project.export.resolution.rawValue)
        let size = project.export.aspect.size(shortSide: short)
        let at = CMTime(seconds: min(time, max(duration - 0.02, 0)), preferredTimescale: 600)
        stillTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard !Task.isCancelled,
                  let vc = built.videoComposition.mutableCopy() as? AVMutableVideoComposition else { return }
            vc.renderSize = size
            let gen = AVAssetImageGenerator(asset: built.composition)
            gen.videoComposition = vc
            gen.requestedTimeToleranceBefore = .zero
            gen.requestedTimeToleranceAfter = .zero
            guard let (cg, _) = try? await gen.image(at: at), !Task.isCancelled else { return }
            guard let self, !self.isPlaying else { return }
            self.stillImage = NSImage(cgImage: cg, size: size)
        }
    }

    /// While a zoom is selected and paused, show the whole canvas so its focus box can be placed.
    var isEditingZoomFocus: Bool {
        if case .zoom = selection, !isPlaying { return true }
        return false
    }

    private func updateRenderOptions() {
        renderState.update(options: FrameRenderer.Options(ignoreZoom: isEditingZoomFocus))
        refreshFrame()
    }

    // MARK: - Project changes

    private func projectChanged(from old: Project) {
        // One undo step per burst of changes (a drag or slider move collapses into one).
        if !isRestoringHistory, Date().timeIntervalSince(lastChangeAt) > 0.8 {
            undoStack.append(old)
            if undoStack.count > 100 { undoStack.removeFirst() }
            redoStack.removeAll()
        }
        lastChangeAt = Date()
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
        if old.clips != project.clips || old.cuts != project.cuts || old.subtitles != project.subtitles {
            refreshWordsAndCaptions()
        }
        if old.style.backgroundImage != project.style.backgroundImage {
            renderState.update(backgroundImage: bundle.backgroundImage(for: project))
        }
        if old.clips != project.clips || old.cuts != project.cuts {
            cursorLogs = bundle.loadCursorLogs(for: project)
            cursorTrack = CursorTrack(project: project, logs: cursorLogs)
            renderState.update(project: project, cursor: cursorTrack)
            Task { await rebuild() }
        } else if old.export.aspect != project.export.aspect {
            renderState.update(project: project)
            Task { await rebuild() }
        } else {
            renderState.update(project: project)
            refreshFrame()
        }
        scheduleSave()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [bundle, project] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            try? bundle.save(project)
        }
    }

    func saveNow() {
        saveTask?.cancel()
        try? bundle.save(project)
    }

    /// Called after recording more takes into this project.
    func appendRecordedClips(from recorded: Project) {
        project.clips = recorded.clips
        saveNow()
        scanCameraGlitches()
    }

    /// Finds single bad webcam frames in takes not scanned yet, so preview and export can hide them.
    func scanCameraGlitches() {
        let todo = project.clips.filter { $0.cameraFile != nil && $0.cameraGlitches == nil }
        guard !todo.isEmpty, glitchScan == nil else { return }
        let bundle = bundle
        glitchScan = Task {
            defer { glitchScan = nil }
            var found: [UUID: [TimeSpan]] = [:]
            for clip in todo {
                guard let file = clip.cameraFile else { continue }
                found[clip.id] = (try? await CameraGlitchDetector.scan(bundle.file(file))) ?? []
            }
            // Bookkeeping, not an edit: keep it out of undo history.
            var p = project
            for i in p.clips.indices { if let g = found[p.clips[i].id] { p.clips[i].cameraGlitches = g } }
            isRestoringHistory = true
            project = p
            isRestoringHistory = false
        }
    }

    func reloadAfterRecording() {
        Task { await rebuild() }
    }

    // MARK: - Backgrounds

    /// Uses a library image as this project's background (copied into the project).
    func useBackground(_ libraryURL: URL) {
        do {
            project.style.backgroundImage = try bundle.importBackground(from: libraryURL)
        } catch {
            NSLog("Background import failed: \(error)")
        }
    }

    func useGradientBackground() { project.style.backgroundImage = nil }

    /// Adds images to the shared library and applies the last one. Returns the library copies.
    @discardableResult
    func addToLibrary(_ urls: [URL]) -> [URL] {
        let added = urls.compactMap { try? BackgroundLibrary.add($0) }
        if let last = added.last { useBackground(last) }
        return added
    }

    // MARK: - Blocks

    /// Free space around `t` in a track, so new/moved blocks never overlap neighbours.
    private func gap(around t: Double, in ranges: [(id: UUID, start: Double, end: Double)], excluding: UUID? = nil) -> ClosedRange<Double> {
        let others = ranges.filter { $0.id != excluding }
        let lo = others.filter { $0.end <= t }.map(\.end).max() ?? 0
        let hi = others.filter { $0.start >= t }.map(\.start).min() ?? duration
        return lo ... max(lo, hi)
    }

    private var cameraRanges: [(id: UUID, start: Double, end: Double)] { project.cameraBlocks.map { ($0.id, $0.start, $0.end) } }
    private var zoomRanges: [(id: UUID, start: Double, end: Double)] { project.zoomBlocks.map { ($0.id, $0.start, $0.end) } }

    func addCameraBlock(at t: Double) {
        guard !project.cameraBlocks.contains(where: { $0.start <= t && t < $0.end }) else { return }
        let space = gap(around: t, in: cameraRanges)
        let end = min(t + 5, space.upperBound)
        guard end - t >= Self.minBlock else { return }
        // Pick something visibly different from the default so the new block reads as a change.
        let layout: CameraLayout = if case .centre = project.defaultCamera { .corner(.bottomRight, .square, .small) } else { .centre(coverage: 0.6) }
        let block = CameraBlock(start: t, end: end, layout: layout)
        project.cameraBlocks.append(block)
        selection = .camera(block.id)
    }

    func addZoomBlock(at t: Double) {
        guard !project.zoomBlocks.contains(where: { $0.start <= t && t < $0.end }) else { return }
        let space = gap(around: t, in: zoomRanges)
        let end = min(t + 3, space.upperBound)
        guard end - t >= Self.minBlock else { return }
        let focus = cursorTrack.position(at: t) ?? CGPoint(x: 0.5, y: 0.5)
        let block = ZoomBlock(start: t, end: end, scale: 2, focus: focus)
        project.zoomBlocks.append(block)
        selection = .zoom(block.id)
    }

    /// Moves or resizes a block to [start, end], clamped to its neighbours and the timeline.
    func setCameraBlockRange(_ id: UUID, start: Double, end: Double) {
        guard let i = project.cameraBlocks.firstIndex(where: { $0.id == id }) else { return }
        let r = clamp(start: start, end: end, current: project.cameraBlocks[i].start ..< project.cameraBlocks[i].end,
                      ranges: cameraRanges, id: id)
        project.cameraBlocks[i].start = r.lowerBound
        project.cameraBlocks[i].end = r.upperBound
    }

    func setZoomBlockRange(_ id: UUID, start: Double, end: Double) {
        guard let i = project.zoomBlocks.firstIndex(where: { $0.id == id }) else { return }
        let r = clamp(start: start, end: end, current: project.zoomBlocks[i].start ..< project.zoomBlocks[i].end,
                      ranges: zoomRanges, id: id)
        project.zoomBlocks[i].start = r.lowerBound
        project.zoomBlocks[i].end = r.upperBound
        project.zoomBlocks[i].isAuto = false
    }

    private func clamp(start: Double, end: Double, current: Range<Double>, ranges: [(id: UUID, start: Double, end: Double)],
                       id: UUID) -> ClosedRange<Double> {
        let space = gap(around: (current.lowerBound + current.upperBound) / 2, in: ranges, excluding: id)
        let length = end - start
        if abs(length - (current.upperBound - current.lowerBound)) < 1e-9 {
            // Moving: keep the length, slide within the free space.
            let s = min(max(start, space.lowerBound), space.upperBound - length)
            return max(s, space.lowerBound) ... min(max(s, space.lowerBound) + length, space.upperBound)
        }
        let s = min(max(start, space.lowerBound), end - Self.minBlock)
        let e = max(min(end, space.upperBound), s + Self.minBlock)
        return max(s, space.lowerBound) ... min(e, space.upperBound)
    }

    func updateCamera(_ id: UUID, layout: CameraLayout) {
        guard let i = project.cameraBlocks.firstIndex(where: { $0.id == id }) else { return }
        project.cameraBlocks[i].layout = layout
    }

    func updateZoom(_ id: UUID, scale: Double? = nil, focus: CGPoint? = nil) {
        guard let i = project.zoomBlocks.firstIndex(where: { $0.id == id }) else { return }
        if let scale { project.zoomBlocks[i].scale = scale }
        if let focus { project.zoomBlocks[i].focus = CGPoint(x: min(max(focus.x, 0), 1), y: min(max(focus.y, 0), 1)) }
        project.zoomBlocks[i].isAuto = false
    }

    func deleteSelection() {
        if wordSelection != nil {
            deleteSelectedWords()
            return
        }
        switch selection {
        case let .camera(id): project.cameraBlocks.removeAll { $0.id == id }
        case let .zoom(id): project.zoomBlocks.removeAll { $0.id == id }
        case .section: deleteSelectedSection()
        case nil: return
        }
        selection = nil
    }

    /// Replaces untouched auto-zooms with fresh suggestions; hand-edited zooms stay and win any overlap.
    func autoZoom() {
        let manual = project.zoomBlocks.filter { !$0.isAuto }
        let suggested = AutoZoom.suggest(clicks: cursorTrack.clicks, duration: duration).filter { s in
            !manual.contains { $0.start < s.end && s.start < $0.end }
        }
        project.zoomBlocks = manual + suggested
    }

    var hasClicks: Bool { !cursorTrack.clicks.isEmpty }

    // MARK: - Sections

    /// The section currently selected, re-found in the live segment list.
    var selectedSection: Segment? {
        guard case let .section(clipID, start) = selection,
              let ci = project.clips.firstIndex(where: { $0.id == clipID }) else { return nil }
        return project.segments.first { $0.clipIndex == ci && abs($0.sourceStart - start) < 0.001 }
    }

    func select(section seg: Segment) {
        selection = .section(clipID: project.clips[seg.clipIndex].id, start: seg.sourceStart)
    }

    /// Splits the section under the playhead.
    func splitAtPlayhead() {
        project.split(at: time)
    }

    func deleteSelectedSection() {
        guard let seg = selectedSection else { return }
        project.delete(segment: seg)
        selection = nil
    }

    /// Trims a section's start/end (clip-local seconds); keeps it selected afterwards.
    func trim(_ seg: Segment, newStart: Double? = nil, newEnd: Double? = nil) {
        let id = project.clips[seg.clipIndex].id
        project.trim(segment: seg, newStart: newStart, newEnd: newEnd)
        let start = newStart.map { max($0, 0) } ?? seg.sourceStart
        if let ci = project.clips.firstIndex(where: { $0.id == id }),
           let s = project.segments.first(where: { $0.clipIndex == ci && abs($0.sourceStart - start) < 0.05 }) {
            select(section: s)
        }
    }

    // MARK: - Import

    /// Adds video files to the end of the project as new takes.
    func importClips(_ urls: [URL]) async {
        var added: [Clip] = []
        for url in urls {
            do {
                added.append(try await ClipImporter.importVideo(url, into: bundle))
            } catch {
                transcribeError = "Couldn't import \(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
        guard !added.isEmpty else { return }
        project.clips += added
        saveNow()
    }

    /// Removes a take in one undoable step. Its files stay until the project is closed, so undo can bring it back.
    func deleteClip(_ id: UUID) {
        guard let i = project.clips.firstIndex(where: { $0.id == id }) else { return }
        var p = project
        let start = p.clipStarts[i]
        let len = p.clipEditedDurations[i]
        let end = start + len
        func shift(_ s: Double, _ e: Double) -> (Double, Double)? {
            if e <= start { return (s, e) }
            if s >= end { return (s - len, e - len) }
            let ns = s < start ? s : start
            let ne = e > end ? e - len : start
            return ne - ns >= Self.minBlock ? (ns, ne) : nil
        }
        p.cameraBlocks = p.cameraBlocks.compactMap { b in shift(b.start, b.end).map { var b = b; (b.start, b.end) = $0; return b } }
        p.zoomBlocks = p.zoomBlocks.compactMap { b in shift(b.start, b.end).map { var b = b; (b.start, b.end) = $0; return b } }
        p.cuts.removeAll { $0.clipID == id }
        p.clips.remove(at: i)
        project = p
        saveNow()
    }

    /// Called when leaving the editor: saves and deletes files of takes that were removed.
    func close() {
        player.pause()
        saveNow()
        bundle.removeOrphanedClips(keeping: project)
    }

    // MARK: - Export

    func export(to url: URL) async throws {
        scanCameraGlitches()
        await glitchScan?.value
        saveNow()
        exportProgress = 0
        defer { exportProgress = nil }
        try await Exporter.export(project: project, bundle: bundle, cursor: cursorTrack, captions: captions, to: url) { p in
            Task { @MainActor [weak self] in self?.exportProgress = p }
        }
    }
}

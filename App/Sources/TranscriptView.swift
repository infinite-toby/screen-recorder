import RecorderCore
import SwiftUI

/// Right-hand panel: the existing inspector, or the transcript editor.
struct SidePanel: View {
    @ObservedObject var editor: EditorModel
    @AppStorage("sidePanel.tab") private var tab = "edit"

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text("Edit").tag("edit")
                Text("Transcript").tag("transcript")
                Text("Subtitles").tag("subtitles")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(10)
            Divider()
            if tab == "transcript" {
                TranscriptView(editor: editor)
            } else if tab == "subtitles" {
                SubtitlesEditorView(editor: editor)
            } else {
                InspectorView(editor: editor)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct TranscriptView: View {
    @ObservedObject var editor: EditorModel
    @State private var editing: TranscriptWord?
    @State private var editText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(12)
            Divider()
            if editor.hasTranscript && editor.words.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Label("No speech found", systemImage: "waveform.slash").font(.headline)
                    Text(editor.silentMicTakes.isEmpty
                         ? "The recording didn't contain recognisable speech."
                         : "The microphone recorded silence in take \(editor.silentMicTakes.map(String.init).joined(separator: ", ")). Check the mic is on, unmuted and connected, and watch the level meter on the setup screen before recording.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .padding(12)
                Spacer()
            } else if editor.hasTranscript {
                ScrollViewReader { proxy in
                    ScrollView {
                        wordsView
                            .padding(12)
                    }
                    .onChange(of: editor.currentWordID) { _, id in
                        if editor.isPlaying, let id { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) } }
                    }
                }
            } else {
                Spacer()
            }
        }
        .onChange(of: editing) { _, w in editor.isEditingText = w != nil }
        .alert("Edit word", isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            TextField("Word", text: $editText)
            Button("Save") {
                if let w = editing { editor.editWord(w, text: editText) }
                editing = nil
            }
            Button("Cancel", role: .cancel) { editing = nil }
        } message: {
            Text("Correct the transcription. This changes the subtitles, not the audio.")
        }
    }

    @ViewBuilder private var header: some View {
        if let p = editor.transcribeProgress {
            ProgressView(value: p) { Text("Transcribing… \(Int(p * 100))%").font(.callout).monospacedDigit() }
            Text("Runs on this Mac. The first run downloads the speech model.").font(.caption).foregroundStyle(.secondary)
        } else if !editor.untranscribedClips.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    editor.transcribe()
                } label: {
                    Label(editor.hasTranscript ? "Transcribe new takes" : "Transcribe", systemImage: "text.bubble")
                }
                .buttonStyle(.borderedProminent)
                Text("On-device, in \(Locale.current.localizedString(forIdentifier: Locale.current.identifier) ?? "your language").")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } else if editor.project.clips.allSatisfy({ $0.speechAudioFile == nil }) {
            Text("No microphone was recorded, so there's nothing to transcribe.").font(.callout).foregroundStyle(.secondary)
        }
        if let err = editor.transcribeError {
            Text(err).font(.caption).foregroundStyle(.red)
        }
        if editor.hasTranscript {
            HStack {
                Button("Delete") { editor.deleteSelectedWords() }
                    .disabled(!editor.selectionHasKeptWords)
                    .help("Cut the selected words from the video (Delete key)")
                Button("Restore") { editor.restoreSelectedWords() }
                    .disabled(!editor.selectionHasCutWords)
                    .help("Put back cut words in the selection")
                Spacer()
                Text("Drag or shift-click to select; double-click a sentence").font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.top, 4)
        }
    }

    @State private var wordFrames: [Int: CGRect] = [:]
    @State private var dragAnchor: Int?

    /// Word nearest a point in the transcript: the one on that line whose horizontal span is closest.
    private func word(at p: CGPoint) -> Int? {
        let onLine = wordFrames.filter { $0.value.minY - 3 <= p.y && p.y <= $0.value.maxY + 3 }
        let pool = onLine.isEmpty ? wordFrames : onLine
        return pool.min { a, b in
            func dist(_ r: CGRect) -> CGFloat {
                let dx = p.x < r.minX ? r.minX - p.x : (p.x > r.maxX ? p.x - r.maxX : 0)
                let dy = p.y < r.minY ? r.minY - p.y : (p.y > r.maxY ? p.y - r.maxY : 0)
                return dx + dy * 4
            }
            return dist(a.value) < dist(b.value)
        }?.key
    }

    private var wordsView: some View {
        let sel = editor.wordSelection
        let current = editor.currentWordID
        return FlowLayout(spacing: 3, lineSpacing: 5) {
            ForEach(editor.words) { w in
                let selected = sel?.contains(w.id) ?? false
                Text(w.word.text)
                    .font(.system(size: 14))
                    .strikethrough(w.isCut)
                    .foregroundStyle(w.isCut ? Color.secondary.opacity(0.6) : Color.primary)
                    .padding(.horizontal, 2)
                    .padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 3).fill(
                        selected ? Color.accentColor.opacity(0.35) : (w.id == current ? Color.yellow.opacity(0.35) : .clear)))
                    .modifier(ParagraphBreak(active: w.startsParagraph && w.id > 0))
                    .background(GeometryReader { g in
                        Color.clear.preference(key: WordFrames.self, value: [w.id: g.frame(in: .named("words"))])
                    })
                    .id(w.id)
                    .onTapGesture(count: 2) { editor.selectSentence(containing: w.id) }
                    .onTapGesture {
                        editor.selectWord(w.id, extend: NSEvent.modifierFlags.contains(.shift))
                    }
                    .contextMenu {
                        Button("Edit word…") {
                            editText = w.word.text
                            editing = w
                        }
                        Button("Select sentence") { editor.selectSentence(containing: w.id) }
                    }
            }
        }
        .coordinateSpace(name: "words")
        .onPreferenceChange(WordFrames.self) { wordFrames = $0 }
        // Drag across words to select them.
        .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .named("words"))
            .onChanged { v in
                if dragAnchor == nil { dragAnchor = word(at: v.startLocation) }
                guard let a = dragAnchor, let b = word(at: v.location) else { return }
                editor.wordSelection = min(a, b) ... max(a, b)
                editor.selection = nil
            }
            .onEnded { _ in dragAnchor = nil })
    }
}

private struct WordFrames: PreferenceKey {
    static let defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

/// Forces a line break before a word that starts a new paragraph.
private struct ParagraphBreak: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View { content.layoutValue(key: StartsNewLine.self, value: active) }
}

private struct StartsNewLine: LayoutValueKey {
    static let defaultValue = false
}

/// Wraps children left-to-right like text; children flagged `StartsNewLine` begin a new paragraph.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? 300, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(width: bounds.width, subviews: subviews)
        for (i, p) in result.positions.enumerated() {
            subviews[i].place(at: CGPoint(x: bounds.minX + p.x, y: bounds.minY + p.y), proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (positions: [CGPoint], size: CGSize) {
        var positions: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, maxX: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            let paragraph = sub[StartsNewLine.self]
            if x > 0 && (x + size.width > width || paragraph) {
                y += lineHeight + lineSpacing + (paragraph ? 8 : 0)
                x = 0
                lineHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            maxX = max(maxX, x)
        }
        return (positions, CGSize(width: min(maxX, width), height: y + lineHeight))
    }
}

struct SubtitleSettingsView: View {
    @ObservedObject var editor: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Show subtitles in video", isOn: $editor.project.subtitles.burnIn)
            if editor.project.subtitles.burnIn {
                Picker("Position", selection: $editor.project.subtitles.position) {
                    Text("Bottom").tag(SubtitleSettings.Position.bottom)
                    Text("Top").tag(SubtitleSettings.Position.top)
                }
                .pickerStyle(.segmented)
                slider("Size", $editor.project.subtitles.size, 0.03 ... 0.08)
                Toggle("Highlight the spoken word", isOn: $editor.project.subtitles.highlightWord)
            }
            Button("Export subtitles (.srt)…") { editor.exportSRT() }
                .disabled(editor.captions.isEmpty)
        }
    }
}

/// Every caption as an editable line. Typing, deleting or retyping words changes only the subtitles.
struct SubtitlesEditorView: View {
    @ObservedObject var editor: EditorModel
    @FocusState private var focused: Double?
    @State private var drafts: [Double: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SubtitleSettingsView(editor: editor).padding(12)
            Divider()
            if editor.captions.isEmpty {
                Text(editor.hasTranscript ? "No subtitles: the transcript has no words."
                     : "Transcribe in the Transcript tab first; subtitles are made from it.")
                    .font(.callout).foregroundStyle(.secondary).padding(12)
                Spacer()
            } else {
                Text("Edit the text freely. This changes only the subtitles, never the video.")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.top, 8)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(editor.captions, id: \.start) { caption in
                                row(caption)
                            }
                        }
                        .padding(12)
                    }
                    .onChange(of: currentCaptionStart) { _, start in
                        if editor.isPlaying, let start { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(start, anchor: .center) } }
                    }
                }
            }
        }
        .onChange(of: focused) { old, new in
            // Leaving a line commits it.
            if let old, old != new, let c = editor.captions.first(where: { $0.start == old }) { commit(c) }
            editor.isEditingText = new != nil
        }
        .onAppear {
            // macOS focuses the first text field on appear; don't grab the keyboard until a line is clicked.
            DispatchQueue.main.async { focused = nil }
        }
        .onDisappear { editor.isEditingText = false }
    }

    private var currentCaptionStart: Double? { CaptionBuilder.caption(at: editor.time, in: editor.captions)?.start }

    private func row(_ caption: Caption) -> some View {
        let isCurrent = currentCaptionStart == caption.start
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button(format(caption.start)) { editor.seek(to: caption.start) }
                .buttonStyle(.borderless)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .help("Jump here")
            TextField("", text: Binding(get: { drafts[caption.start] ?? caption.text },
                                        set: { drafts[caption.start] = $0 }), axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused($focused, equals: caption.start)
                .onSubmit { commit(caption) }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6).fill(isCurrent ? Color.yellow.opacity(0.18) : Color.primary.opacity(0.04)))
        .id(caption.start)
    }

    private func commit(_ caption: Caption) {
        guard let text = drafts.removeValue(forKey: caption.start), text != caption.text else { return }
        editor.applySubtitleEdit(caption, text: text)
    }
}

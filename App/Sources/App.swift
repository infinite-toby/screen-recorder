import RecorderCore
import SwiftUI

@main
struct ScreenRecorderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("Screen Recorder", id: "main") {
            RootView()
                .environmentObject(model)
                .frame(minWidth: 980, minHeight: 640)
        }
        .defaultSize(width: 1280, height: 820)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Recording…") { model.newRecording() }.keyboardShortcut("n")
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// The main window is minimised while recording; the app must keep running with no visible windows.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@MainActor
final class AppModel: ObservableObject {
    enum Screen {
        case home
        /// Choosing sources; `appendTo` is set when recording another take into an open project.
        case setup(appendTo: EditorModel?)
        case editor(EditorModel)
    }

    @Published var screen: Screen = .home
    @Published var recording: RecordingController?
    @Published var projects: [ProjectBundle] = []
    @Published var error: String?

    init() { reloadProjects() }

    func reloadProjects() { projects = ProjectBundle.list() }

    func newRecording() { screen = .setup(appendTo: nil) }

    /// Starts a project from pre-recorded videos.
    func importNewProject(_ urls: [URL]) {
        Task {
            do {
                let name = urls.first?.deletingPathExtension().lastPathComponent ?? "Imported"
                let (bundle, project) = try ProjectBundle.create(name: name)
                let editor = EditorModel(bundle: bundle, project: project)
                await editor.importClips(urls)
                guard !editor.project.clips.isEmpty else {
                    try? FileManager.default.removeItem(at: bundle.url)
                    self.error = editor.transcribeError ?? "Nothing could be imported."
                    return
                }
                screen = .editor(editor)
                reloadProjects()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    func open(_ bundle: ProjectBundle) {
        do {
            let project = try bundle.load()
            screen = .editor(EditorModel(bundle: bundle, project: project))
        } catch {
            self.error = "Couldn't open project: \(error.localizedDescription)"
        }
    }

    /// Brings the editor window back to the front after recording (restoring it from the Dock if minimised).
    func showMainWindow(_ preferred: [NSWindow] = []) {
        NSApp.activate(ignoringOtherApps: true)
        let candidates = preferred + NSApp.windows.filter { !($0 is NSPanel) && ($0.isMiniaturized || $0.canBecomeMain) }
        guard let window = candidates.first else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        // Deminiaturising animates; make sure it ends up in front once it has.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
    }

    func startRecording(settings: Recorder.Settings, appendTo editor: EditorModel?) {
        let controller = RecordingController(settings: settings, editor: editor) { [weak self] result in
            guard let self else { return }
            let warning = recording?.silenceWarning
            let windows = recording?.minimised ?? []
            recording = nil
            if let warning { self.error = warning }
            showMainWindow(windows)
            switch result {
            case let .success(editor):
                if let editor {
                    editor.reloadAfterRecording()
                    screen = .editor(editor)
                } else {
                    screen = .home
                }
            case let .failure(err):
                self.error = err.localizedDescription
                screen = editor.map { .editor($0) } ?? .home
            }
            reloadProjects()
        }
        recording = controller
        controller.start()
    }
}

struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Group {
            switch model.screen {
            case .home: HomeView()
            case let .setup(editor): RecordSetupView(appendTo: editor)
            case let .editor(editor): EditorView(editor: editor)
            }
        }
        .alert("Something went wrong", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: {
            Text(model.error ?? "")
        }
    }
}

struct HomeView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Projects").font(.title2.weight(.semibold))
                Spacer()
                Button {
                    if let urls = chooseVideos() { model.importNewProject(urls) }
                } label: {
                    Label("Import Video…", systemImage: "square.and.arrow.down")
                }
                .controlSize(.large)
                Button {
                    model.newRecording()
                } label: {
                    Label("New Recording", systemImage: "record.circle")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding(20)
            Divider()
            if model.projects.isEmpty {
                ContentUnavailableView("No recordings yet", systemImage: "video",
                                       description: Text("Start a new recording to create your first project."))
            } else {
                List(model.projects, id: \.url) { bundle in
                    HStack {
                        Image(systemName: "film").foregroundStyle(.secondary)
                        Text(bundle.url.deletingPathExtension().lastPathComponent)
                        Spacer()
                        Button("Open") { model.open(bundle) }
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { model.open(bundle) }
                    .contextMenu {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([bundle.url]) }
                        Button("Move to Trash", role: .destructive) {
                            try? FileManager.default.trashItem(at: bundle.url, resultingItemURL: nil)
                            model.reloadProjects()
                        }
                    }
                }
            }
        }
        .onAppear { model.reloadProjects() }
    }
}

import CoreImage
import Foundation

/// On-disk project: `<name>.screenrec/` holding `project.json` and `clips/<id>/{screen.mov,camera.mov,mic.m4a,cursor.json}`.
public struct ProjectBundle {
    public static let fileExtension = "screenrec"
    public let url: URL

    public init(url: URL) { self.url = url }

    public static var defaultDirectory: URL {
        // Override for testing against a scratch folder.
        if let dir = ProcessInfo.processInfo.environment["SCREENREC_PROJECTS_DIR"] { return URL(fileURLWithPath: dir) }
        return FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0].appendingPathComponent("Screen Recorder")
    }

    /// Creates a new empty project folder with a unique name.
    public static func create(name: String, in dir: URL = defaultDirectory) throws -> (ProjectBundle, Project) {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var candidate = dir.appendingPathComponent("\(name).\(fileExtension)")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(name) \(n).\(fileExtension)")
            n += 1
        }
        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
        let bundle = ProjectBundle(url: candidate)
        let project = Project(name: candidate.deletingPathExtension().lastPathComponent)
        try bundle.save(project)
        return (bundle, project)
    }

    public static func list(in dir: URL = defaultDirectory) -> [ProjectBundle] {
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return items.filter { $0.pathExtension == fileExtension }
            .sorted { modified($0) > modified($1) }
            .map(ProjectBundle.init)
    }

    private static func modified(_ url: URL) -> Date {
        let json = url.appendingPathComponent("project.json")
        return (try? json.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    public var projectURL: URL { url.appendingPathComponent("project.json") }

    public func load() throws -> Project {
        try JSONDecoder().decode(Project.self, from: Data(contentsOf: projectURL))
    }

    public func save(_ project: Project) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(project).write(to: projectURL, options: .atomic)
    }

    public func file(_ relative: String) -> URL { url.appendingPathComponent(relative) }

    /// Folder for a new clip; returns (absolute folder, relative prefix).
    public func makeClipFolder(id: UUID) throws -> (URL, String) {
        let rel = "clips/\(id.uuidString)"
        let dir = url.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (dir, rel)
    }

    public func loadCursorLogs(for project: Project) -> [UUID: CursorLog] {
        var logs: [UUID: CursorLog] = [:]
        for clip in project.clips {
            guard let f = clip.cursorFile, let data = try? Data(contentsOf: file(f)),
                  let log = try? JSONDecoder().decode(CursorLog.self, from: data) else { continue }
            logs[clip.id] = log
        }
        return logs
    }

    /// Decoded background image for the project's style, if it has one and the file exists.
    public func backgroundImage(for project: Project) -> CIImage? {
        guard let rel = project.style.backgroundImage else { return nil }
        return CIImage(contentsOf: file(rel))
    }

    /// Copies an image into the project (so it stays self-contained) and returns its relative path.
    public func importBackground(from source: URL) throws -> String {
        let dir = url.appendingPathComponent("backgrounds")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(source.lastPathComponent)
        if !FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.copyItem(at: source, to: dest)
        }
        return "backgrounds/\(source.lastPathComponent)"
    }

    /// Deletes files belonging to clips no longer in the project.
    public func removeOrphanedClips(keeping project: Project) {
        let keep = Set(project.clips.map(\.id.uuidString))
        let dir = url.appendingPathComponent("clips")
        for item in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where !keep.contains(item) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(item))
        }
    }
}

/// Background images shared by all projects, in ~/Library/Application Support/Screen Recorder/Backgrounds.
public enum BackgroundLibrary {
    public static var directory: URL {
        if let dir = ProcessInfo.processInfo.environment["SCREENREC_LIBRARY_DIR"] { return URL(fileURLWithPath: dir) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Screen Recorder/Backgrounds")
    }

    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "tif", "tiff", "webp"]

    public static func list() -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey])) ?? []
        return items.filter { imageExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Copies an image into the library, giving it a unique name. Returns the library copy.
    @discardableResult
    public static func add(_ source: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let base = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension
        var dest = directory.appendingPathComponent(source.lastPathComponent)
        var n = 2
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = directory.appendingPathComponent("\(base) \(n).\(ext)")
            n += 1
        }
        try FileManager.default.copyItem(at: source, to: dest)
        return dest
    }

    public static func remove(_ url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }
}

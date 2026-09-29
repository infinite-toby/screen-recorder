import AVFoundation
import Foundation

public enum ClipImporter {
    public enum Failure: LocalizedError {
        case noVideo(String)
        public var errorDescription: String? {
            switch self {
            case let .noVideo(name): "\(name) has no video track."
            }
        }
    }

    /// Copies a video into the project as a new take. Its soundtrack is extracted to an audio file that plays as
    /// "screen audio" and is also what gets transcribed.
    public static func importVideo(_ source: URL, into bundle: ProjectBundle) async throws -> Clip {
        let asset = AVURLAsset(url: source)
        guard let video = try await asset.loadTracks(withMediaType: .video).first else {
            throw Failure.noVideo(source.lastPathComponent)
        }
        let natural = try await video.load(.naturalSize)
        let transform = try await video.load(.preferredTransform)
        let shown = natural.applying(transform)
        let duration = try await asset.load(.duration).seconds

        let id = UUID()
        let (dir, rel) = try bundle.makeClipFolder(id: id)
        let name = "video." + (source.pathExtension.isEmpty ? "mov" : source.pathExtension.lowercased())
        try FileManager.default.copyItem(at: source, to: dir.appendingPathComponent(name))

        var audioRel: String?
        if try await !asset.loadTracks(withMediaType: .audio).isEmpty,
           let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) {
            let out = dir.appendingPathComponent("audio.m4a")
            try await export.export(to: out, as: .m4a)
            audioRel = "\(rel)/audio.m4a"
        }
        return Clip(id: id, screenFile: "\(rel)/\(name)", micFile: nil, duration: duration,
                    screenPixelSize: CGSize(width: abs(shown.width), height: abs(shown.height)), captureRect: .zero)
            .withScreenAudio(audioRel)
    }
}

extension Clip {
    public func withScreenAudio(_ file: String?) -> Clip {
        var c = self
        c.screenAudioFile = file
        return c
    }

    /// The audio to transcribe: the mic if there is one, otherwise the screen/imported soundtrack.
    public var speechAudioFile: String? { micFile ?? screenAudioFile }
}

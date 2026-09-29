import AVFoundation
@testable import RecorderCore
import XCTest

final class EditTests: XCTestCase {
    func twoClips() -> Project {
        var p = Project(name: "E")
        p.clips = [Clip(screenFile: "a", duration: 10, screenPixelSize: CGSize(width: 100, height: 100), captureRect: .zero),
                   Clip(screenFile: "b", duration: 5, screenPixelSize: CGSize(width: 100, height: 100), captureRect: .zero)]
        return p
    }

    func testNoCutsMatchesClipLengths() {
        let p = twoClips()
        XCTAssertEqual(p.duration, 15)
        XCTAssertEqual(p.clipStarts, [0, 10])
        XCTAssertEqual(p.editedTime(clipIndex: 1, local: 2), 12)
    }

    func testRemoveTimeAcrossClipsAndRemapBlocks() {
        var p = twoClips()
        p.cameraBlocks = [CameraBlock(start: 1, end: 3, layout: .hidden),   // before: unchanged
                          CameraBlock(start: 7, end: 13, layout: .hidden),  // spans the cut: trimmed
                          CameraBlock(start: 13, end: 14, layout: .hidden)] // after: shifted
        p.removeTime(from: 8, to: 12) // 8-10 of clip A, 0-2 of clip B
        XCTAssertEqual(p.duration, 11, accuracy: 1e-9)
        XCTAssertEqual(p.cuts.count, 2)
        XCTAssertEqual(p.clipStarts, [0, 8])
        XCTAssertNil(p.editedTime(clipIndex: 0, local: 9))
        XCTAssertEqual(p.editedTime(clipIndex: 1, local: 3)!, 9, accuracy: 1e-9)
        XCTAssertEqual(p.sourceTime(edited: 9)!.clipIndex, 1)
        XCTAssertEqual(p.cameraBlocks[0].start, 1)
        XCTAssertEqual(p.cameraBlocks[1].start, 7)
        XCTAssertEqual(p.cameraBlocks[1].end, 9, accuracy: 1e-9)
        XCTAssertEqual(p.cameraBlocks[2].start, 9, accuracy: 1e-9)
    }

    func testRestoreUndoesCut() {
        var p = twoClips()
        p.zoomBlocks = [ZoomBlock(start: 6, end: 7)]
        p.removeTime(from: 2, to: 4)
        XCTAssertEqual(p.zoomBlocks[0].start, 4, accuracy: 1e-9)
        p.restore(clipID: p.clips[0].id, from: 2, to: 4)
        XCTAssertTrue(p.cuts.isEmpty)
        XCTAssertEqual(p.duration, 15)
        XCTAssertEqual(p.zoomBlocks[0].start, 6, accuracy: 1e-9)
    }

    func testCaptionsSkipCutWordsAndMakeSRT() {
        var p = twoClips()
        let words = ["Hello", "there,", "this", "is", "a", "test.", "Cut", "me", "please", "OK", "done."]
        let t = Transcript(locale: "en", words: words.enumerated().map { i, w in Word(text: w, start: Double(i) * 0.5, end: Double(i) * 0.5 + 0.4) })
        p.removeTime(from: 3.0, to: 4.4) // "Cut me please"
        let caps = CaptionBuilder.captions(project: p, transcripts: [p.clips[0].id: t], maxCharacters: 48)
        let all = caps.map(\.text).joined(separator: " ")
        XCTAssertFalse(all.contains("Cut"))
        XCTAssertTrue(all.hasPrefix("Hello there, this is a test."))
        XCTAssertEqual(caps.first?.text, "Hello there, this is a test.")
        let srt = SRT.make(caps)
        XCTAssertTrue(srt.hasPrefix("1\n00:00:00,000 --> "))
        XCTAssertTrue(srt.contains("\n2\n"))
    }

    func testCutExportLength() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cut-\(UUID().uuidString)")
        let (bundle, empty) = try ProjectBundle.create(name: "Cut", in: dir)
        var p = empty
        let id = UUID()
        let (clipDir, rel) = try bundle.makeClipFolder(id: id)
        try await ExportTests.makeMovie(url: clipDir.appendingPathComponent("screen.mov"),
                                        image: RenderTests.fakeScreen(size: CGSize(width: 640, height: 400)), duration: 4)
        p.clips = [Clip(id: id, screenFile: "\(rel)/screen.mov", duration: 4, screenPixelSize: CGSize(width: 640, height: 400),
                        captureRect: .zero)]
        p.removeTime(from: 1, to: 2.5)
        p.export.resolution = .p1080
        p.export.fps = 30
        let out = dir.appendingPathComponent("o.mp4")
        try await Exporter.export(project: p, bundle: bundle, cursor: CursorTrack(project: p, logs: [:]), to: out, progress: { _ in })
        let d = try await AVURLAsset(url: out).load(.duration).seconds
        XCTAssertEqual(d, 2.5, accuracy: 0.1)
        try? FileManager.default.removeItem(at: dir)
    }

    /// Set MIC_SAMPLE to an audio file to try real on-device transcription.
    func testTranscribeRealAudio() async throws {
        guard let path = ProcessInfo.processInfo.environment["MIC_SAMPLE"] else { throw XCTSkip("MIC_SAMPLE not set") }
        guard #available(macOS 26.0, *) else { throw XCTSkip("needs macOS 26") }
        let start = Date()
        let t = try await Transcriber.transcribe(audio: URL(fileURLWithPath: path), locale: Locale(identifier: "en-GB"))
        print("TRANSCRIPT (\(Int(Date().timeIntervalSince(start)))s, \(t.words.count) words, \(t.locale)):")
        print(t.words.map { String(format: "%@[%.2f-%.2f]", $0.text, $0.start, $0.end) }.joined(separator: " "))
        XCTAssertFalse(t.words.isEmpty)
        for (a, b) in zip(t.words, t.words.dropFirst()) { XCTAssertLessThanOrEqual(a.start, b.start) }
    }

    /// End to end: speech -> transcript -> delete words -> export -> transcribe the export. Set SAY_TEST=1 (needs macOS 26).
    func testDeleteWordsRemovesThemFromExport() async throws {
        guard ProcessInfo.processInfo.environment["SAY_TEST"] == "1" else { throw XCTSkip("SAY_TEST not set") }
        guard #available(macOS 26.0, *) else { throw XCTSkip("needs macOS 26") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("say-\(UUID().uuidString)")
        let (bundle, empty) = try ProjectBundle.create(name: "Say", in: dir)
        var p = empty
        let id = UUID()
        let (clipDir, rel) = try bundle.makeClipFolder(id: id)
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", clipDir.appendingPathComponent("mic.m4a").path, "--data-format=aac",
                         "Welcome to the demo. This part is a mistake and should go. Here is the real content."]
        try say.run()
        say.waitUntilExit()
        let audioDur = try await AVURLAsset(url: clipDir.appendingPathComponent("mic.m4a")).load(.duration).seconds
        try await ExportTests.makeMovie(url: clipDir.appendingPathComponent("screen.mov"),
                                        image: RenderTests.fakeScreen(size: CGSize(width: 640, height: 400)), duration: audioDur)
        p.clips = [Clip(id: id, screenFile: "\(rel)/screen.mov", micFile: "\(rel)/mic.m4a", duration: audioDur,
                        screenPixelSize: CGSize(width: 640, height: 400), captureRect: .zero)]
        let t = try await Transcriber.transcribe(audio: clipDir.appendingPathComponent("mic.m4a"), locale: Locale(identifier: "en-GB"))
        let texts = t.words.map { $0.text.lowercased().trimmingCharacters(in: .punctuationCharacters) }
        let first = try XCTUnwrap(texts.firstIndex(of: "this")), last = try XCTUnwrap(texts.firstIndex(of: "go"))
        p.removeWords(clipIndex: 0, words: t.words, first: first, last: last)
        XCTAssertLessThan(p.duration, audioDur - 1.5)

        p.export.resolution = .p1080
        p.export.fps = 30
        let out = dir.appendingPathComponent("o.mov")
        try await Exporter.export(project: p, bundle: bundle, cursor: CursorTrack(project: p, logs: [:]), to: out, progress: { _ in })
        let after = try await Transcriber.transcribe(audio: out, locale: Locale(identifier: "en-GB"))
        let heard = after.words.map(\.text).joined(separator: " ").lowercased()
        print("BEFORE: \(t.words.map(\.text).joined(separator: " "))\nAFTER:  \(heard)")
        XCTAssertFalse(heard.contains("mistake"))
        XCTAssertTrue(heard.contains("welcome"))
        XCTAssertTrue(heard.contains("real content"))
        try? FileManager.default.removeItem(at: dir)
    }
}

final class AudioCheckTests: XCTestCase {
    func testDetectsSilenceAndSound() throws {
        let fmt = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        func write(_ amp: Float) throws -> URL {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("a-\(UUID().uuidString).caf")
            let f = try AVAudioFile(forWriting: url, settings: fmt.settings)
            let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 48000)!
            b.frameLength = 48000
            for i in 0 ..< 48000 { b.floatChannelData![0][i] = amp * Float(sin(Double(i) * 0.05)) }
            try f.write(from: b)
            return url
        }
        XCTAssertTrue(AudioCheck.isSilent(try write(0)))
        XCTAssertFalse(AudioCheck.isSilent(try write(0.05)))
    }
}

final class SplitAndSubtitleEditTests: XCTestCase {
    func clip(_ d: Double) -> Clip { Clip(screenFile: "s", duration: d, screenPixelSize: CGSize(width: 10, height: 10), captureRect: .zero) }

    func testSplitTrimDelete() {
        var p = Project(name: "S")
        p.clips = [clip(10)]
        p.split(at: 4)
        XCTAssertEqual(p.segments.count, 2)
        XCTAssertEqual(p.duration, 10)
        // Trim 1s off the start of the second section and 2s off its end.
        let second = p.segments[1]
        p.trim(segment: second, newStart: 5, newEnd: 8)
        XCTAssertEqual(p.duration, 7, accuracy: 1e-9)
        XCTAssertEqual(p.segments.map(\.sourceStart), [0, 5])
        // Extend it back out again.
        p.trim(segment: p.segments[1], newEnd: 10)
        XCTAssertEqual(p.duration, 9, accuracy: 1e-9)
        p.delete(segment: p.segments[0])
        XCTAssertEqual(p.duration, 5, accuracy: 1e-9)
    }

    func testSubtitleEditDiff() {
        let words = ["So", "this", "is", "teh", "dashboard"].enumerated().map { Word(text: $1, start: Double($0), end: Double($0) + 0.5) }
        let fixed = SubtitleEdit.apply("So this is the dashboard", to: words)
        XCTAssertEqual(fixed.map(\.text), ["So", "this", "is", "the", "dashboard"])
        XCTAssertEqual(fixed[4].start, 4)
        let deleted = SubtitleEdit.apply("So this dashboard", to: words)
        XCTAssertEqual(deleted.filter { $0.hidden != true }.map(\.text), ["So", "this", "dashboard"])
        let added = SubtitleEdit.apply("So this is teh new dashboard", to: words)
        XCTAssertEqual(added.map(\.text), ["So", "this", "is", "teh new", "dashboard"])
        XCTAssertEqual(SubtitleEdit.apply("", to: words).filter { $0.hidden != true }.count, 0)
    }
}

final class ImportTests: XCTestCase {
    func testImportVideoWithSound() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("imp-\(UUID().uuidString)")
        let (bundle, _) = try ProjectBundle.create(name: "I", in: dir)
        // A clip with picture and sound: fake screen video + `say` audio, merged.
        let video = dir.appendingPathComponent("v.mov"), audio = dir.appendingPathComponent("a.m4a")
        try await ExportTests.makeMovie(url: video, image: RenderTests.fakeScreen(size: CGSize(width: 640, height: 400)), duration: 2)
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", audio.path, "--data-format=aac", "Imported clip"]
        try say.run()
        say.waitUntilExit()
        let comp = AVMutableComposition()
        let va = AVURLAsset(url: video), aa = AVURLAsset(url: audio) // tracks don't retain their assets
        let v = try await va.loadTracks(withMediaType: .video).first!
        let a = try await aa.loadTracks(withMediaType: .audio).first!
        try comp.addMutableTrack(withMediaType: .video, preferredTrackID: 0)!.insertTimeRange(try await v.load(.timeRange), of: v, at: .zero)
        try comp.addMutableTrack(withMediaType: .audio, preferredTrackID: 0)!.insertTimeRange(try await a.load(.timeRange), of: a, at: .zero)
        let merged = dir.appendingPathComponent("in.mov")
        try await AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetPassthrough)!.export(to: merged, as: .mov)
        withExtendedLifetime((va, aa)) {}

        let clip = try await ClipImporter.importVideo(merged, into: bundle)
        XCTAssertEqual(clip.screenPixelSize, CGSize(width: 1280, height: 800)) // the fake screen renders at 2x
        XCTAssertNotNil(clip.screenAudioFile)
        XCTAssertEqual(clip.speechAudioFile, clip.screenAudioFile)
        XCTAssertFalse(AudioCheck.isSilent(bundle.file(clip.screenAudioFile!)))
        try? FileManager.default.removeItem(at: dir)
    }
}

final class CaptionMergeTests: XCTestCase {
    func testNoLonelyLastWord() {
        var p = Project(name: "M")
        p.clips = [Clip(screenFile: "s", duration: 20, screenPixelSize: CGSize(width: 10, height: 10), captureRect: .zero)]
        let words = "This is the dashboard, where you can see every project.".split(separator: " ").enumerated()
            .map { Word(text: String($1), start: Double($0) * 0.3, end: Double($0) * 0.3 + 0.25) }
        let caps = CaptionBuilder.captions(project: p, transcripts: [p.clips[0].id: Transcript(locale: "en", words: words)], maxCharacters: 48)
        XCTAssertEqual(caps.map(\.text), ["This is the dashboard, where you can see every project."])
    }
}

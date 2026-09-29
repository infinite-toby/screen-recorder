import CoreGraphics
import Foundation
@testable import RecorderCore
import XCTest

final class SceneTests: XCTestCase {
    let out = CGSize(width: 1920, height: 1080)

    func project(duration: Double = 20, content: CGSize = CGSize(width: 3840, height: 2160)) -> Project {
        var p = Project(name: "Test")
        p.clips = [Clip(screenFile: "s.mov", duration: duration, screenPixelSize: content,
                        captureRect: CGRect(x: 0, y: 0, width: 1920, height: 1080))]
        return p
    }

    func testCornerLayoutsStayInsideFrame() {
        for aspect in OutputAspect.allCases {
            let size = aspect.size(shortSide: 1080)
            for c in Corner.allCases { for s in CameraShape.allCases { for z in CameraSize.allCases {
                let st = CameraLayoutResolver.state(for: .corner(c, s, z), output: size, style: FrameStyle())
                XCTAssertTrue(CGRect(origin: .zero, size: size).contains(st.rect), "\(aspect) \(c) \(s) \(z)")
            } } }
        }
    }

    func testCameraTransitionIsContinuousAndSettles() {
        var p = project()
        p.defaultCamera = .corner(.bottomRight, .square, .small)
        p.cameraBlocks = [CameraBlock(start: 5, end: 10, layout: .centre(coverage: 0.7))]
        let scene = RenderScene(project: p, output: out, cursor: CursorTrack(project: p, logs: [:]))
        let before = scene.cameraState(at: 4.99)
        let atStart = scene.cameraState(at: 5.0)
        XCTAssertEqual(before.rect.minX, atStart.rect.minX, accuracy: 0.5)
        let settled = scene.cameraState(at: 7)
        XCTAssertEqual(settled, CameraLayoutResolver.state(for: .centre(coverage: 0.7), output: out, style: p.style))
        // Midway through the transition it's somewhere in between.
        let mid = scene.cameraState(at: 5.3)
        XCTAssertTrue(mid.rect.width > before.rect.width && mid.rect.width < settled.rect.width)
    }

    func testHiddenFadesOut() {
        var p = project()
        p.cameraBlocks = [CameraBlock(start: 5, end: 10, layout: .hidden)]
        let scene = RenderScene(project: p, output: out, cursor: CursorTrack(project: p, logs: [:]))
        XCTAssertEqual(scene.cameraState(at: 4.9).opacity, 1)
        let mid = scene.cameraState(at: 5.3).opacity
        XCTAssertTrue(mid > 0 && mid < 1)
        XCTAssertTrue(scene.cameraState(at: 6).isHidden)
        XCTAssertEqual(scene.cameraState(at: 11).opacity, 1)
    }

    func testShortBlockChainHasNoJump() {
        var p = project()
        p.cameraBlocks = [
            CameraBlock(start: 5, end: 5.2, layout: .corner(.topLeft, .square, .large)),
            CameraBlock(start: 5.2, end: 9, layout: .corner(.topRight, .landscape, .small)),
        ]
        let scene = RenderScene(project: p, output: out, cursor: CursorTrack(project: p, logs: [:]))
        // Continuous across both block boundaries, even though the first block ends mid-transition.
        for boundary in [5.0, 5.2] {
            let a = scene.cameraState(at: boundary - 1e-4).rect, b = scene.cameraState(at: boundary + 1e-4).rect
            XCTAssertLessThan(abs(a.minX - b.minX) + abs(a.minY - b.minY) + abs(a.width - b.width), 2, "jump at \(boundary)")
        }
    }

    func testZoomViewStaysInsideContentAndHasOutputAspect() {
        var p = project()
        p.zoomBlocks = [ZoomBlock(start: 2, end: 6, scale: 2.5, focus: CGPoint(x: 0.98, y: 0.02))]
        let scene = RenderScene(project: p, output: out, cursor: CursorTrack(project: p, logs: [:]))
        XCTAssertEqual(scene.view(at: 1), CGRect(origin: .zero, size: out))
        let v = scene.view(at: 4)
        let g = scene.geometry(at: 4)
        XCTAssertTrue(g.contentRect.insetBy(dx: -0.01, dy: -0.01).contains(v))
        XCTAssertEqual(v.width / v.height, 16.0 / 9.0, accuracy: 0.001)
        XCTAssertEqual(v.width, g.fullBleedSize.width / 2.5, accuracy: 0.01)
        // Back out after the block.
        XCTAssertEqual(scene.view(at: 8), CGRect(origin: .zero, size: out))
        XCTAssertNotEqual(scene.view(at: 6.5), CGRect(origin: .zero, size: out))
    }

    func testMotionBlurOnlyWhileMoving() {
        var p = project()
        p.zoomBlocks = [ZoomBlock(start: 2, end: 6, scale: 2)]
        let scene = RenderScene(project: p, output: out, cursor: CursorTrack(project: p, logs: [:]))
        XCTAssertEqual(scene.viewSamples(at: 1).count, 1)
        XCTAssertGreaterThan(scene.viewSamples(at: 2.4).count, 2)
        XCTAssertEqual(scene.viewSamples(at: 4).count, 1)
    }

    func testPortraitFollowsCursor() {
        let p = project()
        let log = CursorLog(samples: (0 ... 200).map { i in
            CursorLog.Sample(t: Double(i) * 0.1, x: i < 100 ? 0.1 : 0.9, y: 0.5)
        })
        let track = CursorTrack(project: p, logs: [p.clips[0].id: log])
        let portrait = OutputAspect.portrait9x16.size(shortSide: 1080)
        let scene = RenderScene(project: p, output: portrait, cursor: track)
        XCTAssertTrue(scene.geometry(at: 0).followsCursor)
        let left = scene.view(at: 3).midX, right = scene.view(at: 17).midX
        XCTAssertLessThan(left, right)
        // Smoothed: the raw cursor teleports ~760px at t=10; the crop moves a small fraction of that per frame.
        XCTAssertLessThan(abs(scene.view(at: 10.0).midX - scene.view(at: 10.034).midX), 60)
    }

    func testUltrawideFitsInLandscape() {
        let g = ScreenGeometry(contentSize: CGSize(width: 3440, height: 1440), output: out, style: FrameStyle())
        XCTAssertFalse(g.followsCursor)
    }

    func testAutoZoomClustersClicks() {
        let clicks: [(t: Double, point: CGPoint)] = [
            (3, CGPoint(x: 0.2, y: 0.2)), (4, CGPoint(x: 0.22, y: 0.25)), (5.5, CGPoint(x: 0.25, y: 0.2)),
            (15, CGPoint(x: 0.8, y: 0.8)),
            // Far away and too soon after the previous zoom to get its own: dropped.
            (15.5, CGPoint(x: 0.1, y: 0.9)),
            (25, CGPoint(x: 0.5, y: 0.5)),
        ]
        let blocks = AutoZoom.suggest(clicks: clicks, duration: 30)
        XCTAssertEqual(blocks.count, 3)
        XCTAssertEqual(blocks[1].focus.x, 0.8, accuracy: 0.001)
        XCTAssertEqual(blocks[0].start, 2.2, accuracy: 0.001)
        XCTAssertEqual(blocks[0].end, 7.3, accuracy: 0.001)
        XCTAssertEqual(blocks[0].focus.x, 0.2233, accuracy: 0.001)
        XCTAssertTrue(blocks.allSatisfy(\.isAuto))
        for (a, b) in zip(blocks, blocks.dropFirst()) { XCTAssertLessThanOrEqual(a.end, b.start) }
    }

    func testProjectRoundTrips() throws {
        var p = project()
        p.cameraBlocks = [CameraBlock(start: 1, end: 2, layout: .centre(coverage: 0.6)),
                          CameraBlock(start: 3, end: 4, layout: .corner(.topLeft, .portrait, .large))]
        p.zoomBlocks = [ZoomBlock(start: 1, end: 3)]
        let data = try JSONEncoder().encode(p)
        XCTAssertEqual(try JSONDecoder().decode(Project.self, from: data), p)
    }

    func testStyleDecodesWithMissingKeys() throws {
        let style = try JSONDecoder().decode(FrameStyle.self, from: Data(#"{"padding": 0.1}"#.utf8))
        XCTAssertEqual(style.padding, 0.1)
        XCTAssertEqual(style.zoomTransitionDuration, FrameStyle().zoomTransitionDuration)
    }
}

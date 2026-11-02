import XCTest

/// Panes turn to any whole-degree angle with two fingers. The picture's box grows to hold the
/// turned window, input maps back through the exact inverse, the box's empty corners take no
/// input, and a twist keeps the window point under the fingers.
final class WorkspaceFreeRotationTests: XCTestCase {
    private let tile = WorkspaceRect(x: 0, y: 0, width: 1000, height: 1000)
    private let source = WorkspaceSize(width: 800, height: 400)

    func testAnglesWrapRoundAndStepToTheNextRightAngle() {
        XCTAssertEqual(WorkspaceRotation(degrees: 370).rawValue, 10)
        XCTAssertEqual(WorkspaceRotation(degrees: -30).rawValue, 330)
        XCTAssertEqual(WorkspaceRotation(degrees: 44.6).rawValue, 45)
        XCTAssertEqual(WorkspaceRotation(degrees: Double.nan), .none)
        XCTAssertEqual(WorkspaceRotation(degrees: 37).clockwise, .quarter, "the menu's Rotate: the next right angle")
        XCTAssertEqual(WorkspaceRotation(degrees: 270).clockwise, .none)
        XCTAssertEqual(WorkspaceRotation.none.turned(by: 4, snap: true), .none, "near a right angle: lands on it")
        XCTAssertEqual(WorkspaceRotation.none.turned(by: 4, snap: false).rawValue, 4)
        XCTAssertEqual(WorkspaceRotation.quarter.turned(by: -97, snap: true).rawValue, 353)
        XCTAssertEqual(WorkspaceRotation(degrees: 80).turned(by: 7, snap: true), .quarter)
    }

    func testSavedAndWireValuesStayWholeNumbers() throws {
        let data = try JSONEncoder().encode(WorkspaceTabView(rotation: WorkspaceRotation(degrees: 33)))
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"rotation\":33"))
        XCTAssertEqual(try JSONDecoder().decode(WorkspaceTabView.self, from: data).rotation.rawValue, 33)
        let old = Data(#"{"rotation":90,"fit":"fit"}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(WorkspaceTabView.self, from: old).rotation, .quarter, "old saved layouts")
    }

    func testAnAngledPaneMapsBothWaysAndItsEmptyCornersTakeNoInput() throws {
        let t = TileContentTransform(tile: tile, source: source, rotation: WorkspaceRotation(degrees: 30), fit: .fit)
        let box = t.rotatedSourceSize
        XCTAssertEqual(box.width, 800 * cos(.pi / 6) + 400 * sin(.pi / 6), accuracy: 1e-9)
        XCTAssertEqual(box.height, 800 * sin(.pi / 6) + 400 * cos(.pi / 6), accuracy: 1e-9)
        XCTAssertEqual(t.scale, 1000 / box.width, accuracy: 1e-9, "Fit holds the whole turned window")
        for p in [WorkspacePoint(x: 1, y: 1), WorkspacePoint(x: 799, y: 1), WorkspacePoint(x: 123, y: 321), WorkspacePoint(x: 400, y: 200)] {
            let q = t.canvasPoint(fromSource: p)
            let back = try XCTUnwrap(t.sourcePoint(fromCanvas: q), "\(p)")
            XCTAssertEqual(back.x, p.x, accuracy: 1e-6)
            XCTAssertEqual(back.y, p.y, accuracy: 1e-6)
        }
        let c = t.contentRect
        XCTAssertNil(t.sourcePoint(fromCanvas: WorkspacePoint(x: c.x + 1, y: c.y + 1)), "the box's corner shows no window")
        let nearest = try XCTUnwrap(t.clampedSourcePoint(fromCanvas: WorkspacePoint(x: c.x + 1, y: c.y + 1)))
        XCTAssertTrue((0...800).contains(nearest.x) && (0...400).contains(nearest.y), "a bound drag still lands in the window")
        // A canvas swipe along the turned window's own x axis is pure x on the Mac.
        let v = t.sourceVector(fromCanvas: WorkspacePoint(x: cos(.pi / 6) * 10, y: sin(.pi / 6) * 10))
        XCTAssertEqual(v.y, 0, accuracy: 1e-9)
        XCTAssertGreaterThan(v.x, 0)
    }

    func testRightAnglesAreUnchanged() {
        let t = TileContentTransform(tile: tile, source: source, rotation: .quarter, fit: .fit)
        XCTAssertEqual(t.rotatedSourceSize, WorkspaceSize(width: 400, height: 800))
        XCTAssertEqual(t.rotated(WorkspacePoint(x: 10, y: 20)), WorkspacePoint(x: 380, y: 10))
        XCTAssertEqual(t.unrotated(WorkspacePoint(x: 380, y: 10)), WorkspacePoint(x: 10, y: 20))
    }

    /// The window point under the fingers stays under them while they twist and spread, and the
    /// picture's size follows the spread only (turning alone never shrinks it).
    func testATwistKeepsTheWindowPointUnderTheFingers() throws {
        let size = WorkspaceSize(width: 1000, height: 1000)
        let from = WorkspacePoint(x: 0.3, y: 0.6), to = WorkspacePoint(x: 0.45, y: 0.4)
        let t0 = TileContentTransform(tile: tile, source: source, rotation: .none, fit: .fit)
        let anchor = try XCTUnwrap(t0.unclampedSourcePoint(fromCanvas: WorkspacePoint(x: 300, y: 600)))
        let view = WorkspaceZoom.turned(nil, rotation: .none, by: 37, snap: true, tile: size, source: source, fit: .fit,
                                        ratio: 1.5, from: from, to: to)
        XCTAssertEqual(view.rotation.rawValue, 37)
        let t1 = TileContentTransform(tile: tile, source: source, rotation: view.rotation, fit: .fit, zoom: try XCTUnwrap(view.zoom))
        let q = t1.canvasPoint(fromSource: anchor)
        XCTAssertEqual(q.x, 450, accuracy: 1e-6)
        XCTAssertEqual(q.y, 400, accuracy: 1e-6)
        XCTAssertEqual(t1.scale, t0.scale * 1.5, accuracy: 1e-9, "size from the spread alone")
        // No twist: the same as a plain pinch.
        let plain = WorkspaceZoom.turned(nil, rotation: .none, by: 0, snap: true, tile: size, source: source, fit: .fit,
                                         ratio: 1.5, from: from, to: to)
        let pinched = try XCTUnwrap(WorkspaceZoom.pinched(nil, tile: size, source: source, rotation: .none, fit: .fit,
                                                          ratio: 1.5, from: from, to: to))
        let z = try XCTUnwrap(plain.zoom)
        XCTAssertEqual(z.scale, pinched.scale, accuracy: 1e-9)
        XCTAssertEqual(z.centerX, pinched.centerX, accuracy: 1e-9)
        XCTAssertEqual(z.centerY, pinched.centerY, accuracy: 1e-9)
    }

    /// The instant preview moves the picture the fingers had by the same turn the Mac will draw.
    func testThePreviewTurnsThePictureLikeTheMacWill() throws {
        let canvas = WorkspaceSize(width: 2000, height: 1000)
        let pane = WorkspaceRect(x: 0, y: 0, width: 1000, height: 1000)
        let t0 = TileContentTransform(tile: pane, source: source, rotation: .none, fit: .fit)
        let t1 = TileContentTransform(tile: pane, source: source, rotation: WorkspaceRotation(degrees: 50), fit: .fit,
                                      zoom: WorkspacePaneZoom(scale: 2, centerX: 0.4, centerY: 0.55))
        let p = try XCTUnwrap(WorkspaceZoomPreview(tile: "a", pane: WorkspaceRect(x: 0, y: 0, width: 0.5, height: 1),
                                                   start: t0, now: t1, canvas: canvas))
        for s in [WorkspacePoint(x: 100, y: 50), WorkspacePoint(x: 700, y: 390)] {
            let a = t0.canvasPoint(fromSource: s), b = t1.canvasPoint(fromSource: s)
            let moved = p.apply(WorkspacePoint(x: a.x / 2000, y: a.y / 1000))
            XCTAssertEqual(moved.x, b.x / 2000, accuracy: 1e-9)
            XCTAssertEqual(moved.y, b.y / 1000, accuracy: 1e-9)
        }
        XCTAssertNotEqual(p.shearB, 0, "a turn has shear terms")
        // Only the window's own outline moves (not the empty corners of its box).
        let corner = t0.canvasPoint(fromSource: WorkspacePoint(x: 800, y: 400))
        XCTAssertEqual(p.fromQuad?.count, 4)
        XCTAssertEqual(p.fromQuad?[2].x ?? 0, corner.x / 2000, accuracy: 1e-12)
        XCTAssertEqual(p.fromQuad?[2].y ?? 0, corner.y / 1000, accuracy: 1e-12)
        XCTAssertEqual(p.rotation.rawValue, 50)
    }
}

import XCTest

/// Free-canvas panning in a pane: any edge or corner of the source can be brought to the pane's
/// centre and left there, at every zoom, without snapping back; touches on the empty canvas
/// send nothing; the source can never be lost. Shared with Android through the workspace vectors.
final class WorkspaceFreePanTests: XCTestCase {
    private let pane = WorkspaceRect(x: 0, y: 0, width: 400, height: 300)
    private let window = WorkspaceSize(width: 1600, height: 1000)

    private func transform(_ zoom: WorkspacePaneZoom, rotation: WorkspaceRotation = .none, tile: WorkspaceRect? = nil,
                           fit: WorkspaceFit = .fit) -> TileContentTransform {
        TileContentTransform(tile: tile ?? pane, source: window, rotation: rotation, fit: fit, zoom: zoom)
    }

    /// A one-finger-pair pan from the pane's centre by `d` (pane-normalized), starting at `start`.
    private func pan(_ start: WorkspacePaneZoom?, by d: (Double, Double), rotation: WorkspaceRotation = .none) -> WorkspacePaneZoom {
        WorkspaceZoom.pinched(start, tile: WorkspaceSize(width: pane.width, height: pane.height), source: window, rotation: rotation,
                              fit: .fit, ratio: 1, from: WorkspacePoint(x: 0.5, y: 0.5),
                              to: WorkspacePoint(x: 0.5 + d.0, y: 0.5 + d.1)) ?? .identity
    }

    func testEveryEdgeAndCornerReachesThePaneCentreAtEveryZoom() {
        for scale in [1.0, 3.0, 8.0] {
            let start = WorkspacePaneZoom(scale: scale, centerX: 0.5, centerY: 0.5)
            // Drag far in each direction: the opposite edge or corner stops at the centre.
            let cases: [((Double, Double), (Double, Double))] = [
                ((20, 0), (0, 0.5)), ((-20, 0), (1, 0.5)), ((0, 20), (0.5, 0)), ((0, -20), (0.5, 1)),
                ((20, 20), (0, 0)), ((-20, 20), (1, 0)), ((20, -20), (0, 1)), ((-20, -20), (1, 1)),
            ]
            for (drag, corner) in cases {
                let z = pan(start, by: drag)
                XCTAssertEqual(z.scale, scale, accuracy: 1e-9)
                XCTAssertEqual(z.centerX, corner.0, accuracy: 1e-9, "\(scale)x drag \(drag)")
                XCTAssertEqual(z.centerY, corner.1, accuracy: 1e-9, "\(scale)x drag \(drag)")
                let c = transform(z).contentRect
                // That source point is drawn exactly at the pane's centre.
                XCTAssertEqual(c.x + corner.0 * c.width, pane.midX, accuracy: 1e-6)
                XCTAssertEqual(c.y + corner.1 * c.height, pane.midY, accuracy: 1e-6)
            }
        }
    }

    func testAContinuousDiagonalPanMovesSmoothlyAndReversesWithoutSnapping() {
        let start = WorkspacePaneZoom(scale: 3, centerX: 0.5, centerY: 0.5)
        var previous = start
        for k in 1...40 {
            let z = pan(start, by: (Double(k) * 0.05, Double(k) * 0.05))
            XCTAssertLessThanOrEqual(z.centerX, previous.centerX + 1e-12, "moves one way only")
            XCTAssertLessThanOrEqual(abs(z.centerX - previous.centerX), 0.05, "no jumps")
            previous = z
        }
        XCTAssertEqual(previous.centerX, 0, accuracy: 1e-9)
        XCTAssertEqual(previous.centerY, 0, accuracy: 1e-9)
        // A new gesture from there, back half way: it moves back from the corner, no snap.
        let back = pan(previous, by: (-0.25, -0.25))
        XCTAssertGreaterThan(back.centerX, 0)
        XCTAssertLessThan(back.centerX, 0.5)
        XCTAssertGreaterThan(back.centerY, 0)
        XCTAssertLessThan(back.centerY, 0.5)
    }

    func testThePanIsKeptUntilResetAndAResetIsTheDefaultView() {
        let z = pan(WorkspacePaneZoom(scale: 3, centerX: 0.5, centerY: 0.5), by: (20, 20))
        var layout = WorkspaceLayout(preset: .single, tiles: [WorkspaceTile(id: "a", source: WorkspaceSource(host: "m", windowID: 7))])
        let id = "a"
        layout = layout.zooming(id, to: z)
        XCTAssertEqual(layout.tiles[id]?.zoom, z, "kept as set: nothing recentres it")
        layout = layout.zooming(id, to: nil)   // two-finger double-tap
        XCTAssertNil(layout.tiles[id]?.zoom)
        XCTAssertTrue(transform(.identity).effectiveZoom.isIdentity)
    }

    func testInputMapsThroughThePanAndTheEmptyCanvasSendsNothing() {
        let z = WorkspacePaneZoom(scale: 3, centerX: 0, centerY: 0)   // top-left corner at the centre
        let t = transform(z)
        // The empty quadrants (left of or above the source) send nothing.
        XCTAssertNil(t.sourcePoint(fromCanvas: WorkspacePoint(x: pane.midX - 20, y: pane.midY + 20)))
        XCTAssertNil(t.sourcePoint(fromCanvas: WorkspacePoint(x: pane.midX + 20, y: pane.midY - 20)))
        XCTAssertNil(t.sourcePoint(fromCanvas: WorkspacePoint(x: 10, y: 10)))
        // Just inside the corner maps near the window's origin, and back again.
        let p = t.sourcePoint(fromCanvas: WorkspacePoint(x: pane.midX + 3, y: pane.midY + 3))!
        XCTAssertEqual(p.x, 3 / t.scale, accuracy: 1e-6)
        XCTAssertEqual(p.y, 3 / t.scale, accuracy: 1e-6)
        let q = t.canvasPoint(fromSource: p)
        XCTAssertEqual(q.x, pane.midX + 3, accuracy: 1e-6)
        XCTAssertEqual(q.y, pane.midY + 3, accuracy: 1e-6)
    }

    func testRotatedAndResizedPanesKeepTheChosenPoint() {
        for rotation in [WorkspaceRotation.none, .quarter, .half, .threeQuarter] {
            let z = pan(WorkspacePaneZoom(scale: 3, centerX: 0.5, centerY: 0.5), by: (20, 0), rotation: rotation)
            let c = transform(z, rotation: rotation).contentRect
            XCTAssertEqual(c.x, pane.midX, accuracy: 1e-6, "\(rotation): the drawn left edge reaches the centre")
            // A divider resize keeps the same source point at the new pane's centre.
            let wider = WorkspaceRect(x: 0, y: 0, width: 620, height: 300)
            XCTAssertEqual(transform(z, rotation: rotation, tile: wider).contentRect.x, wider.midX, accuracy: 1e-6)
        }
    }

    func testTheSourceCanNeverBeLost() {
        for cx in stride(from: -4.0, through: 5.0, by: 0.5) {
            for cy in stride(from: -4.0, through: 5.0, by: 0.5) {
                for scale in [0.7, 1, 8] {
                    for fit in [WorkspaceFit.fit, .fill] {
                        let c = transform(WorkspacePaneZoom(scale: scale, centerX: cx, centerY: cy), fit: fit).contentRect
                        XCTAssertTrue(c.x <= pane.midX + 1e-9 && c.maxX >= pane.midX - 1e-9 && c.y <= pane.midY + 1e-9 && c.maxY >= pane.midY - 1e-9,
                                      "the source covers the pane's centre (\(cx), \(cy), \(scale)x, \(fit))")
                    }
                }
            }
        }
    }
}

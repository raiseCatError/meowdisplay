import CoreGraphics
import XCTest

/// Caret-following Zoom While Typing: the Mac's text caret (normalized, both
/// axes) steers the keyboard-open viewport in place of the last touch, with
/// the touch as the fallback and no panning while the caret stays in the
/// comfortable inner region. The shared vectors in
/// fixtures/viewport/caret-vectors.json are checked by the Kotlin port too.
final class RemoteViewportCaretTests: XCTestCase {
    private let phone = CGRect(x: 0, y: 0, width: 390, height: 844)
    /// Keyboard plus the typing strip cover the bottom 400 points.
    private let visible = CGRect(x: 0, y: 0, width: 390, height: 444)
    private let wide = CGSize(width: 1920, height: 1080)
    private let tall = CGSize(width: 1000, height: 1600)

    private func caret(_ x: CGFloat, _ y: CGFloat) -> CGRect {
        CGRect(x: x, y: y, width: 0.002, height: 0.02)
    }

    private func open(remote: CGSize, zoom: Bool, anchor: CGPoint? = nil, caret: CGRect?, previous: CGRect? = nil,
                      view: CGRect? = nil, visible: CGRect? = nil) -> RemoteViewportTransform {
        RemoteViewportCalculator.keyboardOpen(
            viewBounds: view ?? phone, remoteAspectSize: remote, visibleRect: visible ?? self.visible,
            anchor: anchor, zoomEnabled: zoom, caret: caret, previous: previous)
    }

    /// Where the caret's centre lands in the host view.
    private func caretPosition(_ t: RemoteViewportTransform, _ c: CGRect) -> CGPoint {
        t.viewPoint(forRemote: CGPoint(x: c.midX, y: c.midY))
    }

    // MARK: - The caret stays visible above the keyboard

    func testCaretSitsInTheVisibleAreaAcrossTheDisplayWithZoomOnAndOff() {
        for remote in [wide, tall] {
            for zoom in [true, false] {
                for x in stride(from: 0.02, through: 0.98, by: 0.16) {
                    for y in stride(from: 0.04, through: 0.96, by: 0.16) {
                        let c = caret(CGFloat(x), CGFloat(y))
                        let t = open(remote: remote, zoom: zoom, caret: c)
                        let p = caretPosition(t, c)
                        XCTAssertGreaterThanOrEqual(p.y, visible.minY, "\(remote) zoom=\(zoom) caret=(\(x),\(y))")
                        XCTAssertLessThanOrEqual(p.y, visible.maxY, "\(remote) zoom=\(zoom) caret=(\(x),\(y))")
                        XCTAssertGreaterThanOrEqual(p.x, visible.minX, "\(remote) zoom=\(zoom) caret=(\(x),\(y))")
                        XCTAssertLessThanOrEqual(p.x, visible.maxX, "\(remote) zoom=\(zoom) caret=(\(x),\(y))")
                    }
                }
            }
        }
    }

    func testMagnifiedViewFollowsTheCaretHorizontally() {
        let left = open(remote: wide, zoom: true, caret: caret(0.04, 0.5))
        let right = open(remote: wide, zoom: true, caret: caret(0.95, 0.5))
        XCTAssertGreaterThan(left.displayedRect.width, phone.width, "zoom on magnifies past the view width")
        XCTAssertGreaterThan(left.displayedRect.minX, right.displayedRect.minX,
                             "a caret at the right edge pans the picture further left")
        // Neither pan opens blank space beyond the picture's edges.
        for t in [left, right] {
            XCTAssertLessThanOrEqual(t.displayedRect.minX, visible.minX + 0.001)
            XCTAssertGreaterThanOrEqual(t.displayedRect.maxX, visible.maxX - 0.001)
        }
    }

    func testZoomOffNeverMovesHorizontallyBecauseThePictureAlreadyFitsAcross() {
        let normal = RemoteViewportCalculator.normal(viewBounds: phone, remoteAspectSize: wide)
        for x in [0.02, 0.5, 0.98] {
            let t = open(remote: wide, zoom: false, caret: caret(CGFloat(x), 0.5))
            XCTAssertEqual(t.displayedRect.minX, normal.displayedRect.minX, accuracy: 0.001)
            XCTAssertEqual(t.displayedRect.width, normal.displayedRect.width, accuracy: 0.001)
        }
    }

    func testZoomOnIsNeverSmallerThanZoomOff() {
        for y in stride(from: 0.04, through: 0.96, by: 0.12) {
            let c = caret(0.5, CGFloat(y))
            let on = open(remote: tall, zoom: true, caret: c)
            let off = open(remote: tall, zoom: false, caret: c)
            XCTAssertGreaterThanOrEqual(on.displayedRect.width, off.displayedRect.width - 0.001, "y=\(y)")
        }
    }

    // MARK: - Fallback to the touch

    func testNoCaretBehavesExactlyAsTheTouchAnchorDid() {
        let anchor = CGPoint(x: 0.2, y: 0.9)
        let legacy = RemoteViewportCalculator.keyboardOpen(
            viewBounds: phone, remoteAspectSize: tall, visibleRect: visible, anchor: anchor, zoomEnabled: true)
        XCTAssertEqual(open(remote: tall, zoom: true, anchor: anchor, caret: nil), legacy)
        // A caret that cannot steer (off the display, not finite) is the same as none.
        XCTAssertEqual(open(remote: tall, zoom: true, anchor: anchor, caret: caret(1.4, 0.5)), legacy)
        XCTAssertEqual(open(remote: tall, zoom: true, anchor: anchor, caret: caret(0.5, -0.3)), legacy)
        XCTAssertEqual(open(remote: tall, zoom: true, anchor: anchor,
                            caret: CGRect(x: CGFloat.nan, y: 0.5, width: 0, height: 0)), legacy)
        XCTAssertEqual(open(remote: tall, zoom: true, anchor: anchor, caret: .null), legacy)
    }

    func testTheCaretWinsOverTheTouchAnchor() {
        let withBoth = open(remote: tall, zoom: true, anchor: CGPoint(x: 0.2, y: 0.1), caret: caret(0.8, 0.9))
        let caretOnly = open(remote: tall, zoom: true, anchor: nil, caret: caret(0.8, 0.9))
        XCTAssertEqual(withBoth, caretOnly)
        let touchOnly = open(remote: tall, zoom: true, anchor: CGPoint(x: 0.2, y: 0.1), caret: nil)
        XCTAssertNotEqual(withBoth, touchOnly)
    }

    // MARK: - No jitter inside the comfort region

    func testASmallCaretMoveInsideTheInnerRegionDoesNotMoveThePicture() {
        let first = open(remote: tall, zoom: true, caret: caret(0.40, 0.50))
        var previous = first.displayedRect
        // Typing along the line: every step stays inside the inner region.
        for step in 1...6 {
            let c = caret(0.40 + 0.004 * CGFloat(step), 0.50)
            let t = open(remote: tall, zoom: true, caret: c, previous: previous)
            XCTAssertEqual(t.displayedRect, first.displayedRect, "step \(step) must not pan")
            previous = t.displayedRect
        }
    }

    func testLeavingTheInnerRegionRecentersOnTheCaret() {
        let first = open(remote: tall, zoom: true, caret: caret(0.40, 0.50))
        let far = caret(0.9, 0.9)
        let moved = open(remote: tall, zoom: true, caret: far, previous: first.displayedRect)
        XCTAssertNotEqual(moved.displayedRect, first.displayedRect)
        // The same caret with no history lands in the same place: re-centering is deterministic.
        XCTAssertEqual(moved, open(remote: tall, zoom: true, caret: far))
        // Re-applying it with that history is a no-op: it stays put.
        let again = open(remote: tall, zoom: true, caret: far, previous: moved.displayedRect)
        XCTAssertEqual(again, moved)
    }

    func testPreviousFromAnotherScaleIsIgnored() {
        let c = caret(0.41, 0.51)
        let fresh = open(remote: tall, zoom: true, caret: c)
        let stale = open(remote: tall, zoom: true, caret: c, previous: CGRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertEqual(stale, fresh)
    }

    func testPreviousIsIgnoredWithoutACaret() {
        let anchor = CGPoint(x: 0.3, y: 0.7)
        let withPrevious = open(remote: tall, zoom: true, anchor: anchor, caret: nil,
                                previous: CGRect(x: -50, y: -80, width: 585, height: 936))
        XCTAssertEqual(withPrevious, open(remote: tall, zoom: true, anchor: anchor, caret: nil))
    }

    // MARK: - Degenerate geometry

    func testAKeyboardTooShortToUseStillFitsTheWholeDisplay() {
        let short = CGRect(x: 0, y: 0, width: 390, height: 40)
        let t = open(remote: wide, zoom: true, caret: caret(0.5, 0.5), visible: short)
        XCTAssertLessThanOrEqual(t.displayedRect.maxY, short.maxY + 0.001)
        XCTAssertTrue(t.isValid)
    }

    // MARK: - Shared vectors

    func testSharedVectorsMatch() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/viewport/caret-vectors.json")
        let data = try Data(contentsOf: url)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let cases = try XCTUnwrap(root["cases"] as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(cases.count, 10)
        func rect(_ value: Any?) -> CGRect? {
            guard let a = value as? [NSNumber], a.count == 4 else { return nil }
            return CGRect(x: a[0].doubleValue, y: a[1].doubleValue, width: a[2].doubleValue, height: a[3].doubleValue)
        }
        for c in cases {
            let name = c["name"] as? String ?? "?"
            let remote = try XCTUnwrap(c["remote"] as? [NSNumber], name)
            var anchor: CGPoint?
            if let a = c["anchor"] as? [NSNumber], a.count == 2 { anchor = CGPoint(x: a[0].doubleValue, y: a[1].doubleValue) }
            let t = RemoteViewportCalculator.keyboardOpen(
                viewBounds: try XCTUnwrap(rect(c["view"]), name),
                remoteAspectSize: CGSize(width: remote[0].doubleValue, height: remote[1].doubleValue),
                visibleRect: try XCTUnwrap(rect(c["visible"]), name),
                anchor: anchor, zoomEnabled: c["zoom"] as? Bool ?? false,
                caret: rect(c["caret"]), previous: rect(c["previous"]))
            let expected = try XCTUnwrap(rect(c["displayed"]), name)
            XCTAssertEqual(t.displayedRect.minX, expected.minX, accuracy: 1e-5, name)
            XCTAssertEqual(t.displayedRect.minY, expected.minY, accuracy: 1e-5, name)
            XCTAssertEqual(t.displayedRect.width, expected.width, accuracy: 1e-5, name)
            XCTAssertEqual(t.displayedRect.height, expected.height, accuracy: 1e-5, name)
        }
    }
}

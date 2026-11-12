import CoreGraphics
import XCTest

/// Window view: a window shown with an Open/Save sheet. Geometry measured on macOS 27 with a real
/// `NSOpenPanel` sheet (probe 2026-11-09, 1x display): a single-window capture includes the
/// window's child windows, so its content is the window *with* its sheet, and a capture of the
/// sheet window alone returns the whole tree. QA 9000026: taps on the chooser's Cancel missed it,
/// and taps beside the drawn chooser landed in it.
final class WindowCaptureExtentTests: XCTestCase {
    // Tall window: the sheet sits inside it.
    private let tall = CGRect(x: 200, y: 198, width: 1000, height: 732)
    private let tallSheet = CGRect(x: 260, y: 340, width: 880, height: 448)
    // Short window: the sheet hangs 148 pt past its bottom; the capture is 1000x480.
    private let short = CGRect(x: 200, y: 598, width: 1000, height: 332)
    private let shortSheet = CGRect(x: 260, y: 630, width: 880, height: 448)

    // MARK: Extent

    func testACaptureThatIsTheWindowNeedsNoExtent() {
        XCTAssertNil(WindowCaptureExtent.extent(window: tall, children: [tallSheet], content: CGSize(width: 1000, height: 732)))
        XCTAssertNil(WindowCaptureExtent.extent(window: tall, children: [], content: CGSize(width: 1000.6, height: 731)),
                     "rounding is not an extent")
        XCTAssertNil(WindowCaptureExtent.extent(window: tall, children: [], content: nil), "unknown size: the window, as before")
    }

    func testASheetPastTheWindowsEdgeMakesTheCaptureTheirUnion() {
        let e = WindowCaptureExtent.extent(window: short, children: [shortSheet], content: CGSize(width: 1000, height: 480))
        XCTAssertEqual(e, CGRect(x: 0, y: 0, width: 1000, height: 480))
        // A sheet wider than its window hangs past both sides: the extent starts left of the window.
        let narrow = CGRect(x: 300, y: 100, width: 600, height: 300)
        let wide = CGRect(x: 240, y: 128, width: 720, height: 400)
        XCTAssertEqual(WindowCaptureExtent.extent(window: narrow, children: [wide], content: CGSize(width: 720, height: 428)),
                       CGRect(x: -60, y: 0, width: 720, height: 428))
    }

    func testAnUnexplainedSizeKeepsTheWindow() {
        // No sheet listed yet (the catalog is a moment behind), or Stage Manager's thumbnail.
        XCTAssertNil(WindowCaptureExtent.extent(window: short, children: [], content: CGSize(width: 1000, height: 480)))
        XCTAssertNil(WindowCaptureExtent.extent(window: short, children: [shortSheet], content: CGSize(width: 1000, height: 470)),
                     "a sheet mid-animation: neither the window nor the tree")
    }

    func testASheetCaptureIsDrawnOverItsWindowOnlyWhenItShowsJustTheSheet() {
        XCTAssertFalse(WindowCaptureExtent.isSheetOnly(sheet: tallSheet.size, content: CGSize(width: 1000, height: 732)),
                       "macOS 27: the sheet's capture is the whole window; drawing it into the sheet's frame shrank it")
        XCTAssertTrue(WindowCaptureExtent.isSheetOnly(sheet: tallSheet.size, content: CGSize(width: 880, height: 448)))
        XCTAssertFalse(WindowCaptureExtent.isSheetOnly(sheet: tallSheet.size, content: nil))
    }

    // MARK: What is drawn is where input lands

    private func pane(window: CGRect, extent: CGRect?) -> WorkspaceInputTargeting {
        var t = WorkspaceInputTargeting()
        t.canvas = CGSize(width: 2160, height: 1620)
        t.windowFrames = [10: window]
        if let extent { t.contentExtents = [10: extent] }
        _ = t.update(assignments: [
            WorkspaceTileAssignment(tileID: "chrome", rect: .init(x: 0, y: 0, width: 1, height: 1), windowID: 10, windowGeneration: 1,
                                    pid: 100, bundleID: "com.google.Chrome", follow: .window, rotation: .none, fit: .fit,
                                    assignmentGeneration: 1),
        ])
        return t
    }

    /// Where the compositor draws source point `s` (points within the captured content), normalized.
    private func drawn(_ t: WorkspaceInputTargeting, _ s: CGPoint) -> WorkspacePoint {
        let tr = t.transform(for: t.assignments[0])!
        let q = tr.canvasPoint(fromSource: WorkspacePoint(x: s.x, y: s.y))
        return WorkspacePoint(x: q.x / t.canvas.width, y: q.y / t.canvas.height)
    }

    func testATapOnTheDrawnCancelButtonLandsOnCancel_SheetPastTheEdge() throws {
        // Cancel's centre in the 1000x480 capture (probe frame), i.e. global (993, 1046).
        let cancelInCapture = CGPoint(x: 793, y: 448)
        let cancelOnMac = CGPoint(x: short.minX + 793, y: short.minY + 448)
        var fixed = pane(window: short, extent: CGRect(x: 0, y: 0, width: 1000, height: 480))
        let tap = drawn(fixed, cancelInCapture)
        let hit = try XCTUnwrap(fixed.resolve(.down, at: tap))
        XCTAssertEqual(hit.point.x, cancelOnMac.x, accuracy: 0.5)
        XCTAssertEqual(hit.point.y, cancelOnMac.y, accuracy: 0.5)

        // Before: the 1000x480 picture was squeezed into the 1000x332 window, and input mapped
        // through the window; the press went 138 pt above Cancel (into the file list).
        var before = pane(window: short, extent: nil)
        let squeezed = drawn(before, CGPoint(x: 793, y: 448 * 332 / 480))
        let wrong = try XCTUnwrap(before.resolve(.down, at: squeezed))
        XCTAssertEqual(cancelOnMac.y - wrong.point.y, 138, accuracy: 1)
    }

    func testTheSheetsOwnCaptureNoLongerDrawsAShrunkenCopy_SheetInsideTheWindow() throws {
        // Chrome's case (window 1920x1050, chooser inside it): the window's capture is the window,
        // with the chooser in place. Cancel's centre at (793, 558) in the window.
        var t = pane(window: tall, extent: nil)
        let hit = try XCTUnwrap(t.resolve(.down, at: drawn(t, CGPoint(x: 793, y: 558))))
        XCTAssertEqual(hit.point.x, tall.minX + 793, accuracy: 0.5)
        XCTAssertEqual(hit.point.y, tall.minY + 558, accuracy: 0.5)

        // Before: the sheet's capture (the whole 1000x732 window) was also drawn into the sheet's
        // 880x448 frame, so the visible Cancel sat at (757.8, 483.5): a tap there pressed 35 pt
        // left of and 75 pt above Cancel, and the drawn chooser ended at x 887 while the real one
        // ran to 940, so taps right of what was drawn still landed in the chooser.
        let local = CGPoint(x: tallSheet.minX - tall.minX, y: tallSheet.minY - tall.minY)
        let shrunk = CGPoint(x: local.x + 793 * tallSheet.width / tall.width, y: local.y + 558 * tallSheet.height / tall.height)
        XCTAssertEqual(shrunk.x - 793, -35.2, accuracy: 0.5)
        XCTAssertEqual(shrunk.y - 558, -74.5, accuracy: 0.5)
        XCTAssertFalse(WindowCaptureExtent.isSheetOnly(sheet: tallSheet.size, content: tall.size), "that copy is no longer drawn")
    }

    func testTheCursorAndCaretFollowTheSameExtent() throws {
        let t = pane(window: short, extent: CGRect(x: 0, y: 0, width: 1000, height: 480))
        let onSheet = CGPoint(x: short.minX + 793, y: short.minY + 448)   // past the window's bottom
        let c = try XCTUnwrap(t.cursorPlacement(forGlobal: onSheet), "the cursor shows over the sheet past the window")
        let expected = drawn(t, CGPoint(x: 793, y: 448))
        XCTAssertEqual(c.x, expected.x, accuracy: 1e-6)
        XCTAssertEqual(c.y, expected.y, accuracy: 1e-6)
    }

    func testClosingTheSheetPutsInputBackOnTheWindow() throws {
        var t = pane(window: short, extent: CGRect(x: 0, y: 0, width: 1000, height: 480))
        t.contentExtents = [:]   // the next frame is the window again (measured on close)
        let hit = try XCTUnwrap(t.resolve(.down, at: drawn(t, CGPoint(x: 500, y: 300))))
        XCTAssertEqual(hit.point, CGPoint(x: short.minX + 500, y: short.minY + 300))
    }

    // MARK: Cover check on a sheet past the window

    private typealias W = WorkspaceInputCover.Window

    private func verdict(at p: CGPoint, above: [W], sheets: Set<UInt32> = [21]) -> WorkspaceInputCover.Verdict {
        WorkspaceInputCover.verdict(target: 10, targetFrame: short, at: p, above: above, ownSheets: sheets,
                                    displays: [CGRect(x: 0, y: 0, width: 1920, height: 1080)], hitTest: { nil })
    }

    func testAPressOnTheTargetsSheetPastItsEdgeIsOnTheTarget() {
        let sheet = W(id: 21, owner: "Google Chrome", layer: 0, bounds: shortSheet, alpha: 1, pid: 100)
        XCTAssertEqual(verdict(at: CGPoint(x: 993, y: 1046), above: [sheet]), .clear)
    }

    func testAnotherWindowOverThatPartStillCovers() {
        let sheet = W(id: 21, owner: "Google Chrome", layer: 0, bounds: shortSheet, alpha: 1, pid: 100)
        let other = W(id: 30, owner: "Notes", layer: 0, bounds: CGRect(x: 900, y: 1000, width: 300, height: 80), alpha: 1, pid: 300)
        XCTAssertEqual(verdict(at: CGPoint(x: 993, y: 1046), above: [other, sheet]),
                       .covered(by: 30, cache: CGRect(x: 900, y: 1000, width: 300, height: 80)))
    }

    func testPastTheEdgeButOffTheSheetIsOutside() {
        let sheet = W(id: 21, owner: "Google Chrome", layer: 0, bounds: shortSheet, alpha: 1, pid: 100)
        // Inside the window-plus-sheet rectangle, but on neither (the corner beside the sheet).
        XCTAssertEqual(verdict(at: CGPoint(x: 220, y: 1000), above: [sheet]), .outside)
        // A same-sized window of another app that isn't the target's sheet gives nothing.
        let stranger = W(id: 22, owner: "Notes", layer: 0, bounds: shortSheet, alpha: 1, pid: 300)
        XCTAssertEqual(verdict(at: CGPoint(x: 993, y: 1046), above: [stranger], sheets: []),
                       .covered(by: 22, cache: shortSheet))
    }

    func testAClosedSheetsSuspendedStreamIsNotLive() {
        XCTAssertFalse(WindowWorkspaceEngine.isLiveStatus(.suspended), "a closed sheet's stream turns suspended (measured)")
        XCTAssertFalse(WindowWorkspaceEngine.isLiveStatus(.stopped))
        XCTAssertTrue(WindowWorkspaceEngine.isLiveStatus(.complete))
        XCTAssertTrue(WindowWorkspaceEngine.isLiveStatus(.idle))
    }
}

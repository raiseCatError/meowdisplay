import CoreVideo
import XCTest

/// Sheets ("Save changes?") are separate windows on macOS: a pane shows them over their window.
final class WindowSheetTests: XCTestCase {
    private func w(_ id: UInt32, pid: Int32 = 10, _ frame: CGRect, title: String? = "", layer: Int = 0) -> WindowSheetMatcher.Window {
        WindowSheetMatcher.Window(id: id, pid: pid, frame: frame, title: title, layer: layer)
    }

    func testACentredUntitledWindowRightAboveItsWindowIsItsSheet() {
        // Measured on macOS 27: parent 19510 (480,488 500x432), sheet 19511 (580,629 300x150), centred both ways.
        let parent = w(19510, CGRect(x: 480, y: 488, width: 500, height: 432), title: "Tone A — Window 1")
        let sheet = w(19511, CGRect(x: 580, y: 629, width: 300, height: 150))
        XCTAssertEqual(WindowSheetMatcher.sheets(frontToBack: [sheet, parent]), [19510: [19511]])
        // Attached under the title bar (older macOS) counts too.
        let top = w(7, CGRect(x: 580, y: 516, width: 300, height: 150))
        XCTAssertEqual(WindowSheetMatcher.sheets(frontToBack: [top, parent]), [19510: [7]])
    }

    func testOtherWindowsAreNeverSheets() {
        let parent = w(1, CGRect(x: 100, y: 100, width: 600, height: 400), title: "Doc")
        let titled = w(2, CGRect(x: 250, y: 200, width: 300, height: 150), title: "Inspector")
        let otherApp = w(3, pid: 99, CGRect(x: 250, y: 200, width: 300, height: 150))
        let offCentre = w(4, CGRect(x: 120, y: 200, width: 300, height: 150))
        let below = w(5, CGRect(x: 250, y: 600, width: 300, height: 150))
        let wider = w(6, CGRect(x: 50, y: 200, width: 700, height: 150))
        let floating = w(8, CGRect(x: 250, y: 200, width: 300, height: 150), layer: 3)
        for c in [titled, otherApp, offCentre, below, wider, floating] {
            XCTAssertEqual(WindowSheetMatcher.sheets(frontToBack: [c, parent]), [:], "window \(c.id)")
        }
    }

    func testTheSheetBelongsToTheWindowRightBelowItAndASheetOnASheetToTheSameWindow() {
        let back = w(1, CGRect(x: 100, y: 100, width: 600, height: 400), title: "Back")
        let front = w(2, CGRect(x: 100, y: 100, width: 600, height: 400), title: "Front")
        let sheet = w(3, CGRect(x: 250, y: 200, width: 300, height: 200))
        let alert = w(4, CGRect(x: 300, y: 250, width: 200, height: 100))
        XCTAssertEqual(WindowSheetMatcher.sheets(frontToBack: [sheet, front, back]), [2: [3]])
        XCTAssertEqual(WindowSheetMatcher.sheets(frontToBack: [alert, sheet, front, back]), [2: [4, 3]], "front-most first")
    }

    // MARK: Titled sheets (an Open or Save panel shown as a sheet), QA 9000025

    /// Measured on macOS 27 (probe, 2026-11-09): a 900x632 window at (300,248) and its Open sheet
    /// 880x448 at (310,340), titled "Open" even when the panel's title is set empty.
    private let window = WindowSheetMatcherWindow.make(18024, CGRect(x: 300, y: 248, width: 900, height: 632), "Upload probe")
    private let openSheet = WindowSheetMatcherWindow.make(18026, CGRect(x: 310, y: 340, width: 880, height: 448), "Open")

    func testASmallWindowOfTheAppBetweenASheetAndItsWindowDoesNotPartThem() {
        // Measured live (QA 9000028, macOS 27): an Open sheet 18396 over its window 18371, with a
        // 66 x 20 window of the same app (18392, at the window's top-left) between them. The sheet
        // went unmatched and every press on the chooser was refused as covered by it.
        let window = w(18371, CGRect(x: 160, y: 198, width: 1100, height: 762), title: "Chooser Target")
        let strip = w(18392, CGRect(x: 166, y: 204, width: 66, height: 20))
        let sheet = w(18396, CGRect(x: 270, y: 355, width: 880, height: 448), title: "Open")
        XCTAssertEqual(WindowSheetMatcher.sheets(frontToBack: [sheet, strip, window], confirmsTitled: { _, _ in true }),
                       [18371: [18396]])
        // A window of the app in between that overlaps the sheet still parts them.
        let inspector = w(18393, CGRect(x: 300, y: 400, width: 400, height: 300), title: "Inspector")
        XCTAssertEqual(WindowSheetMatcher.sheets(frontToBack: [sheet, inspector, window], confirmsTitled: { _, _ in true }), [:])
        // Another app's window in between never mattered.
        let other = w(18394, pid: 99, CGRect(x: 300, y: 400, width: 400, height: 300))
        XCTAssertEqual(WindowSheetMatcher.sheets(frontToBack: [sheet, other, window], confirmsTitled: { _, _ in true }),
                       [18371: [18396]])
    }

    func testASheetScreenCaptureKitDoesNotListIsStillItsWindows() {
        // QA 9000030: the third Open sheet in a row was matched but missing from ScreenCaptureKit's
        // listing, so it was dropped and presses on it were refused as covered.
        let window = w(18474, CGRect(x: 160, y: 198, width: 1100, height: 762), title: "Chooser Target")
        let sheet = w(18509, CGRect(x: 270, y: 355, width: 880, height: 448))
        let matched = WindowSheetMatcher.sheets(frontToBack: [sheet, window])
        XCTAssertEqual(matched, [18474: [18509]])
        let unlisted = WindowCatalogBuilder.attachedSheetFrames(sheets: matched, listed: [18474], scFrames: [:], order: [sheet, window])
        XCTAssertEqual(unlisted[18474]?.map(\.id), [18509])
        XCTAssertEqual(unlisted[18474]?.first?.frame, sheet.frame)
        XCTAssertEqual(unlisted[18474]?.first?.fromCapture, false)
        let listed = WindowCatalogBuilder.attachedSheetFrames(sheets: matched, listed: [18474],
                                                              scFrames: [18509: CGRect(x: 270, y: 355, width: 880, height: 448)],
                                                              order: [sheet, window])
        XCTAssertEqual(listed[18474]?.first?.fromCapture, true)
        // A window that isn't listed keeps no sheets.
        XCTAssertTrue(WindowCatalogBuilder.attachedSheetFrames(sheets: matched, listed: [], scFrames: [:], order: [sheet, window]).isEmpty)
    }

    func testATitledSheetIsASheetOnlyWhenTheAppConfirmsIt() {
        XCTAssertEqual(WindowSheetMatcher.sheets(frontToBack: [openSheet, window]), [:], "unconfirmed: an ordinary window")
        var asked: [(UInt32, UInt32)] = []
        let confirmed = WindowSheetMatcher.sheets(frontToBack: [openSheet, window]) { s, p in asked.append((s.id, p.id)); return true }
        XCTAssertEqual(confirmed, [18024: [18026]])
        XCTAssertEqual(asked.map(\.0), [18026])
        XCTAssertEqual(asked.map(\.1), [18024], "asked about the window it sits on")
        XCTAssertEqual(WindowSheetMatcher.sheets(frontToBack: [openSheet, window]) { _, _ in false }, [:])
    }

    func testOnlyTitledWindowsOfSheetShapeOnTheirWindowAreEverAskedAbout() {
        var asked = 0
        let confirm: (WindowSheetMatcher.Window, WindowSheetMatcher.Window) -> Bool = { _, _ in asked += 1; return true }
        let untitled = WindowSheetMatcherWindow.make(5, CGRect(x: 310, y: 340, width: 880, height: 448), "")
        XCTAssertEqual(WindowSheetMatcher.sheets(frontToBack: [untitled, window], confirmsTitled: confirm), [18024: [5]])
        let offCentre = WindowSheetMatcherWindow.make(6, CGRect(x: 320, y: 340, width: 600, height: 300), "Open")
        let otherApp = WindowSheetMatcher.Window(id: 7, pid: 99, frame: openSheet.frame, title: "Open", layer: 0)
        let floating = WindowSheetMatcher.Window(id: 8, pid: 10, frame: openSheet.frame, title: "Open", layer: 3)
        let tiny = WindowSheetMatcherWindow.make(9, CGRect(x: 740, y: 340, width: 20, height: 20), "Open")
        for c in [offCentre, otherApp, floating, tiny] {
            XCTAssertEqual(WindowSheetMatcher.sheets(frontToBack: [c, window], confirmsTitled: confirm), [:], "window \(c.id)")
        }
        XCTAssertEqual(asked, 0)
    }

    func testAnAlertOnAConfirmedSaveSheetBelongsToTheSameWindow() {
        let save = WindowSheetMatcherWindow.make(11, CGRect(x: 565, y: 473, width: 370, height: 182), "Save")
        let alert = WindowSheetMatcherWindow.make(12, CGRect(x: 600, y: 500, width: 300, height: 120), "")
        XCTAssertEqual(WindowSheetMatcher.sheets(frontToBack: [alert, save, window]) { _, _ in true }, [18024: [12, 11]])
        // Unconfirmed Save sheet: the alert is its sheet, but neither belongs to the window.
        XCTAssertEqual(WindowSheetMatcher.sheets(frontToBack: [alert, save, window]), [11: [12]])
    }

    func testTheCompositorDrawsTheSheetWhereItSitsOnTheWindow() throws {
        let compositor = try XCTUnwrap(WorkspaceCompositor())
        compositor.resize(to: CGSize(width: 800, height: 600))
        let window = try solid(400, 300, b: 0, g: 0, r: 255)
        let sheet = try solid(200, 100, b: 255, g: 0, r: 0)
        // The 400x300-point window fills the 800x600 canvas (2 px per point); its sheet sits at (100,100) 200x100.
        let t = TileContentTransform(tile: WorkspaceRect(x: 0, y: 0, width: 800, height: 600), source: WorkspaceSize(width: 400, height: 300),
                                     rotation: .none, fit: .fit)
        let item = WorkspaceCompositor.Item(rect: WorkspaceRect(x: 0, y: 0, width: 1, height: 1), transform: t, frame: window,
                                            sourceSize: .zero, dimmed: false,
                                            overlay: .init(frame: sheet, rect: CGRect(x: 100, y: 100, width: 200, height: 100)))
        let out = try XCTUnwrap(compositor.compose([item]))
        XCTAssertEqual(pixel(out, 400, 300).b, 255, accuracy: 3, "the sheet's middle")
        XCTAssertEqual(pixel(out, 400, 300).r, 0, accuracy: 3)
        XCTAssertEqual(pixel(out, 100, 100).r, 255, accuracy: 3, "the window outside the sheet")
        XCTAssertEqual(pixel(out, 610, 300).r, 255, accuracy: 3, "just right of the sheet (it ends at x=600)")
        XCTAssertEqual(pixel(out, 590, 390).b, 255, accuracy: 3, "inside the sheet's bottom-right corner")
    }

    private func solid(_ w: Int, _ h: Int, b: UInt8, g: UInt8, r: UInt8) throws -> CVPixelBuffer {
        var out: CVPixelBuffer?
        let attrs = [kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]] as CFDictionary
        XCTAssertEqual(CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, attrs, &out), kCVReturnSuccess)
        let buffer = try XCTUnwrap(out)
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
        let row = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<h { for x in 0..<w { let p = base + y * row + x * 4; p[0] = b; p[1] = g; p[2] = r; p[3] = 255 } }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    private func pixel(_ buffer: CVPixelBuffer, _ x: Int, _ y: Int) -> (b: Double, g: Double, r: Double) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let p = base + y * CVPixelBufferGetBytesPerRow(buffer) + x * 4
        return (Double(p[0]), Double(p[1]), Double(p[2]))
    }
}

private enum WindowSheetMatcherWindow {
    static func make(_ id: UInt32, _ frame: CGRect, _ title: String) -> WindowSheetMatcher.Window {
        WindowSheetMatcher.Window(id: id, pid: 10, frame: frame, title: title, layer: 0)
    }
}

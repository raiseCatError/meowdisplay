import CoreGraphics
import Security
import XCTest

/// Window mode on the sender: when input at a point may go to a tiled window. Geometry from the
/// macOS 27 Mac where Window view input stopped (2026-11-05): one 1920×1080 display, the Dock's
/// single window at layer 20 spanning it, a Terminal window as the target.
final class WorkspaceInputCoverTests: XCTestCase {
    private typealias W = WorkspaceInputCover.Window
    private let display = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    private let target: UInt32 = 4440
    private let targetFrame = CGRect(x: 451, y: 190, width: 597, height: 432)
    private let inside = CGPoint(x: 700, y: 400)
    private let dock = W(id: 27, owner: "Dock", layer: 20, bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080), alpha: 1)

    /// The verdict, and how many times the window server was asked.
    private func verdict(above: [W], at point: CGPoint? = nil, frame: CGRect?? = nil, sheets: Set<UInt32> = [],
                         displays: [CGRect]? = nil, hit: UInt32?) -> (WorkspaceInputCover.Verdict, Int) {
        var asked = 0
        let v = WorkspaceInputCover.verdict(target: target, targetFrame: frame ?? targetFrame, at: point ?? inside, above: above,
                                           ownSheets: sheets, displays: displays ?? [display],
                                           hitTest: { asked += 1; return hit })
        return (v, asked)
    }

    // MARK: The macOS 27 Dock false positive

    func testTheDocksDisplayWideWindowDoesNotCoverWhereTheWindowServerHitsTheTarget() {
        let (v, asked) = verdict(above: [dock], hit: target)
        XCTAssertEqual(v, .clear, "a press over the Terminal window goes to it")
        XCTAssertEqual(asked, 1)
    }

    func testTheDockStripStillCoversWhereTheDockTakesTheClick() {
        // The same window, but over the Dock itself (or Mission Control, App Exposé, the Apps
        // screen): the window server hits the Dock.
        let (v, _) = verdict(above: [dock], hit: 27)
        XCTAssertEqual(v, .covered(by: 27, cache: CGRect(x: 660, y: 360, width: 80, height: 80)))
    }

    func testNoAnswerFromTheWindowServerFailsClosed() {
        XCTAssertNotEqual(verdict(above: [dock], hit: nil).0, .clear, "a timeout or no window hit")
    }

    func testAHitOnAnyOtherWindowFailsClosed() {
        XCTAssertNotEqual(verdict(above: [dock], hit: 5583).0, .clear, "another app's window under the surface")
        XCTAssertNotEqual(verdict(above: [dock], hit: 2721).0, .clear, "the menu bar")
    }

    func testTheSurfaceIsCachedOnlyNearThePoint() {
        // Not the whole display: a hover over the Dock strip mustn't block hovers elsewhere.
        guard case .covered(_, let cache) = verdict(above: [dock], hit: 27).0 else { return XCTFail() }
        XCTAssertLessThanOrEqual(cache.width, 80)
        XCTAssertTrue(cache.contains(inside))
    }

    // MARK: Real occlusion still covers, without asking the window server

    func testAnotherAppsWindowOverThePointCovers() {
        let chrome = W(id: 5583, owner: "Google Chrome", layer: 0, bounds: CGRect(x: 600, y: 300, width: 400, height: 300), alpha: 1)
        let (v, asked) = verdict(above: [dock, chrome], hit: target)
        XCTAssertEqual(v, .covered(by: 5583, cache: chrome.bounds), "even when the hit-test says otherwise")
        XCTAssertEqual(asked, 0)
    }

    func testMenusPanelsAndBannersCover() {
        let menu = W(id: 900, owner: "Terminal", layer: 101, bounds: CGRect(x: 650, y: 380, width: 220, height: 300), alpha: 1)
        let panel = W(id: 901, owner: "Preview", layer: 3, bounds: CGRect(x: 600, y: 350, width: 300, height: 200), alpha: 1)
        let banner = W(id: 902, owner: "NotificationCenter", layer: 23, bounds: CGRect(x: 600, y: 380, width: 360, height: 90), alpha: 1)
        for cover in [menu, panel, banner] {
            let (v, asked) = verdict(above: [cover, dock], hit: target)
            XCTAssertEqual(v, .covered(by: cover.id, cache: cover.bounds), cover.owner)
            XCTAssertEqual(asked, 0, cover.owner)
        }
    }

    func testARealWindowUnderTheSurfaceStillCovers() {
        // Front to back: the Dock's surface, then a real window over the target.
        let finder = W(id: 7315, owner: "Finder", layer: 0, bounds: CGRect(x: 421, y: 178, width: 1029, height: 747), alpha: 1)
        XCTAssertEqual(verdict(above: [dock, finder], hit: target).0, .covered(by: 7315, cache: finder.bounds))
    }

    func testAnotherSurfaceThatTakesTheClickCovers() {
        // A display-wide overlay that takes clicks (the screenshot crosshair, a screen saver).
        let overlay = W(id: 990, owner: "screencaptureui", layer: 1000, bounds: display, alpha: 1)
        XCTAssertNotEqual(verdict(above: [overlay, dock], hit: 990).0, .clear)
    }

    func testOnlyDisplayWideSurfacesAboveTheNormalLayerQualify() {
        // A display-sized ordinary window (a borderless full-display app window) always covers.
        let borderless = W(id: 77, owner: "Player", layer: 0, bounds: display, alpha: 1)
        XCTAssertEqual(verdict(above: [borderless], hit: target).0, .covered(by: 77, cache: display))
        // Nearly display-wide isn't display-wide: a maximized window under the menu bar.
        let big = W(id: 78, owner: "Claude", layer: 1, bounds: CGRect(x: 0, y: 30, width: 1920, height: 1050), alpha: 1)
        XCTAssertEqual(verdict(above: [big], hit: target).0, .covered(by: 78, cache: big.bounds))
        let nudged = W(id: 79, owner: "Dock", layer: 20, bounds: CGRect(x: 0, y: 2, width: 1920, height: 1078), alpha: 1)
        XCTAssertFalse(WorkspaceInputCover.isDisplayWideSurface(nudged, at: inside, displays: [display]))
    }

    // MARK: Stage Manager, Spaces and displays

    func testStageManagersStripCovers() {
        let thumbnail = W(id: 386, owner: "WindowManager", layer: 0, bounds: CGRect(x: 8, y: 281, width: 220, height: 157), alpha: 1)
        let (v, asked) = verdict(above: [dock, thumbnail], at: CGPoint(x: 100, y: 350),
                                 frame: CGRect(x: 0, y: 30, width: 1200, height: 900), hit: target)
        XCTAssertEqual(v, .covered(by: 386, cache: thumbnail.bounds))
        XCTAssertEqual(asked, 0)
    }

    func testATargetNotOnScreenIsNeverTopmost() {
        // Another Space, minimized, or hidden: no on-screen frame.
        let (v, asked) = verdict(above: [dock], frame: .some(nil), hit: target)
        XCTAssertEqual(v, .outside)
        XCTAssertEqual(asked, 0)
        XCTAssertEqual(verdict(above: [], at: CGPoint(x: 100, y: 100), hit: target).0, .outside, "outside the window")
    }

    func testEachDisplaysSurfaceCountsOnlyOnItsDisplay() {
        let second = CGRect(x: 1920, y: 0, width: 1080, height: 810)
        let point = CGPoint(x: 2100, y: 300)
        let frame = CGRect(x: 2000, y: 100, width: 600, height: 500)
        // The main display's Dock surface doesn't contain a point on the second display.
        let (v1, asked1) = verdict(above: [dock], at: point, frame: frame, displays: [display, second], hit: 27)
        XCTAssertEqual(v1, .clear)
        XCTAssertEqual(asked1, 0, "nothing over the point: no need to ask")
        // A surface spanning the second display is decided there by the window server.
        let dock2 = W(id: 28, owner: "Dock", layer: 20, bounds: second, alpha: 1)
        XCTAssertEqual(verdict(above: [dock2, dock], at: point, frame: frame, displays: [display, second], hit: target).0, .clear)
        XCTAssertNotEqual(verdict(above: [dock2, dock], at: point, frame: frame, displays: [display, second], hit: 28).0, .clear)
        // Spanning one display doesn't make it display-wide on another.
        XCTAssertFalse(WorkspaceInputCover.isDisplayWideSurface(dock, at: point, displays: [display, second]))
    }

    // MARK: The rules that were already there

    func testTheTargetsOwnSheetIsPartOfIt() {
        let sheet = W(id: 4441, owner: "Terminal", layer: 0, bounds: CGRect(x: 550, y: 212, width: 400, height: 180), alpha: 1)
        XCTAssertEqual(verdict(above: [sheet], at: CGPoint(x: 700, y: 300), sheets: [4441], hit: nil).0, .clear)
        XCTAssertEqual(verdict(above: [sheet, dock], at: CGPoint(x: 700, y: 300), sheets: [4441], hit: 4441).0, .clear,
                       "the hit-test landing on the target's own sheet")
        XCTAssertEqual(verdict(above: [sheet], at: CGPoint(x: 700, y: 300), hit: nil).0,
                       .covered(by: 4441, cache: sheet.bounds), "someone else's sheet covers")
    }

    func testTransparentAndWindowServerWindowsNeverCover() {
        let invisible = W(id: 5574, owner: "BetterDisplay", layer: 0, bounds: targetFrame, alpha: 0)
        let menuBar = W(id: 2721, owner: "Window Server", layer: 24, bounds: CGRect(x: 0, y: 0, width: 1920, height: 30), alpha: 1)
        let (v, asked) = verdict(above: [invisible, menuBar], at: CGPoint(x: 700, y: 200), hit: nil)
        XCTAssertEqual(v, .clear)
        XCTAssertEqual(asked, 0)
    }

    func testNothingAboveIsClear() {
        let (v, asked) = verdict(above: [], hit: nil)
        XCTAssertEqual(v, .clear)
        XCTAssertEqual(asked, 0)
    }

    // MARK: Reading the window list

    func testTheWindowListsOwnTypesAreRead() {
        // As CGWindowListCopyWindowInfo hands them over: numbers, a bounds dictionary.
        let info: [String: Any] = [kCGWindowNumber as String: NSNumber(value: 27), kCGWindowLayer as String: NSNumber(value: 20),
                                   kCGWindowOwnerName as String: "Dock", kCGWindowAlpha as String: NSNumber(value: 1.0),
                                   kCGWindowBounds as String: display.dictionaryRepresentation]
        XCTAssertEqual(WorkspaceInputCover.window(from: info), dock)
    }

    func testAWindowListedWithoutANumberStillCovers() throws {
        let bounds = CGRect(x: 600, y: 300, width: 300, height: 300)
        let info: [String: Any] = [kCGWindowBounds as String: bounds.dictionaryRepresentation, kCGWindowLayer as String: 0,
                                   kCGWindowOwnerName as String: "Other", kCGWindowAlpha as String: 1.0]
        let w = try XCTUnwrap(WorkspaceInputCover.window(from: info), "kept, not dropped")
        XCTAssertEqual(w.id, 0)
        let (v, asked) = verdict(above: [dock, w], hit: target)
        XCTAssertEqual(v, .covered(by: 0, cache: bounds))
        XCTAssertEqual(asked, 0)
    }

    func testMissingValuesReadAsACover() throws {
        // Only bounds, the size of the display: without a layer it is never a display-wide surface.
        let w = try XCTUnwrap(WorkspaceInputCover.window(from: [kCGWindowBounds as String: display.dictionaryRepresentation]))
        XCTAssertEqual(w, W(id: 0, owner: "", layer: 0, bounds: display, alpha: 1))
        let (v, asked) = verdict(above: [w], hit: target)
        XCTAssertEqual(v, .covered(by: 0, cache: display))
        XCTAssertEqual(asked, 0)
    }

    func testAWindowWithoutBoundsIsSkipped() {
        XCTAssertNil(WorkspaceInputCover.window(from: [kCGWindowNumber as String: NSNumber(value: 9), kCGWindowLayer as String: NSNumber(value: 0)]))
    }

    // MARK: Coordinates across displays

    func testTheHitTestPointFlipsAboutThePrimaryDisplayOnEveryDisplay() {
        func cocoa(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            WorkspaceInputCover.cocoaPoint(fromGlobal: CGPoint(x: x, y: y), primaryHeight: 1080)
        }
        // The primary display (measured: global (960, 15) is the menu bar, Cocoa y 1065).
        XCTAssertEqual(cocoa(960, 15), CGPoint(x: 960, y: 1065))
        XCTAssertEqual(cocoa(960, 1062), CGPoint(x: 960, y: 18))
        // A display above the primary (global y negative): Cocoa y past the primary's height.
        XCTAssertEqual(cocoa(100, -450), CGPoint(x: 100, y: 1530))
        // A display below it: Cocoa y negative.
        XCTAssertEqual(cocoa(500, 1500), CGPoint(x: 500, y: -420))
        // A display to its left: x is unchanged, negative as in global coordinates.
        XCTAssertEqual(cocoa(-1000, 200), CGPoint(x: -1000, y: 880))
    }

    // MARK: The live query's bound

    func testTheMainThreadQueryRunsInlineOnTheMainThread() {
        XCTAssertTrue(Thread.isMainThread)
        XCTAssertEqual(MainThreadQuery.run(timeout: 0.01) { 7 }, 7)
    }

    func testTheMainThreadQueryAnswersFromAnotherQueue() {
        let answered = expectation(description: "answer")
        DispatchQueue.global().async {
            XCTAssertEqual(MainThreadQuery.run(timeout: 2) { 42 }, 42)
            answered.fulfill()
        }
        wait(for: [answered], timeout: 5)
    }

    func testTheMainThreadQueryGivesUpWhenTheMainThreadIsBusy() {
        // The main thread is blocked below until the background query returns, so the query
        // can't run in time: nil, which the occlusion check treats as covered.
        let result = Box()
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            result.value = MainThreadQuery.run(timeout: 0.05) { 1 }
            finished.signal()
        }
        XCTAssertEqual(finished.wait(timeout: .now() + 5), .success)
        XCTAssertNil(result.value)
    }

    private final class Box: @unchecked Sendable { var value: Int? }

    // MARK: The system Open/Save panel (QA 9000025: Chrome's upload chooser showed, took no presses)

    private let servicePID: Int32 = 9001
    private let sheet: UInt32 = 9318
    /// An untitled panel sheet of the target's app, as Chrome's upload chooser is, centred under its title bar.
    private let sheetFrame = CGRect(x: 476, y: 218, width: 547, height: 380)
    private let inSheet = CGPoint(x: 700, y: 400)

    private func service(_ id: UInt32, _ frame: CGRect, pid: Int32? = nil, layer: Int = 0, alpha: Double = 1) -> W {
        W(id: id, owner: "com.apple.appkit.xpc.openAndSavePanelService (Google Chrome)", layer: layer,
          bounds: frame, alpha: alpha, pid: pid ?? servicePID)
    }

    private func chromeSheet() -> W { W(id: sheet, owner: "Google Chrome", layer: 0, bounds: sheetFrame, alpha: 1, pid: 400) }

    /// The verdict with a panel-service check that knows only `servicePID`, and how often it was asked.
    private func panelVerdict(above: [W], sheets: Set<UInt32> = [], at point: CGPoint? = nil,
                              hit: UInt32? = nil) -> (WorkspaceInputCover.Verdict, Int) {
        var asked = 0
        let v = WorkspaceInputCover.verdict(
            target: target, targetFrame: targetFrame, at: point ?? inside, above: above, ownSheets: sheets,
            displays: [display], isFilePanelService: { asked += 1; return $0 == self.servicePID }, hitTest: { hit })
        return (v, asked)
    }

    func testThePanelServiceWindowOverAPanelShownInItsOwnPaneIsPartOfIt() {
        // The app's "Open" window is the target; the service's window sits directly on it.
        let (v, asked) = panelVerdict(above: [service(70, targetFrame)])
        XCTAssertEqual(v, .clear)
        XCTAssertEqual(asked, 1)
    }

    func testThePanelServiceWindowOverTheTargetsOwnSheetIsPartOfIt() {
        // Chrome: the browser window is the target, its untitled sheet is drawn in the pane, and
        // the service's window sits directly on the sheet.
        let (v, _) = panelVerdict(above: [service(70, sheetFrame), chromeSheet()], sheets: [sheet], at: inSheet)
        XCTAssertEqual(v, .clear)
    }

    func testWithoutThePanelServiceCheckTheSheetPressIsRefused() {
        // The QA 9000025 failure: the service window counted as a cover (the default check says never).
        let v = WorkspaceInputCover.verdict(target: target, targetFrame: targetFrame, at: inSheet,
                                            above: [service(70, sheetFrame), chromeSheet()],
                                            ownSheets: [sheet], displays: [display], hitTest: { nil })
        XCTAssertEqual(v, .covered(by: 70, cache: sheetFrame))
    }

    func testAPanelServiceWindowWithAnythingInBetweenStillCovers() {
        let between = W(id: 55, owner: "Notes", layer: 0, bounds: CGRect(x: 0, y: 0, width: 10, height: 10), alpha: 1)
        XCTAssertEqual(panelVerdict(above: [service(70, targetFrame), between]).0, .covered(by: 70, cache: targetFrame))
        XCTAssertEqual(panelVerdict(above: [service(70, sheetFrame), between, chromeSheet()], sheets: [sheet], at: inSheet).0,
                       .covered(by: 70, cache: sheetFrame))
    }

    func testAPanelServiceWindowOverAWindowThatIsntTheTargetsSheetStillCovers() {
        // Another app's panel over another app's window overlapping the target, or over a window
        // of the same frame as a sheet that isn't one of the target's sheets.
        let other = CGRect(x: 600, y: 300, width: 500, height: 400)
        let (v, asked) = panelVerdict(above: [service(70, other), W(id: 81, owner: "TextEdit", layer: 0, bounds: other, alpha: 1)])
        XCTAssertEqual(v, .covered(by: 70, cache: other))
        XCTAssertEqual(asked, 0, "the process isn't even looked up")
        XCTAssertEqual(panelVerdict(above: [service(70, sheetFrame), chromeSheet()], sheets: [], at: inSheet).0,
                       .covered(by: 70, cache: sheetFrame))
    }

    func testAPanelServiceWindowOfAnotherFrameStillCovers() {
        let off = targetFrame.offsetBy(dx: 2, dy: 0)
        let (v, asked) = panelVerdict(above: [service(70, off)])
        XCTAssertEqual(v, .covered(by: 70, cache: off))
        XCTAssertEqual(asked, 0)
        // Within a point is the same frame (the window server rounds).
        XCTAssertEqual(panelVerdict(above: [service(70, targetFrame.insetBy(dx: 0.5, dy: 0.5))]).0, .clear)
    }

    func testAWindowOfTheRightShapeFromAnotherProcessStillCovers() {
        // Same place, same layer, directly on the target: not the verified service, so a cover.
        let (v, asked) = panelVerdict(above: [service(70, targetFrame, pid: 666)])
        XCTAssertEqual(v, .covered(by: 70, cache: targetFrame))
        XCTAssertEqual(asked, 1)
    }

    func testThePanelServicesMenusAndHiddenOrUnnumberedWindowsStillCover() {
        // Its pop-up menus are above the normal layer; a hidden, unnumbered or ownerless window is never part of it.
        let menu = CGRect(x: 600, y: 300, width: 200, height: 300)
        XCTAssertEqual(panelVerdict(above: [service(71, menu, layer: 101), service(70, targetFrame)], at: CGPoint(x: 650, y: 350)).0,
                       .covered(by: 71, cache: menu))
        XCTAssertEqual(panelVerdict(above: [service(0, targetFrame)]).0, .covered(by: 0, cache: targetFrame))
        XCTAssertEqual(panelVerdict(above: [service(70, targetFrame, pid: -1)]).0, .covered(by: 70, cache: targetFrame))
        // Transparent: not a cover, and not part of the target either (the press goes by the rest).
        XCTAssertEqual(panelVerdict(above: [service(70, targetFrame, alpha: 0)]).1, 0)
    }

    func testAWindowOverThePanelStillCovers() {
        // A notification banner over the panel: the panel is part of the target, the banner isn't.
        let banner = W(id: 90, owner: "NotificationCenter", layer: 0, bounds: CGRect(x: 650, y: 350, width: 300, height: 80), alpha: 1)
        let (v, _) = panelVerdict(above: [banner, service(70, targetFrame)], at: CGPoint(x: 700, y: 380))
        XCTAssertEqual(v, .covered(by: 90, cache: banner.bounds))
    }

    func testUnderTheDockTheWindowServerMayHitThePanelServiceWindow() {
        XCTAssertEqual(panelVerdict(above: [dock, service(70, targetFrame)], hit: 70).0, .clear)
        XCTAssertEqual(panelVerdict(above: [dock, service(70, targetFrame)], hit: 27).0,
                       .covered(by: 27, cache: CGRect(x: 660, y: 360, width: 80, height: 80)))
    }

    func testOnlyAppKitsSealedPanelServiceExecutablePasses() {
        let suffix = "/XPCServices/com.apple.appkit.xpc.openAndSavePanelService.xpc/Contents/MacOS/com.apple.appkit.xpc.openAndSavePanelService"
        let real = "/System/Library/Frameworks/AppKit.framework/Versions/C" + suffix
        XCTAssertTrue(WorkspaceInputCover.isFilePanelServicePath(real))
        XCTAssertTrue(WorkspaceInputCover.isFilePanelServicePath("/System/Library/Frameworks/AppKit.framework/Versions/A" + suffix))
        for path in [
            "", "/Applications/Fake.app/Contents/MacOS/com.apple.appkit.xpc.openAndSavePanelService",
            "/System/Volumes/Data/Users/x/com.apple.appkit.xpc.openAndSavePanelService.xpc/Contents/MacOS/com.apple.appkit.xpc.openAndSavePanelService",
            "/System/Volumes/Data/System/Library/Frameworks/AppKit.framework/Versions/C" + suffix,
            "/System/Library/Frameworks/AppKit.framework/Versions/" + suffix,
            "/System/Library/Frameworks/AppKit.framework/Versions/.." + suffix,
            "/System/Library/Frameworks/AppKit.framework/Versions/C/../../../../Users/x" + suffix,
            real + "-copy", real.uppercased(),
        ] {
            XCTAssertFalse(WorkspaceInputCover.isFilePanelServicePath(path), path)
        }
    }

    func testTheSignatureRequirementParsesAndOtherProcessesFailIt() {
        var requirement: SecRequirement?
        XCTAssertEqual(SecRequirementCreateWithString(WorkspaceInputCover.filePanelServiceRequirement as CFString, [], &requirement),
                       errSecSuccess)
        // This test process isn't the panel service; nor are pids that name no process.
        XCTAssertFalse(WindowWorkspaceEngine.isFilePanelService(ProcessInfo.processInfo.processIdentifier))
        XCTAssertFalse(WindowWorkspaceEngine.isFilePanelService(0))
        XCTAssertFalse(WindowWorkspaceEngine.isFilePanelService(-1))
        XCTAssertFalse(WindowWorkspaceEngine.isFilePanelService(1), "launchd is Apple's, but not the panel service")
    }
}

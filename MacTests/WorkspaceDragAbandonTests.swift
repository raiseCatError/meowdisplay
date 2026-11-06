import XCTest

/// A drag from Stage Peek's search whose gesture lost its end left the icon frozen in Floating
/// placement (owner, QA 9000024, IMG_2307/2308). `abandonDrag` (called by the iOS
/// `WorkspaceDragGuard` when no finger is down, on leaving the foreground or turning) undoes any
/// drag as a cancel; a window that closed while dragged is never placed.
@MainActor
final class WorkspaceDragAbandonTests: XCTestCase {
    private var sent: [[String: Any]] = []

    private func catalog(_ windows: [(UInt32, UInt64, String)]) -> WorkspaceEvent {
        WorkspaceEvent.parse(type: WireMessage.windowCatalog, [
            "type": WireMessage.windowCatalog, "host": "mac-a",
            "windows": windows.map { ["id": Int($0.0), "gen": Int($0.1), "bundle": $0.2, "app": $0.2, "title": "t\($0.0)",
                                      "w": 800, "h": 600, "state": "visible"] },
            "apps": [],
        ])!
    }

    private func model() -> WorkspaceModel {
        let m = WorkspaceModel(defaults: UserDefaults(suiteName: "WorkspaceDragAbandonTests-\(UUID().uuidString)")!)
        m.floatsDrawnHere = true
        m.send = { [unowned self] in self.sent.append($0); return true }
        m.inputAllowed = { true }
        m.apply(.connected(peerID: "mac-a"))
        m.apply(.features([WindowWorkspaceWire.welcomeFeature, WindowWorkspaceWire.floatFeature]))
        m.apply(.mode(window: true))
        m.updateSpace(WorkspaceSize(width: 400, height: 800), hinge: nil)
        m.pictureGlobal = CGRect(x: 0, y: 0, width: 400, height: 800)
        m.apply(catalog([(10, 1, "dev.zed.Zed"), (11, 1, "com.apple.Safari")]))
        m.choose(m.catalog!.windows[0], asNewTile: false)
        return m
    }

    func testAbandonedWindowDragChangesNothingInEitherPlacement() {
        let m = model()
        let before = m.layout
        for float in [false, true] {
            m.beginDrag(.window(m.catalog!.windows[1]), at: CGPoint(x: 200, y: 400))
            if float { XCTAssertTrue(m.toggleDragPlacement() || m.drag?.placement == .float) }
            m.moveDrag(to: CGPoint(x: 200, y: 780))
            m.abandonDrag(reason: "no finger down")
            XCTAssertNil(m.drag, "no preview or placement chip left (float: \(float))")
            XCTAssertEqual(m.placementSwitchProgress, 0)
            XCTAssertEqual(m.layout, before)
        }
        m.abandonDrag(reason: "nothing on")   // harmless when nothing is dragged
        XCTAssertEqual(m.layout, before)
    }

    func testAbandonedAppDragAsksNothingAndOpensNothing() {
        let m = model()
        let app = MacAppItem(bundleID: "com.apple.Notes", name: "Notes", running: false, windowCount: 0, lastUsed: nil)
        m.beginDrag(.app(app), at: CGPoint(x: 200, y: 400))
        m.moveDrag(to: CGPoint(x: 200, y: 780))
        m.abandonDrag(reason: "left the foreground")
        XCTAssertNil(m.drag)
        XCTAssertNil(m.appDrop, "no open offer for a drag that never ended")
        XCTAssertFalse(sent.contains { $0["type"] as? String == WireMessage.appLaunch })
    }

    /// The dragged window closed on the Mac before the drop: nothing is placed.
    func testAWindowClosedWhileDraggedIsNotPlaced() {
        let m = model()
        let safari = m.catalog!.windows[1]
        let before = m.layout
        m.beginDrag(.window(safari), at: CGPoint(x: 200, y: 400))
        m.moveDrag(to: CGPoint(x: 200, y: 780))
        XCTAssertNotNil(m.dropTarget(forGlobal: CGPoint(x: 200, y: 780)))
        m.apply(catalog([(10, 1, "dev.zed.Zed")]))
        XCTAssertFalse(m.endDrag())
        XCTAssertEqual(m.layout, before)
        // Its id reused by another window (a new generation): still not placed.
        m.apply(catalog([(10, 1, "dev.zed.Zed"), (11, 2, "com.apple.TextEdit")]))
        m.beginDrag(.window(safari), at: CGPoint(x: 200, y: 400))
        m.moveDrag(to: CGPoint(x: 200, y: 780))
        XCTAssertFalse(m.endDrag())
        XCTAssertEqual(m.layout, before)
    }
}

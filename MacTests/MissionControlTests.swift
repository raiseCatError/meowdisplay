import XCTest

/// Mission Control on the Mac (2026-10-31, macOS 27): macOS pauses every window capture while it
/// is open. Panes wait without restarts, devices say why, and Exit Mission Control needs control
/// and is only sent when the Mac confirms it is open.
@MainActor
final class MissionControlTests: XCTestCase {
    // MARK: Mac: no restart loop while it is open

    func testPausedPanesWaitWhileMissionControlIsOpen() {
        // Paused for 8 s although listed on the stage: normally one fresh stream.
        XCTAssertEqual(TileCaptureWatch.verdict(now: 10, startedAt: 0, firstCompleteAt: 1, suspendedSince: 2,
                                                sourceLooksAvailable: true, missionControlOpen: false), .stalled)
        XCTAssertEqual(TileCaptureWatch.verdict(now: 10, startedAt: 0, firstCompleteAt: 1, suspendedSince: 2,
                                                sourceLooksAvailable: true, missionControlOpen: true), .paused)
    }

    func testAStreamStartedDuringMissionControlIsNotStuck() {
        XCTAssertEqual(TileCaptureWatch.verdict(now: 10, startedAt: 0, firstCompleteAt: nil, suspendedSince: nil,
                                                sourceLooksAvailable: true, missionControlOpen: false), .stalled)
        XCTAssertEqual(TileCaptureWatch.verdict(now: 10, startedAt: 0, firstCompleteAt: nil, suspendedSince: nil,
                                                sourceLooksAvailable: true, missionControlOpen: true), .paused)
    }

    func testAPaneStillSendingStaysLive() {
        // A whole-display pane keeps streaming (it shows Mission Control itself).
        XCTAssertEqual(TileCaptureWatch.verdict(now: 10, startedAt: 0, firstCompleteAt: 1, suspendedSince: nil,
                                                sourceLooksAvailable: true, missionControlOpen: true), .live)
    }

    func testOpeningAndClosingQuicklyNeverEscalates() {
        // Rapid open/close/open: every check while open is a wait; once closed the usual short
        // grace applies from the close (the engine restarts `suspendedSince` there).
        for open in [true, false, true, false] {
            let closedAt = 20.0
            let v = TileCaptureWatch.verdict(now: open ? 30 : closedAt + 0.5, startedAt: 0, firstCompleteAt: 1,
                                             suspendedSince: open ? 2 : closedAt, sourceLooksAvailable: true,
                                             missionControlOpen: open)
            XCTAssertEqual(v, .paused, "open=\(open)")
        }
        XCTAssertEqual(TileCaptureWatch.verdict(now: 22.5, startedAt: 0, firstCompleteAt: 1, suspendedSince: 20,
                                                sourceLooksAvailable: true, missionControlOpen: false), .stalled,
                       "still paused 2 s after it closed: one fresh stream")
    }

    // MARK: Mac: detection

    func testThePublicHintIsAWindowManagerOrDockWindowCoveringADisplay() {
        let displays = [CGRect(x: 0, y: 0, width: 1920, height: 1080), CGRect(x: 1920, y: 0, width: 1512, height: 982)]
        let wm: Int32 = 667, dock: Int32 = 765, other: Int32 = 900
        typealias W = MissionControlSignals.Window
        XCTAssertTrue(MissionControlSignals.coversADisplay(windows: [W(ownerPID: wm, bounds: displays[0])], owners: [wm, dock], displays: displays))
        XCTAssertTrue(MissionControlSignals.coversADisplay(windows: [W(ownerPID: dock, bounds: displays[1])], owners: [wm, dock], displays: displays))
        XCTAssertFalse(MissionControlSignals.coversADisplay(windows: [W(ownerPID: wm, bounds: CGRect(x: 10, y: 200, width: 180, height: 120))],
                                                            owners: [wm, dock], displays: displays), "a Stage Manager strip window")
        XCTAssertFalse(MissionControlSignals.coversADisplay(windows: [W(ownerPID: other, bounds: displays[0])], owners: [wm, dock], displays: displays),
                       "another app's full-screen window")
        XCTAssertFalse(MissionControlSignals.coversADisplay(windows: [], owners: [wm, dock], displays: displays))
    }

    // MARK: Devices

    private func state(missionControl: Bool, tiles: [(String, String)], active: String? = nil) -> WorkspaceEvent {
        var obj: [String: Any] = [
            "type": WireMessage.workspaceState, "host": "mac-a", "hostFocus": "noActiveTile",
            "tiles": tiles.enumerated().map { i, t in ["id": t.0, "window": 10 + i, "gen": 1, "state": t.1, "app": "Zed", "bundle": "dev.zed.Zed", "title": "t"] },
        ]
        if missionControl { obj["missionControl"] = "open" }
        if let active { obj["active"] = active }
        return WorkspaceEvent.parse(type: WireMessage.workspaceState, obj)!
    }

    private func model(_ sent: @escaping ([String: Any]) -> Void) -> WorkspaceModel {
        let m = WorkspaceModel(defaults: UserDefaults(suiteName: "MissionControlTests-\(UUID().uuidString)")!)
        m.send = { sent($0); return true }
        m.inputAllowed = { true }
        m.apply(.connected(peerID: "mac-a"))
        m.apply(.features([WindowWorkspaceWire.welcomeFeature]))
        m.apply(.mode(window: true))
        return m
    }

    func testTheStateSaysWhenMissionControlIsOpen() {
        guard case .state(let open) = state(missionControl: true, tiles: []) else { return XCTFail() }
        XCTAssertTrue(open.missionControlOpen)
        guard case .state(let closed) = state(missionControl: false, tiles: []) else { return XCTFail() }
        XCTAssertFalse(closed.missionControlOpen, "an older Mac never says it: nothing changes")
    }

    /// Window view on an iPad-sized screen: two window panes, a Full Desktop pane and a float.
    private func arranged(_ sent: @escaping ([String: Any]) -> Void)
        -> (m: WorkspaceModel, a: String, b: String, desktop: String, float: String) {
        let m = WorkspaceModel(defaults: UserDefaults(suiteName: "MissionControlTests-\(UUID().uuidString)")!)
        m.floatsDrawnHere = true   // the iPhone/iPad receiver (this test runs on the Mac)
        m.send = { sent($0); return true }
        m.inputAllowed = { true }
        m.apply(.connected(peerID: "mac-a"))
        m.apply(.features([WindowWorkspaceWire.welcomeFeature, WindowWorkspaceWire.floatFeature]))
        m.apply(.mode(window: true))
        m.apply(WorkspaceEvent.parse(type: WireMessage.windowCatalog, [
            "type": WireMessage.windowCatalog, "host": "mac-a",
            "windows": [10, 11, 12].map { ["id": $0, "gen": 5, "bundle": "app.\($0)", "app": "App\($0)", "title": "t", "w": 1600, "h": 1000, "state": "visible"] },
            "apps": [], "displays": [["id": 1, "name": "Built-in Display", "w": 1512, "h": 982, "main": true]],
        ])!)
        m.updateSpace(WorkspaceSize(width: 1180, height: 820), hinge: nil)
        let w = m.catalog!.windows
        m.choose(w[0], asNewTile: false)
        m.choose(m.displayWindow(m.catalog!.displays[0]), asNewTile: true)
        m.choose(w[1], asNewTile: true)
        m.openFloating(w[2])
        func tile(_ window: UInt32) -> String { m.layout.tiles.first { $0.value.source?.windowID == window }?.key ?? "missing \(window)" }
        return (m, tile(10), tile(11), tile(WorkspaceSource.displayKey(1)), tile(12))
    }

    /// Only the windows Mission Control pauses get its notice: never Full Desktop (it keeps showing
    /// the Mac's screen, Mission Control and all, 2026-11-06 iPhone QA), never a live window, nothing
    /// when it's closed or outside Window view. A float gets it like a pane.
    func testOnlyTheWindowsItPausesGetTheNotice() {
        let (m, a, b, desktop, f) = arranged { _ in }
        XCTAssertEqual(m.layout.floatIDs, [f])
        XCTAssertEqual(Set([a, b, desktop, f]).count, 4, "\(m.layout.tiles.keys)")
        m.apply(state(missionControl: true, tiles: [(a, "paused"), (b, "live"), (desktop, "live"), (f, "paused")]))
        XCTAssertEqual(m.missionControlNotice(a), .full)
        XCTAssertEqual(m.missionControlNotice(f), .full, "a float too")
        XCTAssertNil(m.missionControlNotice(b), "a live window shows its picture")
        XCTAssertNil(m.missionControlNotice(desktop), "Full Desktop shows Mission Control itself")

        // Waiting or retrying while it's open: held by Mission Control too. A display never is.
        m.apply(state(missionControl: true, tiles: [(a, "waiting"), (b, "retrying"), (desktop, "paused"), (f, "offscreen")]))
        XCTAssertTrue(m.missionControlPaused(a))
        XCTAssertTrue(m.missionControlPaused(b))
        XCTAssertFalse(m.missionControlPaused(desktop))
        XCTAssertFalse(m.missionControlPaused(f), "minimized: its own notice, not Mission Control's")
        for s in ["closed", "failed", "limit", "live"] {
            m.apply(state(missionControl: true, tiles: [(a, s)]))
            XCTAssertNil(m.missionControlNotice(a), s)
        }
        XCTAssertNil(m.missionControlNotice("nope"), "not a tile here")

        m.apply(state(missionControl: false, tiles: [(a, "paused"), (f, "paused")]))
        XCTAssertNil(m.missionControlNotice(a), "closed: a paused window is macOS's usual pause")
        XCTAssertNil(m.missionControlNotice(f))

        m.apply(state(missionControl: true, tiles: [(a, "paused")]))
        XCTAssertNotNil(m.missionControlNotice(a))
        m.apply(.mode(window: false))
        XCTAssertNil(m.missionControlNotice(a), "Mirror/Extend: no Window view, nothing to say")
        XCTAssertNil(m.missionControlAction)
    }

    /// The × only folds the notice on this device: a small status stays, nothing is sent and
    /// Mission Control stays open. Per window; tapping the status brings it back, and closing
    /// Mission Control (or the session ending) forgets every fold.
    func testTheNoticeFoldsHereOnlyUntilMissionControlCloses() {
        var sent: [[String: Any]] = []
        var requested = 0
        let (m, a, b, desktop, f) = arranged { sent.append($0) }
        m.requestControl = { requested += 1 }
        m.controlState = { .allowed }
        m.apply(state(missionControl: true, tiles: [(a, "paused"), (b, "paused"), (desktop, "live"), (f, "paused")]))
        sent.removeAll()
        m.foldMissionControlNotice(a)
        m.foldMissionControlNotice(f)
        m.foldMissionControlNotice(desktop)
        XCTAssertEqual(m.missionControlNotice(a), .folded)
        XCTAssertEqual(m.missionControlNotice(f), .folded)
        XCTAssertEqual(m.missionControlNotice(b), .full, "per window")
        XCTAssertEqual(m.missionControlFolded, [a, f], "nothing to fold where there's no notice")
        XCTAssertTrue(sent.isEmpty, "folding sends nothing, never an Escape: \(sent)")
        XCTAssertEqual(requested, 0)
        XCTAssertTrue(m.missionControlPaused(a), "the true state stays")
        XCTAssertEqual(m.missionControlAction, .exit, "the way out is still offered")

        m.unfoldMissionControlNotice(f)
        XCTAssertEqual(m.missionControlNotice(f), .full, "the status tapped: the notice again")

        // Still open (the Mac's next state): it stays folded.
        m.apply(state(missionControl: true, tiles: [(a, "waiting"), (b, "paused"), (desktop, "live"), (f, "paused")]))
        XCTAssertEqual(m.missionControlNotice(a), .folded)

        // Closed: every fold is forgotten; the next time it opens, the notice is back in full.
        m.apply(state(missionControl: false, tiles: [(a, "live"), (b, "live"), (desktop, "live"), (f, "live")]))
        XCTAssertTrue(m.missionControlFolded.isEmpty)
        m.apply(state(missionControl: true, tiles: [(a, "paused")]))
        XCTAssertEqual(m.missionControlNotice(a), .full)

        m.foldMissionControlNotice(a)
        m.apply(.disconnected)
        XCTAssertTrue(m.missionControlFolded.isEmpty, "a new session starts unfolded")
        // (Live panes ask for their stills as usual; never a window action.)
        XCTAssertFalse(sent.contains { $0["type"] as? String == WireMessage.windowAction }, "\(sent)")
    }

    /// A float's notice sits on the part of it that shows, fits a phone-sized float, and steps
    /// aside when a float in front covers its spot (that float hides it, as it hides the window).
    func testAFloatsNoticeSitsOnItsWindowUnlessAFloatInFrontCoversIt() {
        let screen = CGRect(x: 0, y: 59, width: 430, height: 839)   // iPhone 14 Pro Max, portrait safe area
        let back = CGRect(x: 20, y: 200, width: 220, height: 180)
        let spot = WorkspaceModel.missionControlNoticeSpot(on: back, folded: false, within: screen, inFront: [])
        XCTAssertEqual(spot?.midX, back.midX)
        XCTAssertEqual(spot?.midY, back.midY)
        XCTAssertLessThanOrEqual(spot?.width ?? .infinity, back.width, "fits a phone-sized float")

        let over = CGRect(x: 150, y: 260, width: 220, height: 180)
        XCTAssertNil(WorkspaceModel.missionControlNoticeSpot(on: back, folded: false, within: screen, inFront: [over]))
        XCTAssertNotNil(WorkspaceModel.missionControlNoticeSpot(on: back, folded: false, within: screen,
                                                                inFront: [CGRect(x: 250, y: 500, width: 160, height: 120)]))

        // Partly past the edge: centred on what shows. Folded: just the small status.
        let off = CGRect(x: -100, y: 300, width: 260, height: 200)
        let folded = WorkspaceModel.missionControlNoticeSpot(on: off, folded: true, within: screen, inFront: [])
        XCTAssertEqual(folded?.midX ?? 0, 80, accuracy: 0.01)
        XCTAssertEqual(folded?.height, 30)
    }

    /// What a paused window's notice offers is the one thing this device can do, whatever is
    /// paused or selected (a float included); its pane's menu and accessibility action offer the same.
    func testTheNoticeOffersTheOneThingThisDeviceCanDo() {
        var sent: [[String: Any]] = []
        var requested = 0
        let m = model { sent.append($0) }
        m.requestControl = { requested += 1 }
        m.apply(state(missionControl: false, tiles: [("a", "paused")]))
        XCTAssertNil(m.missionControlAction, "closed: nothing offered")

        // A float is the only paused tile (it used to get no button at all).
        m.apply(state(missionControl: true, tiles: [("a", "live"), ("f", "paused")], active: "f"))
        m.controlState = { .allowed }
        XCTAssertEqual(m.missionControlAction, .exit)
        m.performMissionControlAction()
        XCTAssertEqual(sent.filter { $0["action"] as? String == "missionControl" }.count, 1)

        let expected: [(SessionInputWireState, WorkspaceModel.MissionControlAction)] =
            [(.off, .requestControl), (.notAllowed, .requestControl), (.requesting, .awaitingApproval), (.requestsDisabled, .closeOnMac)]
        for (s, action) in expected {
            m.controlState = { s }
            XCTAssertEqual(m.missionControlAction, action, "\(s)")
            m.performMissionControlAction()
        }
        XCTAssertEqual(requested, 2, "Request Control only from off and declined, once each")
        XCTAssertEqual(sent.filter { $0["action"] as? String == "missionControl" }.count, 1, "never an Exit (Escape) without control")
    }

    func testExitNeedsTheMacsGrantAndIsOneRequest() {
        var sent: [[String: Any]] = []
        let m = model { sent.append($0) }
        m.apply(state(missionControl: true, tiles: [("a", "paused")]))
        for s: SessionInputWireState in [.off, .requesting, .notAllowed, .requestsDisabled] {
            m.controlState = { s }
            m.exitMissionControl()
        }
        XCTAssertFalse(sent.contains { $0["action"] as? String == "missionControl" }, "View Only sends nothing")
        m.controlState = { .allowed }
        m.exitMissionControl()
        let exits = sent.filter { $0["action"] as? String == "missionControl" }
        XCTAssertEqual(exits.count, 1)
        XCTAssertEqual(exits.first?["type"] as? String, WireMessage.windowAction)
        XCTAssertEqual(exits.first?["exit"] as? Bool, true)
        m.apply(state(missionControl: false, tiles: [("a", "live")]))
        m.exitMissionControl()
        XCTAssertEqual(sent.filter { $0["action"] as? String == "missionControl" }.count, 1, "closed: nothing to exit")
    }
}

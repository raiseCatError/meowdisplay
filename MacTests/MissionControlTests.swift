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

    func testOnePaneOffersExitPreferringTheSelectedOne() {
        let m = model { _ in }
        m.apply(state(missionControl: true, tiles: [("a", "paused"), ("b", "paused")], active: "b"))
        XCTAssertEqual(m.missionControlActionPane, "b")
        m.apply(state(missionControl: true, tiles: [("a", "paused"), ("b", "live")], active: "b"))
        XCTAssertEqual(m.missionControlActionPane, "a", "the selected pane still shows a picture")
        m.apply(state(missionControl: false, tiles: [("a", "paused"), ("b", "paused")], active: "b"))
        XCTAssertNil(m.missionControlActionPane, "closed: nothing offered")
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

import XCTest

/// Open Fullscreen (#287): the opening's fullscreen-on-place intent and the session that keeps
/// what showed before (Shared/WorkspaceAppOpening.swift), pure.
final class WorkspaceAppFirstOpeningTests: XCTestCase {
    private let zed = "dev.zed.Zed"

    private func window(_ id: UInt32, _ bundle: String, gen: UInt64 = 1) -> CatalogWindowItem {
        CatalogWindowItem(id: id, generation: gen, bundleID: bundle, app: bundle, title: "t\(id)", width: 800, height: 600,
                          minimized: false, active: false)
    }

    private func start(_ windows: [CatalogWindowItem], control: WorkspaceAppOpening.Control = .allowed,
                       reveal: Bool = false) -> (WorkspaceAppOpening, WorkspaceAppOpening.Step) {
        WorkspaceAppOpening.startFullscreen(bundleID: zed, name: "Zed", reveal: reveal, control: control, windows: windows, now: 0)
    }

    /// A running app with one window: placed at once (no launch, no control needed), and the
    /// placement carries the fullscreen intent.
    func testOneWindowIsPlacedAtOnceWithoutControl() {
        let w = window(10, zed)
        let (o, step) = start([w, window(11, "com.apple.Safari")], control: .off)
        XCTAssertEqual(step, .place(w))
        XCTAssertEqual(o.phase, .placed(w))
        XCTAssertTrue(o.fullscreenOnPlace)
        XCTAssertTrue(o.showsOverLayout, "shown over the layout, not in the picker")
        XCTAssertNil(o.tile)
    }

    /// Several windows: the person picks (never chosen here); the pick is placed with the intent.
    func testSeveralWindowsAskThenThePickIsPlaced() {
        let a = window(10, zed), b = window(12, zed)
        let started = start([a, b])
        var o = started.0
        XCTAssertEqual(started.1, .choose([a, b]))
        XCTAssertTrue(o.attached, "nothing was launched")
        XCTAssertEqual(o.pick(12, generation: 1, windows: [a, b], tileUnchanged: true), .place(b))
        XCTAssertEqual(o.phase, .placed(b))
        XCTAssertTrue(o.fullscreenOnPlace)
    }

    /// One of the windows closes while the person decides: the choice follows the listing; the
    /// last one gone ends it as no window.
    func testTheChoiceFollowsTheListingAndEndsWhenNoneIsLeft() {
        let a = window(10, zed), b = window(12, zed)
        var o = start([a, b]).0
        XCTAssertEqual(o.advance(windows: [b], now: 1, control: .allowed, tileUnchanged: true), .choose([b]))
        XCTAssertEqual(o.advance(windows: [], now: 2, control: .allowed, tileUnchanged: true), .fail(.noWindow))
    }

    /// Not running: launched with control, then its new window (after the settle) is placed.
    func testNotRunningLaunchesThenPlacesItsNewWindow() {
        let other = window(11, "com.apple.Safari")
        let started = start([other])
        var o = started.0
        XCTAssertEqual(started.1, .launch)
        XCTAssertTrue(o.isWaiting)
        XCTAssertEqual(o.launchAnswered(ok: true, now: 1), .none)
        let new = window(20, zed)
        XCTAssertEqual(o.advance(windows: [other, new], now: 2, control: .allowed, tileUnchanged: true), .none, "waits for siblings")
        XCTAssertEqual(o.advance(windows: [other, new], now: 2 + WorkspaceAppOpening.settle, control: .allowed, tileUnchanged: true),
                       .place(new))
        XCTAssertTrue(o.fullscreenOnPlace)
    }

    /// Control not granted and nothing to attach: it fails at once and never launches or asks for
    /// control itself (the Request Control row stays the way); no Request Control Again either.
    func testWithoutControlAndNoWindowItFailsWithoutLaunching() {
        for control in [WorkspaceAppOpening.Control.off, .requesting, .denied, .refused] {
            let (o, step) = start([], control: control)
            XCTAssertEqual(step, .fail(.controlDenied), "\(control)")
            XCTAssertEqual(o.phase, .failed(.controlDenied))
            XCTAssertFalse(o.offersRetry)
        }
    }

    func testLaunchFailureIsRetryable() {
        var o = start([]).0
        XCTAssertEqual(o.launchAnswered(ok: false, now: 1), .fail(.launchFailed))
        XCTAssertTrue(o.offersRetry)
    }

    func testNoAnswerInTimeFails() {
        var o = start([]).0
        XCTAssertEqual(o.advance(windows: [], now: WorkspaceAppOpening.answerTimeout - 1, control: .allowed, tileUnchanged: true), .none)
        XCTAssertEqual(o.advance(windows: [], now: WorkspaceAppOpening.answerTimeout, control: .allowed, tileUnchanged: true),
                       .fail(.noAnswer))
        XCTAssertTrue(o.offersRetry)
    }

    func testNoWindowAppearingInTimeFails() {
        var o = start([]).0
        _ = o.launchAnswered(ok: true, now: 1)
        XCTAssertEqual(o.advance(windows: [], now: 1 + WorkspaceAppOpening.windowTimeout, control: .allowed, tileUnchanged: true),
                       .fail(.noWindow))
        XCTAssertTrue(o.offersRetry, "Show a Window on Mac")
    }

    /// Running without a window and a background open gave it none: no point waiting, unless
    /// the retry asked the Mac to bring the app forward.
    func testRunningWithoutAWindowFailsAsNoWindowUnlessRevealed() {
        var o = start([]).0
        XCTAssertEqual(o.launchAnswered(ok: true, window: false, now: 1), .fail(.noWindow))
        var r = start([], reveal: true).0
        XCTAssertEqual(r.launchAnswered(ok: true, window: false, now: 1), .none)
    }

    /// Control ends before the Mac answered: it stops, and doesn't offer to request control.
    func testControlEndingBeforeTheAnswerFailsWithoutRequestControlAgain() {
        var o = start([]).0
        XCTAssertEqual(o.advance(windows: [], now: 1, control: .off, tileUnchanged: true), .fail(.controlEnded))
        XCTAssertFalse(o.offersRetry)
    }

    func testSessionEndingOrTheMacLockingMidOpenFails() {
        var o = start([]).0
        XCTAssertEqual(o.disconnected(), .fail(.disconnected))
        XCTAssertFalse(o.offersRetry)
        var l = start([]).0
        XCTAssertEqual(l.macLocked(), .fail(.macLocked))
    }

    /// The picker's openings are unchanged: no intent, shown in the picker, and Request Control
    /// Again still offered after control ended.
    func testOtherOpeningsCarryNoFullscreenIntent() {
        var (o, _) = WorkspaceAppOpening.start(bundleID: zed, name: "Zed", tile: nil, tileSource: nil, control: .allowed, windows: [], now: 0)
        XCTAssertFalse(o.fullscreenOnPlace)
        XCTAssertFalse(o.showsOverLayout)
        _ = o.advance(windows: [], now: 1, control: .off, tileUnchanged: true)
        XCTAssertEqual(o.phase, .failed(.controlEnded))
        XCTAssertTrue(o.offersRetry)
    }

    // MARK: WorkspaceAppFirst

    private func layout(_ ids: [String]) -> WorkspaceLayout {
        WorkspaceLayout(preset: ids.count == 1 ? .single : .natural(for: ids.count, landscape: false),
                        tiles: ids.map { WorkspaceTile(id: $0, source: WorkspaceSource(host: "mac-a", windowID: 1)) })
    }

    func testPreviousIsWindowViewOrTheModeItLeft() {
        let l = layout(["w1"])
        XCTAssertEqual(WorkspaceAppFirst.Previous.current(layout: l, fullscreen: "w1", windowMode: true, extending: false, mirroring: true),
                       WorkspaceAppFirst.Previous(layout: l, fullscreen: "w1", mode: nil))
        XCTAssertEqual(WorkspaceAppFirst.Previous.current(layout: l, fullscreen: "w1", windowMode: false, extending: false, mirroring: true),
                       WorkspaceAppFirst.Previous(layout: l, fullscreen: nil, mode: .mirror))
        XCTAssertEqual(WorkspaceAppFirst.Previous.current(layout: l, fullscreen: nil, windowMode: false, extending: true, mirroring: false),
                       WorkspaceAppFirst.Previous(layout: l, fullscreen: nil, mode: .extend))
        XCTAssertNil(WorkspaceAppFirst.Previous.current(layout: l, fullscreen: nil, windowMode: false, extending: false, mirroring: false).mode)
    }

    /// Another app opened fullscreen from one still showing (or one that ended) keeps the first
    /// "before"; one left by other means, or from another Mac, doesn't.
    func testANewSessionCarriesTheFirstPrevious() {
        let first = WorkspaceAppFirst.Previous(layout: layout(["w1", "w2"]), fullscreen: nil, mode: .mirror)
        let now = WorkspaceAppFirst.Previous(layout: layout(["w9"]), fullscreen: "w9", mode: nil)
        let a = WorkspaceAppFirst.begin(host: "mac-a", bundleID: "a", name: "A", tile: "w9", continuing: nil, fullscreen: nil, previous: first)
        XCTAssertEqual(a.previous, first)
        let b = WorkspaceAppFirst.begin(host: "mac-a", bundleID: "b", name: "B", tile: "w10", continuing: a, fullscreen: "w9", previous: now)
        XCTAssertEqual(b.previous, first, "Exit goes back to before the first")
        let stale = WorkspaceAppFirst.begin(host: "mac-a", bundleID: "b", name: "B", tile: "w10", continuing: a, fullscreen: nil, previous: now)
        XCTAssertEqual(stale.previous, now, "its fullscreen was left another way")
        let otherMac = WorkspaceAppFirst.begin(host: "mac-b", bundleID: "b", name: "B", tile: "w10", continuing: a, fullscreen: "w9", previous: now)
        XCTAssertEqual(otherMac.previous, now)
        var ended = a
        XCTAssertTrue(ended.windowsClosed(emptied: ["w9"], removed: [], fullscreen: "w9", appRunning: true))
        let reopened = WorkspaceAppFirst.begin(host: "mac-a", bundleID: "a", name: "A", tile: "w11", continuing: ended, fullscreen: nil, previous: now)
        XCTAssertEqual(reopened.previous, first)
    }

    func testItsWindowClosingEndsItAndSaysWhetherTheAppQuit() {
        let p = WorkspaceAppFirst.Previous(layout: layout(["w1"]), fullscreen: nil, mode: nil)
        var s = WorkspaceAppFirst.begin(host: "mac-a", bundleID: zed, name: "Zed", tile: "w5", continuing: nil, fullscreen: nil, previous: p)
        XCTAssertTrue(s.isCurrent(fullscreen: "w5"))
        XCTAssertFalse(s.windowsClosed(emptied: ["w1"], removed: [], fullscreen: "w5", appRunning: true), "another pane")
        XCTAssertFalse(s.windowsClosed(emptied: ["w5"], removed: [], fullscreen: nil, appRunning: true), "not fullscreen any more")
        XCTAssertNil(s.ended)
        XCTAssertTrue(s.windowsClosed(emptied: ["w5"], removed: [], fullscreen: "w5", appRunning: true))
        XCTAssertEqual(s.ended, .windowClosed)
        XCTAssertFalse(s.isCurrent(fullscreen: "w5"))
        XCTAssertFalse(s.listed(running: [CatalogAppItem(bundleID: zed, name: "Zed", hasWindows: false)]))
        XCTAssertEqual(s.ended, .windowClosed)
        XCTAssertTrue(s.listed(running: []))
        XCTAssertEqual(s.ended, .appQuit)

        var q = WorkspaceAppFirst.begin(host: "mac-a", bundleID: zed, name: "Zed", tile: "w5", continuing: nil, fullscreen: nil, previous: p)
        XCTAssertTrue(q.windowsClosed(emptied: [], removed: ["w5"], fullscreen: "w5", appRunning: false))
        XCTAssertEqual(q.ended, .appQuit)
    }

    func testTheInputNoteShowsOncePerInstall() {
        let d = UserDefaults(suiteName: "WorkspaceAppFirstOpeningTests-\(UUID().uuidString)")!
        XCTAssertTrue(WorkspaceAppFirst.takeInputNote(d))
        XCTAssertFalse(WorkspaceAppFirst.takeInputNote(d))
    }
}

/// Open Fullscreen through the model: attach or open, fullscreen alone, Exit restores what was
/// there, from Window view, Mirror and Extend; its window closing ends it honestly.
@MainActor
final class WorkspaceAppFirstModelTests: XCTestCase {
    private var sent: [[String: Any]] = []
    private var now: TimeInterval = 100
    private var control: SessionInputWireState = .allowed
    private var controlRequests = 0
    private var windowModeRequests = 0
    private var modeRequests: [ReceiverDisplayMode] = []
    private var mirroring = false
    private var extending = false

    private let zedApp = MacAppItem(bundleID: "dev.zed.Zed", name: "Zed", running: true, windowCount: 1, lastUsed: nil)
    private let notes = MacAppItem(bundleID: "com.apple.Notes", name: "Notes", running: false, windowCount: 0, lastUsed: nil)
    private let base: [UInt32: String] = [10: "dev.zed.Zed", 11: "com.apple.Safari", 12: "com.apple.Terminal"]
    private let running = ["dev.zed.Zed", "com.apple.Safari", "com.apple.Terminal"]

    private func catalog(_ windows: [UInt32: String], running: [String]) -> WorkspaceEvent {
        WorkspaceEvent.parse(type: WireMessage.windowCatalog, [
            "type": WireMessage.windowCatalog, "host": "mac-a",
            "windows": windows.keys.sorted().map { ["id": Int($0), "gen": 1, "bundle": windows[$0]!, "app": windows[$0]!, "title": "t\($0)",
                                                     "w": 800, "h": 600, "state": "visible"] },
            "apps": running.map { ["bundle": $0, "name": $0, "windows": windows.values.contains($0)] },
        ])!
    }

    private func gone(_ ids: [UInt32]) -> WorkspaceEvent {
        WorkspaceEvent.parse(type: WireMessage.workspaceState, [
            "type": WireMessage.workspaceState, "host": "mac-a", "tiles": [], "hostFocus": "deliver",
            "gone": ids.map { ["window": Int($0), "gen": 1] },
        ])!
    }

    /// Connected and listed; `windowMode`: Window view with Safari and Terminal in two panes.
    private var defaults = UserDefaults.standard

    private func wire(_ m: WorkspaceModel) {
        m.send = { [unowned self] in self.sent.append($0); return true }
        m.inputAllowed = { true }
        m.controlState = { [unowned self] in self.control }
        m.requestControl = { [unowned self] in self.controlRequests += 1 }
        m.requestWindowMode = { [unowned self] in self.windowModeRequests += 1 }
        m.requestDisplayMode = { [unowned self] in self.modeRequests.append($0); return true }
        m.mirroring = { [unowned self] in self.mirroring }
        m.extending = { [unowned self] in self.extending }
        m.clock = { [unowned self] in self.now }
    }

    /// The layout this device saved for `host`, by window.
    private func persisted(_ host: String = "mac-a") -> [String: UInt32] {
        let l = defaults.data(forKey: "workspace.layout.\(host)").flatMap(WorkspaceLayoutRecord.decode) ?? WorkspaceLayout()
        return l.tiles.compactMapValues { $0.source?.windowID }
    }

    private func model(windowMode: Bool = true) -> WorkspaceModel {
        defaults = UserDefaults(suiteName: "WorkspaceAppFirstModelTests-\(UUID().uuidString)")!
        let m = WorkspaceModel(defaults: defaults)
        wire(m)
        m.apply(.connected(peerID: "mac-a"))
        m.apply(.features([WindowWorkspaceWire.welcomeFeature]))
        m.updateSpace(WorkspaceSize(width: 400, height: 800), hinge: nil)
        if windowMode { m.apply(.mode(window: true)) }
        m.apply(catalog(base, running: running))
        if windowMode {
            m.choose(m.catalog!.windows.first { $0.id == 11 }!, asNewTile: false)
            m.choose(m.catalog!.windows.first { $0.id == 12 }!, asNewTile: true)
        }
        sent.removeAll()
        windowModeRequests = 0
        return m
    }

    private func shown(_ m: WorkspaceModel) -> [String: UInt32] { m.layout.tiles.compactMapValues { $0.source?.windowID } }

    private func launches() -> [String] {
        sent.filter { $0["type"] as? String == WireMessage.appLaunch }.compactMap { $0["bundle"] as? String }
    }

    private func notesOpens(_ m: WorkspaceModel, windows: [UInt32] = [20]) {
        m.apply(.launchResult(bundleID: "com.apple.Notes", ok: true))
        now += 1
        var listed = base
        for id in windows { listed[id] = "com.apple.Notes" }
        m.apply(catalog(listed, running: running + ["com.apple.Notes"]))
        now += WorkspaceAppOpening.settle
        m.advanceAppOpening()
    }

    /// Only `id` shows, in one pane, fullscreen on this device as Open Fullscreen's pane.
    private func assertAlone(_ m: WorkspaceModel, _ id: UInt32, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(Array(shown(m).values), [id], file: file, line: line)
        XCTAssertEqual(m.layout.tiles.count, 1, file: file, line: line)
        XCTAssertNotNil(m.localFullscreen, file: file, line: line)
        XCTAssertEqual(m.localFullscreen, m.appFirst?.tile, file: file, line: line)
    }

    /// Window view, running app with one window: alone and fullscreen at once; Exit Fullscreen
    /// brings back the two panes as they were, and the pane that was fullscreen.
    func testFromWindowViewOneWindowGoesFullscreenAndExitRestoresThePanes() {
        let m = model()
        let before = shown(m)
        XCTAssertEqual(before.count, 2)
        m.enterLocalFullscreen(before.first { $0.value == 11 }!.key)
        let fullBefore = m.localFullscreen
        let closes = m.stagePeekCloseRequest
        XCTAssertTrue(m.canOpenFullscreen(zedApp))
        m.openAppFullscreen(zedApp)
        assertAlone(m, 10)
        XCTAssertNil(m.appOpening)
        XCTAssertEqual(launches(), [], "a window it has is used; nothing launched")
        XCTAssertEqual(windowModeRequests, 0, "already Window view")
        XCTAssertGreaterThan(m.stagePeekCloseRequest, closes)
        XCTAssertNil(m.appFirst?.previous.mode)

        m.exitLocalFullscreen()
        XCTAssertNil(m.appFirst)
        XCTAssertEqual(m.localFullscreen, fullBefore, "the pane that was fullscreen is again")
        m.exitLocalFullscreen()
        XCTAssertEqual(shown(m), before)
        XCTAssertEqual(modeRequests, [])
    }

    /// Several windows: the existing pick, then fullscreen with the one picked.
    func testSeveralWindowsUseThePickStep() {
        let m = model()
        var listed = base
        listed[13] = "dev.zed.Zed"
        m.apply(catalog(listed, running: running))
        m.openAppFullscreen(zedApp)
        guard case .choosing(let ws)? = m.appOpening?.phase else { return XCTFail("expected the pick") }
        XCTAssertEqual(Set(ws.map(\.id)), [10, 13])
        XCTAssertEqual(m.appOpening?.showsOverLayout, true)
        XCTAssertNil(m.localFullscreen, "nothing changes before the pick")
        m.pickOpenedWindow(ws.first { $0.id == 13 }!)
        assertAlone(m, 13)
    }

    /// Not running: launched (control granted), progress over the layout, then its window alone.
    func testNotRunningLaunchesWaitsThenGoesFullscreen() {
        let m = model()
        let before = shown(m)
        XCTAssertTrue(m.canOpenFullscreen(notes))
        m.openAppFullscreen(notes)
        XCTAssertEqual(launches(), ["com.apple.Notes"])
        XCTAssertEqual(m.appOpening?.isWaiting, true)
        XCTAssertEqual(m.appOpening?.showsOverLayout, true)
        XCTAssertEqual(shown(m), before, "nothing placed before its window exists")
        notesOpens(m)
        assertAlone(m, 20)
        m.exitLocalFullscreen()
        XCTAssertEqual(shown(m), before)
    }

    /// Without control an app with no window isn't offered, and nothing asks for control or launches.
    func testWithoutControlNothingIsOpenedOrRequested() {
        let m = model()
        control = .notAllowed
        XCTAssertFalse(m.canOpenFullscreen(notes))
        XCTAssertTrue(m.canOpenFullscreen(zedApp), "a window it has needs no control")
        m.openAppFullscreen(notes)
        XCTAssertNil(m.appOpening)
        XCTAssertEqual(launches(), [])
        XCTAssertEqual(controlRequests, 0)
    }

    /// Cancel while it opens: its window, when it comes, isn't placed.
    func testCancelledOpeningPlacesNothing() {
        let m = model()
        let before = shown(m)
        m.openAppFullscreen(notes)
        m.dismissAppOpening()
        notesOpens(m)
        XCTAssertEqual(shown(m), before)
        XCTAssertNil(m.localFullscreen)
        XCTAssertNil(m.appFirst)
    }

    /// The session ends while it opens: it fails, saying so, and nothing is placed.
    func testSessionEndingMidOpenFails() {
        let m = model()
        m.openAppFullscreen(notes)
        m.apply(.disconnected)
        XCTAssertEqual(m.appOpening?.phase, .failed(.disconnected))
        XCTAssertNil(m.appFirst)
    }

    /// From Mirror: Window view starts with the app alone; Exit asks for Mirror again.
    func testFromMirrorExitAsksForMirrorAgain() {
        mirroring = true
        let m = model(windowMode: false)
        m.openAppFullscreen(zedApp)
        XCTAssertEqual(windowModeRequests, 1)
        XCTAssertNil(m.leaveExtendRequest, "Mirror never asks")
        assertAlone(m, 10)
        XCTAssertEqual(m.appFirst?.previous.mode, .mirror)
        m.apply(.mode(window: true))
        m.exitLocalFullscreen()
        XCTAssertEqual(modeRequests, [.mirror])
        XCTAssertNil(m.appFirst)
        XCTAssertNil(m.localFullscreen)
    }

    /// From Extend: the existing Leave Extend question first; Stay changes nothing, Switch goes
    /// fullscreen, and Exit asks for Extend again.
    func testFromExtendAsksFirstThenExitAsksForExtendAgain() {
        extending = true
        let m = model(windowMode: false)
        let before = shown(m)
        m.openAppFullscreen(zedApp)
        XCTAssertNotNil(m.leaveExtendRequest)
        XCTAssertEqual(shown(m), before)
        m.cancelLeavingExtend()
        XCTAssertNil(m.appFirst)
        XCTAssertEqual(windowModeRequests, 0)

        m.openAppFullscreen(zedApp)
        m.confirmLeavingExtend()
        assertAlone(m, 10)
        XCTAssertEqual(windowModeRequests, 1)
        XCTAssertEqual(m.appFirst?.previous.mode, .extend)
        m.apply(.mode(window: true))
        m.exitLocalFullscreen()
        XCTAssertEqual(modeRequests, [.extend])
    }

    /// From Extend with an app to open: asked once, up front; its window lands later without a
    /// second question.
    func testFromExtendAnOpeningAsksOnlyOnce() {
        extending = true
        let m = model(windowMode: false)
        m.openAppFullscreen(notes)
        XCTAssertEqual(launches(), [], "nothing opens before the person confirms")
        m.confirmLeavingExtend()
        XCTAssertEqual(launches(), ["com.apple.Notes"])
        notesOpens(m)
        XCTAssertNil(m.leaveExtendRequest)
        assertAlone(m, 20)
        XCTAssertEqual(m.appFirst?.previous.mode, .extend)
    }

    /// Its window closes on the Mac: the fullscreen ends by itself (no empty pane left
    /// fullscreen), says the window closed (then that the app quit), and Exit restores.
    func testItsWindowClosingLeavesFullscreenAndExitRestores() {
        let m = model()
        let before = shown(m)
        m.openAppFullscreen(zedApp)
        let tile = m.appFirst!.tile
        m.apply(gone([10]))
        XCTAssertNil(m.localFullscreen)
        XCTAssertEqual(m.appFirst?.ended, .windowClosed)
        XCTAssertNil(m.layout.tiles[tile]?.source, "an empty pane, not a frozen picture")
        m.apply(catalog([11: "com.apple.Safari", 12: "com.apple.Terminal"], running: ["com.apple.Safari", "com.apple.Terminal"]))
        XCTAssertEqual(m.appFirst?.ended, .appQuit)
        m.exitAppFirst()
        XCTAssertNil(m.appFirst)
        XCTAssertEqual(shown(m), before)
    }

    /// Reopen after its window closed: the app's window goes fullscreen again, and Exit still goes
    /// back to the panes from before the first.
    func testReopenKeepsTheFirstPrevious() {
        let m = model()
        let before = shown(m)
        m.openAppFullscreen(zedApp)
        m.apply(gone([10]))
        var listed = base
        listed[10] = nil
        listed[14] = "dev.zed.Zed"
        m.apply(catalog(listed, running: running))
        XCTAssertEqual(m.appFirst?.ended, .windowClosed)
        m.reopenAppFirst()
        assertAlone(m, 14)
        m.exitLocalFullscreen()
        XCTAssertEqual(shown(m), before)
    }

    /// Choose Another Window: the picker opens for that pane; the session is done.
    func testChooseAnotherOpensThePickerForThePane() {
        let m = model()
        m.openAppFullscreen(zedApp)
        let tile = m.appFirst!.tile
        m.apply(gone([10]))
        m.chooseAnotherAfterAppFirst()
        XCTAssertNil(m.appFirst)
        XCTAssertTrue(m.overviewOpen)
        XCTAssertEqual(m.replacingTile, tile)
    }

    /// A plain Fullscreen on This Device is unchanged: Exit only leaves fullscreen.
    func testPlainFullscreenIsUnchanged() {
        let m = model()
        let before = shown(m)
        m.enterLocalFullscreen(before.keys.sorted()[0])
        m.exitLocalFullscreen()
        XCTAssertNil(m.localFullscreen)
        XCTAssertEqual(shown(m), before)
        XCTAssertEqual(modeRequests, [])
    }

    /// The input note: on the first Open Fullscreen of this install only.
    func testTheInputNoteShowsOnTheFirstUseOnly() {
        let m = model()
        m.openAppFullscreen(zedApp)
        XCTAssertTrue(m.appFirstInputNote)
        m.exitLocalFullscreen()
        XCTAssertFalse(m.appFirstInputNote)
        m.openAppFullscreen(zedApp)
        XCTAssertFalse(m.appFirstInputNote)
    }

    // MARK: Saved layout, session end, Window view ending

    /// While the app is fullscreen, what's saved on this device is the layout from before, so a
    /// relaunch (a new model on the same defaults) gets the person's panes back.
    func testWhileFullscreenThePreviousLayoutIsWhatIsSaved() {
        let m = model()
        let before = shown(m)
        XCTAssertEqual(persisted(), before)
        m.openAppFullscreen(zedApp)
        assertAlone(m, 10)
        XCTAssertEqual(persisted(), before, "never the single app pane")

        let relaunched = WorkspaceModel(defaults: defaults)
        wire(relaunched)
        relaunched.apply(.connected(peerID: "mac-a"))
        XCTAssertEqual(shown(relaunched), before)
        XCTAssertNil(relaunched.appFirst)
        XCTAssertNil(relaunched.localFullscreen)
    }

    /// Switching to another Mac ends it there; coming back finds the earlier panes.
    func testAnotherMacEndsItAndTheEarlierPanesAreKept() {
        let m = model()
        let before = shown(m)
        m.openAppFullscreen(zedApp)
        m.apply(.connected(peerID: "mac-b"))
        XCTAssertNil(m.appFirst)
        XCTAssertEqual(persisted("mac-a"), before)
        m.apply(.connected(peerID: "mac-a"))
        XCTAssertEqual(shown(m), before)
        XCTAssertNil(m.appFirst)
    }

    /// The session ends: Open Fullscreen ends with it (its pane, fullscreen and question), the
    /// earlier panes are back, and nothing later can ask for an old mode.
    func testDisconnectEndsItAndRestoresTheEarlierPanes() {
        mirroring = true
        let m = model(windowMode: false)
        let before = shown(m)
        m.openAppFullscreen(zedApp)
        m.apply(.mode(window: true))
        m.apply(.disconnected)
        XCTAssertNil(m.appFirst)
        XCTAssertNil(m.localFullscreen)
        XCTAssertEqual(shown(m), before)
        XCTAssertEqual(modeRequests, [])
        m.exitLocalFullscreen()
        m.exitAppFirst()
        XCTAssertEqual(modeRequests, [], "no old Mirror asked for later")
        m.apply(.connected(peerID: "mac-a"))
        XCTAssertNil(m.appFirst)
        XCTAssertEqual(shown(m), before)
    }

    /// Its window closed and the question shows; the session ends: the question goes too, and
    /// Reopen can't act on the old listing.
    func testDisconnectClearsTheWindowClosedQuestion() {
        let m = model()
        let before = shown(m)
        m.openAppFullscreen(zedApp)
        m.apply(gone([10]))
        XCTAssertEqual(m.appFirst?.ended, .windowClosed)
        m.apply(.disconnected)
        XCTAssertNil(m.appFirst)
        m.reopenAppFirst()
        XCTAssertNil(m.appOpening)
        XCTAssertEqual(shown(m), before)
    }

    /// The reconnect its own switch into Window view causes (the Mac rebuilds this device's
    /// session) doesn't end it: the app pane stays fullscreen, and Exit still goes back to Mirror.
    func testItsOwnSwitchIntoWindowViewSurvivesTheReconnect() {
        mirroring = true
        let m = model(windowMode: false)
        let before = shown(m)
        m.openAppFullscreen(zedApp)
        m.apply(.disconnected)
        m.apply(.connected(peerID: "mac-a"))
        m.apply(.features([WindowWorkspaceWire.welcomeFeature]))
        m.apply(.mode(window: true))
        assertAlone(m, 10)
        XCTAssertEqual(persisted(), before)
        m.exitLocalFullscreen()
        XCTAssertEqual(modeRequests, [.mirror])
        XCTAssertEqual(persisted(), before)
    }

    /// Window view ends another way (Settings, the Mac, a refused switch): it ends quietly with
    /// the earlier panes back and asks for no mode.
    func testWindowViewEndingAnotherWayEndsIt() {
        let m = model()
        let before = shown(m)
        m.openAppFullscreen(zedApp)
        m.apply(.mode(window: false))
        XCTAssertNil(m.appFirst)
        XCTAssertNil(m.localFullscreen)
        XCTAssertEqual(shown(m), before)
        XCTAssertEqual(modeRequests, [])
    }

    /// Exit before the Mac confirmed Window view: the earlier panes come back, but no mode is
    /// asked for (it would be a new switch, not a return).
    func testExitBeforeWindowViewStartedAsksForNoMode() {
        mirroring = true
        let m = model(windowMode: false)
        m.openAppFullscreen(zedApp)
        m.exitLocalFullscreen()
        XCTAssertNil(m.appFirst)
        XCTAssertEqual(modeRequests, [])
    }
}

/// What's saved during Open Fullscreen (Shared/WorkspaceAppOpening.swift), pure.
final class WorkspaceAppFirstPersistenceTests: XCTestCase {
    private func layout(_ ids: [String], window: UInt32) -> WorkspaceLayout {
        WorkspaceLayout(preset: ids.count == 1 ? .single : .natural(for: ids.count, landscape: false),
                        tiles: ids.map { WorkspaceTile(id: $0, source: WorkspaceSource(host: "mac-a", windowID: window)) })
    }

    func testThePreviousLayoutIsSavedOnlyForItsOwnMac() {
        let before = layout(["w1", "w2"], window: 1)
        let app = layout(["w9"], window: 9)
        let s = WorkspaceAppFirst.begin(host: "mac-a", bundleID: "a", name: "A", tile: "w9", continuing: nil, fullscreen: nil,
                                        previous: WorkspaceAppFirst.Previous(layout: before, fullscreen: nil, mode: nil))
        XCTAssertEqual(WorkspaceAppFirst.layoutToPersist(app, session: s, host: "mac-a"), before)
        XCTAssertEqual(WorkspaceAppFirst.layoutToPersist(app, session: s, host: "mac-b"), app)
        XCTAssertEqual(WorkspaceAppFirst.layoutToPersist(app, session: nil, host: "mac-a"), app)
    }
}

import XCTest

/// The window picker's search over windows and apps, when it asks for the Mac's app list, and
/// opening an app into the tile it was opened for (Shared/WorkspaceAppOpening.swift).
final class WorkspaceAppOpeningTests: XCTestCase {
    private func window(_ id: UInt32, _ bundle: String, app: String? = nil, title: String = "", gen: UInt64 = 1) -> CatalogWindowItem {
        CatalogWindowItem(id: id, generation: gen, bundleID: bundle, app: app ?? bundle, title: title, width: 800, height: 600,
                          minimized: false, active: false)
    }

    private func installed(_ bundle: String, _ name: String, used: TimeInterval? = nil) -> MacAppItem {
        MacAppItem(bundleID: bundle, name: name, running: false, windowCount: 0, lastUsed: used.map { Date(timeIntervalSince1970: $0) })
    }

    // MARK: Search

    /// The owner's case (build 9000023): Calendar isn't running and "Calendar" found nothing.
    /// Apps with no listed window come from the Mac's app list, apart from the windows.
    func testSearchFindsAnAppThatIsNotRunningApartFromTheWindows() {
        let windows = [window(10, "com.apple.Safari", app: "Safari", title: "Calendar – Google"), window(11, "dev.zed.Zed", app: "Zed")]
        let list = [installed("com.apple.iCal", "Calendar"), installed("com.apple.Safari", "Safari"), installed("com.apple.TextEdit", "TextEdit")]
        let r = WorkspacePickerSearch.results("Calendar", windows: windows, running: [], installed: list)
        XCTAssertEqual(r.windows.map(\.id), [10], "a window whose title matches is a window")
        XCTAssertEqual(r.apps.map(\.bundleID), ["com.apple.iCal"])
        XCTAssertEqual(r.apps.first?.running, false)

        let safari = WorkspacePickerSearch.results("safari", windows: windows, running: [], installed: list)
        XCTAssertEqual(safari.windows.map(\.id), [10])
        XCTAssertTrue(safari.apps.isEmpty, "an app with a listed window shows as its windows, not as an app to open")

        let text = WorkspacePickerSearch.results("text", windows: windows, running: [], installed: list)
        XCTAssertTrue(text.windows.isEmpty)
        XCTAssertEqual(text.apps.map(\.name), ["TextEdit"])
    }

    /// A running app with no window to show is offered once (merged with the app list), marked running.
    func testARunningAppWithNoWindowIsOfferedOnceAndMarkedRunning() {
        let running = [CatalogAppItem(bundleID: "com.apple.iCal", name: "Calendar", hasWindows: false),
                       CatalogAppItem(bundleID: "dev.helper", name: "Helper", hasWindows: false),
                       CatalogAppItem(bundleID: "dev.zed.Zed", name: "Zed", hasWindows: true)]
        let windows = [window(11, "dev.zed.Zed", app: "Zed")]
        let r = WorkspacePickerSearch.results("", windows: windows, running: running,
                                              installed: [installed("com.apple.iCal", "Calendar"), installed("dev.zed.Zed", "Zed")])
        XCTAssertEqual(r.windows.map(\.id), [11], "an empty search lists every window")
        XCTAssertEqual(r.apps.map(\.bundleID), ["com.apple.iCal", "dev.helper"], "running without a window, by name; no duplicates")
        XCTAssertTrue(r.apps.allSatisfy(\.running))
        let cal = WorkspacePickerSearch.results("cal", windows: windows, running: running, installed: [installed("com.apple.iCal", "Calendar")])
        XCTAssertEqual(cal.apps.count, 1)
    }

    /// An empty search lists a few apps (running ones, then recently used) and says more exist;
    /// a search is ranked (prefix first, accents folded) and bounded.
    func testEmptySearchListsAFewAppsAndASearchIsRankedAndBounded() {
        var list = (0..<60).map { installed("dev.app\($0)", "App \($0)") }
        list.append(installed("com.apple.iCal", "Calendar", used: 200))
        list.append(installed("com.apple.TextEdit", "TextEdit", used: 300))
        list.append(installed("dev.cafe", "Café Noir"))
        let browse = WorkspacePickerSearch.results("  ", windows: [], running: [], installed: list)
        XCTAssertEqual(browse.apps.map(\.bundleID), ["com.apple.TextEdit", "com.apple.iCal"], "recently used, newest first")
        XCTAssertTrue(browse.moreApps)

        let all = WorkspacePickerSearch.results("app", windows: [], running: [], installed: list)
        XCTAssertEqual(all.apps.count, WorkspacePickerSearch.searchLimit)
        XCTAssertTrue(all.moreApps)
        XCTAssertEqual(WorkspacePickerSearch.results("cafe", windows: [], running: [], installed: list).apps.map(\.bundleID), ["dev.cafe"])
        let ranked = WorkspacePickerSearch.results("te", windows: [], running: [], installed: list + [installed("dev.other", "Note Taker")])
        XCTAssertEqual(ranked.apps.first?.name, "TextEdit", "a name that starts with the search comes first")
    }

    // MARK: When the app list is asked for

    /// Asked when the picker (or another browser) opens; a refresh tick repeats only an ask that
    /// got no answer, a few times; opened again right after an answer, nothing is asked.
    func testTheAppListIsAskedOnOpenNotOnEveryRefresh() {
        var p = AppInventoryRequestPlanner()
        XCTAssertTrue(p.opened(now: 0))
        XCTAssertFalse(p.opened(now: 1), "an ask is out")
        XCTAssertFalse(p.tick(now: 3))
        XCTAssertTrue(p.tick(now: 5), "no answer: asked again")
        XCTAssertTrue(p.tick(now: 10))
        XCTAssertTrue(p.tick(now: 15))
        XCTAssertFalse(p.tick(now: 20), "at most \(AppInventoryRequestPlanner.maxRetries) repeats")
        p.answered(now: 21)
        for t in stride(from: 22.0, to: 120, by: 3) { XCTAssertFalse(p.tick(now: t), "answered: the ticks ask nothing") }
        XCTAssertFalse(p.opened(now: 25), "just answered")
        XCTAssertTrue(p.opened(now: 21 + AppInventoryRequestPlanner.recentEnough), "opened again later: asked (an unchanged list is a short answer)")
        p.reset()
        XCTAssertTrue(p.opened(now: 0), "a new connection asks again")
    }

    // MARK: Opening into a tile

    private let tileSource = WorkspaceSource(host: "mac-a", windowID: 10, bundleID: "dev.zed.Zed")

    private func start(control: WorkspaceAppOpening.Control = .allowed, windows: [CatalogWindowItem] = [], now: TimeInterval = 0,
                       tile: String? = "w2") -> (WorkspaceAppOpening, WorkspaceAppOpening.Step) {
        WorkspaceAppOpening.start(bundleID: "com.apple.iCal", name: "Calendar", tile: tile, tileSource: tileSource,
                                  control: control, windows: windows, now: now)
    }

    func testOneNewWindowIsPlacedOnceTheAppOpensAndItSettles() {
        let other = window(11, "dev.zed.Zed")
        var (o, step) = start(windows: [other])
        XCTAssertEqual(step, .launch)
        XCTAssertEqual(o.phase, .launching)
        XCTAssertEqual(o.launchAnswered(ok: true, now: 1), .none)
        XCTAssertEqual(o.phase, .waitingForWindow)
        XCTAssertEqual(o.advance(windows: [other], now: 2, control: .allowed, tileUnchanged: true), .none)
        let cal = window(20, "com.apple.iCal")
        XCTAssertEqual(o.advance(windows: [other, cal], now: 3, control: .allowed, tileUnchanged: true), .none,
                       "first seen: a moment for windows opening with it")
        XCTAssertEqual(o.advance(windows: [other, cal], now: 3 + WorkspaceAppOpening.settle, control: .allowed, tileUnchanged: true),
                       .place(cal))
        XCTAssertEqual(o.phase, .placed(cal))
        XCTAssertEqual(o.advance(windows: [other, cal], now: 9, control: .allowed, tileUnchanged: true), .none, "done")
    }

    /// The app's window can show before the Mac's answer; the answer is then not needed.
    func testAWindowBeforeTheAnswerCountsAsOpened() {
        var (o, _) = start()
        let cal = window(20, "com.apple.iCal")
        XCTAssertEqual(o.advance(windows: [cal], now: 1, control: .allowed, tileUnchanged: true), .none)
        XCTAssertEqual(o.phase, .waitingForWindow)
        XCTAssertEqual(o.advance(windows: [cal], now: 2, control: .allowed, tileUnchanged: true), .place(cal))
    }

    /// Only a NEW window of exactly that app: its windows listed before the launch, other apps'
    /// windows and displays never count.
    func testOnlyANewWindowOfThatAppCounts() {
        let old = window(15, "com.apple.iCal")
        var (o, _) = start(windows: [old])
        XCTAssertEqual(o.known, [15])
        _ = o.launchAnswered(ok: true, now: 0)
        let others = [old, window(30, "com.apple.TextEdit"), window(WorkspaceSource.displayKey(1), "com.apple.iCal")]
        for t in [1.0, 3, 6] {
            XCTAssertEqual(o.advance(windows: others, now: t, control: .allowed, tileUnchanged: true), .none)
        }
        XCTAssertEqual(o.newWindows(others), [])
        XCTAssertEqual(o.advance(windows: others, now: WorkspaceAppOpening.windowTimeout, control: .allowed, tileUnchanged: true),
                       .fail(.noWindow), "never another window instead")
    }

    /// Several new windows: the person picks; the list follows the Mac; a pick of a window that's
    /// gone (or came back as another identity) is refused and the choice refreshed.
    func testSeveralNewWindowsAskThePersonAndStaleChoicesAreRefused() {
        var (o, _) = start()
        _ = o.launchAnswered(ok: true, now: 0)
        let a = window(20, "com.apple.iCal", title: "Home"), b = window(21, "com.apple.iCal", title: "Work")
        XCTAssertEqual(o.advance(windows: [a], now: 1, control: .allowed, tileUnchanged: true), .none)
        XCTAssertEqual(o.advance(windows: [a, b], now: 2, control: .allowed, tileUnchanged: true), .choose([a, b]),
                       "never one picked for the person")
        XCTAssertEqual(o.advance(windows: [a, b], now: 3, control: .allowed, tileUnchanged: true), .none, "asked once")
        let c = window(22, "com.apple.iCal", title: "Shared")
        XCTAssertEqual(o.advance(windows: [b, c], now: 4, control: .allowed, tileUnchanged: true), .choose([b, c]), "follows the Mac")
        XCTAssertEqual(o.pick(20, generation: 1, windows: [b, c], tileUnchanged: true), .choose([b, c]), "20 closed")
        XCTAssertTrue(o.pickWasStale)
        let reused = window(21, "com.apple.iCal", title: "Work", gen: 2)
        XCTAssertEqual(o.pick(21, generation: 1, windows: [reused, c], tileUnchanged: true), .choose([reused, c]),
                       "same id, another identity: not the window the person saw")
        XCTAssertEqual(o.pick(22, generation: 1, windows: [reused, c], tileUnchanged: true), .place(c))
    }

    func testAChoiceWhoseWindowsAllCloseOrWhoseTileChangedStops() {
        var (o, _) = start()
        _ = o.launchAnswered(ok: true, now: 0)
        let a = window(20, "com.apple.iCal"), b = window(21, "com.apple.iCal")
        _ = o.advance(windows: [a, b], now: 1, control: .allowed, tileUnchanged: true)
        XCTAssertEqual(o.advance(windows: [a, b], now: 2, control: .allowed, tileUnchanged: true), .choose([a, b]))
        var gone = o
        XCTAssertEqual(gone.advance(windows: [], now: 3, control: .allowed, tileUnchanged: true), .fail(.noWindow))
        var picked = o
        XCTAssertEqual(picked.pick(20, generation: 1, windows: [a, b], tileUnchanged: false), .fail(.tileChanged))
        XCTAssertEqual(o.pick(20, generation: 1, windows: [], tileUnchanged: true), .fail(.noWindow))
    }

    func testFailureNoAnswerAndNoWindowStopWaiting() {
        var failed = start().0
        XCTAssertEqual(failed.launchAnswered(ok: false, now: 1), .fail(.launchFailed))
        XCTAssertEqual(failed.phase, .failed(.launchFailed))
        XCTAssertTrue(WorkspaceAppOpening.Failure.launchFailed.retryable)

        var silent = start().0
        XCTAssertEqual(silent.advance(windows: [], now: WorkspaceAppOpening.answerTimeout - 1, control: .allowed, tileUnchanged: true), .none)
        XCTAssertTrue(silent.isSlow(now: WorkspaceAppOpening.slowAfter), "slow startup is said, not treated as failure")
        XCTAssertEqual(silent.advance(windows: [], now: WorkspaceAppOpening.answerTimeout, control: .allowed, tileUnchanged: true),
                       .fail(.noAnswer))

        var windowless = start().0
        _ = windowless.launchAnswered(ok: true, now: 2)
        XCTAssertEqual(windowless.advance(windows: [], now: 2 + WorkspaceAppOpening.windowTimeout - 1, control: .allowed, tileUnchanged: true), .none)
        XCTAssertEqual(windowless.advance(windows: [], now: 2 + WorkspaceAppOpening.windowTimeout, control: .allowed, tileUnchanged: true),
                       .fail(.noWindow))
        XCTAssertTrue(WorkspaceAppOpening.Failure.noWindow.retryable)

        var unsent = start().0
        XCTAssertEqual(unsent.launchNotSent(), .fail(.noAnswer))
    }

    /// Control ending before the Mac opened the app stops it (the Mac opens nothing without
    /// control); once opened, showing its window needs no control.
    func testControlEndingBeforeTheAppOpenedStopsIt() {
        var o = start().0
        XCTAssertEqual(o.advance(windows: [], now: 1, control: .denied, tileUnchanged: true), .fail(.controlEnded))
        var opened = start().0
        _ = opened.launchAnswered(ok: true, now: 1)
        let cal = window(20, "com.apple.iCal")
        XCTAssertEqual(opened.advance(windows: [cal], now: 2, control: .off, tileUnchanged: true), .none)
        XCTAssertEqual(opened.advance(windows: [cal], now: 3, control: .off, tileUnchanged: true), .place(cal))
    }

    /// Without control: Request Control first; the app opens only once the Mac allows it, and its
    /// earlier windows are taken from that moment.
    func testWithoutControlItWaitsForTheMacToAllowIt() {
        var (o, step) = start(control: .off)
        XCTAssertEqual(step, .none, "nothing is launched without control")
        XCTAssertEqual(o.phase, .awaitingControl)
        XCTAssertEqual(o.advance(windows: [], now: 1, control: .denied, tileUnchanged: true), .none,
                       "a no from an earlier request isn't this one's answer")
        XCTAssertEqual(o.advance(windows: [], now: 2, control: .requesting, tileUnchanged: true), .none)
        let old = window(15, "com.apple.iCal")
        XCTAssertEqual(o.advance(windows: [old], now: 8, control: .allowed, tileUnchanged: true), .launch)
        XCTAssertEqual(o.known, [15])
        XCTAssertEqual(o.phase, .launching)

        var declined = start(control: .requesting).0
        XCTAssertEqual(declined.advance(windows: [], now: 5, control: .denied, tileUnchanged: true), .fail(.controlDenied))
        var never = start(control: .off).0
        XCTAssertEqual(never.advance(windows: [], now: WorkspaceAppOpening.controlTimeout, control: .requesting, tileUnchanged: true),
                       .fail(.controlDenied))
        let refused = start(control: .refused)
        XCTAssertEqual(refused.1, .fail(.controlDenied), "requests turned off on the Mac: nothing to wait for")
    }

    /// The tile the picker was opened for is removed or shows another window meanwhile: stop,
    /// never place it elsewhere.
    func testTheTileChangingMeanwhileStopsIt() {
        var o = start().0
        XCTAssertEqual(o.advance(windows: [], now: 1, control: .allowed, tileUnchanged: false), .fail(.tileChanged))
        XCTAssertFalse(WorkspaceAppOpening.Failure.tileChanged.retryable)

        let probe = start().0
        XCTAssertTrue(probe.tileUnchanged(WorkspaceTile(id: "w2", source: tileSource)))
        XCTAssertTrue(probe.tileUnchanged(WorkspaceTile(id: "w2", source: WorkspaceSource(host: "mac-a", windowID: 10, bundleID: nil))),
                      "the same window (its app filled in later) is unchanged")
        XCTAssertFalse(probe.tileUnchanged(WorkspaceTile(id: "w2", source: WorkspaceSource(host: "mac-a", windowID: 12))))
        XCTAssertFalse(probe.tileUnchanged(WorkspaceTile(id: "w2")), "emptied")
        XCTAssertFalse(probe.tileUnchanged(nil), "removed")
        XCTAssertTrue(start(tile: nil).0.tileUnchanged(nil), "no tile: where a picked window goes")
    }

    func testADisconnectStopsItAndAFinishedOpeningIgnoresEverything() {
        var o = start().0
        XCTAssertEqual(o.disconnected(), .fail(.disconnected))
        XCTAssertTrue(o.isFinished)
        XCTAssertFalse(o.isWaiting)
        XCTAssertEqual(o.disconnected(), .none)
        XCTAssertEqual(o.launchAnswered(ok: true, now: 2), .none)
        XCTAssertEqual(o.advance(windows: [window(20, "com.apple.iCal")], now: 3, control: .allowed, tileUnchanged: true), .none)
    }

    func testControlFollowsTheSessionAndTheMacsDecision() {
        typealias C = WorkspaceAppOpening.Control
        XCTAssertEqual(C(live: true, state: .allowed), .allowed)
        XCTAssertEqual(C(live: false, state: .allowed), .off, "no live session: no control")
        XCTAssertEqual(C(live: true, state: .requesting), .requesting)
        XCTAssertEqual(C(live: true, state: .notAllowed), .denied)
        XCTAssertEqual(C(live: true, state: .requestsDisabled), .refused)
        XCTAssertEqual(C(live: true, state: .off), .off)
    }
}

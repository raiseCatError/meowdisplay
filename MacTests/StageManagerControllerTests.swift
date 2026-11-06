import XCTest

/// Window-mode tests use this instead of `StageManagerController.shared`: nothing is ever switched,
/// and the owner's shortcuts (or `shortcuts list`) never run.
final class StageManagerStandIn: StageManagerCoordinating, @unchecked Sendable {
    private let lock = NSLock()
    private var counts = (started: 0, ended: 0)
    var started: Int { lock.withLock { counts.started } }
    var ended: Int { lock.withLock { counts.ended } }
    func windowModeStarted(changed: @escaping @Sendable () -> Void) -> StageManagerHold {
        lock.withLock { counts.started += 1 }
        changed()
        return StageManagerHold()
    }
    func windowModeEnded(_ hold: StageManagerHold) { lock.withLock { counts.ended += 1 } }
    func deviceAsked(on: Bool, done: @escaping @Sendable (Bool) -> Void) { done(false) }
    var wireControl: String { "setup" }
    var isOnRecently: Bool { false }
}

/// Stage Manager has one owner that counts Window-mode devices, waits out reconnects, owes a
/// restore before it turns anything off, never runs shortcuts that would change the Dock, limits
/// automatic changes, and says what happened. Everything here is fake: no real `shortcuts`.
final class StageManagerControllerTests: XCTestCase {
    /// The Mac as the controller sees it.
    private final class FakeMac: @unchecked Sendable {
        struct State {
            var on = true
            var applies = true
            var list = "Morning\nMeowDisplay Stage Manager Off\nMeowDisplay Stage Manager On\n"
            var exit: Int32 = 0
            var stderr = ""
            /// The owner hides the Dock and shows recent apps.
            var dock = DockSettings(showDock: false, showRecentApps: true)
            /// What a run also writes (a shortcut that ignores the owner's settings).
            var runWritesDock: DockSettings?
            var commands: [[String]] = []
        }
        private let lock = NSLock()
        private var s = State()
        /// When set, each run waits for one signal (after signalling `started`).
        var gate: DispatchSemaphore?
        let started = DispatchSemaphore(value: 0)

        subscript<T>(_ key: WritableKeyPath<State, T>) -> T {
            get { lock.withLock { s[keyPath: key] } }
            set { lock.withLock { s[keyPath: key] = newValue } }
        }
        var runs: [String] { self[\.commands].filter { $0.first == "run" }.map { $0.last == StageManagerSwitch.onShortcut ? "on" : "off" } }

        var system: StageManagerController.System {
            .init(isOn: { self[\.on] },
                  dockSettings: { self[\.dock] },
                  runShortcuts: { args in
                      self.lock.withLock { self.s.commands.append(args) }
                      switch args.first {
                      case "list": return ToolRun(status: 0, output: self[\.list])
                      case "run":
                          self.started.signal()
                          self.gate?.wait()
                          return self.lock.withLock {
                              if self.s.exit == 0, self.s.applies { self.s.on = args.last == StageManagerSwitch.onShortcut }
                              if let d = self.s.runWritesDock { self.s.dock = d }
                              return ToolRun(status: self.s.exit, output: "", errorOutput: self.s.stderr)
                          }
                      default: return ToolRun(status: 0, output: "")
                      }
                  },
                  pause: { _ in },
                  settleTimeout: 0.4)
        }
    }

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var t = Date(timeIntervalSince1970: 1_800_000_000)
        var now: Date { lock.withLock { t } }
        func advance(_ s: TimeInterval) { lock.withLock { t += s } }
    }

    /// Timers the test fires by hand.
    private final class Timers: @unchecked Sendable {
        private let lock = NSLock()
        private var pending: [(delay: TimeInterval, work: @Sendable () -> Void)] = []
        var delays: [TimeInterval] { lock.withLock { pending.map(\.delay) } }
        func add(_ d: TimeInterval, _ w: @escaping @Sendable () -> Void) { lock.withLock { pending.append((d, w)) } }
        func fire() { for p in lock.withLock({ () -> [(delay: TimeInterval, work: @Sendable () -> Void)] in defer { pending = [] }; return pending }) { p.work() } }
    }

    private var mac: FakeMac!
    private var clock: Clock!
    private var timers: Timers!
    private var suite: String!
    private var defaults: UserDefaults!
    private typealias Keys = StageManagerController.Keys

    override func setUp() {
        mac = FakeMac()
        clock = Clock()
        timers = Timers()
        suite = "StageManagerControllerTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        defaults.set(true, forKey: StageManagerSwitch.offDuringWindowModeKey)
        recordShortcuts(mac[\.dock])
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    /// The shortcuts were set up by this version for these settings.
    private func recordShortcuts(_ settings: DockSettings) {
        defaults.set(StageManagerShortcutInstaller.formatVersion, forKey: Keys.shortcutFormat)
        defaults.set(settings.showDock, forKey: Keys.shortcutShowDock)
        defaults.set(settings.showRecentApps, forKey: Keys.shortcutShowRecentApps)
    }

    private func make(_ policy: StageManagerController.Policy = .init()) -> StageManagerController {
        let clock = clock!, timers = timers!
        return StageManagerController(system: mac.system, defaults: defaults, policy: policy,
                                      now: { clock.now }, schedule: { timers.add($0, $1) })
    }

    @discardableResult
    private func start(_ c: StageManagerController) -> StageManagerHold {
        let hold = c.windowModeStarted {}
        c.waitUntilIdle()
        return hold
    }

    private func end(_ c: StageManagerController, _ hold: StageManagerHold) {
        c.windowModeEnded(hold)
        c.waitUntilIdle()
    }

    private func fire(_ c: StageManagerController) {
        timers.fire()
        c.waitUntilIdle()
    }

    private func device(_ c: StageManagerController, on: Bool) -> Bool {
        let done = expectation(description: "device")
        let box = Box()
        c.deviceAsked(on: on) { ok in box.ok = ok; done.fulfill() }
        wait(for: [done], timeout: 5)
        return box.ok
    }

    private final class Box: @unchecked Sendable { var ok = false }

    // MARK: Counting and the grace period

    func testOnlyTheFirstDeviceTurnsItOffAndOnlyTheLastOneRestoresAfterTheGracePeriod() {
        let c = make()
        let a = start(c)
        let b = start(c)
        XCTAssertEqual(mac.runs, ["off"], "two devices: turned off once")
        XCTAssertFalse(mac[\.on])
        XCTAssertTrue(c.status.owed)
        XCTAssertEqual(c.status.windowModes, 2)
        end(c, a)
        XCTAssertEqual(timers.delays, [], "another device still uses Window mode")
        XCTAssertFalse(mac[\.on])
        end(c, b)
        XCTAssertEqual(timers.delays, [25], "back on after the grace period, not right away")
        XCTAssertEqual(mac.runs, ["off"])
        XCTAssertNotNil(c.status.restoreAt)
        fire(c)
        XCTAssertEqual(mac.runs, ["off", "on"])
        XCTAssertTrue(mac[\.on])
        XCTAssertFalse(c.status.owed)
        XCTAssertFalse(defaults.bool(forKey: Keys.owed))
        XCTAssertTrue(mac[\.commands].allSatisfy { ["list", "run"].contains($0.first) }, "only Shortcuts, never a preference write")
    }

    func testAReconnectWithinTheGracePeriodTogglesNothing() {
        let c = make()
        end(c, start(c))
        let again = start(c)   // reconnect, or Mirror ↔ Window
        fire(c)                // the cancelled restore
        XCTAssertEqual(mac.runs, ["off"], "no On/Off pair for a reconnect")
        XCTAssertFalse(mac[\.on])
        XCTAssertTrue(c.status.owed)
        end(c, again)
        fire(c)
        XCTAssertEqual(mac.runs, ["off", "on"])
    }

    func testAStartWhileARestoreRunsEndsWithItOffAndStillOwed() {
        let c = make()
        end(c, start(c))
        mac.gate = DispatchSemaphore(value: 0)
        timers.fire()                       // the restore starts and is held mid-run
        mac.started.wait()                  // (the Off's signal)
        mac.started.wait()                  // the On is running now
        let b = c.windowModeStarted {}      // a device comes back meanwhile
        mac.gate?.signal()                  // On finishes
        mac.gate?.signal()                  // the new Off finishes
        c.waitUntilIdle()
        XCTAssertEqual(mac.runs, ["off", "on", "off"], "the new start isn't lost behind the restore")
        XCTAssertFalse(mac[\.on], "Window mode doesn't run with Stage Manager on")
        XCTAssertTrue(c.status.owed)
        mac.gate = nil
        end(c, b)
        fire(c)
        XCTAssertTrue(mac[\.on])
        XCTAssertFalse(c.status.owed)
    }

    // MARK: Owed restores

    func testTheDebtIsSavedBeforeTurningOffAndALaunchPaysIt() {
        mac.gate = DispatchSemaphore(value: 0)
        let c = make()
        _ = c.windowModeStarted {}
        mac.started.wait()
        XCTAssertTrue(defaults.bool(forKey: Keys.owed), "saved before the shortcut runs, so a crash mid-run still restores")
        mac.gate?.signal()
        c.waitUntilIdle()
        mac.gate = nil

        // Quit or crash during Window mode: the next launch restores after the grace period.
        let relaunched = make()
        XCTAssertTrue(relaunched.status.owed)
        relaunched.appLaunched()
        relaunched.waitUntilIdle()
        XCTAssertEqual(timers.delays, [25])
        XCTAssertEqual(mac.runs, ["off"])
        fire(relaunched)
        XCTAssertEqual(mac.runs, ["off", "on"])
        XCTAssertFalse(relaunched.status.owed)
    }

    func testAFailedRestoreStaysOwedAndSaysWhy() {
        let c = make()
        end(c, start(c))
        mac[\.exit] = 1
        mac[\.stderr] = "Error: The shortcut couldn't run.\nmore detail"
        fire(c)
        XCTAssertFalse(mac[\.on])
        XCTAssertTrue(c.status.owed)
        XCTAssertTrue(defaults.bool(forKey: Keys.owed), "still owed after a relaunch")
        let last = try? XCTUnwrap(c.status.lastChange)
        XCTAssertEqual(last?.outcome, .failed)
        XCTAssertEqual(last?.exitCode, 1)
        XCTAssertEqual(last?.errorSummary, "Error: The shortcut couldn't run.")
        let lines = c.status.lines(now: clock.now)
        XCTAssertTrue(lines.contains { $0.contains("hasn't turned it back on") }, "\(lines)")
        XCTAssertTrue(lines.contains { $0.contains("failed (exit 1)") && $0.contains("couldn't run") }, "\(lines)")
        XCTAssertEqual(timers.delays, [], "never retried in a loop")
        XCTAssertEqual(make().status.lastChange?.outcome, .failed, "the result survives a relaunch")
    }

    func testAChangeMacOSDidNotApplyIsReportedAndNothingIsOwed() {
        mac[\.applies] = false
        let c = make()
        let a = start(c)
        XCTAssertEqual(mac.runs, ["off"])
        XCTAssertTrue(mac[\.on])
        XCTAssertFalse(c.status.owed, "still on: nothing to turn back on")
        XCTAssertEqual(c.status.lastChange?.outcome, .notApplied)
        end(c, a)
        XCTAssertEqual(timers.delays, [])
    }

    func testOnlyItsOwnChangeIsUndone() {
        mac[\.on] = false   // the owner turned it off themselves
        let c = make()
        end(c, start(c))
        XCTAssertEqual(mac.runs, [])
        XCTAssertEqual(timers.delays, [])
        XCTAssertFalse(c.status.owed)
    }

    func testTheOwnerTurningItBackOnClearsTheDebt() {
        let c = make()
        let a = start(c)
        mac[\.on] = true   // Control Center, during Window mode
        let done = expectation(description: "refresh")
        c.refresh { done.fulfill() }
        wait(for: [done], timeout: 5)
        XCTAssertFalse(c.status.owed)
        end(c, a)
        XCTAssertEqual(timers.delays, [], "nothing to restore")
        XCTAssertEqual(mac.runs, ["off"])
    }

    // MARK: Devices and the setting

    func testWithoutTheSettingNothingSwitchesButADevicesTurnOffIsRestoredAfterWindowMode() {
        defaults.set(false, forKey: StageManagerSwitch.offDuringWindowModeKey)
        let c = make()
        let a = start(c)
        XCTAssertEqual(mac.runs, [])
        XCTAssertEqual(c.wireControl, "ready")
        XCTAssertTrue(device(c, on: false))
        XCTAssertFalse(mac[\.on])
        XCTAssertTrue(c.status.owed)
        end(c, a)
        fire(c)
        XCTAssertEqual(mac.runs, ["off", "on"])
        XCTAssertTrue(mac[\.on])
    }

    func testADeviceTurningItOnClearsTheDebtOnlyOnceItIsOn() {
        let c = make()
        start(c)
        mac[\.exit] = 1
        XCTAssertFalse(device(c, on: true))
        XCTAssertTrue(c.status.owed, "it didn't come on: still owed")
        mac[\.exit] = 0
        XCTAssertTrue(device(c, on: true))
        XCTAssertTrue(mac[\.on])
        XCTAssertFalse(c.status.owed)
    }

    func testWithoutTheShortcutsNothingRunsAndItSaysSo() {
        mac[\.list] = "Morning\nMeowDisplay Stage Manager Off\n"   // the On one is missing
        let c = make()
        start(c)
        XCTAssertEqual(mac.runs, [])
        XCTAssertTrue(mac[\.on])
        XCTAssertEqual(c.status.shortcuts, .missing)
        XCTAssertEqual(c.status.lastSkip?.reason, .notSetUp)
        XCTAssertEqual(c.wireControl, "setup")
        XCTAssertFalse(c.status.owed)
    }

    // MARK: Leaving the Dock alone

    func testShortcutsFromBeforeThisVersionNeverRunOnTheirOwn() {
        for key in [Keys.shortcutFormat, Keys.shortcutShowDock, Keys.shortcutShowRecentApps] { defaults.removeObject(forKey: key) }
        let c = make()
        let a = start(c)
        XCTAssertEqual(mac.runs, [], "an old shortcut would turn Dock hiding off")
        XCTAssertEqual(c.status.shortcuts, .outdated)
        XCTAssertEqual(c.status.lastSkip?.reason, .needsSetUpAgain)
        XCTAssertEqual(c.wireControl, "setup", "devices explain instead of offering Turn Off")
        XCTAssertTrue(c.status.setupNeedsRemoval, "setup asks the owner to delete the old ones first")
        XCTAssertTrue(c.status.lines(now: clock.now).contains("Stage Manager shortcuts need setting up again so they don't change your Dock."))
        XCTAssertFalse(device(c, on: false), "a device can't show the Dock caveat")
        XCTAssertEqual(mac.runs, [])
        end(c, a)
    }

    func testAnOwedRestoreWithOldShortcutsWaitsForTheOwnerWhoSeesTheDockCaveat() {
        for key in [Keys.shortcutFormat, Keys.shortcutShowDock, Keys.shortcutShowRecentApps] { defaults.removeObject(forKey: key) }
        defaults.set(true, forKey: Keys.owed)   // from an older MeowDisplay
        mac[\.on] = false
        let c = make()
        c.appLaunched()
        c.waitUntilIdle()
        fire(c)
        XCTAssertEqual(mac.runs, [], "not run automatically")
        XCTAssertTrue(c.status.owed)
        XCTAssertEqual(c.status.dockSideEffects, ["turns Dock hiding off"], "what Settings says before the owner runs it")
        let done = expectation(description: "owner")
        c.ownerTurnOn { ok in XCTAssertTrue(ok); done.fulfill() }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(mac.runs, ["on"])
        XCTAssertFalse(c.status.owed)
    }

    func testChangedDockSettingsStopAutomaticRuns() {
        mac[\.dock] = DockSettings(showDock: true, showRecentApps: true)   // the owner changed it after setup
        let c = make()
        start(c)
        XCTAssertEqual(mac.runs, [])
        XCTAssertEqual(c.status.shortcuts, .settingsChanged)
        XCTAssertEqual(c.wireControl, "setup")
        XCTAssertTrue(c.status.lines(now: clock.now).first?.contains("changed since setup") == true)
    }

    func testARunThatChangesTheDockIsReportedAndStopsFurtherRuns() {
        mac[\.runWritesDock] = DockSettings(showDock: true, showRecentApps: true)
        let c = make()
        let a = start(c)
        XCTAssertEqual(mac.runs, ["off"])
        let last = c.status.lastChange
        XCTAssertEqual(last?.dockBefore, DockSettings(showDock: false, showRecentApps: true))
        XCTAssertEqual(last?.dockAfter, DockSettings(showDock: true, showRecentApps: true))
        XCTAssertTrue(c.status.lines(now: clock.now).contains { $0.contains("also turns Dock hiding off") })
        XCTAssertEqual(c.status.shortcuts, .settingsChanged)
        end(c, a)
        fire(c)
        XCTAssertEqual(mac.runs, ["off"], "not run again automatically")
        XCTAssertTrue(c.status.owed, "shown as owed instead")
    }

    // MARK: Rate limit

    func testAutomaticChangesAreLimitedAndItSaysSo() {
        let c = make()
        for _ in 0..<2 { end(c, start(c)); fire(c) }
        XCTAssertEqual(mac.runs, ["off", "on", "off", "on"])
        let a = start(c)
        XCTAssertEqual(mac.runs.count, 4, "a fifth change in 10 minutes doesn't run")
        XCTAssertTrue(mac[\.on])
        XCTAssertEqual(c.status.lastSkip?.reason, .paused)
        XCTAssertEqual(c.status.pausedUntil, clock.now.addingTimeInterval(600))
        XCTAssertTrue(c.status.lines(now: clock.now).contains { $0.contains("paused until") })
        end(c, a)
        clock.advance(601)
        start(c)
        XCTAssertEqual(mac.runs.count, 5, "switches again after the pause")
    }

    func testAPausedRestoreIsTriedOnceWhenThePauseEnds() {
        var policy = StageManagerController.Policy()
        policy.automaticLimit = 3
        let c = make(policy)
        end(c, start(c)); fire(c)
        let a = start(c)
        XCTAssertEqual(mac.runs, ["off", "on", "off"])
        end(c, a)
        fire(c)                                   // the restore hits the limit
        XCTAssertEqual(mac.runs.count, 3)
        XCTAssertTrue(c.status.owed)
        XCTAssertEqual(timers.delays, [600], "one later attempt, not a loop")
        clock.advance(600)
        mac[\.exit] = 1
        fire(c)
        XCTAssertEqual(mac.runs, ["off", "on", "off", "on"])
        XCTAssertTrue(c.status.owed, "failed: stays owed")
        XCTAssertEqual(timers.delays, [], "and isn't retried")
    }

    // MARK: Setup bookkeeping

    func testNewShortcutsCountOnceBothAreInShortcuts() {
        for key in [Keys.shortcutFormat, Keys.shortcutShowDock, Keys.shortcutShowRecentApps] { defaults.removeObject(forKey: key) }
        mac[\.list] = "Morning\n"
        let c = make()
        refresh(c)
        XCTAssertEqual(c.status.shortcuts, .missing)
        XCTAssertFalse(c.status.setupNeedsRemoval)
        c.prepared(StageManagerShortcutInstaller.names, with: mac[\.dock])
        mac[\.list] = "Morning\nMeowDisplay Stage Manager Off\n"   // one added so far
        refresh(c)
        XCTAssertEqual(c.status.shortcuts, .missing)
        mac[\.list] = "Morning\nMeowDisplay Stage Manager Off\nMeowDisplay Stage Manager On\n"
        refresh(c)
        XCTAssertEqual(c.status.shortcuts, .ready)
        XCTAssertEqual(defaults.integer(forKey: Keys.shortcutFormat), StageManagerShortcutInstaller.formatVersion)
        XCTAssertNil(defaults.object(forKey: Keys.pendingSetup))
    }

    func testAddingOneNewShortcutBesideAnOldOneDoesNotCount() {
        for key in [Keys.shortcutFormat, Keys.shortcutShowDock, Keys.shortcutShowRecentApps] { defaults.removeObject(forKey: key) }
        let c = make()
        c.prepared([StageManagerSwitch.onShortcut], with: mac[\.dock])   // the Off one is from before
        refresh(c)
        XCTAssertEqual(c.status.shortcuts, .outdated)
        XCTAssertTrue(c.status.setupNeedsRemoval)
    }

    private func refresh(_ c: StageManagerController) {
        let done = expectation(description: "refresh")
        c.refresh { done.fulfill() }
        wait(for: [done], timeout: 5)
    }
}

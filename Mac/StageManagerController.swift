import Foundation

/// The two settings macOS's "Set Stage Manager" action also writes on every run, On or Off:
/// `showDock` (the Dock's "Automatically hide and show": `com.apple.dock autohide`, inverted) and
/// `showRecentApps` (Stage Manager's "Show recent apps": `com.apple.WindowManager AutoHide`,
/// inverted). Both default to true in the action, so a shortcut that leaves them unset turns Dock
/// hiding off every time it runs (measured: Dock logs `setting autoHideOn=0` right after each run).
struct DockSettings: Equatable, Codable, Sendable {
    var showDock: Bool
    var showRecentApps: Bool
    /// What a shortcut without the two values sets (the action's defaults).
    static let actionDefaults = DockSettings(showDock: true, showRecentApps: true)
}

/// How one run of a command-line tool ended, with everything it printed.
struct ToolRun: Equatable, Sendable {
    /// Exit status; -1 when it couldn't start, -2 when it was stopped after the timeout.
    var status: Int32
    var output: String
    var errorOutput: String = ""

    /// The first line of stderr, short enough for Settings and the log.
    var errorSummary: String? {
        let line = errorOutput.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
        return line.map { $0.count > 160 ? String($0.prefix(159)) + "…" : $0 }
    }
}

enum ToolRunner {
    /// Runs `executable`, reading stdout and stderr WHILE it runs (a tool that fills a pipe's
    /// buffer would otherwise wait forever for a reader), and stops it after `timeout`.
    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) -> ToolRun {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in exited.signal() }
        do { try p.run() } catch { return ToolRun(status: -1, output: "", errorOutput: error.localizedDescription) }
        let reads = DispatchGroup()
        let outBox = DataBox(), errBox = DataBox()
        for (handle, box) in [(out.fileHandleForReading, outBox), (err.fileHandleForReading, errBox)] {
            reads.enter()
            DispatchQueue.global(qos: .utility).async {
                box.set(handle.readDataToEndOfFile())
                reads.leave()
            }
        }
        var timedOut = false
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            p.terminate()
            if exited.wait(timeout: .now() + 2) == .timedOut {
                kill(p.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 1)
            }
        }
        // Both pipes close when the tool exits (unless something it started keeps one open).
        _ = reads.wait(timeout: .now() + 2)
        let stdout = String(decoding: outBox.get(), as: UTF8.self)
        let stderr = String(decoding: errBox.get(), as: UTF8.self)
        return ToolRun(status: timedOut ? -2 : p.terminationStatus, output: stdout, errorOutput: stderr)
    }

    private final class DataBox: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func set(_ d: Data) { lock.withLock { data = d } }
        func get() -> Data { lock.withLock { data } }
    }
}

/// One Window-mode session's claim that Stage Manager stays off (see `StageManagerController`).
struct StageManagerHold: Hashable, Sendable {
    let id = UUID()
}

/// What Window mode needs from Stage Manager. The app uses `StageManagerController.shared`;
/// tests pass a stand-in, so a test can never run the owner's shortcuts.
protocol StageManagerCoordinating: AnyObject, Sendable {
    /// A device started Window mode. With the owner's setting on, the FIRST one turns Stage Manager
    /// off. `changed` runs (on any queue) once that is settled, for the state message.
    func windowModeStarted(changed: @escaping @Sendable () -> Void) -> StageManagerHold
    /// That device's Window mode ended. After the last one ends, an owed Stage Manager comes back
    /// on after a grace period that a new start cancels.
    func windowModeEnded(_ hold: StageManagerHold)
    /// A person with control confirmed Turn Off / Turn On on a device. `done(true)` when macOS applied it.
    func deviceAsked(on: Bool, done: @escaping @Sendable (Bool) -> Void)
    /// `workspaceState.stageManagerControl`: "ready" or "setup". Never blocks.
    var wireControl: String { get }
    /// Stage Manager is on (read at most every 2 s). Never runs anything.
    var isOnRecently: Bool { get }
}

/// What Settings shows about Stage Manager switching. Plain values; `lines` words them.
struct StageManagerStatus: Equatable, Sendable {
    enum Shortcuts: Equatable, Sendable {
        /// Not checked yet.
        case unknown
        /// One or both aren't in Shortcuts.
        case missing
        case ready
        /// Made before this MeowDisplay (or by hand without saying so): they may change the Dock.
        case outdated
        /// The Dock or recent-apps setting changed since they were made: running them would change it back.
        case settingsChanged
    }

    struct Change: Equatable, Codable, Sendable {
        enum Outcome: String, Codable, Sendable { case done, notApplied, failed, timedOut, couldNotStart }
        var turnOn: Bool
        var automatic: Bool
        var at: Date
        var outcome: Outcome
        var exitCode: Int32
        var errorSummary: String?
        /// Set only when the Dock or recent-apps setting read back differently after the run.
        var dockBefore: DockSettings?
        var dockAfter: DockSettings?
    }

    /// An automatic (or device) change that MeowDisplay didn't run, and why.
    struct Skip: Equatable, Sendable {
        enum Reason: Equatable, Sendable { case notSetUp, needsSetUpAgain, paused }
        var turnOn: Bool
        var reason: Reason
        var at: Date
    }

    var shortcuts: Shortcuts = .unknown
    var present: Set<String> = []
    var copies: [String] = []
    /// Some shortcuts exist but aren't usable as they are: the owner deletes them in Shortcuts
    /// before setup can add new ones (Shortcuts would add numbered copies instead).
    var setupNeedsRemoval = false
    /// What the existing shortcuts set besides Stage Manager, when known, and the live settings.
    var shortcutDock: DockSettings?
    var liveDock: DockSettings?
    /// MeowDisplay turned Stage Manager off and owes turning it back on.
    var owed = false
    /// Devices in Window mode right now.
    var windowModes = 0
    /// When an owed Stage Manager comes back on (grace period, or after a pause).
    var restoreAt: Date?
    /// Automatic switching is paused until then (it switched too often).
    var pausedUntil: Date?
    var lastChange: Change?
    var lastSkip: Skip?

    /// Running the existing shortcuts would change these (Dock caveat for an explicit Turn On).
    var dockSideEffects: [String] {
        guard shortcuts != .ready, let live = liveDock else { return [] }
        let would = shortcutDock ?? .actionDefaults
        return Self.describe(from: live, to: would)
    }

    static func describe(from a: DockSettings, to b: DockSettings) -> [String] {
        var out: [String] = []
        if a.showDock != b.showDock {
            out.append(b.showDock ? String(localized: "turns Dock hiding off") : String(localized: "turns Dock hiding on"))
        }
        if a.showRecentApps != b.showRecentApps {
            out.append(b.showRecentApps ? String(localized: "shows recent apps in Stage Manager") : String(localized: "hides recent apps in Stage Manager"))
        }
        return out
    }

    /// Short, plain lines for Settings, most important first.
    func lines(now: Date) -> [String] {
        func time(_ d: Date) -> String { d.formatted(date: .omitted, time: .shortened) }
        var out: [String] = []
        switch shortcuts {
        case .outdated:
            out.append(String(localized: "Stage Manager shortcuts need setting up again so they don't change your Dock."))
        case .settingsChanged:
            out.append(String(localized: "Your Dock or recent apps setting changed since setup. Set up the shortcuts again so they don't change it back."))
        default: break
        }
        if owed {
            if windowModes > 0 {
                out.append(String(localized: "Turned off for Window mode. MeowDisplay turns it back on after Window mode ends."))
            } else if let at = restoreAt {
                out.append(String(localized: "Turning Stage Manager back on at \(time(at)), unless Window mode starts again."))
            } else {
                out.append(String(localized: "MeowDisplay turned Stage Manager off and hasn't turned it back on."))
            }
        }
        if let until = pausedUntil, until > now {
            out.append(String(localized: "Automatic switching is paused until \(time(until)): it switched too often."))
        }
        if let s = lastSkip, s.at >= (lastChange?.at ?? .distantPast) {
            let what = s.turnOn ? String(localized: "Didn't turn it on") : String(localized: "Didn't turn it off")
            let why: String
            switch s.reason {
            case .notSetUp: why = String(localized: "the shortcuts aren't set up")
            case .needsSetUpAgain: why = String(localized: "the shortcuts need setting up again")
            case .paused: why = String(localized: "automatic switching is paused")
            }
            out.append("\(time(s.at)): \(what): \(why).")
        }
        if let c = lastChange {
            let what = c.turnOn ? String(localized: "Turned on") : String(localized: "Turned off")
            let how = c.automatic ? String(localized: "automatically") : String(localized: "when asked")
            let result: String
            switch c.outcome {
            case .done: result = String(localized: "done")
            case .notApplied: result = String(localized: "macOS didn't apply it")
            case .failed: result = String(localized: "the shortcut failed (exit \(Int(c.exitCode)))")
            case .timedOut: result = String(localized: "the shortcut didn't finish in time")
            case .couldNotStart: result = String(localized: "Shortcuts couldn't start")
            }
            var line = String(localized: "Last change: \(what) \(how) at \(time(c.at)): \(result).")
            if c.outcome != .done, let e = c.errorSummary { line += " " + e }
            out.append(line)
            if let a = c.dockBefore, let b = c.dockAfter, a != b {
                let changes = Self.describe(from: a, to: b).joined(separator: String(localized: " and "))
                out.append(String(localized: "That change also \(changes). Check Desktop & Dock in System Settings."))
            }
        }
        return out
    }
}

/// The ONE owner of everything MeowDisplay does to Stage Manager: a serial queue holds all state,
/// so starts, stops, device requests, the launch restore and Settings never race.
///
/// - Counts devices in Window mode. With the owner's setting on, the first start turns Stage
///   Manager off; it comes back on only after the LAST one ends, after `Policy.grace` (a start
///   within it cancels the restore, so reconnects and Mirror ↔ Window switches don't toggle).
/// - "Owed" is saved BEFORE turning it off (a crash mid-run still restores at the next launch) and
///   cleared only once it is seen on again. A restore that fails stays owed and says so.
/// - Automatic changes run only with shortcuts made by this format AND for the Dock and recent-apps
///   settings in effect now; otherwise nothing runs and Settings asks to set them up again.
/// - At most `Policy.automaticLimit` automatic changes per `Policy.automaticPeriod`; then automatic
///   switching pauses for a period and says so. Nothing is retried in a loop.
/// - Every run is read back: Stage Manager's state, and the Dock settings (any change is shown).
final class StageManagerController: StageManagerCoordinating, @unchecked Sendable {
    static let shared = StageManagerController()
    /// Posted on the main queue when `status` changes.
    static let didChange = Notification.Name("StageManagerController.didChange")

    /// Saved in this app's defaults.
    enum Keys {
        static let owed = StageManagerSwitch.turnedOffKey
        static let shortcutFormat = "stageManager.shortcutFormat"
        static let shortcutShowDock = "stageManager.shortcutShowDock"
        static let shortcutShowRecentApps = "stageManager.shortcutShowRecentApps"
        static let pendingSetup = "stageManager.pendingShortcutSetup"
        static let lastChange = "stageManager.lastChange"
    }

    /// The Mac, injectable for tests.
    struct System: Sendable {
        var isOn: @Sendable () -> Bool
        var dockSettings: @Sendable () -> DockSettings
        var runShortcuts: @Sendable (_ arguments: [String]) -> ToolRun
        /// Waits (between state reads; before reading the Dock back).
        var pause: @Sendable (TimeInterval) -> Void
        /// How long macOS gets to apply a change before it counts as not applied.
        var settleTimeout: TimeInterval

        static let live = System(isOn: StageManagerSwitch.readIsOn, dockSettings: StageManagerSwitch.readDockSettings,
                                 runShortcuts: StageManagerSwitch.runShortcuts, pause: { Thread.sleep(forTimeInterval: $0) },
                                 settleTimeout: 4)
    }

    struct Policy: Sendable {
        /// After the last Window mode ends, before an owed Stage Manager comes back on.
        var grace: TimeInterval = 25
        var automaticLimit = 4
        var automaticPeriod: TimeInterval = 600
        /// How long a `shortcuts list` answer is reused.
        var listCacheSeconds: TimeInterval = 30
    }

    private let queue = DispatchQueue(label: "meow.stagemanager", qos: .utility)
    private let system: System
    private let defaults: UserDefaults
    private let policy: Policy
    private let now: @Sendable () -> Date
    private let schedule: @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void

    // `queue` only.
    private var holds = Set<StageManagerHold>()
    private var timerGeneration = 0
    private var automaticRuns: [Date] = []
    private var listedAt: Date?
    private var state = StageManagerStatus()

    // Any thread.
    private let lock = NSLock()
    private var snapshot = StageManagerStatus()
    private var onCache: (on: Bool, at: TimeInterval)?

    init(system: System = .live, defaults: UserDefaults = .standard, policy: Policy = Policy(),
         now: @escaping @Sendable () -> Date = { Date() },
         schedule: (@Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void)? = nil) {
        self.system = system
        self.defaults = defaults
        self.policy = policy
        self.now = now
        let timerQueue = DispatchQueue(label: "meow.stagemanager.timer")
        self.schedule = schedule ?? { delay, work in timerQueue.asyncAfter(deadline: .now() + delay, execute: work) }
        state.owed = defaults.bool(forKey: Keys.owed)
        if let data = defaults.data(forKey: Keys.lastChange) {
            state.lastChange = try? JSONDecoder().decode(StageManagerStatus.Change.self, from: data)
        }
        snapshot = state
    }

    // MARK: Reading (any thread, never blocks on a run)

    var status: StageManagerStatus { lock.withLock { snapshot } }

    var wireControl: String { status.shortcuts == .ready ? "ready" : "setup" }

    var isOnRecently: Bool {
        let t = ProcessInfo.processInfo.systemUptime
        if let c = lock.withLock({ onCache }), t - c.at < 2 { return c.on }
        let on = system.isOn()
        lock.withLock { onCache = (on, t) }
        return on
    }

    /// The Dock and recent-apps settings in effect now (what new shortcuts get).
    var liveDockSettings: DockSettings { system.dockSettings() }

    var offDuringWindowMode: Bool { defaults.bool(forKey: StageManagerSwitch.offDuringWindowModeKey) }

    /// Waits until everything asked so far is done (tests).
    func waitUntilIdle() { queue.sync {} }

    // MARK: Window mode

    func windowModeStarted(changed: @escaping @Sendable () -> Void) -> StageManagerHold {
        let hold = StageManagerHold()
        queue.async { [self] in
            holds.insert(hold)
            cancelTimer()
            listShortcuts(force: false)
            if holds.count == 1, offDuringWindowMode { turnOffAutomatically() }
            publish()
            changed()
        }
        return hold
    }

    func windowModeEnded(_ hold: StageManagerHold) {
        queue.async { [self] in
            guard holds.remove(hold) != nil else { return }
            if holds.isEmpty, state.owed { startTimer(after: policy.grace) }
            publish()
        }
    }

    // MARK: Asked by a person

    func deviceAsked(on: Bool, done: @escaping @Sendable (Bool) -> Void) {
        queue.async { [self] in
            listShortcuts(force: false)
            let ok = on ? turnOnWhenAsked(requireCurrentShortcuts: true) : turnOffWhenAsked()
            publish()
            done(ok)
        }
    }

    /// Settings ▸ Turn Stage Manager On: the owner's explicit restore. Runs even with outdated
    /// shortcuts (Settings states what they also change first) and while automatic switching is paused.
    func ownerTurnOn(done: @escaping @MainActor @Sendable (Bool) -> Void) {
        queue.async { [self] in
            listShortcuts(force: true)
            let ok = turnOnWhenAsked(requireCurrentShortcuts: false)
            publish()
            Task { @MainActor in done(ok) }
        }
    }

    /// The app started: a restore owed from before (a quit or crash during Window mode) runs after
    /// the grace period, so a device reconnecting right away doesn't make it toggle.
    func appLaunched() {
        queue.async { [self] in
            if state.owed, holds.isEmpty { startTimer(after: policy.grace) }
            publish()
        }
    }

    /// Re-checks the shortcuts (and whether Stage Manager is on again), then `done` on the main actor.
    func refresh(done: (@MainActor @Sendable () -> Void)? = nil) {
        queue.async { [self] in
            listShortcuts(force: true)
            if state.owed, readIsOn() { owe(false); Log.info("stage manager: on again, nothing left to restore") }
            publish()
            if let done { Task { @MainActor in done() } }
        }
    }

    // MARK: Setup bookkeeping

    /// Setup prepared these shortcuts with these settings; they count once all of them are in Shortcuts.
    func prepared(_ names: [String], with settings: DockSettings) {
        queue.async { [self] in
            defaults.set(["format": StageManagerShortcutInstaller.formatVersion, "showDock": settings.showDock,
                          "showRecentApps": settings.showRecentApps, "names": names] as [String: Any], forKey: Keys.pendingSetup)
        }
    }

    /// The owner says they made both shortcuts by hand with the settings Setup showed (the live ones).
    func madeByHand(done: (@MainActor @Sendable () -> Void)? = nil) {
        queue.async { [self] in
            record(system.dockSettings())
            listShortcuts(force: true)
            publish()
            if let done { Task { @MainActor in done() } }
        }
    }

    // MARK: Private (queue only)

    private func readIsOn() -> Bool {
        let on = system.isOn()
        lock.withLock { onCache = (on, ProcessInfo.processInfo.systemUptime) }
        return on
    }

    private func owe(_ owed: Bool) {
        state.owed = owed
        defaults.set(owed, forKey: Keys.owed)
        if !owed { cancelTimer() }
    }

    private func startTimer(after delay: TimeInterval) {
        timerGeneration += 1
        let generation = timerGeneration
        state.restoreAt = now().addingTimeInterval(delay)
        schedule(delay) { [weak self] in
            guard let self else { return }
            self.queue.async { self.timerFired(generation) }
        }
    }

    private func cancelTimer() {
        timerGeneration += 1
        state.restoreAt = nil
    }

    private func timerFired(_ generation: Int) {
        guard generation == timerGeneration, holds.isEmpty else { return }
        state.restoreAt = nil
        listShortcuts(force: false)
        restoreAutomatically()
        publish()
    }

    /// The format and settings the existing shortcuts were made with (nil: unknown or older format).
    private var installed: DockSettings? {
        guard defaults.integer(forKey: Keys.shortcutFormat) == StageManagerShortcutInstaller.formatVersion,
              defaults.object(forKey: Keys.shortcutShowDock) != nil, defaults.object(forKey: Keys.shortcutShowRecentApps) != nil
        else { return nil }
        return DockSettings(showDock: defaults.bool(forKey: Keys.shortcutShowDock),
                            showRecentApps: defaults.bool(forKey: Keys.shortcutShowRecentApps))
    }

    private func record(_ settings: DockSettings) {
        defaults.set(StageManagerShortcutInstaller.formatVersion, forKey: Keys.shortcutFormat)
        defaults.set(settings.showDock, forKey: Keys.shortcutShowDock)
        defaults.set(settings.showRecentApps, forKey: Keys.shortcutShowRecentApps)
        defaults.removeObject(forKey: Keys.pendingSetup)
        Log.info("stage manager setup: shortcuts recorded (format \(StageManagerShortcutInstaller.formatVersion), showDock=\(settings.showDock), showRecentApps=\(settings.showRecentApps))")
    }

    /// `shortcuts list` (reused for `Policy.listCacheSeconds`), then what that means.
    private func listShortcuts(force: Bool) {
        let t = now()
        if force || listedAt.map({ t.timeIntervalSince($0) >= policy.listCacheSeconds }) ?? true {
            let r = system.runShortcuts(["list"])
            let found = StageManagerShortcutInstaller.inventory(listOutput: r.status == 0 ? r.output : "")
            if r.status != 0 { Log.info("stage manager: shortcuts list failed (\(r.status)) \(r.errorSummary ?? "")") }
            state.present = found.present
            state.copies = found.copies
            listedAt = r.status == 0 ? t : nil
            if r.status != 0 { state.shortcuts = .unknown; return }
            promotePendingSetup()
        }
        let all = state.present.count == StageManagerShortcutInstaller.names.count
        let live = system.dockSettings()
        let made = installed
        state.liveDock = live
        state.shortcutDock = made
        state.setupNeedsRemoval = !state.present.isEmpty && made != live
        state.shortcuts = !all ? .missing : made == nil ? .outdated : made == live ? .ready : .settingsChanged
    }

    /// Shortcuts that setup prepared count once they're all there: either setup made both (so
    /// none is from before), or the ones already there were made with the same settings.
    private func promotePendingSetup() {
        guard state.present.count == StageManagerShortcutInstaller.names.count,
              let p = defaults.dictionary(forKey: Keys.pendingSetup),
              p["format"] as? Int == StageManagerShortcutInstaller.formatVersion,
              let dock = p["showDock"] as? Bool, let recent = p["showRecentApps"] as? Bool,
              let names = p["names"] as? [String] else { return }
        let settings = DockSettings(showDock: dock, showRecentApps: recent)
        if Set(names) == Set(StageManagerShortcutInstaller.names) || installed == settings { record(settings) }
    }

    /// Why an automatic change may not run now (nil: it may, and it is counted).
    private func automaticBlock(turnOn: Bool) -> StageManagerStatus.Skip.Reason? {
        switch state.shortcuts {
        case .ready: break
        case .unknown, .missing: return .notSetUp
        case .outdated, .settingsChanged: return .needsSetUpAgain
        }
        let t = now()
        if let until = state.pausedUntil {
            if t < until { return .paused }
            state.pausedUntil = nil
        }
        automaticRuns.removeAll { t.timeIntervalSince($0) >= policy.automaticPeriod }
        if automaticRuns.count >= policy.automaticLimit {
            state.pausedUntil = t.addingTimeInterval(policy.automaticPeriod)
            Log.info("stage manager: \(automaticRuns.count) automatic changes in \(Int(policy.automaticPeriod)) s; pausing automatic switching")
            return .paused
        }
        automaticRuns.append(t)
        return nil
    }

    private func skip(turnOn: Bool, _ reason: StageManagerStatus.Skip.Reason) {
        state.lastSkip = .init(turnOn: turnOn, reason: reason, at: now())
        Log.info("stage manager: didn't turn it \(turnOn ? "on" : "off"): \(reason)")
    }

    private func turnOffAutomatically() {
        guard readIsOn() else { return }   // already off (by the owner, or still off from before)
        if let reason = automaticBlock(turnOn: false) { return skip(turnOn: false, reason) }
        owe(true)   // before the attempt: a crash mid-run still restores at the next launch
        if !run(turnOn: false, automatic: true), readIsOn() { owe(false) }   // still on: nothing to restore
    }

    private func restoreAutomatically() {
        guard state.owed else { return }
        if readIsOn() { owe(false); Log.info("stage manager: already on, nothing to restore"); return }
        if let reason = automaticBlock(turnOn: true) {
            skip(turnOn: true, reason)
            // One later attempt once the pause ends (a start cancels it). A failure isn't retried.
            if reason == .paused, holds.isEmpty, let until = state.pausedUntil {
                startTimer(after: max(1, until.timeIntervalSince(now())))
            }
            return
        }
        if run(turnOn: true, automatic: true) { owe(false) }
    }

    private func turnOffWhenAsked() -> Bool {
        guard readIsOn() else { return true }
        guard state.shortcuts == .ready else {
            skip(turnOn: false, state.shortcuts == .outdated || state.shortcuts == .settingsChanged ? .needsSetUpAgain : .notSetUp)
            return false
        }
        owe(true)
        let ok = run(turnOn: false, automatic: false)
        if !ok, readIsOn() { owe(false) }
        return ok
    }

    /// From a device (current shortcuts only) or the owner in Settings (any two shortcuts).
    private func turnOnWhenAsked(requireCurrentShortcuts: Bool) -> Bool {
        if readIsOn() { if state.owed { owe(false) }; return true }
        let usable = requireCurrentShortcuts ? state.shortcuts == .ready
            : state.present.count == StageManagerShortcutInstaller.names.count
        guard usable else {
            skip(turnOn: true, state.shortcuts == .outdated || state.shortcuts == .settingsChanged ? .needsSetUpAgain : .notSetUp)
            return false
        }
        let ok = run(turnOn: true, automatic: false)
        if ok { owe(false) }
        return ok
    }

    /// Runs one shortcut, waits for macOS to apply it, reads the Dock settings back, records it all.
    private func run(turnOn: Bool, automatic: Bool) -> Bool {
        let name = turnOn ? StageManagerSwitch.onShortcut : StageManagerSwitch.offShortcut
        let before = system.dockSettings()
        let r = system.runShortcuts(["run", name])
        let applied: Bool
        if r.status == 0 || r.status == -2 {   // a run stopped at the timeout may still have applied
            applied = settled(on: turnOn)
        } else {
            applied = readIsOn() == turnOn
        }
        system.pause(1)   // the Dock writes its setting a moment after the run
        let after = system.dockSettings()
        let outcome: StageManagerStatus.Change.Outcome = applied ? .done
            : r.status == 0 ? .notApplied : r.status == -2 ? .timedOut : r.status == -1 ? .couldNotStart : .failed
        let change = StageManagerStatus.Change(turnOn: turnOn, automatic: automatic, at: now(), outcome: outcome,
                                               exitCode: r.status, errorSummary: r.errorSummary,
                                               dockBefore: before != after ? before : nil, dockAfter: before != after ? after : nil)
        state.lastChange = change
        if let data = try? JSONEncoder().encode(change) { defaults.set(data, forKey: Keys.lastChange) }
        Log.info("stage manager: turn \(turnOn ? "on" : "off") (\(automatic ? "automatic" : "asked")): \(outcome.rawValue), exit \(r.status)\(r.errorSummary.map { ", stderr: \($0)" } ?? "")")
        if before != after {
            Log.info("stage manager: the shortcut also changed Dock settings: showDock \(before.showDock)→\(after.showDock), showRecentApps \(before.showRecentApps)→\(after.showRecentApps)")
            listShortcuts(force: false)   // the shortcuts no longer match: automatic runs stop
        }
        return applied
    }

    /// Waits up to `settleTimeout` for Stage Manager to read `on`.
    private func settled(on: Bool) -> Bool {
        let step = 0.2
        var waited = 0.0
        while true {
            if readIsOn() == on { return true }
            if waited >= system.settleTimeout { return false }
            system.pause(step)
            waited += step
        }
    }

    private func publish() {
        state.windowModes = holds.count
        let s = state
        let changed = lock.withLock { () -> Bool in
            defer { snapshot = s }
            return snapshot != s
        }
        if changed { DispatchQueue.main.async { NotificationCenter.default.post(name: Self.didChange, object: nil) } }
    }
}

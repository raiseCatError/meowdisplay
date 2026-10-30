import AppKit
import SwiftUI

/// Stage Manager on this Mac. macOS keeps windows in Stage Manager's side strip paused, so Window
/// mode can't show them live (WINDOW-WORKSPACE-DESIGN W2; capture lab 2026-10-30: no public or
/// private capture returns the real window from the strip on macOS 27.0).
///
/// Turning it off goes through macOS's own control: the "Set Stage Manager" action in Shortcuts
/// (the system's StageManagerToggleIntent, the same one Control Center uses), run from two
/// shortcuts the owner makes once. Writing the `GloballyEnabled` preference is NOT used: the
/// lab measured that macOS doesn't apply it (unchanged 3 s later; 27.0, 26A428), which leaves the
/// preference saying something that isn't true. MeowDisplay changes Stage Manager only when the
/// owner asks (here, or confirmed from a device with control) and turns it back on afterwards.
enum StageManagerSwitch {
    /// MeowDisplay turned it off and owes turning it back on.
    static let turnedOffKey = "stageManager.turnedOffByMeowDisplay"
    /// Settings ▸ System: turn it off while a device uses Window mode (off by default).
    static let offDuringWindowModeKey = "stageManager.offDuringWindowMode"
    static let offShortcut = "MeowDisplay Stage Manager Off"
    static let onShortcut = "MeowDisplay Stage Manager On"

    /// Reads the current state (macOS keeps it in the WindowManager preference). Injectable for tests.
    nonisolated(unsafe) static var readIsOn: () -> Bool = {
        CFPreferencesAppSynchronize("com.apple.WindowManager" as CFString)
        return (CFPreferencesCopyAppValue("GloballyEnabled" as CFString, "com.apple.WindowManager" as CFString) as? Bool) ?? false
    }
    /// Runs `/usr/bin/shortcuts` with these arguments: exit status and output. Injectable for tests.
    nonisolated(unsafe) static var runShortcuts: (_ arguments: [String]) -> (status: Int32, output: String) = { arguments in
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        p.arguments = arguments
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return (-1, "") }
        let deadline = Date().addingTimeInterval(15)
        while p.isRunning, Date() < deadline { usleep(50_000) }
        if p.isRunning { p.terminate(); return (-2, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }
    /// How long to wait for macOS to apply a change before saying it didn't.
    nonisolated(unsafe) static var settleTimeout: TimeInterval = 4

    static var isOn: Bool { readIsOn() }

    /// `isOn`, read at most every 2 s (for the frequent workspace state messages).
    static var isOnRecently: Bool {
        cacheLock.lock(); defer { cacheLock.unlock() }
        let now = ProcessInfo.processInfo.systemUptime
        if let c = cached, now - c.at < 2 { return c.on }
        let on = isOn
        cached = (on, now)
        return on
    }
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cached: (on: Bool, at: TimeInterval)?
    nonisolated(unsafe) private static var shortcutsCache: (ready: Bool, at: TimeInterval)?

    static var offDuringWindowMode: Bool {
        get { UserDefaults.standard.bool(forKey: offDuringWindowModeKey) }
        set { UserDefaults.standard.set(newValue, forKey: offDuringWindowModeKey) }
    }

    /// Both shortcuts exist (checked with `shortcuts list`, remembered for 30 s).
    static func shortcutsReady(refresh: Bool = false) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        if !refresh, let c = cacheLock.withLock({ shortcutsCache }), now - c.at < 30 { return c.ready }
        let r = runShortcuts(["list"])
        let found = StageManagerShortcutInstaller.inventory(listOutput: r.status == 0 ? r.output : "")
        let ready = r.status == 0 && found.present.count == StageManagerShortcutInstaller.names.count
        cacheLock.withLock { shortcutsCache = (ready, now); inventoryCache = found }
        return ready
    }

    /// What the last check found: which of the two exist, and numbered copies of them.
    static var lastInventory: (present: Set<String>, copies: [String])? { cacheLock.withLock { inventoryCache } }
    nonisolated(unsafe) private static var inventoryCache: (present: Set<String>, copies: [String])?

    /// The last known answer of `shortcutsReady`, without running anything (state messages).
    static var shortcutsReadyKnown: Bool? { cacheLock.withLock { shortcutsCache?.ready } }

    /// Asks macOS to turn Stage Manager on or off with the owner's shortcut, then waits for it to
    /// take effect. True only when it did. Blocks: call off the main thread and the engine queue.
    @discardableResult
    static func set(_ on: Bool) -> Bool {
        guard shortcutsReady() else { Log.info("stage manager: shortcuts not set up"); return false }
        let r = runShortcuts(["run", on ? onShortcut : offShortcut])
        guard r.status == 0 else { Log.info("stage manager: shortcut failed (\(r.status))"); return false }
        let deadline = Date().addingTimeInterval(settleTimeout)
        repeat {
            cacheLock.withLock { cached = nil }
            if isOn == on { return true }
            usleep(200_000)
        } while Date() < deadline
        Log.info("stage manager: macOS didn't apply the change")
        return false
    }

    /// Turns it off for Window mode, remembering to turn it back on. True when it is off.
    @discardableResult
    static func turnOffForWindowMode() -> Bool {
        guard isOn else { return true }
        guard set(false) else { return false }
        UserDefaults.standard.set(true, forKey: turnedOffKey)
        Log.info("stage manager: turned off for Window mode")
        return true
    }

    /// Turns it back on if MeowDisplay turned it off and it is still off. Called when Window mode
    /// ends and when the app starts (after a crash or quit during Window mode).
    static func restoreIfTurnedOffByUs() {
        guard UserDefaults.standard.bool(forKey: turnedOffKey) else { return }
        UserDefaults.standard.set(false, forKey: turnedOffKey)
        if !isOn, set(true) { Log.info("stage manager: turned back on") }
    }

    /// Runs `body` on a utility queue (shortcuts take a moment), then `done` on the main queue.
    static func inBackground(_ body: @escaping @Sendable () -> Void, done: (@MainActor @Sendable () -> Void)? = nil) {
        DispatchQueue.global(qos: .utility).async {
            body()
            if let done { Task { @MainActor in done() } }
        }
    }
}

/// Settings ▸ System ▸ Stage Manager: what it means for Window mode, the one-time setup of the two
/// shortcuts that let MeowDisplay switch it, and the owner's choice to turn it off while a device
/// uses Window mode (turned back on afterwards). Off by default.
struct StageManagerSettingsSection: View {
    @State private var isOn = StageManagerSwitch.isOn
    @State private var ready = StageManagerSwitch.shortcutsReadyKnown ?? false
    @State private var offDuringWindowMode = StageManagerSwitch.offDuringWindowMode
    @State private var confirming = false
    @State private var showingSetup = false
    @State private var setup: SetupPhase = .idle
    @State private var missing: [String] = []
    @State private var copies: [String] = []
    private enum SetupPhase: Equatable { case idle, preparing, waiting(until: Date), failed(String) }

    var body: some View {
        Section {
            LabeledContent("Stage Manager", value: isOn ? String(localized: "On") : String(localized: "Off"))
            LabeledContent("Switching from MeowDisplay") {
                HStack {
                    Text(statusText).foregroundStyle(.secondary)
                    if ready {
                        Button("Open in Shortcuts") { StageManagerShortcutInstaller.view(StageManagerSwitch.offShortcut) }
                    } else {
                        Button(setup == .idle || isFailed ? "Set Up Automatically" : "Setting Up…") { setUp() }
                            .disabled(setup == .preparing || isWaiting)
                    }
                    Button("How It Works…") { showingSetup = true }
                }
            }
            if isWaiting {
                Text("Shortcuts is asking you to add \(missing.map { "“\($0)”" }.joined(separator: " and ")). Click Add Shortcut there; MeowDisplay notices when it's done.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if case .failed(let message) = setup {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            if !copies.isEmpty {
                Text("Shortcuts also has \(copies.map { "“\($0)”" }.joined(separator: ", ")). MeowDisplay uses only the exact names; you can delete the copies in Shortcuts.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Turn Off During Window Mode", isOn: Binding(get: { offDuringWindowMode && ready }, set: { on in
                if on { confirming = true } else { offDuringWindowMode = false; StageManagerSwitch.offDuringWindowMode = false }
            }))
            .disabled(!ready)
            .confirmationDialog("Turn off Stage Manager while a device uses Window mode?", isPresented: $confirming) {
                Button("Turn Off During Window Mode") { offDuringWindowMode = true; StageManagerSwitch.offDuringWindowMode = true }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("MeowDisplay turns it back on when Window mode ends.")
            }
        } header: {
            Text("Stage Manager")
        } footer: {
            Text("macOS pauses windows in Stage Manager's side strip, so a device sees their last picture until they're on the Mac's stage. Windows on the current stage always stream. A device with control can show one on the Mac, or, once set up, turn Stage Manager off for Window mode after you confirm there.")
        }
        .onAppear { refresh() }
        .sheet(isPresented: $showingSetup, onDismiss: refresh) { StageManagerShortcutSetup() }
    }

    private var isWaiting: Bool { if case .waiting = setup { return true }; return false }
    private var isFailed: Bool { if case .failed = setup { return true }; return false }

    private var statusText: String {
        if ready { return String(localized: "Ready") }
        switch setup {
        case .preparing: return String(localized: "Preparing…")
        case .waiting: return String(localized: "Waiting for you in Shortcuts")
        default:
            return missing.count == 1 ? String(localized: "“\(missing[0])” missing") : String(localized: "Not set up")
        }
    }

    private func refresh() {
        isOn = StageManagerSwitch.isOn
        StageManagerSwitch.inBackground({ _ = StageManagerSwitch.shortcutsReady(refresh: true) }) {
            apply()
        }
    }

    private func apply() {
        ready = StageManagerSwitch.shortcutsReadyKnown ?? false
        let found = StageManagerSwitch.lastInventory ?? (present: [], copies: [])
        missing = StageManagerShortcutInstaller.missing(present: found.present)
        copies = found.copies
        if ready, setup != .idle {
            setup = .idle
            StageManagerShortcutInstaller.cleanUp()
            Log.info("stage manager setup: both shortcuts are in Shortcuts")
        }
    }

    /// Prepares only the missing shortcuts, opens them in Shortcuts for the owner to add, then
    /// checks every 2 s (for up to 3 minutes) until both exist.
    private func setUp() {
        setup = .preparing
        StageManagerSwitch.inBackground({ _ = StageManagerSwitch.shortcutsReady(refresh: true) }) {
            apply()
            guard !ready else { return }
            let wanted = missing
            let box = PreparedBox()
            StageManagerSwitch.inBackground({ box.result = StageManagerShortcutInstaller.prepare(wanted) }) {
                switch box.result {
                case .success(let files)?:
                    guard StageManagerShortcutInstaller.open(files) else { setup = .failed(String(localized: "Shortcuts didn't open. Try again, or make them yourself (How It Works…).")); return }
                    setup = .waiting(until: Date().addingTimeInterval(180))
                    poll()
                case .failure(.sign)?:
                    setup = .failed(String(localized: "macOS couldn't sign the shortcuts (it needs an internet connection). Try again in a moment."))
                default:
                    setup = .failed(String(localized: "MeowDisplay couldn't prepare the shortcuts. Try again, or make them yourself (How It Works…)."))
                }
            }
        }
    }

    private func poll() {
        guard case .waiting(let until) = setup else { return }
        guard Date() < until else {
            setup = .failed(String(localized: "Not added yet. Click Set Up Automatically to show them again."))
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            StageManagerSwitch.inBackground({ _ = StageManagerSwitch.shortcutsReady(refresh: true) }) {
                apply()
                if !ready { poll() }
            }
        }
    }
}

/// The one-time setup: two shortcuts, each with the system's "Set Stage Manager" action.
private struct StageManagerShortcutSetup: View {
    @Environment(\.dismiss) private var dismiss
    @State private var ready = StageManagerSwitch.shortcutsReadyKnown ?? false
    @State private var checking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Let MeowDisplay Switch Stage Manager").font(.title3.weight(.semibold))
            Text("macOS lets apps change Stage Manager only through Shortcuts. Set Up Automatically prepares these two shortcuts and opens them in Shortcuts, which asks you to Add Shortcut for each; nothing is added without that click. MeowDisplay runs them only when you allow it. To make them yourself instead:")
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                step(1, "In Shortcuts, choose File ▸ New Shortcut and name it “\(StageManagerSwitch.offShortcut)”.")
                step(2, "Add the action “Set Stage Manager” and set it to Off.")
                step(3, "Make a second shortcut named “\(StageManagerSwitch.onShortcut)” with “Set Stage Manager” set to On.")
            }
            Text("The names must match exactly. MeowDisplay never turns Stage Manager off without your confirmation, and turns it back on when Window mode ends.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Label(ready ? "Both shortcuts found" : "Not found yet", systemImage: ready ? "checkmark.circle.fill" : "circle.dashed")
                    .foregroundStyle(ready ? .green : .secondary)
                Spacer()
                Button("Open Shortcuts") { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Shortcuts.app")) }
                Button(checking ? "Checking…" : "Check Again") {
                    checking = true
                    StageManagerSwitch.inBackground({ _ = StageManagerSwitch.shortcutsReady(refresh: true) }) {
                        ready = StageManagerSwitch.shortcutsReadyKnown ?? false; checking = false
                    }
                }.disabled(checking)
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(n).").monospacedDigit().foregroundStyle(.secondary)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Carries a background result back to the main actor.
private final class PreparedBox: @unchecked Sendable {
    var result: Result<[URL], StageManagerShortcutInstaller.InstallError>?
}

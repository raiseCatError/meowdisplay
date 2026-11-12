import AppKit
import Combine
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
/// Every change goes through `StageManagerController` (one serial owner, counted, rate limited).
enum StageManagerSwitch {
    /// MeowDisplay turned it off and owes turning it back on (`StageManagerController`).
    static let turnedOffKey = "stageManager.turnedOffByMeowDisplay"
    /// Settings ▸ System: turn it off while a device uses Window mode (off by default).
    static let offDuringWindowModeKey = "stageManager.offDuringWindowMode"
    static let offShortcut = "MeowDisplay Stage Manager Off"
    static let onShortcut = "MeowDisplay Stage Manager On"

    /// The current state (macOS keeps it in the WindowManager preference). Only ever read.
    @Sendable static func readIsOn() -> Bool {
        CFPreferencesAppSynchronize("com.apple.WindowManager" as CFString)
        return (CFPreferencesCopyAppValue("GloballyEnabled" as CFString, "com.apple.WindowManager" as CFString) as? Bool) ?? false
    }

    /// The Dock and recent-apps settings the Set Stage Manager action also writes. Only ever read.
    @Sendable static func readDockSettings() -> DockSettings {
        CFPreferencesAppSynchronize("com.apple.dock" as CFString)
        CFPreferencesAppSynchronize("com.apple.WindowManager" as CFString)
        let autohide = CFPreferencesCopyAppValue("autohide" as CFString, "com.apple.dock" as CFString) as? Bool ?? false
        let hideRecent = CFPreferencesCopyAppValue("AutoHide" as CFString, "com.apple.WindowManager" as CFString) as? Bool ?? false
        return DockSettings(showDock: !autohide, showRecentApps: !hideRecent)
    }

    /// Runs `/usr/bin/shortcuts` with these arguments (stopped after 15 s; output read as it comes).
    @Sendable static func runShortcuts(_ arguments: [String]) -> ToolRun {
        ToolRunner.run("/usr/bin/shortcuts", arguments, timeout: 15)
    }

    static var offDuringWindowMode: Bool {
        get { UserDefaults.standard.bool(forKey: offDuringWindowModeKey) }
        set { UserDefaults.standard.set(newValue, forKey: offDuringWindowModeKey) }
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
/// shortcuts that let MeowDisplay switch it, the owner's choice to turn it off while a device uses
/// Window mode (turned back on afterwards; off by default), and what MeowDisplay last did.
struct StageManagerSettingsSection: View {
    private var controller: StageManagerController { .shared }
    @State private var status = StageManagerController.shared.status
    @State private var isOn = StageManagerSwitch.readIsOn()
    @State private var offDuringWindowMode = StageManagerSwitch.offDuringWindowMode
    @State private var confirming = false
    @State private var confirmingTurnOn = false
    @State private var turningOn = false
    @State private var showingSetup = false
    @State private var setup: SetupPhase = .idle
    private enum SetupPhase: Equatable { case idle, preparing, waiting(until: Date), failed(String) }

    /// Both shortcuts exist (made by any MeowDisplay version).
    private var present: Bool { status.present.count == StageManagerShortcutInstaller.names.count }
    private var ready: Bool { status.shortcuts == .ready }
    private var missing: [String] { StageManagerShortcutInstaller.missing(present: status.present) }

    var body: some View {
        Section {
            LabeledContent("Stage Manager", value: isOn ? String(localized: "On") : String(localized: "Off"))
            LabeledContent("Switching from MeowDisplay") {
                HStack {
                    Text(statusText).foregroundStyle(.secondary)
                    if ready {
                        Button("Open in Shortcuts") { StageManagerShortcutInstaller.view(StageManagerSwitch.offShortcut) }
                    } else {
                        Button(setup == .preparing || isWaiting ? "Setting Up…" : "Set Up Automatically") { setUp() }
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
            if status.setupNeedsRemoval, !isWaiting {
                HStack {
                    Text("To set them up again, first delete \(status.present.sorted().map { "“\($0)”" }.joined(separator: " and ")) in Shortcuts (MeowDisplay never deletes shortcuts), then click Set Up Automatically.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Open Shortcuts") { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Shortcuts.app")) }
                }
            }
            if !status.copies.isEmpty {
                Text("Shortcuts also has \(status.copies.map { "“\($0)”" }.joined(separator: ", ")). MeowDisplay uses only the exact names; you can delete the copies in Shortcuts.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Turn Off During Window Mode", isOn: Binding(get: { offDuringWindowMode && present }, set: { on in
                if on { confirming = true } else { offDuringWindowMode = false; StageManagerSwitch.offDuringWindowMode = false }
            }))
            .disabled(!present)
            .confirmationDialog("Turn off Stage Manager while a device uses Window mode?", isPresented: $confirming) {
                Button("Turn Off During Window Mode") { offDuringWindowMode = true; StageManagerSwitch.offDuringWindowMode = true }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("MeowDisplay turns it back on about 25 seconds after the last device leaves Window mode. Your own Stage Manager automations in Shortcuts run each time it switches.")
            }
            ForEach(status.lines(now: Date()), id: \.self) { line in
                Text(line).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if status.owed, !isOn, status.windowModes == 0, status.restoreAt == nil, present {
                Button(turningOn ? "Turning On…" : "Turn Stage Manager On") {
                    if status.dockSideEffects.isEmpty { turnOn() } else { confirmingTurnOn = true }
                }
                .disabled(turningOn)
                .confirmationDialog("Turn Stage Manager on with these shortcuts?", isPresented: $confirmingTurnOn) {
                    Button("Turn On") { turnOn() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Running them also \(status.dockSideEffects.joined(separator: String(localized: " and "))). To avoid that, set them up again first, or turn Stage Manager on in Control Center.")
                }
            }
        } header: {
            Text("Stage Manager")
        } footer: {
            Text("macOS pauses windows in Stage Manager's side strip, so a device sees their last picture until they're on the Mac's stage. Windows on the current stage always stream. A device with control can show one on the Mac, or, once set up, turn Stage Manager off for Window mode after you confirm there.")
        }
        .onAppear { refresh() }
        .onReceive(NotificationCenter.default.publisher(for: StageManagerController.didChange)) { _ in apply() }
        .sheet(isPresented: $showingSetup, onDismiss: refresh) { StageManagerShortcutSetup() }
    }

    private var isWaiting: Bool { if case .waiting = setup { return true }; return false }

    private var statusText: String {
        switch setup {
        case .preparing: return String(localized: "Preparing…")
        case .waiting: return String(localized: "Waiting for you in Shortcuts")
        default: break
        }
        switch status.shortcuts {
        case .ready: return String(localized: "Ready")
        case .outdated, .settingsChanged: return String(localized: "Needs setting up again")
        case .missing where missing.count == 1: return String(localized: "“\(missing[0])” missing")
        case .missing, .unknown: return String(localized: "Not set up")
        }
    }

    private func refresh() {
        isOn = StageManagerSwitch.readIsOn()
        controller.refresh { apply() }
    }

    private func apply() {
        status = controller.status
        isOn = controller.isOnRecently
        if present, setup != .idle, setup != .preparing {
            setup = .idle
            StageManagerShortcutInstaller.cleanUp()
            Log.info("stage manager setup: both shortcuts are in Shortcuts (\(status.shortcuts))")
        }
    }

    private func turnOn() {
        turningOn = true
        controller.ownerTurnOn { _ in
            turningOn = false
            apply()
        }
    }

    /// Prepares only the missing shortcuts (with the Dock settings in effect now), opens them in
    /// Shortcuts for the owner to add, then checks every 2 s (for up to 3 minutes) until both exist.
    /// Shortcuts that can't stay (older format, other settings) must be deleted by the owner first.
    private func setUp() {
        setup = .preparing
        controller.refresh {
            apply()
            guard !ready, !status.setupNeedsRemoval else { setup = .idle; return }
            let wanted = missing
            let settings = controller.liveDockSettings
            let box = PreparedBox()
            StageManagerSwitch.inBackground({ box.result = StageManagerShortcutInstaller.prepare(wanted, settings: settings) }) {
                switch box.result {
                case .success(let files)?:
                    controller.prepared(wanted, with: settings)
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
            controller.refresh {
                apply()
                if !present { poll() } else { setup = .idle }
            }
        }
    }
}

/// The one-time setup: two shortcuts, each with the system's "Set Stage Manager" action.
private struct StageManagerShortcutSetup: View {
    @Environment(\.dismiss) private var dismiss
    @State private var status = StageManagerController.shared.status
    @State private var checking = false
    private let settings = StageManagerController.shared.liveDockSettings

    private var present: Bool { status.present.count == StageManagerShortcutInstaller.names.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Let MeowDisplay Switch Stage Manager").font(.title3.weight(.semibold))
            Text("macOS lets apps change Stage Manager only through Shortcuts. Set Up Automatically prepares these two shortcuts and opens them in Shortcuts, which asks you to Add Shortcut for each; nothing is added without that click. MeowDisplay runs them only when you allow it. To make them yourself instead:")
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                step(1, String(localized: "In Shortcuts, choose File ▸ New Shortcut and name it “\(StageManagerSwitch.offShortcut)”."))
                step(2, String(localized: "Add the action “Set Stage Manager” and set it to Off. In its options, turn Show Dock \(onOff(settings.showDock)) and Show Recent Apps \(onOff(settings.showRecentApps)), as your Mac has them now, so it leaves them alone."))
                step(3, String(localized: "Make a second shortcut named “\(StageManagerSwitch.onShortcut)” the same way, with “Set Stage Manager” set to On."))
            }
            Text("The names must match exactly. MeowDisplay never turns Stage Manager off without your confirmation, and turns it back on about 25 seconds after the last device leaves Window mode. Your own Stage Manager automations in Shortcuts run each time MeowDisplay switches it. If you change your Dock settings later, set the shortcuts up again.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Label(status.shortcuts == .ready ? "Both shortcuts found" : present ? "Found, but not made for your Dock settings" : "Not found yet",
                      systemImage: status.shortcuts == .ready ? "checkmark.circle.fill" : "circle.dashed")
                    .foregroundStyle(status.shortcuts == .ready ? .green : .secondary)
                Spacer()
                if present, status.shortcuts != .ready {
                    Button("I Made Them as Shown") { StageManagerController.shared.madeByHand { status = StageManagerController.shared.status } }
                }
                Button("Open Shortcuts") { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Shortcuts.app")) }
                Button(checking ? "Checking…" : "Check Again") {
                    checking = true
                    StageManagerController.shared.refresh {
                        status = StageManagerController.shared.status; checking = false
                    }
                }.disabled(checking)
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private func onOff(_ on: Bool) -> String { on ? String(localized: "on") : String(localized: "off") }

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

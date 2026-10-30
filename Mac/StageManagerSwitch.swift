import SwiftUI

/// Stage Manager on this Mac (Desktop & Dock ▸ Stage Manager). macOS keeps windows in Stage
/// Manager's side strip paused, so Window mode can't show them live (WINDOW-WORKSPACE-DESIGN W2).
/// There is no public API for the setting; it is the user preference `GloballyEnabled` in
/// `com.apple.WindowManager` (what Control Center and the Shortcuts action change). MeowDisplay
/// changes it only when the owner asks (here, or confirmed from a device with control), and
/// turns it back on afterwards when it was the one that turned it off.
enum StageManagerSwitch {
    private static var domain: CFString { "com.apple.WindowManager" as CFString }
    private static var key: CFString { "GloballyEnabled" as CFString }
    /// MeowDisplay turned it off and owes turning it back on.
    static let turnedOffKey = "stageManager.turnedOffByMeowDisplay"
    /// Settings ▸ System: turn it off while a device uses Window mode (off by default).
    static let offDuringWindowModeKey = "stageManager.offDuringWindowMode"

    static var isOn: Bool {
        CFPreferencesAppSynchronize(domain)
        return (CFPreferencesCopyAppValue(key, domain) as? Bool) ?? false
    }

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

    static var offDuringWindowMode: Bool {
        get { UserDefaults.standard.bool(forKey: offDuringWindowModeKey) }
        set { UserDefaults.standard.set(newValue, forKey: offDuringWindowModeKey) }
    }

    /// Writes the setting; true when it reads back as asked.
    @discardableResult
    static func set(_ on: Bool) -> Bool {
        CFPreferencesSetAppValue(key, on as CFBoolean, domain)
        CFPreferencesAppSynchronize(domain)
        cacheLock.lock(); cached = nil; cacheLock.unlock()
        return isOn == on
    }

    /// Turns it off for Window mode, remembering to turn it back on. True when it is off.
    @discardableResult
    static func turnOffForWindowMode() -> Bool {
        guard isOn else { return true }
        guard set(false) else { Log.info("stage manager: couldn't turn it off"); return false }
        UserDefaults.standard.set(true, forKey: turnedOffKey)
        Log.info("stage manager: turned off for Window mode")
        return true
    }

    /// Turns it back on if MeowDisplay turned it off and it is still off. Called when Window mode
    /// ends and when the app starts (after a crash or quit during Window mode).
    static func restoreIfTurnedOffByUs() {
        guard UserDefaults.standard.bool(forKey: turnedOffKey) else { return }
        UserDefaults.standard.set(false, forKey: turnedOffKey)
        if !isOn { set(true); Log.info("stage manager: turned back on") }
    }
}

/// Settings ▸ System ▸ Stage Manager: what it means for Window mode, and the owner's choice to
/// turn it off while a device uses Window mode (turned back on afterwards). Off by default.
struct StageManagerSettingsSection: View {
    @State private var isOn = StageManagerSwitch.isOn
    @State private var offDuringWindowMode = StageManagerSwitch.offDuringWindowMode
    @State private var confirming = false

    var body: some View {
        Section {
            LabeledContent("Stage Manager", value: isOn ? String(localized: "On") : String(localized: "Off"))
            Toggle("Turn Off During Window Mode", isOn: Binding(get: { offDuringWindowMode }, set: { on in
                if on { confirming = true } else { offDuringWindowMode = false; StageManagerSwitch.offDuringWindowMode = false }
            }))
            .confirmationDialog("Turn off Stage Manager while a device uses Window mode?", isPresented: $confirming) {
                Button("Turn Off During Window Mode") { offDuringWindowMode = true; StageManagerSwitch.offDuringWindowMode = true }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("MeowDisplay turns it back on when Window mode ends.")
            }
        } header: {
            Text("Stage Manager")
        } footer: {
            Text("macOS pauses windows in Stage Manager's side strip, so a device sees their last picture until they're on the Mac's stage. A device with control can also show one on the Mac, or turn Stage Manager off for Window mode after you confirm there. Windows on the current stage always stream.")
        }
        .onAppear { isOn = StageManagerSwitch.isOn }
    }
}

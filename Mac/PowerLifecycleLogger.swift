#if DEBUG
import AppKit

/// DEBUG-only: logs macOS power/display lifecycle notifications so a
/// physical wake test's log has the surrounding context (did the OS report
/// a wake at all, did the screens actually wake, what changed about display
/// topology) alongside the `wakeDebug:` lines from a manual test action.
/// Observation only — never reacts to any of these by rebuilding capture.
enum PowerLifecycleLogger {
    private static var started = false

    static func start() {
        guard !started else { return }
        started = true
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            Log.info("macPower: didWake")
        }
        center.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { _ in
            Log.info("macPower: screensDidWake")
        }
        center.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { _ in
            Log.info("macPower: screensDidSleep")
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { _ in
            let count = NSScreen.screens.count
            Log.info("macPower: displayTopology screenCount=\(count)")
        }
    }
}
#endif

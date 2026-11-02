import CoreGraphics
import Foundation

/// Locks this Mac's screen the way its own Lock Screen shortcut (Control-Command-Q) does, and
/// checks that macOS really shows the lock screen. Public API only: the key presses are posted
/// like MeowDisplay's remote input (Accessibility), and the lock state is read from the session.
enum MacScreenLock {
    /// What a lock request ended with (sent to the device as `LockMacResult`).
    static func result(posted: Bool, lockedAfter: Bool) -> LockMacResult {
        if lockedAfter { return .locked }
        return posted ? .failed : .accessibility
    }

    /// True while macOS shows the lock screen.
    static var isLocked: Bool {
        guard let info = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (info["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue ?? false
    }

    /// Posts Control-Command-Q, then waits up to `timeout` for the lock screen. `done` runs on the
    /// main queue. Already locked counts as locked.
    static func lock(timeout: TimeInterval = 3, done: @escaping @Sendable (LockMacResult) -> Void) {
        if isLocked { DispatchQueue.main.async { done(.locked) }; return }
        guard CGPreflightPostEventAccess(), let source = CGEventSource(stateID: .hidSystemState) else {
            Log.info("lock mac: can't post the Lock Screen shortcut (Accessibility not allowed)")
            DispatchQueue.main.async { done(.accessibility) }
            return
        }
        let q: CGKeyCode = 12
        let flags: CGEventFlags = [.maskCommand, .maskControl]
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: q, keyDown: down)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }
        Log.info("lock mac: Lock Screen shortcut posted")
        let start = ProcessInfo.processInfo.systemUptime
        func check() {
            if isLocked || ProcessInfo.processInfo.systemUptime - start >= timeout {
                let r = result(posted: true, lockedAfter: isLocked)
                Log.info("lock mac: \(r.rawValue)")
                done(r)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { check() }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { check() }
    }
}

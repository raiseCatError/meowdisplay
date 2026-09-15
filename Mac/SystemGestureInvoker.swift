import ApplicationServices
import CoreGraphics

/// Invokes built-in macOS system gestures through synthetic keyboard shortcuts.
@MainActor
enum SystemGestureInvoker {
    static func invoke(_ gesture: ReceiverGesture) {
        post(SystemGestureShortcutMapping.shortcut(for: gesture),
             description: gesture.rawValue)
    }

    private static func post(_ shortcut: SystemGestureShortcut, description: String) {
        guard AXIsProcessTrusted() else {
            Log.info("System gesture skipped: Accessibility permission is missing")
            return
        }
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            Log.info("System gesture skipped: could not create CGEvent source")
            return
        }

        guard let keyDown = CGEvent(keyboardEventSource: source,
                                    virtualKey: shortcut.keyCode,
                                    keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source,
                                  virtualKey: shortcut.keyCode,
                                  keyDown: false) else {
            Log.info("System gesture skipped: could not create key events for \(description)")
            return
        }

        keyDown.flags = shortcut.flags
        keyUp.flags = shortcut.flags
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)

        // `keyUp` above still carries `shortcut.flags` — a faithful
        // reproduction of a REAL held-modifier shortcut (a physically-held
        // Control key's own keyDown precedes the arrow's, and its keyUp
        // follows it), which is why the flag has to be on both events for
        // macOS to recognize the shortcut at all. But no genuine modifier
        // keyDown/keyUp pair is ever posted here, only the arrow/space
        // key — so nothing ever tells Quartz's combined-session modifier
        // state that the modifier is released again, and it can leak into
        // any later event (this app's own mouse clicks included — see
        // `MouseEventFlags`'s doc for the exact bug that caused) that
        // doesn't explicitly state its own flags. Defensively release
        // every modifier this shortcut's flags implied via that
        // modifier's OWN virtual key code — the same mechanism
        // `InputInjector.handleModifier` already uses for the receiver's
        // control tray, and the standard way to tell Quartz a modifier is
        // actually up.
        for modifier in ControlModifier.allCases where shortcut.flags.contains(modifier.eventFlag) {
            guard let release = CGEvent(keyboardEventSource: source, virtualKey: modifier.keyCode, keyDown: false) else { continue }
            release.flags = []
            release.post(tap: .cghidEventTap)
        }
    }
}

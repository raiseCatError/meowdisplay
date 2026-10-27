import CoreGraphics
import Foundation

/// Fast User Switching: several people can be logged in to one Mac, each
/// running their own MeowDisplay. Only the login session on the console is
/// on screen. A switched-out session has nothing a receiver could see, and
/// it must never put input in front of whoever is using the Mac now, so the
/// injector refuses all input while this session is not on the console
/// (`InputInjector.inputIsAllowed`) and the sender's controller releases
/// held keys and buttons the moment it is switched out.
///
/// Updated from `NSWorkspace`'s session notifications; read on every
/// injected event, so it is a lock-protected value rather than a window
/// server query.
final class LoginSessionConsole: @unchecked Sendable {
    static let shared = LoginSessionConsole()

    private let lock = NSLock()
    private var onConsole: Bool

    init(onConsole: Bool = LoginSessionConsole.windowServerReportsOnConsole()) {
        self.onConsole = onConsole
    }

    var isOnConsole: Bool {
        lock.lock(); defer { lock.unlock() }
        return onConsole
    }

    /// Returns whether the value changed.
    @discardableResult
    func set(onConsole value: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard onConsole != value else { return false }
        onConsole = value
        return true
    }

    /// What the window server says about this process's login session. A
    /// process without a GUI session (no dictionary) counts as on console,
    /// exactly as `MacSender.consoleIsInteractive` always has: nothing
    /// changes on a Mac that never switches users.
    static func windowServerReportsOnConsole() -> Bool {
        guard let info = CGSessionCopyCurrentDictionary() as? [String: Any] else { return true }
        return info[kCGSessionOnConsoleKey as String] as? Bool ?? true
    }
}

/// This user's opt-in to being listed as one of several login sessions on
/// this Mac (`SenderSessionAdvertisement`). Stored in the user's own
/// defaults: every person decides for their own session, and nothing about
/// other accounts is read or shown. Off by default, so an ordinary install
/// advertises exactly what it always did.
enum SessionDiscoveryPreferences {
    static let enabledKey = "sessionDiscovery.enabled"
    static let labelKey = "sessionDiscovery.label"

    static func label(defaults: UserDefaults = .standard) -> String? {
        SenderSessionAdvertisement.normalizedLabel(defaults.string(forKey: labelKey))
    }

    /// On only with a usable label: the account name is never a fallback.
    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: enabledKey) && label(defaults: defaults) != nil
    }

    static func advertisement(hostName: String, localHostName: String?, onConsole: Bool,
                              defaults: UserDefaults = .standard) -> SenderSessionAdvertisement? {
        guard isEnabled(defaults: defaults) else { return nil }
        return SenderSessionAdvertisement(hostName: hostName, localHostName: localHostName,
                                          sessionLabel: label(defaults: defaults),
                                          availability: onConsole ? .available : .switchedOut)
    }
}

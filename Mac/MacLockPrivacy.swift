import AppKit
import CoreGraphics
import Foundation

// Lock screen privacy (SECURITY.md "When the Mac is locked"): while macOS shows its lock screen,
// is switched to another user, or can't say, no receiver gets this Mac's content or puts input
// in. One gate (`MacPrivacyGate`) is read where content and input leave or enter: every media
// frame (`MacSender.sendFramed`), every content message (`LockedContentPolicy`), window capture
// (`syncWorkspaceSuspension`) and every injected event (`InputInjector.inputIsAllowed`).

/// The window server's session dictionary, read for privacy. Missing or malformed: unknown,
/// never "unlocked".
enum MacLockReading {
    static func state(_ info: [String: Any]?) -> MacScreenPrivacy {
        guard let info, let onConsole = info[kCGSessionOnConsoleKey as String] as? Bool else { return .unknown }
        if !onConsole { return .switchedOut }
        if (info["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue == true { return .locked }
        return .unlocked
    }

    /// About 130 µs (measured 2026-11-07, macOS 27): fine a few times a second, not per frame.
    static func current() -> MacScreenPrivacy { state(CGSessionCopyCurrentDictionary() as? [String: Any]) }
}

/// Combines macOS's lock notifications with session reads. A lock notice locks at once; a read
/// that still says unlocked just after it (the dictionary can lag the notice) doesn't unlock
/// again for `unlockLag`. Unlocking needs a read that says so, once that lag has passed or an
/// unlock notice came.
struct MacLockTracker: Equatable, Sendable {
    static let unlockLag: TimeInterval = 3
    private(set) var state: MacScreenPrivacy
    private var lockedNoticeAt: TimeInterval?

    init(reading: MacScreenPrivacy) { state = reading }

    /// `com.apple.screenIsLocked`. Returns whether the state changed.
    mutating func lockNotice(now: TimeInterval) -> Bool {
        lockedNoticeAt = now
        return state == .unlocked ? set(.locked) : false   // switched out or unknown stay as they are
    }

    /// `com.apple.screenIsUnlocked`: the next read decides.
    mutating func unlockNotice() { lockedNoticeAt = nil }

    /// A session read. Returns whether the state changed.
    mutating func read(_ reading: MacScreenPrivacy, now: TimeInterval) -> Bool {
        var next = reading
        if reading == .unlocked, let at = lockedNoticeAt {
            if now - at < Self.unlockLag { next = state == .unlocked ? .locked : state } else { lockedNoticeAt = nil }
        }
        return set(next)
    }

    private mutating func set(_ s: MacScreenPrivacy) -> Bool {
        guard s != state else { return false }
        state = s
        return true
    }
}

/// The one lock-protected answer every content and input path reads, on any thread.
final class MacPrivacyGate: @unchecked Sendable {
    /// Starts from a real read (fail closed). The app keeps it current (`MacLockMonitor`) from
    /// launch, before any receiver can connect.
    static let shared = MacPrivacyGate(MacLockReading.current())

    private let lock = NSLock()
    private var value: MacScreenPrivacy

    init(_ state: MacScreenPrivacy) { value = state }

    var state: MacScreenPrivacy {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    var allowsContent: Bool { state.allowsContent }
    /// Input needs the same: nothing a device sends reaches the lock screen or a window behind it.
    var allowsInput: Bool { state.allowsContent }

    /// Returns whether it changed.
    @discardableResult
    func set(_ s: MacScreenPrivacy) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard value != s else { return false }
        value = s
        return true
    }
}

/// Which Mac -> receiver messages carry content, so stop while the Mac is locked. Session and
/// control messages (welcome, pings, input and video state, the lock state itself) still go,
/// so the receiver can say what's happening and nothing reconnects.
enum LockedContentPolicy {
    static let contentTypes: Set<String> = [
        WireMessage.windowCatalog, WireMessage.windowThumbnail, WireMessage.appIcon,
        WireMessage.workspaceState, WireMessage.workspaceView, WireMessage.workspaceBackdrop,
        WireMessage.appCatalog, WireMessage.displayThumbnail, WireMessage.files,
        WireMessage.menu, WireMessage.menuResult, WireMessage.appLaunchResult, WireMessage.windowCloseResult,
        ClipboardWire.type,
        // Where the focused text field is: on the lock screen, the password field.
        WireMessage.textCaret,
    ]

    static func allows(type: String?, privacy: MacScreenPrivacy) -> Bool {
        privacy.allowsContent || !contentTypes.contains(type ?? "")
    }
}

/// Keeps `MacPrivacyGate.shared` current: macOS's lock and unlock notifications, login session
/// switches, display sleep and wake, and a read twice a second while any receiver is connected
/// (a missed notification can't leave it unlocked for long). Main actor.
@MainActor
final class MacLockMonitor {
    private var tracker = MacLockTracker(reading: MacLockReading.current())
    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?
    private let onChange: (MacScreenPrivacy) -> Void

    static let pollInterval: TimeInterval = 0.5

    init(onChange: @escaping (MacScreenPrivacy) -> Void) {
        self.onChange = onChange
        MacPrivacyGate.shared.set(tracker.state)
        Log.info("macLock: starts \(tracker.state.rawValue)")
    }

    func start() {
        let distributed = DistributedNotificationCenter.default()
        observers.append(distributed.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.lockNotice() }
        })
        observers.append(distributed.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.unlockNotice() }
        })
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.sessionDidBecomeActiveNotification, NSWorkspace.sessionDidResignActiveNotification,
                     NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.read() }
            })
        }
    }

    /// Reads twice a second while `connected` (receivers are connected), else only on notifications.
    func setPolling(_ connected: Bool) {
        guard connected != (timer != nil) else { return }
        timer?.invalidate()
        timer = nil
        guard connected else { return }
        let t = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.read() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        read()
    }

    var state: MacScreenPrivacy { tracker.state }

    private func lockNotice() {
        apply(changed: tracker.lockNotice(now: ProcessInfo.processInfo.systemUptime))
    }

    private func unlockNotice() {
        tracker.unlockNotice()
        read()
    }

    private func read() {
        apply(changed: tracker.read(MacLockReading.current(), now: ProcessInfo.processInfo.systemUptime))
    }

    private func apply(changed: Bool) {
        guard changed else { return }
        let s = tracker.state
        MacPrivacyGate.shared.set(s)
        Log.info("macLock: \(s.rawValue)")
        onChange(s)
    }
}

import AppKit
import ApplicationServices

/// Whether Mission Control is open on this Mac (macOS 27).
///
/// macOS has no API that says so. Measured 2026-10-31 on macOS 27.0, two steps:
/// 1. Public hint (CGWindowList): while it is open, the WindowManager process
///    (`com.apple.WindowManager`) or the Dock owns an on-screen window covering a whole display.
///    Otherwise neither does (Stage Manager's strip windows are small), so the Accessibility
///    step runs only then.
/// 2. Confirmation (Accessibility, the permission MeowDisplay already has for input):
///    WindowManager exposes a group with the identifier `mc.display` per display, and the Dock
///    one with the identifier `mc` ("Mission Control"); both are gone once it closes.
/// Meanwhile macOS suspends window captures (ScreenCaptureKit reports `.suspended`), so
/// Window-mode panes pause: that is macOS, not a failure, and nothing restarts until it closes.
/// Read-only; nothing private.
final class MissionControlMonitor: @unchecked Sendable {
    static let shared = MissionControlMonitor()

    /// Open right now: the public hint, then the Accessibility confirmation.
    static func isOpenNow() -> Bool {
        let wm = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.WindowManager").first?.processIdentifier
        let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier
        let owners = Set([wm, dock].compactMap { $0 })
        guard !owners.isEmpty, MissionControlSignals.coversADisplay(windows: onScreenWindows(), owners: owners, displays: displayBounds()) else {
            return false
        }
        guard AXIsProcessTrusted() else { return false }
        if let wm, MissionControlAX.containsMissionControl(app(wm), identifier: "mc.display") { return true }
        if let dock, MissionControlAX.containsMissionControl(app(dock), identifier: "mc") { return true }
        return false
    }

    private static func app(_ pid: pid_t) -> AXUIElement {
        let e = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(e, 0.25)   // a busy Dock never holds the poll for long
        return e
    }

    private static func onScreenWindows() -> [MissionControlSignals.Window] {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.compactMap { w in
            guard let pid = w[kCGWindowOwnerPID as String] as? Int32,
                  let b = w[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: b as CFDictionary) else { return nil }
            return .init(ownerPID: pid, bounds: bounds)
        }
    }

    private static func displayBounds() -> [CGRect] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(16, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).map { CGDisplayBounds($0) }
    }

    private let lock = NSLock()
    private var open = false
    private var timer: DispatchSourceTimer?
    private var listeners: [UUID: @Sendable (Bool) -> Void] = [:]

    var isOpen: Bool { lock.withLock { open } }

    /// Watches twice a second while anyone listens (a Window-mode session); calls back on changes.
    /// A listener added while it is already open hears so at once.
    func addListener(_ change: @escaping @Sendable (Bool) -> Void) -> UUID {
        let id = UUID()
        let alreadyOpen = lock.withLock { () -> Bool in
            listeners[id] = change
            if timer == nil {
                let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
                t.schedule(deadline: .now(), repeating: .milliseconds(500), leeway: .milliseconds(100))
                t.setEventHandler { [weak self] in self?.poll() }
                timer = t
                t.resume()
            }
            return open
        }
        if alreadyOpen { change(true) }
        return id
    }

    func removeListener(_ id: UUID) {
        lock.withLock {
            guard listeners.removeValue(forKey: id) != nil, listeners.isEmpty else { return }
            timer?.cancel(); timer = nil; open = false
        }
    }

    private func poll() {
        let now = Self.isOpenNow()
        let notify = lock.withLock { () -> [@Sendable (Bool) -> Void]? in
            guard timer != nil, now != open else { return nil }
            open = now
            return Array(listeners.values)
        }
        guard let notify else { return }
        Log.info("missionControl: \(now ? "open — window captures pause until it closes" : "closed")")
        notify.forEach { $0(now) }
    }

    /// Closes Mission Control with Escape, only after checking it is open right now (never a
    /// blind toggle, and never an Escape that would land in another app's dialog).
    @discardableResult
    static func exit() -> Bool {
        guard isOpenNow() else {
            Log.info("missionControl: exit asked but it isn't open — nothing sent")
            return false
        }
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            CGEvent(keyboardEventSource: source, virtualKey: 53, keyDown: down)?.post(tap: .cghidEventTap)
        }
        Log.info("missionControl: Escape sent to close it")
        return true
    }
}

/// The public hint as a pure rule (tested): a WindowManager or Dock window covering a display.
enum MissionControlSignals {
    struct Window: Equatable { let ownerPID: Int32; let bounds: CGRect }

    static func coversADisplay(windows: [Window], owners: Set<Int32>, displays: [CGRect]) -> Bool {
        windows.contains { w in
            owners.contains(w.ownerPID) && displays.contains { d in
                abs(w.bounds.minX - d.minX) < 1 && abs(w.bounds.minY - d.minY) < 1
                    && abs(w.bounds.width - d.width) < 1 && abs(w.bounds.height - d.height) < 1
            }
        }
    }
}

/// The Accessibility check, separate so its rule is plain: an element of the app (two levels deep)
/// carries the identifier Mission Control uses.
enum MissionControlAX {
    static func containsMissionControl(_ app: AXUIElement, identifier: String) -> Bool {
        for child in children(app) {
            if string(child, kAXIdentifierAttribute) == identifier { return true }
            for grandchild in children(child) where string(grandchild, kAXIdentifierAttribute) == identifier { return true }
        }
        return false
    }

    private static func children(_ e: AXUIElement) -> [AXUIElement] {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &v) == .success else { return [] }
        return v as? [AXUIElement] ?? []
    }

    private static func string(_ e: AXUIElement, _ attribute: String) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, attribute as CFString, &v) == .success else { return nil }
        return v as? String
    }
}

import AppKit
import ApplicationServices

// Fill Window on Mac / Restore Previous Size on Mac (PROTOCOL.md 6.10, WINDOW_MODE.md).
//
// The only place MeowDisplay changes the size of a real Mac window, and only when a person with
// control picks one of those two items in a pane's menu. Never automatic: moving, resizing,
// zooming, floating or fullscreening a pane on a device never reaches here.
//
// Like macOS's own Window ▸ Move & Resize ▸ Fill, but without asking the app: the one window's
// Accessibility position and size are set, nothing else. No green button, no Window menu, no key
// shortcut, no AXRaise, no activation and never AXFullScreen (no new Space). The window must be
// exactly the listed one (CGWindowID + its owner's pid + the session's generation, then exactly
// one Accessibility window with its frame and title), control is checked again right before the
// first write, and the result is read back from both Accessibility and the window server before
// anything is reported as done.

extension NSScreen {
    /// The screen's display id (`NSScreenNumber`).
    var displayID: CGDirectDisplayID? { (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value }
}

/// One screen as the geometry needs it.
struct WindowFrameScreen: Equatable, Sendable {
    var displayID: CGDirectDisplayID
    /// Global points, top-left origin of the primary display (`CGDisplayBounds`), the space
    /// Accessibility and CGWindowList use.
    var bounds: CGRect
    /// AppKit's `frame` and `visibleFrame` (bottom-left origin). Only their difference is used:
    /// the menu bar and Dock insets, the same in either y direction.
    var cocoaFrame: CGRect
    var cocoaVisibleFrame: CGRect
}

struct WindowFrameInsets: Equatable, Sendable {
    var top: CGFloat = 0, left: CGFloat = 0, bottom: CGFloat = 0, right: CGFloat = 0
}

/// Pure geometry and decisions (tested).
enum WindowFrameGeometry {
    /// Frames within this many points are the same (the catalog's own rule).
    static let tolerance: CGFloat = 2
    /// Room kept between Stage Manager's strip and a filled window.
    static let stripClearance: CGFloat = 8
    /// A strip thumbnail is at most this big, and sits this close to its display's edge.
    static let stripItemMaxSide: CGFloat = 400
    static let stripEdgeReach: CGFloat = 320
    /// Nothing smaller is ever a fill target (a broken visibleFrame, an odd display).
    static let minimumTarget = CGSize(width: 200, height: 150)

    static func matches(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = tolerance) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }

    /// The menu bar (top) and the Dock (left, bottom or right), from AppKit's frame and
    /// visibleFrame. Never negative.
    static func insets(frame: CGRect, visibleFrame: CGRect) -> WindowFrameInsets {
        WindowFrameInsets(top: max(0, frame.maxY - visibleFrame.maxY), left: max(0, visibleFrame.minX - frame.minX),
                          bottom: max(0, visibleFrame.minY - frame.minY), right: max(0, frame.maxX - visibleFrame.maxX))
    }

    /// The screen a window is on: the one it overlaps most (as macOS decides a window's screen).
    static func screen(for window: CGRect, among screens: [WindowFrameScreen]) -> WindowFrameScreen? {
        var best: (screen: WindowFrameScreen, area: CGFloat)?
        for s in screens {
            let i = window.intersection(s.bounds)
            guard !i.isNull, i.width > 0, i.height > 0 else { continue }
            let area = i.width * i.height
            if area > (best?.area ?? 0) { best = (s, area) }
        }
        return best?.screen
    }

    /// How far a filled window keeps clear of Stage Manager's strip on `display` (global): its
    /// thumbnails hug the left edge (the right one when the Dock is on the left). Only small
    /// items near an edge count; none means the strip is off or hidden there.
    static func stripInsets(display: CGRect, stripItems: [CGRect]) -> (left: CGFloat, right: CGFloat) {
        var left: CGFloat = 0, right: CGFloat = 0
        for r in stripItems {
            let i = r.intersection(display)
            guard !i.isNull, i.width > 0, i.height > 0,
                  r.width <= stripItemMaxSide, r.height <= stripItemMaxSide else { continue }
            if i.minX - display.minX <= stripEdgeReach, i.midX < display.midX {
                left = max(left, i.maxX - display.minX + stripClearance)
            } else if display.maxX - i.maxX <= stripEdgeReach, i.midX > display.midX {
                right = max(right, display.maxX - i.minX + stripClearance)
            }
        }
        // Never more than a third of the display: anything bigger isn't the strip.
        let cap = display.width / 3
        return (min(left, cap), min(right, cap))
    }

    /// Where Fill puts a window on `screen` (global, top-left): below the menu bar, clear of the
    /// Dock and of Stage Manager's strip. nil when what is left is too small to be meant.
    static func target(on screen: WindowFrameScreen, stripItems: [CGRect] = []) -> CGRect? {
        let e = insets(frame: screen.cocoaFrame, visibleFrame: screen.cocoaVisibleFrame)
        let strip = stripInsets(display: screen.bounds, stripItems: stripItems)
        let left = max(e.left, strip.left), right = max(e.right, strip.right)
        let r = CGRect(x: screen.bounds.minX + left, y: screen.bounds.minY + e.top,
                       width: screen.bounds.width - left - right, height: screen.bounds.height - e.top - e.bottom)
        guard r.width >= minimumTarget.width, r.height >= minimumTarget.height else { return nil }
        // Whole points, inside the area (never half a point under the menu bar).
        let x = r.minX.rounded(.up), y = r.minY.rounded(.up)
        return CGRect(x: x, y: y, width: r.maxX.rounded(.down) - x, height: r.maxY.rounded(.down) - y)
    }

    /// What a Fill did, from the frame the window server reports afterwards.
    static func gradeFill(before: CGRect, target: CGRect, after: CGRect?) -> WindowFrameResult {
        guard let after else { return .failed }
        if matches(after, target) { return .filled }
        if matches(after, before) { return .notResizable }
        // At the target's corner, but the app kept its own size limits (or size steps).
        if abs(after.minX - target.minX) <= tolerance && abs(after.minY - target.minY) <= tolerance { return .limited }
        // Moved and mostly in the area (macOS nudged a window too big for it): still the app's limits.
        let i = after.intersection(target)
        if !i.isNull, i.width * i.height >= 0.5 * after.width * after.height { return .limited }
        return .failed
    }

    /// What Restore should go back to after a Fill from `current`: the frame before the earlier Fill
    /// when the window is still where that Fill left it (Fill again on a window its app limited),
    /// otherwise `current`.
    static func frameBeforeFill(previous: WindowFrameMemoryEntry?, current: CGRect) -> CGRect {
        guard let previous, matches(previous.after, current) else { return current }
        return previous.before
    }

    /// Share of `rect` on these displays (0...1).
    static func visibleShare(_ rect: CGRect, displays: [CGRect]) -> CGFloat {
        let area = rect.width * rect.height
        guard area > 0 else { return 0 }
        let seen = displays.reduce(CGFloat(0)) { sum, d in
            let i = rect.intersection(d)
            return i.isNull ? sum : sum + i.width * i.height
        }
        return min(1, seen / area)
    }

    enum RestoreDecision: Equatable {
        case restore(CGRect)
        case nothingToRestore
        /// Moved or resized since Fill: the remembered size is stale.
        case changed
        /// The old frame isn't (at least half) on a connected display any more.
        case displayChanged
    }

    /// Restore puts back the old frame only while the window is still exactly where Fill left
    /// it, and only onto displays that are still there.
    static func restoreDecision(entry: WindowFrameMemoryEntry?, current: CGRect, displays: [CGRect]) -> RestoreDecision {
        guard let entry else { return .nothingToRestore }
        guard matches(current, entry.after) else { return .changed }
        guard visibleShare(entry.before, displays: displays) >= 0.5 else { return .displayChanged }
        return .restore(entry.before)
    }
}

/// Which Accessibility window is the listed one (pure, tested).
enum WindowFrameCandidates {
    struct Candidate: Equatable, Sendable {
        var frame: CGRect?
        var title: String?
        var subrole: String?
    }

    enum Pick: Equatable {
        case one(Int)
        /// It matched, but it isn't a standard window (a dialog, a panel): not resized.
        case notStandard
        case none
        case many
    }

    /// Exactly one window with the window server's frame (±2) and, when the listing has one,
    /// exactly its title. Zero is stale, several are ambiguous: titles are never guessed at.
    static func pick(_ candidates: [Candidate], bounds: CGRect, title: String) -> Pick {
        let matching = candidates.indices.filter { i in
            guard let f = candidates[i].frame, WindowFrameGeometry.matches(f, bounds) else { return false }
            return title.isEmpty || candidates[i].title == title
        }
        guard matching.count == 1, let only = matching.first else { return matching.isEmpty ? .none : .many }
        return candidates[only].subrole == (kAXStandardWindowSubrole as String) ? .one(only) : .notStandard
    }

    /// One window as the window server lists it.
    struct ServerWindow: Equatable, Sendable {
        var id: UInt32
        var pid: Int32
        var layer: Int
        var bounds: CGRect
        var onScreen: Bool
    }

    /// Another on-screen window of the same app with the same bounds: Accessibility's frame
    /// can't tell them apart, so nothing is moved. (Windows on other Spaces aren't in the app's
    /// Accessibility list, so they can't be picked by mistake.)
    static func hasTwin(windowID: UInt32, pid: Int32, bounds: CGRect, in windows: [ServerWindow]) -> Bool {
        windows.contains { $0.id != windowID && $0.pid == pid && $0.layer == 0 && $0.onScreen && WindowFrameGeometry.matches($0.bounds, bounds) }
    }
}

// MARK: - Memory

struct WindowFrameMemoryKey: Hashable, Sendable {
    var windowID: UInt32
    var pid: Int32
}

/// What Fill changed, for Restore: the frame before, the frame it verified after.
struct WindowFrameMemoryEntry: Equatable, Sendable {
    var before: CGRect
    var after: CGRect
    var displayID: CGDirectDisplayID
    var title: String
    var at: TimeInterval
}

/// Bounded, in memory only (never saved): one entry per window, the oldest dropped first.
struct WindowFrameMemoryStore: Sendable {
    static let capacity = 64
    private(set) var entries: [WindowFrameMemoryKey: WindowFrameMemoryEntry] = [:]

    func entry(_ key: WindowFrameMemoryKey) -> WindowFrameMemoryEntry? { entries[key] }

    mutating func remember(_ key: WindowFrameMemoryKey, _ entry: WindowFrameMemoryEntry) {
        entries[key] = entry
        while entries.count > Self.capacity, let oldest = entries.min(by: { $0.value.at < $1.value.at })?.key {
            entries[oldest] = nil
        }
    }

    mutating func forget(_ key: WindowFrameMemoryKey) { entries[key] = nil }

    /// Forgets windows that are gone (or whose id now belongs to another app), and windows a
    /// listing newer than their Fill shows somewhere else (moved or resized by hand on the Mac).
    mutating func reconcile(existing: Set<WindowFrameMemoryKey>, listed: [WindowFrameMemoryKey: CGRect],
                            listedAt: TimeInterval, settle: TimeInterval = 1.5) {
        for (key, entry) in entries {
            if !existing.contains(key) { entries[key] = nil; continue }
            if let frame = listed[key], listedAt > entry.at + settle, !WindowFrameGeometry.matches(frame, entry.after) {
                entries[key] = nil
            }
        }
    }
}

/// The process-wide memory (every receiver's engine and the setter share it; Restore after a
/// reconnect still works, a closed or reused window never restores).
final class WindowFrameMemory: @unchecked Sendable {
    static let shared = WindowFrameMemory()
    private let lock = NSLock()
    private var store = WindowFrameMemoryStore()

    func entry(_ key: WindowFrameMemoryKey) -> WindowFrameMemoryEntry? { lock.withLock { store.entry(key) } }
    func remember(_ key: WindowFrameMemoryKey, _ entry: WindowFrameMemoryEntry) { lock.withLock { store.remember(key, entry) } }
    func forget(_ key: WindowFrameMemoryKey) { lock.withLock { store.forget(key) } }
    var isEmpty: Bool { lock.withLock { store.entries.isEmpty } }
    var keys: Set<WindowFrameMemoryKey> { lock.withLock { Set(store.entries.keys) } }

    func reconcile(existing: Set<WindowFrameMemoryKey>, listed: [WindowFrameMemoryKey: CGRect], listedAt: TimeInterval) {
        lock.withLock { store.reconcile(existing: existing, listed: listed, listedAt: listedAt) }
    }

    /// Every window that exists now, by id and owner (one window-server call; only while
    /// something is remembered).
    static func existingWindows() -> Set<WindowFrameMemoryKey> {
        let list = (CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]) ?? []
        return Set(list.compactMap { info in
            guard let id = info[kCGWindowNumber as String] as? UInt32, let pid = info[kCGWindowOwnerPID as String] as? Int32 else { return nil }
            return WindowFrameMemoryKey(windowID: id, pid: pid)
        })
    }
}

// MARK: - The Accessibility work

enum WindowFrameSetter {
    struct Job: Sendable {
        var op: WindowFrameOp
        var windowID: UInt32
        var pid: Int32
        /// The listed title ("" when the listing has none: then the frame alone must be unique).
        var title: String
        /// Side-effect-free: this device still has control of the Mac on the connection it asked
        /// on. Evaluated right before the first write, after every read.
        var stillAllowed: @Sendable () -> Bool
    }

    private static let queue = DispatchQueue(label: "meow.window.frame", qos: .userInitiated)
    /// Per Accessibility message: a busy app fails fast instead of holding the queue.
    static let messagingTimeout: Float = 0.3
    static let settleInterval: TimeInterval = 0.1
    static let settleLimit: TimeInterval = 0.6

    /// One at a time, off the main thread. `completion` runs on a background queue.
    static func perform(_ job: Job, memory: WindowFrameMemory = .shared, completion: @escaping @Sendable (WindowFrameResult) -> Void) {
        queue.async {
            let result = run(job, memory: memory)
            Log.info("workspace: \(job.op.rawValue) window \(job.windowID) on Mac: \(result.rawValue)")
            completion(result)
        }
    }

    private typealias ServerWindow = WindowFrameCandidates.ServerWindow

    private static func serverWindows() -> [ServerWindow] {
        let list = (CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]) ?? []
        return list.compactMap { info in
            guard let id = info[kCGWindowNumber as String] as? UInt32, let pid = info[kCGWindowOwnerPID as String] as? Int32,
                  let dict = info[kCGWindowBounds as String] as? NSDictionary, let bounds = CGRect(dictionaryRepresentation: dict) else { return nil }
            return ServerWindow(id: id, pid: pid, layer: (info[kCGWindowLayer as String] as? Int) ?? 0, bounds: bounds,
                                onScreen: (info[kCGWindowIsOnscreen as String] as? Bool) == true)
        }
    }

    /// The window server's bounds for this one window, when it is on screen and still `pid`'s.
    private static func serverBounds(_ id: UInt32, pid: Int32) -> CGRect? {
        guard let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]])?.first,
              (info[kCGWindowNumber as String] as? UInt32) == id, (info[kCGWindowOwnerPID as String] as? Int32) == pid,
              (info[kCGWindowIsOnscreen as String] as? Bool) == true,
              let dict = info[kCGWindowBounds as String] as? NSDictionary else { return nil }
        return CGRect(dictionaryRepresentation: dict)
    }

    private static func run(_ job: Job, memory: WindowFrameMemory) -> WindowFrameResult {
        guard AXIsProcessTrusted() else { return .accessibility }
        let key = WindowFrameMemoryKey(windowID: job.windowID, pid: job.pid)
        let previous = memory.entry(key)

        // 1. The window server's own record for this id, now: same owner, a normal window, on screen.
        let server = serverWindows()
        guard let me = server.first(where: { $0.id == job.windowID }), me.pid == job.pid, me.layer == 0 else { return .stale }
        guard me.onScreen else { return .offscreen }
        let bounds = me.bounds
        if WindowFrameCandidates.hasTwin(windowID: job.windowID, pid: job.pid, bounds: bounds, in: server) {
            return .ambiguous
        }

        // 2. Exactly one Accessibility window is that window.
        let app = AXUIElementCreateApplication(job.pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        guard let windows = elements(app, kAXWindowsAttribute) else { return .failed }   // the app didn't answer
        let listed = Array(windows.prefix(64))
        let candidates = listed.map { w -> WindowFrameCandidates.Candidate in
            AXUIElementSetMessagingTimeout(w, messagingTimeout)
            return .init(frame: frame(w), title: string(w, kAXTitleAttribute), subrole: string(w, kAXSubroleAttribute))
        }
        let window: AXUIElement
        switch WindowFrameCandidates.pick(candidates, bounds: bounds, title: job.title) {
        case .one(let i): window = listed[i]
        case .notStandard: return .notResizable
        case .none: return .stale
        case .many: return .ambiguous
        }
        if bool(window, "AXFullScreen") == true { return .fullScreen }   // read only, never written
        if bool(window, kAXMinimizedAttribute) == true { return .offscreen }
        guard settable(window, kAXPositionAttribute), settable(window, kAXSizeAttribute) else { return .notResizable }

        // 3. Where it goes.
        guard let screens = MainThreadQuery.run(timeout: 0.5, { () -> [WindowFrameScreen] in
            NSScreen.screens.compactMap { s in
                s.displayID.map { WindowFrameScreen(displayID: $0, bounds: CGDisplayBounds($0), cocoaFrame: s.frame, cocoaVisibleFrame: s.visibleFrame) }
            }
        }), !screens.isEmpty else { return .failed }
        let destination: CGRect
        var displayID: CGDirectDisplayID = 0
        switch job.op {
        case .fill:
            guard let screen = WindowFrameGeometry.screen(for: bounds, among: screens) else { return .offscreen }
            guard let target = WindowFrameGeometry.target(on: screen, stripItems: stageStripItems(on: screen.bounds, server: server)) else {
                return .failed
            }
            // Already there: nothing moves, and an earlier "before" is kept for Restore.
            if WindowFrameGeometry.matches(bounds, target) { return .alreadyFilled }
            destination = target
            displayID = screen.displayID
        case .restore:
            switch WindowFrameGeometry.restoreDecision(entry: previous, current: bounds, displays: screens.map(\.bounds)) {
            case .nothingToRestore: return .nothingToRestore
            case .changed: memory.forget(key); return .changed
            case .displayChanged: return .displayChanged
            case .restore(let r): destination = r
            }
        }

        // 4. Right before the first write: still allowed, nothing in the way, and still that window there.
        if PrivacyShieldWindows.isUnlocking { return .privacyShield }
        guard job.stillAllowed() else { return .control }
        if MissionControlMonitor.shared.isOpen { return .missionControl }
        guard let now = frame(window), WindowFrameGeometry.matches(now, bounds),
              let serverNow = serverBounds(job.windowID, pid: job.pid), WindowFrameGeometry.matches(serverNow, bounds) else { return .stale }

        // 5. Position, size, position again (macOS keeps a growing window on screen by moving it).
        write(window, destination)

        // 6. Read it back until it settles; the window server must agree it is this window.
        let (axAfter, serverAfter) = settle(window, windowID: job.windowID, pid: job.pid)
        guard let serverAfter else { return .failed }   // gone or off screen meanwhile
        if WindowFrameGeometry.matches(serverAfter, bounds) {
            if let axAfter, !WindowFrameGeometry.matches(axAfter, bounds) {
                // Accessibility moved, the window didn't: that element isn't this window. Put it back.
                write(window, bounds)
                Log.info("workspace: frame change for window \(job.windowID) moved another element; put back")
                return .ambiguous
            }
            guard job.op == .fill else { return .failed }
            // Unchanged after an earlier Fill left it here: as large as the app allows already.
            return previous.map { WindowFrameGeometry.matches($0.after, bounds) } == true ? .limited : .notResizable
        }
        // The window moved. Only a frame both sides agree on proves it was this window.
        let agreed = axAfter.map { WindowFrameGeometry.matches($0, serverAfter) } ?? false
        switch job.op {
        case .fill:
            let before = WindowFrameGeometry.frameBeforeFill(previous: previous, current: bounds)
            memory.remember(key, WindowFrameMemoryEntry(before: before, after: serverAfter, displayID: displayID, title: job.title,
                                                        at: ProcessInfo.processInfo.systemUptime))
            return agreed ? WindowFrameGeometry.gradeFill(before: bounds, target: destination, after: serverAfter) : .failed
        case .restore:
            memory.forget(key)
            return agreed && WindowFrameGeometry.matches(serverAfter, destination) ? .restored : .failed
        }
    }

    /// Stage Manager's strip on that display: the window manager's own small windows near an edge.
    private static func stageStripItems(on display: CGRect, server: [ServerWindow]) -> [CGRect] {
        guard StageManagerWindows.isEnabled(),
              let wm = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.WindowManager").first?.processIdentifier
        else { return [] }
        return server.filter { $0.pid == wm && $0.onScreen && $0.bounds.width >= 20 && $0.bounds.height >= 20 && $0.bounds.intersects(display) }
            .map(\.bounds)
    }

    private static func write(_ window: AXUIElement, _ r: CGRect) {
        var origin = r.origin, size = r.size
        guard let p = AXValueCreate(.cgPoint, &origin), let s = AXValueCreate(.cgSize, &size) else { return }
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, p)
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, s)
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, p)
    }

    /// Reads the frame every 0.1 s until two reads agree and the window server reports the same,
    /// for at most 0.6 s; then the last reads, whatever they are.
    private static func settle(_ window: AXUIElement, windowID: UInt32, pid: Int32) -> (CGRect?, CGRect?) {
        let deadline = Date().addingTimeInterval(settleLimit)
        var last: CGRect?
        var ax: CGRect?, server: CGRect?
        repeat {
            Thread.sleep(forTimeInterval: settleInterval)
            ax = frame(window)
            server = serverBounds(windowID, pid: pid)
            if let ax, let last, WindowFrameGeometry.matches(ax, last, tolerance: 1),
               let server, WindowFrameGeometry.matches(server, ax) { break }
            last = ax
        } while Date() < deadline
        return (ax, server)
    }

    // MARK: Accessibility reads

    private static func elements(_ e: AXUIElement, _ attribute: String) -> [AXUIElement]? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, attribute as CFString, &v) == .success else { return nil }
        return v as? [AXUIElement]
    }

    private static func string(_ e: AXUIElement, _ attribute: String) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, attribute as CFString, &v) == .success else { return nil }
        return v as? String
    }

    private static func bool(_ e: AXUIElement, _ attribute: String) -> Bool? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, attribute as CFString, &v) == .success else { return nil }
        return (v as? NSNumber)?.boolValue
    }

    private static func settable(_ e: AXUIElement, _ attribute: String) -> Bool {
        var ok = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(e, attribute as CFString, &ok) == .success && ok.boolValue
    }

    private static func frame(_ e: AXUIElement) -> CGRect? {
        var p: CFTypeRef?, s: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, kAXPositionAttribute as CFString, &p) == .success,
              AXUIElementCopyAttributeValue(e, kAXSizeAttribute as CFString, &s) == .success,
              let p, let s, CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero, size = CGSize.zero
        // swiftlint:disable force_cast
        guard AXValueGetValue(p as! AXValue, .cgPoint, &origin), AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
        // swiftlint:enable force_cast
        return CGRect(origin: origin, size: size)
    }
}

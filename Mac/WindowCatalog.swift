import AppKit
import CoreGraphics
import Foundation
@preconcurrency import ScreenCaptureKit

// Window mode's catalog: which Mac windows a receiver may pick.
//
// Measured on macOS 27 (integration evidence W1-sck): ScreenCaptureKit lists
// many layer-0 helper windows WITH bundle ids — every app's untitled
// menu-bar strip, off-screen 500x500 placeholders, cursor and password-prompt
// agents — so "no bundle id" (Sill #223) is not enough, and coordinate rules
// would hide legitimate windows on other Spaces or off-screen. The rules here
// use identity and metadata; untitled windows are listed only while on
// screen, titled ones also when minimized, hidden or on another Space.

/// What the classifier needs about one window. Built from SCWindow + the
/// matching CGWindowList entry, or by tests.
struct WindowCandidate: Equatable, Sendable {
    var windowID: UInt32
    var pid: Int32
    var bundleID: String?
    var appName: String?
    var title: String?
    var layer: Int
    /// Frame in global points (top-left origin), as SCWindow/CGWindowList report it.
    var frame: CGRect
    var isOnScreen: Bool
    var alpha: Double
    /// kCGWindowSharingState: 0 = none (the window opted out of capture).
    var sharingState: Int
    var isActive: Bool
}

enum WindowAvailability: String, Codable, Sendable {
    /// Visible on a display now (possibly covered).
    case visible
    /// Exists but not on screen: minimized, app hidden, other Space. Streams
    /// pause until it is back (SCK delivers no frames, -3811 for stills).
    case offscreen
}

enum WindowCatalogPolicy {
    /// Never listed: system UI, input/auth agents, the window manager's own
    /// thumbnails (Stage Manager strip, App Icon Window), screen sharing.
    static let systemBundles: Set<String> = [
        "com.apple.WindowManager", "com.apple.dock", "com.apple.loginwindow",
        "com.apple.SecurityAgent", "com.apple.LocalAuthentication.UIAgent", "com.apple.coreautha",
        "com.apple.controlcenter", "com.apple.notificationcenterui", "com.apple.Spotlight",
        "com.apple.universalcontrol", "com.apple.screencaptureui", "com.apple.WindowServer",
        "com.apple.SafariPlatformSupport.Helper", "com.apple.ScreenSharing", "com.apple.TextInputUI.xpc.CursorUIViewService",
        "com.apple.TextInputMenuAgent", "com.apple.wallpaper.agent", "com.apple.AutoFillPanelService",
        "com.apple.AuthenticationServicesCore.AuthenticationServicesAgent", "com.apple.PassKit.PaymentAuthorizationUIExtension",
    ]
    static let systemBundlePrefixes = ["com.apple.appkit.xpc.", "com.apple.TextInputUI.", "com.apple.CoreAuthentication"]
    static let minimumSize = CGSize(width: 120, height: 80)

    enum Exclusion: String, Equatable, Sendable {
        case notNormalLayer, noBundle, ownApp, system, transparent, notShareable, tooSmall, untitledOffscreen, menuBarStrip
    }

    /// Nil when the window may be listed.
    static func exclusion(for w: WindowCandidate, ownBundleIDs: Set<String>, ownPID: Int32) -> Exclusion? {
        guard w.layer == 0 else { return .notNormalLayer }
        guard let bundle = w.bundleID, !bundle.isEmpty else { return .noBundle }
        // MeowDisplay never offers its own windows: pairing codes, approval
        // prompts and settings stay on this Mac.
        if w.pid == ownPID || ownBundleIDs.contains(bundle) { return .ownApp }
        if systemBundles.contains(bundle) || systemBundlePrefixes.contains(where: bundle.hasPrefix) { return .system }
        guard w.alpha > 0.01 else { return .transparent }
        guard w.sharingState != 0 else { return .notShareable }
        let untitled = (w.title ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        // Every app's menu-bar backdrop: untitled, full width, a menu bar tall.
        if untitled, w.frame.height <= 50, w.frame.minY <= 0 { return .menuBarStrip }
        guard w.frame.width >= minimumSize.width, w.frame.height >= minimumSize.height else { return .tooSmall }
        if untitled, !w.isOnScreen { return .untitledOffscreen }
        return nil
    }

    static func availability(_ w: WindowCandidate) -> WindowAvailability {
        w.isOnScreen ? .visible : .offscreen
    }
}

/// One listed window, as sent to the receiver (`windowCatalog`).
struct WindowCatalogEntry: Equatable, Sendable {
    var windowID: UInt32
    /// Session-local identity generation: a window id seen again with a
    /// different owner is a different window and gets a new generation.
    var generation: UInt64
    var pid: Int32
    var bundleID: String
    var appName: String
    var title: String
    var frame: CGRect
    var availability: WindowAvailability
    var isActive: Bool
    /// In Stage Manager's side strip: macOS shows a thumbnail and pauses capture of it.
    /// `frame` is then the real window's (from Accessibility), not the thumbnail's.
    var inStageStrip = false

    var wire: [String: Any] {
        var m: [String: Any] = [
            "id": Int(windowID), "gen": Int(generation), "bundle": bundleID, "app": appName,
            "title": String(title.prefix(160)), "w": Int(frame.width.rounded()), "h": Int(frame.height.rounded()),
            "state": availability.rawValue, "active": isActive,
        ]
        if inStageStrip { m["strip"] = true }
        return m
    }
}

struct RunningAppEntry: Equatable, Sendable {
    var bundleID: String
    var name: String
    var pid: Int32
    var hasWindows: Bool

    var wire: [String: Any] { ["bundle": bundleID, "name": String(name.prefix(80)), "windows": hasWindows] }
}

/// Assigns stable per-session generations to window ids. A window id the
/// WindowServer reuses for a different process is a new identity, so a tile
/// holding the old one can never silently start showing (or typing into) it.
struct WindowIdentityLedger: Sendable {
    private struct Key: Hashable { let id: UInt32; let pid: Int32 }
    private var owners: [UInt32: Key] = [:]
    private var generations: [Key: UInt64] = [:]
    private var lastSeen: [UInt32: TimeInterval] = [:]
    private var next: UInt64 = 1
    /// A window missing from one listing keeps its identity this long (SCK
    /// listings can skip a window briefly); after that it is gone for good.
    static let absenceGrace: TimeInterval = 5

    mutating func generation(windowID: UInt32, pid: Int32) -> UInt64 {
        let key = Key(id: windowID, pid: pid)
        if let gen = generations[key], owners[windowID] == key { return gen }
        if let old = owners[windowID], old != key { generations[old] = nil }
        owners[windowID] = key
        let gen = next
        next += 1
        generations[key] = gen
        return gen
    }

    func current(windowID: UInt32) -> (pid: Int32, generation: UInt64)? {
        guard let key = owners[windowID], let gen = generations[key] else { return nil }
        return (key.pid, gen)
    }

    /// Forget ids absent for longer than the grace, so the ledger stays bounded.
    mutating func retain(_ live: Set<UInt32>, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        for id in live { lastSeen[id] = now }
        for (id, key) in owners where !live.contains(id) && now - (lastSeen[id] ?? now) > Self.absenceGrace {
            owners[id] = nil
            generations[key] = nil
            lastSeen[id] = nil
        }
    }

    /// Still known (seen within the grace) under this generation.
    func knows(windowID: UInt32, generation: UInt64) -> Bool {
        current(windowID: windowID)?.generation == generation
    }
}

/// A sheet ("Save changes?", an alert sheet, an Open panel) open on a listed window.
/// macOS draws it as a separate window, so a pane shows and clicks it as part of its window.
struct AttachedSheet: @unchecked Sendable {
    var windowID: UInt32
    /// Global points, top-left origin.
    var frame: CGRect
    var scWindow: SCWindow?
}

/// SCWindow values are immutable snapshots, safe to hand between queues.
struct WindowCatalogSnapshot: @unchecked Sendable {
    var windows: [WindowCatalogEntry]
    var apps: [RunningAppEntry]
    /// SCWindow by id, for starting captures without another enumeration.
    var scWindows: [UInt32: SCWindow]
    var takenAt: TimeInterval
    /// Sheets open on listed windows, by the window they belong to (front-most first).
    var sheets: [UInt32: [AttachedSheet]] = [:]
}

/// Which on-screen windows are sheets of which window. A sheet is an untitled normal-layer
/// window of the same app, ordered directly above its window and horizontally centred on it,
/// starting inside it (attached under the title bar, or centred as on macOS 26 and later).
/// Measured on macOS 27: an NSWindow sheet is its own CGWindow (e.g. 19511 over 19510).
enum WindowSheetMatcher {
    struct Window: Equatable, Sendable {
        var id: UInt32
        var pid: Int32
        var frame: CGRect
        var title: String?
        var layer: Int
    }

    /// `frontToBack`: on-screen windows in window-server order (CGWindowList order).
    /// Returns sheet ids by the id of the window they belong to.
    static func sheets(frontToBack: [Window]) -> [UInt32: [UInt32]] {
        var parentOf: [UInt32: UInt32] = [:]
        for (i, w) in frontToBack.enumerated() where isSheetShaped(w) {
            // Its window: the next window of the same app below it that it sits on.
            guard let parent = frontToBack[(i + 1)...].first(where: { $0.pid == w.pid && $0.layer == 0 && $0.id != w.id }),
                  sits(w.frame, on: parent.frame) else { continue }
            parentOf[w.id] = parent.id
        }
        // A sheet on a sheet (an alert over a Save panel) belongs to the same window. Front-most first.
        var result: [UInt32: [UInt32]] = [:]
        for w in frontToBack {
            guard var owner = parentOf[w.id] else { continue }
            var hops = 0
            while let up = parentOf[owner], hops < 8 { owner = up; hops += 1 }
            result[owner, default: []].append(w.id)
        }
        return result
    }

    static func isSheetShaped(_ w: Window) -> Bool {
        w.layer == 0 && (w.title ?? "").trimmingCharacters(in: .whitespaces).isEmpty && w.frame.width >= 40 && w.frame.height >= 30
    }

    static func sits(_ sheet: CGRect, on window: CGRect) -> Bool {
        abs(sheet.midX - window.midX) <= 3 && sheet.width < window.width + 1
            && sheet.minY > window.minY && sheet.minY < window.maxY - 20
    }
}

enum WindowCatalogBuilder {
    /// Enumerate shareable windows. ScreenCaptureKit is the source of truth
    /// for what can be captured; CGWindowList adds alpha/sharing state and
    /// proves a window still exists (SCK keeps a closed window listed for
    /// ~0.6 s, measured). Never activates apps or moves windows.
    /// `includeOwnProcess` exists for the engine's integration test only; the
    /// app never sets it (MeowDisplay's own windows are never offered).
    static func build(ledger input: WindowIdentityLedger, includeOwnProcess: Bool = false) async throws
        -> (WindowCatalogSnapshot, WindowIdentityLedger) {
        var ledger = input
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        let cgList = (CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]) ?? []
        var cgByID: [UInt32: [String: Any]] = [:]
        for info in cgList {
            if let n = info[kCGWindowNumber as String] as? UInt32 { cgByID[n] = info }
        }
        let ownPID = includeOwnProcess ? -2 : ProcessInfo.processInfo.processIdentifier
        let ownBundles: Set<String> = includeOwnProcess ? [] : Set([Bundle.main.bundleIdentifier].compactMap { $0 })
        var entries: [WindowCatalogEntry] = []
        var scByID: [UInt32: SCWindow] = [:]
        var windowPIDs = Set<Int32>()
        for window in content.windows {
            guard let cg = cgByID[window.windowID] else { continue }   // gone already
            let app = window.owningApplication
            var bundleID = app?.bundleIdentifier
            if includeOwnProcess, app?.processID == ProcessInfo.processInfo.processIdentifier, (bundleID ?? "").isEmpty {
                bundleID = "dev.meowdisplay.integration-test"   // the xctest tool has no bundle id
            }
            let candidate = WindowCandidate(
                windowID: window.windowID, pid: app?.processID ?? -1, bundleID: bundleID,
                appName: app?.applicationName, title: window.title, layer: window.windowLayer, frame: window.frame,
                isOnScreen: window.isOnScreen, alpha: (cg[kCGWindowAlpha as String] as? Double) ?? 1,
                sharingState: (cg[kCGWindowSharingState as String] as? Int) ?? 1, isActive: window.isActive)
            guard WindowCatalogPolicy.exclusion(for: candidate, ownBundleIDs: ownBundles, ownPID: ownPID) == nil,
                  let bundle = candidate.bundleID else { continue }
            let gen = ledger.generation(windowID: window.windowID, pid: candidate.pid)
            var frame = candidate.frame
            var inStrip = false
            if candidate.isOnScreen, StageManagerWindows.looksLikeThumbnail(frame), StageManagerWindows.isEnabled(),
               let real = StageManagerWindows.realFrame(pid: candidate.pid, title: candidate.title ?? ""),
               real.width > frame.width * 1.5 || real.height > frame.height * 1.5 {
                frame = real
                inStrip = true
            }
            entries.append(WindowCatalogEntry(
                windowID: window.windowID, generation: gen, pid: candidate.pid, bundleID: bundle,
                appName: candidate.appName ?? bundle, title: candidate.title ?? "", frame: frame,
                availability: WindowCatalogPolicy.availability(candidate), isActive: candidate.isActive, inStageStrip: inStrip))
            scByID[window.windowID] = window
            windowPIDs.insert(candidate.pid)
        }
        // Sheets belong to their window: shown and clicked in its pane, never listed on their own.
        let sheetMap = sheetsOfListedWindows(content: content, cgList: cgList, listed: Set(entries.map(\.windowID)))
        let sheetIDs = Set(sheetMap.values.flatMap { $0.map(\.windowID) })
        if !sheetIDs.isEmpty {
            entries.removeAll { sheetIDs.contains($0.windowID) }
            for id in sheetIDs { scByID[id] = nil }
        }
        ledger.retain(Set(entries.map(\.windowID)))
        let apps = content.applications.compactMap { app -> RunningAppEntry? in
            let bundle = app.bundleIdentifier
            guard !bundle.isEmpty, app.processID != ownPID, !ownBundles.contains(bundle),
                  !WindowCatalogPolicy.systemBundles.contains(bundle),
                  !WindowCatalogPolicy.systemBundlePrefixes.contains(where: bundle.hasPrefix),
                  NSRunningApplication(processIdentifier: app.processID)?.activationPolicy == .regular else { return nil }
            return RunningAppEntry(bundleID: bundle, name: app.applicationName, pid: app.processID,
                                   hasWindows: windowPIDs.contains(app.processID))
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return (WindowCatalogSnapshot(windows: entries, apps: apps, scWindows: scByID,
                                      takenAt: ProcessInfo.processInfo.systemUptime, sheets: sheetMap), ledger)
    }

    private static func sheetsOfListedWindows(content: SCShareableContent, cgList: [[String: Any]],
                                              listed: Set<UInt32>) -> [UInt32: [AttachedSheet]] {
        var scByID: [UInt32: SCWindow] = [:]
        for w in content.windows { scByID[w.windowID] = w }
        let order = cgList.compactMap { info -> WindowSheetMatcher.Window? in
            guard (info[kCGWindowIsOnscreen as String] as? Bool) == true,
                  let id = info[kCGWindowNumber as String] as? UInt32,
                  let pid = info[kCGWindowOwnerPID as String] as? Int32,
                  let dict = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: dict) else { return nil }
            // CGWindowList hides names without Screen Recording; ScreenCaptureKit's title is the one used for listing.
            let title = scByID[id]?.title ?? (info[kCGWindowName as String] as? String)
            return WindowSheetMatcher.Window(id: id, pid: pid, frame: frame, title: title,
                                             layer: (info[kCGWindowLayer as String] as? Int) ?? 0)
        }
        var result: [UInt32: [AttachedSheet]] = [:]
        for (parent, ids) in WindowSheetMatcher.sheets(frontToBack: order) where listed.contains(parent) {
            result[parent] = ids.compactMap { id in
                guard let sc = scByID[id] else { return nil }
                return AttachedSheet(windowID: id, frame: sc.frame, scWindow: sc)
            }
        }
        return result.filter { !$0.value.isEmpty }
    }

    /// Installed apps the receiver may ask to open: /Applications only,
    /// bounded, names and bundle ids (no icons until asked).
    static func installedApplications(limit: Int = 200) -> [(bundleID: String, name: String, url: URL)] {
        var result: [(String, String, URL)] = []
        let dirs = [URL(fileURLWithPath: "/Applications"), URL(fileURLWithPath: "/System/Applications")]
        for dir in dirs {
            let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            for url in items where url.pathExtension == "app" {
                guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier,
                      id != Bundle.main.bundleIdentifier else { continue }
                let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                    ?? url.deletingPathExtension().lastPathComponent
                result.append((id, name, url))
                if result.count >= limit { return result }
            }
        }
        return result.sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }
    }
}


/// Stage Manager draws windows outside the current stage as thumbnails in its side strip, and
/// ScreenCaptureKit and CGWindowList then report the thumbnail's frame (measured on macOS 27:
/// a 1554x993 Zed window at (214,30) listed as 176x166 at (-238,180)). macOS also pauses capture
/// of those windows. Accessibility still reports the real frame. Reads settings, never changes them.
enum StageManagerWindows {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var enabledCache: (at: TimeInterval, value: Bool)?
    nonisolated(unsafe) private static var frames: [String: (at: TimeInterval, frame: CGRect?)] = [:]

    /// Thumbnails in the strip are small (about 200 points at most).
    static func looksLikeThumbnail(_ frame: CGRect) -> Bool { frame.width <= 320 && frame.height <= 320 }

    static func isEnabled() -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        if let c = lock.withLock({ enabledCache }), now - c.at < 3 { return c.value }
        let value = (CFPreferencesCopyAppValue("GloballyEnabled" as CFString, "com.apple.WindowManager" as CFString) as? Bool) ?? false
        lock.withLock { enabledCache = (now, value) }
        return value
    }

    /// The real frame of the app's window with this title, cached for 2 s. Accessibility titles
    /// can carry more than the window's (Chrome adds " - High memory usage…"): an exact match
    /// first, then a unique prefix match, then the app's only window.
    static func realFrame(pid: Int32, title: String) -> CGRect? {
        guard AXIsProcessTrusted() else { return nil }
        let key = "\(pid)|\(title)"
        let now = ProcessInfo.processInfo.systemUptime
        if let c = lock.withLock({ frames[key] }), now - c.at < 2 { return c.frame }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.15)
        var value: CFTypeRef?
        var all: [(title: String, frame: CGRect)] = []
        if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success, let windows = value as? [AXUIElement] {
            for w in windows.prefix(64) {
                var t: CFTypeRef?, p: CFTypeRef?, s: CFTypeRef?
                guard AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &p) == .success,
                      AXUIElementCopyAttributeValue(w, kAXSizeAttribute as CFString, &s) == .success,
                      let p, let s, CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { continue }
                var origin = CGPoint.zero, size = CGSize.zero
                AXValueGetValue(p as! AXValue, .cgPoint, &origin)   // swiftlint:disable:this force_cast
                AXValueGetValue(s as! AXValue, .cgSize, &size)      // swiftlint:disable:this force_cast
                AXUIElementCopyAttributeValue(w, kAXTitleAttribute as CFString, &t)
                if size.width > 0, size.height > 0 { all.append(((t as? String) ?? "", CGRect(origin: origin, size: size))) }
            }
        }
        let frame = matchingFrame(title: title, in: all)
        lock.withLock {
            frames[key] = (now, frame)
            if frames.count > 256 { frames = frames.filter { now - $0.value.at < 2 } }
        }
        return frame
    }

    /// Pure: which Accessibility window is the listed one.
    static func matchingFrame(title: String, in windows: [(title: String, frame: CGRect)]) -> CGRect? {
        let exact = windows.filter { $0.title == title }
        if exact.count == 1 { return exact[0].frame }
        if exact.isEmpty, !title.isEmpty {
            let prefixed = windows.filter { $0.title.hasPrefix(title) }
            if prefixed.count == 1 { return prefixed[0].frame }
        }
        return windows.count == 1 ? windows[0].frame : nil
    }
}

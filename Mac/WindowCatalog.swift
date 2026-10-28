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

    var wire: [String: Any] {
        [
            "id": Int(windowID), "gen": Int(generation), "bundle": bundleID, "app": appName,
            "title": String(title.prefix(160)), "w": Int(frame.width.rounded()), "h": Int(frame.height.rounded()),
            "state": availability.rawValue, "active": isActive,
        ]
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
    private var next: UInt64 = 1

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

    /// Forget ids no longer present so the ledger stays bounded.
    mutating func retain(_ live: Set<UInt32>) {
        for (id, key) in owners where !live.contains(id) {
            owners[id] = nil
            generations[key] = nil
        }
    }
}

/// SCWindow values are immutable snapshots, safe to hand between queues.
struct WindowCatalogSnapshot: @unchecked Sendable {
    var windows: [WindowCatalogEntry]
    var apps: [RunningAppEntry]
    /// SCWindow by id, for starting captures without another enumeration.
    var scWindows: [UInt32: SCWindow]
    var takenAt: TimeInterval
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
            entries.append(WindowCatalogEntry(
                windowID: window.windowID, generation: gen, pid: candidate.pid, bundleID: bundle,
                appName: candidate.appName ?? bundle, title: candidate.title ?? "", frame: candidate.frame,
                availability: WindowCatalogPolicy.availability(candidate), isActive: candidate.isActive))
            scByID[window.windowID] = window
            windowPIDs.insert(candidate.pid)
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
                                      takenAt: ProcessInfo.processInfo.systemUptime), ledger)
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

import CoreGraphics
import Foundation
import ImageIO
import QuartzCore

// Window workspaces on Apple receivers (iPhone, iPad, Mac Receiver): what the
// Mac sends, what this device asks for, and the model the views draw. Same
// rules as the Android client (AndroidReceiver/.../workspace); the Mac stays
// authoritative for what's listed, accepted and focused.

// MARK: - Messages from the Mac (parsed on the network queue, Sendable)

struct CatalogWindowItem: Equatable, Sendable, Identifiable {
    var id: UInt32
    var generation: UInt64
    var bundleID: String
    var app: String
    var title: String
    var width: Int
    var height: Int
    var minimized: Bool
    var active: Bool
    /// In Stage Manager's side strip: macOS pauses its picture there (PROTOCOL.md §6.10).
    var inStageStrip = false

    /// A short card badge for a window that can't show a current picture, or nil.
    var pausedBadge: String? {
        minimized ? String(localized: "Minimized") : inStageStrip ? String(localized: "In Strip") : nil
    }
    /// The same for VoiceOver.
    var pausedSpoken: String? {
        minimized ? String(localized: "Minimized") : inStageStrip ? String(localized: "In Stage Manager’s side strip, picture paused") : nil
    }
}

/// The outcome of one Close Window, worded for the person who asked.
struct WindowCloseNotice: Equatable, Sendable {
    var windowID: UInt32
    var name: String
    /// nil: no answer from the Mac (or it can't close windows from here).
    var result: WindowCloseResult?
    var unsupported = false

    var isError: Bool { result != .closed && result != .stale }

    var message: String {
        if unsupported { return String(localized: "Update MeowDisplay on the Mac to close windows from here.") }
        switch result {
        case .closed: return String(localized: "Closed “\(name)”.")
        case .saveDialog: return String(localized: "“\(name)” has unsaved changes. Choose Save or Don’t Save on the Mac.")
        case .stillOpen: return String(localized: "“\(name)” stayed open. Its app may be busy or asking something on the Mac.")
        case .stale: return String(localized: "“\(name)” was already closed.")
        case .control: return String(localized: "Closing windows needs control of the Mac. Use Request Control first.")
        case .accessibility: return String(localized: "The Mac needs Accessibility permission for MeowDisplay to close windows.")
        case .noButton: return String(localized: "“\(name)” can’t be closed: it has no close button.")
        case .ambiguous: return String(localized: "The Mac couldn’t tell which window to close, so nothing was closed.")
        case nil: return String(localized: "The Mac didn’t confirm closing “\(name)”.")
        }
    }
}

/// The outcome of one Fill Window on Mac / Restore Previous Size on Mac, worded for the person who
/// asked (shown briefly on the pane). These change the real Mac window, unlike the pane's own
/// Fill/Show Whole Window, which only changes how this device draws it.
struct WindowFrameNotice: Equatable, Sendable {
    var tile: String
    var windowID: UInt32
    var op: WindowFrameOp
    /// nil: no answer from the Mac in time.
    var result: WindowFrameResult?

    var isError: Bool { !(result?.succeeded ?? false) }

    var message: String {
        switch result {
        case .filled: return String(localized: "The window now fills its screen on the Mac.")
        case .limited: return String(localized: "Resized on the Mac as far as the app allows.")
        case .alreadyFilled: return String(localized: "The window already fills its screen on the Mac.")
        case .restored: return String(localized: "The window is back to its previous size on the Mac.")
        case .nothingToRestore: return String(localized: "There’s no previous size to restore on the Mac.")
        case .changed: return String(localized: "The window was moved or resized on the Mac since, so its previous size wasn’t restored.")
        case .displayChanged: return String(localized: "The display the window was on isn’t connected now, so nothing was moved.")
        case .stale: return String(localized: "That window isn’t available on the Mac any more.")
        case .ambiguous: return String(localized: "The Mac couldn’t tell which window this is, so nothing was moved.")
        case .notResizable: return String(localized: "This window can’t be resized on the Mac.")
        case .fullScreen: return String(localized: "The window is in full screen on the Mac. Exit full screen there first.")
        case .offscreen: return String(localized: "The window is minimized, hidden or on another Space on the Mac.")
        case .stageStrip: return String(localized: "The window is in Stage Manager’s side strip. Show it on the Mac first.")
        case .missionControl: return String(localized: "Mission Control is open on the Mac. Close it and try again.")
        case .privacyShield: return String(localized: "The Mac is asking for its password to remove the Privacy Shield. Try again after that.")
        case .control: return String(localized: "Resizing Mac windows needs control of the Mac. Use Request Control first.")
        case .accessibility: return String(localized: "The Mac needs Accessibility permission for MeowDisplay to resize windows.")
        case .failed:
            return op == .fill ? String(localized: "The Mac couldn’t resize the window.")
                : String(localized: "The Mac couldn’t restore the window’s previous size.")
        case nil: return String(localized: "The Mac didn’t confirm resizing the window.")
        }
    }
}

struct CatalogAppItem: Equatable, Sendable { var bundleID: String; var name: String; var hasWindows: Bool }
struct InstalledAppItem: Equatable, Sendable { var bundleID: String; var name: String }

struct WorkspaceCatalogMessage: Equatable, Sendable {
    var host: String?
    var windows: [CatalogWindowItem]
    var apps: [CatalogAppItem]
    var installed: [InstalledAppItem]
    var unavailable: Bool
    /// Window mode is still starting on the Mac: not a listing failure. The picker keeps asking.
    var starting = false
    /// The Mac's displays (Full Desktop sources), main first.
    var displays: [CatalogDisplayItem] = []

    func search(_ query: String) -> [CatalogWindowItem] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return windows }
        return windows.filter { $0.title.localizedCaseInsensitiveContains(q) || $0.app.localizedCaseInsensitiveContains(q) }
    }
}

/// A pane's capture on the Mac. `paused`: macOS paused it (Stage Manager's side strip, a hidden
/// window); `retrying`: it stalled and the Mac is restarting it; `failed`: gave up (Retry).
enum RemoteTileStatus: String, Sendable { case live, waiting, offscreen, closed, failed, limit, paused, retrying }

enum RemoteHostFocus: String, Sendable {
    case deliver, noActiveTile, hostFocusElsewhere, otherWindowFocused
    var isMismatch: Bool { self == .hostFocusElsewhere || self == .otherWindowFocused }
}

struct RemoteTileItem: Equatable, Sendable {
    var id: String
    var windowID: UInt32
    var generation: UInt64
    var status: RemoteTileStatus
    var app: String
    var bundleID: String
    var title: String
    /// Restarts so far while `retrying`.
    var attempt = 0
    /// The window sits in Stage Manager's side strip (macOS pauses its picture there).
    var inStageStrip = false
    /// The Mac accepted it as a floating pane (`layer: "float"`).
    var isFloat = false
    /// The Mac can put this window back to its size before Fill Window on Mac (`restore`).
    var restorable = false
}

struct WorkspaceStateMessage: Equatable, Sendable {
    var host: String?
    var tiles: [RemoteTileItem]
    var active: String?
    var hostFocus: RemoteHostFocus
    var rejected: [String: String]
    /// Stage Manager is on on the Mac (its strip pauses windows).
    var stageManager = false
    /// Whether Stage Manager is on (true) or off (false); nil: an older Mac that only says when it is on.
    var stageManagerOn: Bool?
    /// Whether the Mac can switch it: "ready", "setup" (the owner hasn't made the two shortcuts on
    /// the Mac yet) or "failed" (macOS didn't apply the last change). nil: an older Mac, never offered.
    var stageManagerControl: String?
    /// The last Add to Current Stage (for 8 s): the window and "added", "notInStrip", "ambiguous",
    /// "accessibility" or "failed".
    var stageAdd: StageAddReply?
    /// The Mac can add a strip window to the current stage (off until it is shown to work).
    var stageAddAvailable = false
    /// Mission Control is open on the Mac: macOS pauses window pictures until it closes.
    var missionControlOpen = false
    /// Windows this receiver holds (`watch`) that closed on the Mac (PROTOCOL.md 6.10 `gone`).
    var gone: [WorkspaceHeldWindow] = []
}

/// A Mac window as this receiver holds it: its id and the generation it was listed under.
struct WorkspaceHeldWindow: Hashable, Sendable {
    var window: UInt32
    var generation: UInt64
}

struct StageAddReply: Equatable, Sendable { let window: UInt32; let result: String }

enum WorkspaceEvent: Sendable {
    case features(Set<String>)
    /// The Mac locked or unlocked its screen (`macLockState`).
    case macLock(MacLockNotice)
    /// The Mac's Privacy Shield covers its own screens while this device is connected (welcome).
    case privacyShield(Bool)
    case mode(window: Bool)
    case catalog(WorkspaceCatalogMessage)
    case state(WorkspaceStateMessage)
    case thumbnail(windowID: UInt32, generation: UInt64, data: Data?, stale: Bool = false)
    case icon(bundleID: String, data: Data)
    case displayThumbnail(displayID: UInt32, data: Data)
    /// `apps` nil: the receiver's revision is current.
    case appCatalog(revision: Int, apps: [MacAppItem]?)
    case launchResult(bundleID: String, ok: Bool)
    /// Close Window from Stage Peek (PROTOCOL.md 6.10).
    case closeResult(windowID: UInt32, result: WindowCloseResult)
    /// Lock This Mac (PROTOCOL.md 6.16).
    case lockResult(LockMacResult)
    /// Fill Window on Mac / Restore Previous Size on Mac (PROTOCOL.md 6.10).
    case frameResult(WindowFrameReply)
    /// Remote Finder (PROTOCOL.md 6.12).
    case files(RemoteFilesReply)
    /// Unified Clipboard (PROTOCOL.md 6.15).
    case clip(ClipboardMessage)
    /// Pane menus (PROTOCOL.md 6.13).
    case menu(AppMenuReply)
    case menuResult(ok: Bool, error: String?)
    /// Panes whose latest view (epoch) the Mac has composed and sent.
    case view([String: Int])
    /// A pane's whole source as a still, for the instant local zoom.
    case backdrop(tile: String, windowID: UInt32, data: Data, stale: Bool)
    case connected(peerID: String)
    case disconnected

    static let maxBase64 = 256 * 1024   // a sharp 640-wide Stage Peek still
    static let maxBackdropBase64 = WorkspaceBackdrop.maxBase64   // a pane's whole source, up to 1600 wide

    /// Bounded, defensive parsing of one control message; nil for anything else.
    static func parse(type: String, _ obj: [String: Any]) -> WorkspaceEvent? {
        func str(_ o: [String: Any], _ k: String, _ limit: Int = 160) -> String? { (o[k] as? String).map { String($0.prefix(limit)) } }
        func u32(_ o: [String: Any], _ k: String) -> UInt32? { (o[k] as? Int).flatMap { UInt32(exactly: $0) } }
        func u64(_ o: [String: Any], _ k: String) -> UInt64? { (o[k] as? Int).flatMap { UInt64(exactly: $0) } }
        switch type {
        case MacLockWire.type:
            return MacLockNotice(message: obj).map { .macLock($0) }
        case WireMessage.windowCatalog:
            let windows = (obj["windows"] as? [[String: Any]] ?? []).prefix(120).compactMap { w -> CatalogWindowItem? in
                guard let id = u32(w, "id"), let bundle = str(w, "bundle") else { return nil }
                return CatalogWindowItem(id: id, generation: u64(w, "gen") ?? 0, bundleID: bundle, app: str(w, "app", 80) ?? "",
                                         title: str(w, "title") ?? "", width: w["w"] as? Int ?? 0, height: w["h"] as? Int ?? 0,
                                         minimized: (w["state"] as? String) == "offscreen", active: w["active"] as? Bool ?? false,
                                         inStageStrip: w["strip"] as? Bool ?? false)
            }
            let apps = (obj["apps"] as? [[String: Any]] ?? []).prefix(60).compactMap { a -> CatalogAppItem? in
                guard let b = str(a, "bundle") else { return nil }
                return CatalogAppItem(bundleID: b, name: str(a, "name", 80) ?? "", hasWindows: a["windows"] as? Bool ?? false)
            }
            let installed = (obj["installed"] as? [[String: Any]] ?? []).prefix(150).compactMap { a -> InstalledAppItem? in
                guard let b = str(a, "bundle") else { return nil }
                return InstalledAppItem(bundleID: b, name: str(a, "name", 80) ?? "")
            }
            let displays = (obj["displays"] as? [[String: Any]] ?? []).prefix(8).compactMap { d -> CatalogDisplayItem? in
                guard let id = u32(d, "id") else { return nil }
                return CatalogDisplayItem(id: id, name: str(d, "name", 80) ?? "Display", width: d["w"] as? Int ?? 0,
                                          height: d["h"] as? Int ?? 0, isMain: d["main"] as? Bool ?? false,
                                          isVirtual: d["virtual"] as? Bool ?? false)
            }
            return .catalog(WorkspaceCatalogMessage(host: str(obj, "host"), windows: Array(windows), apps: Array(apps),
                                                   installed: Array(installed),
                                                   unavailable: obj["error"] != nil && obj["error"] as? String != "starting",
                                                   starting: obj["error"] as? String == "starting", displays: Array(displays)))
        case WireMessage.workspaceState:
            let tiles = (obj["tiles"] as? [[String: Any]] ?? []).prefix(WorkspaceLayout.maximumTiles).compactMap { t -> RemoteTileItem? in
                guard let id = str(t, "id", 32) else { return nil }
                return RemoteTileItem(id: id, windowID: u32(t, "window") ?? 0, generation: u64(t, "gen") ?? 0,
                                      status: (t["state"] as? String).flatMap(RemoteTileStatus.init(rawValue:)) ?? .waiting,
                                      app: str(t, "app", 80) ?? "", bundleID: str(t, "bundle") ?? "", title: str(t, "title", 120) ?? "",
                                      attempt: min(max(t["attempt"] as? Int ?? 0, 0), 99), inStageStrip: t["strip"] as? Bool ?? false,
                                      isFloat: t["layer"] as? String == "float",
                                      restorable: t[WindowFrameWire.tileRestorable] as? Bool ?? false)
            }
            let rejected = (obj["rejected"] as? [String: Any] ?? [:]).prefix(32).reduce(into: [String: String]()) { r, e in
                if let v = e.value as? String { r[e.key] = v }
            }
            return .state(WorkspaceStateMessage(host: str(obj, "host"), tiles: Array(tiles), active: str(obj, "active", 32),
                                                hostFocus: (obj["hostFocus"] as? String).flatMap(RemoteHostFocus.init(rawValue:)) ?? .noActiveTile,
                                                rejected: rejected, stageManager: obj["stageManager"] as? Bool ?? false,
                                                stageManagerOn: (obj["stageManagerState"] as? String).flatMap { $0 == "on" ? true : $0 == "off" ? false : nil },
                                                stageManagerControl: str(obj, "stageManagerControl", 16),
                                                stageAdd: (obj["stageAdd"] as? [String: Any]).flatMap { a in
                                                    u32(a, "window").flatMap { w in str(a, "result", 16).map { StageAddReply(window: w, result: $0) } }
                                                },
                                                stageAddAvailable: obj["stageAddAvailable"] as? Bool ?? false,
                                                missionControlOpen: obj["missionControl"] as? String == "open",
                                                gone: (obj["gone"] as? [[String: Any]] ?? []).prefix(128).compactMap { g in
                                                    u32(g, "window").flatMap { w in u64(g, "gen").map { WorkspaceHeldWindow(window: w, generation: $0) } }
                                                }))
        case WireMessage.windowThumbnail:
            guard let id = u32(obj, "id") else { return nil }
            let data = (obj["jpeg"] as? String).flatMap { $0.count <= maxBase64 ? Data(base64Encoded: $0) : nil }
            return .thumbnail(windowID: id, generation: u64(obj, "gen") ?? 0, data: data, stale: obj["stale"] as? Bool ?? false)
        case WireMessage.displayThumbnail:
            guard let id = u32(obj, "id"), let jpeg = obj["jpeg"] as? String, jpeg.count <= maxBase64,
                  let data = Data(base64Encoded: jpeg) else { return nil }
            return .displayThumbnail(displayID: id, data: data)
        case WireMessage.appCatalog:
            guard let rev = obj["rev"] as? Int else { return nil }
            if obj["same"] as? Bool == true { return .appCatalog(revision: rev, apps: nil) }
            let apps = (obj["apps"] as? [[String: Any]] ?? []).prefix(900).compactMap { a -> MacAppItem? in
                guard let b = str(a, "bundle"), !b.isEmpty else { return nil }
                return MacAppItem(bundleID: b, name: str(a, "name", 80) ?? b, running: a["running"] as? Bool ?? false,
                                  windowCount: a["windows"] as? Int ?? 0,
                                  lastUsed: (a["used"] as? Int).map { Date(timeIntervalSince1970: TimeInterval($0)) })
            }
            return .appCatalog(revision: rev, apps: Array(apps))
        case WireMessage.appLaunchResult:
            guard let b = str(obj, "bundle") else { return nil }
            return .launchResult(bundleID: b, ok: obj["ok"] as? Bool ?? false)
        case WireMessage.windowCloseResult:
            guard let id = u32(obj, "window"), let r = str(obj, "result", 32).flatMap(WindowCloseResult.init(rawValue:)) else { return nil }
            return .closeResult(windowID: id, result: r)
        case LockMacWire.result:
            return str(obj, "result", 32).flatMap(LockMacResult.init(rawValue:)).map { .lockResult($0) }
        case WindowFrameWire.result:
            return WindowFrameReply.parse(obj).map { .frameResult($0) }
        case WireMessage.files:
            return RemoteFilesReply.parse(obj).map { .files($0) }
        case ClipboardWire.type:
            return .clip(ClipboardMessage(obj: obj))
        case WireMessage.menu:
            return AppMenuReply.parse(obj).map { .menu($0) }
        case WireMessage.menuResult:
            return .menuResult(ok: obj["ok"] as? Bool ?? false, error: (obj["error"] as? String).map { String($0.prefix(32)) })
        case WireMessage.workspaceView:
            let tiles = (obj["tiles"] as? [String: Any] ?? [:]).prefix(WorkspaceLayout.maximumTiles * 2).reduce(into: [String: Int]()) { r, e in
                if e.key.count <= 32, let v = e.value as? Int { r[e.key] = v }
            }
            return .view(tiles)
        case WireMessage.workspaceBackdrop:
            guard let tile = str(obj, "tile", 32), let jpeg = obj["jpeg"] as? String, jpeg.count <= maxBackdropBase64,
                  let data = Data(base64Encoded: jpeg) else { return nil }
            return .backdrop(tile: tile, windowID: u32(obj, "window") ?? 0, data: data, stale: obj["stale"] as? Bool ?? false)
        case WireMessage.appIcon:
            guard let bundle = str(obj, "bundle"), let png = obj["png"] as? String, png.count <= maxBase64,
                  let data = Data(base64Encoded: png) else { return nil }
            return .icon(bundleID: bundle, data: data)
        default:
            return nil
        }
    }
}

/// Hands workspace events from the network queue to the main actor, in the order they came
/// (Remote Finder's file data arrives in ordered parts).
final class WorkspaceEventSink: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@MainActor @Sendable (WorkspaceEvent) -> Void)?

    func set(_ handler: (@MainActor @Sendable (WorkspaceEvent) -> Void)?) {
        lock.lock(); self.handler = handler; lock.unlock()
    }

    func emit(_ event: WorkspaceEvent) {
        lock.lock(); let handler = self.handler; lock.unlock()
        guard let handler else { return }
        DispatchQueue.main.async { MainActor.assumeIsolated { handler(event) } }
    }
}

extension Notification.Name {
    /// Settings asks the receiver screen to open the window overview.
    static let meowOpenWindowOverview = Notification.Name("MeowDisplay.openWindowOverview")
}

// MARK: - Requests to the Mac

enum WorkspaceRequests {
    static func catalog(installed: Bool) -> [String: Any] {
        var m: [String: Any] = ["type": WireMessage.windowCatalogRequest]
        if installed { m["installed"] = true }
        return m
    }

    static func thumbnails(_ ids: [UInt32], maxWidth: Int, icons: [String], displays: [UInt32] = []) -> [String: Any] {
        var m: [String: Any] = ["type": WireMessage.windowThumbnailRequest, "ids": ids.prefix(24).map { Int($0) }, "max": maxWidth]
        if !icons.isEmpty { m["icons"] = Array(icons.prefix(48)) }
        if !displays.isEmpty { m["displays"] = displays.prefix(8).map { Int($0) } }
        return m
    }

    static func appCatalog(revision: Int?) -> [String: Any] {
        var m: [String: Any] = ["type": WireMessage.appCatalogRequest]
        if let revision { m["rev"] = revision }
        return m
    }

    /// Opens an app on the Mac without activating it (needs control).
    static func appLaunch(_ bundle: String) -> [String: Any] { ["type": WireMessage.appLaunch, "bundle": bundle] }

    /// Minimizes the real Mac window: only from its own explicit action.
    static func minimizeWindow(_ id: UInt32, generation: UInt64) -> [String: Any] {
        ["type": WireMessage.windowAction, "action": "minimize", "window": Int(id), "gen": Int(generation)]
    }

    /// Only this host's tiles, at their normalized frames. `floats`: the Mac draws floating panes
    /// (`windowFloat`): the shown floats follow the tiled panes as `layer: "float"`, back to
    /// front by `z`. Without it no float is sent (they wait tucked), and a layout without floats
    /// is sent exactly as before.
    static func workspace(_ layout: WorkspaceLayout, frames: WorkspaceFrames, host: String, focus: String?,
                          generation: (WorkspaceSource) -> UInt64?,
                          displayID: (WorkspaceSource) -> UInt32? = { _ in nil },
                          viewEpoch: (String) -> Int? = { _ in nil },
                          floats: Bool = false, lifted: Set<String> = [],
                          watch: [WorkspaceHeldWindow] = []) -> [String: Any] {
        var tiles: [[String: Any]] = []
        let floating = floats ? layout.floatIDs.filter { frames.tiles[$0] != nil } : []
        for id in layout.orderedTileIDs + floating {
            guard let tile = layout.tiles[id], let source = tile.source, source.host == host,
                  let r = frames.tiles[id], r.width > 0, r.height > 0 else { continue }
            var t: [String: Any] = ["id": id, "host": host, "x": r.x, "y": r.y, "w": r.width, "h": r.height,
                                    "follow": source.follow.rawValue,
                                    "rotation": tile.rotation.rawValue, "fit": tile.fit.rawValue]
            if source.isDisplay {
                // A whole Mac display (Full Desktop in a pane), by its real display id.
                guard let d = displayID(source) else { continue }
                t["display"] = Int(d)
            } else {
                t["window"] = Int(source.windowID)
                if let gen = generation(source) { t["gen"] = Int(gen) }
            }
            if let z = tile.zoom { t["zoom"] = z.wire }
            if let e = viewEpoch(id) { t["view"] = e }
            if let z = floating.firstIndex(of: id) {
                t["layer"] = "float"; t["z"] = z
                // Drawn here under the finger for now: the Mac leaves it out (`floatLift`).
                if lifted.contains(id) { t["lift"] = true }
            }
            tiles.append(t)
        }
        var m: [String: Any] = ["type": WireMessage.workspaceRequest, "tiles": tiles]
        if let focus { m["focus"] = focus }
        // Every window held here, shown or not (other tabs, tucked floats): the Mac says which closed.
        if !watch.isEmpty { m["watch"] = watch.prefix(128).map { ["window": Int($0.window), "gen": Int($0.generation)] } }
        return m
    }

    /// Start a pane's capture again now (it stalled or failed).
    static func retry(_ tile: String) -> [String: Any] { ["type": WireMessage.workspaceRetry, "tile": tile] }

    /// A pane's whole source as a still (`max` pixels wide at most).
    static func backdrop(_ tile: String, max: Int, req: Int) -> [String: Any] {
        ["type": WireMessage.workspaceBackdropRequest, "tile": tile, "max": max, "req": req]
    }

    /// Brings the real Mac window forward (needs control): the only way to show a window
    /// Stage Manager keeps in its side strip.
    /// Owner-confirmed on the device, control only: turn Stage Manager off for Window mode
    /// (the Mac turns it back on when Window mode ends), or undo that.
    /// Exit Mission Control: the Mac checks it is open, then presses Escape (control only).
    static var exitMissionControl: [String: Any] {
        ["type": WireMessage.windowAction, "action": "missionControl", "exit": true]
    }

    static func stageManager(on: Bool) -> [String: Any] {
        ["type": WireMessage.windowAction, "action": "stageManager", "on": on]
    }

    static func activateWindow(_ id: UInt32, generation: UInt64) -> [String: Any] {
        ["type": WireMessage.windowAction, "action": "activate", "window": Int(id), "gen": Int(generation)]
    }

    /// `raise` false: the tile was chosen by arranging this device's view, so the Mac keeps its
    /// window where it is until a key or a press for it needs it in front (older Macs ignore it).
    static func focus(_ tile: String?, raise: Bool = true) -> [String: Any] {
        var m: [String: Any] = ["type": WireMessage.workspaceFocus]
        if let tile { m["tile"] = tile }
        if !raise { m["raise"] = false }
        return m
    }

    static func launch(_ bundle: String) -> [String: Any] { ["type": WireMessage.windowAction, "action": "launch", "bundle": bundle] }

    /// Close Window from Stage Peek: presses that window's close button (any mode, needs control).
    static func windowClose(_ id: UInt32, generation: UInt64, req: Int) -> [String: Any] {
        ["type": WireMessage.windowClose, "window": Int(id), "gen": Int(generation), "req": req]
    }

    /// Closes the real Mac window: only from its own explicit confirm.
    static func closeWindow(_ id: UInt32, generation: UInt64) -> [String: Any] {
        ["type": WireMessage.windowAction, "action": "close", "window": Int(id), "gen": Int(generation)]
    }
}

// MARK: - Images (bounded before decoding)

enum WorkspaceImageDecoder {
    /// A small file can declare a huge image: read the header first, refuse
    /// anything over 16 MP, and decode a thumbnail no larger than `maxSide`.
    static func image(_ data: Data, maxSide: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0, Int64(w) * Int64(h) <= 4096 * 4096 else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceThumbnailMaxPixelSize: maxSide,
                                        kCGImageSourceCreateThumbnailWithTransform: true]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

// MARK: - The model the views draw

enum WorkspaceRailEdge: String, CaseIterable, Sendable { case top, bottom, left, right }

/// Something being dragged over the panes.
struct WorkspaceDrag: Equatable {
    enum Item: Equatable {
        /// A Mac window from Stage Peek.
        case window(CatalogWindowItem)
        /// A pane's label (all its windows), or one of its tabs.
        case pane(String, tab: Int?)
        /// An app from Stage Peek's carousel, search or Launchpad: its window when it has one;
        /// several → the person picks; none → offered to open it (never just because a drag began).
        case app(MacAppItem)
        /// A floating pane, circled (or switched) into Pane placement: it docks where it's dropped.
        case float(String)
    }
    var item: Item
    /// Global (screen) coordinates.
    var location: CGPoint
    /// Where a drop goes: into the panes (tab, split, swap) or floating at the finger. Switched
    /// by circling while holding (`WorkspaceCircleGesture`), or the Float zone; Cancel keeps everything.
    var placement: WorkspacePlacement = .pane

    /// A float being docked (circled into a card while it moved).
    var isFloat: Bool { if case .float = item { return true } else { return false } }
}

/// The two ways a dragged window lands in one workspace (never a global mode).
enum WorkspacePlacement: String, CaseIterable, Sendable {
    /// Into the panes: the pane, tab and split targets.
    case pane
    /// Floating, where it is dropped.
    case float
}

/// What tucked floats' edge handles give way to, in global (window) coordinates. Who wins,
/// highest first: the system's edge bands (the top and bottom of `screen`), then `controls`,
/// then the handles (`WorkspaceFloatGeometry.tuckHandles`).
struct WorkspaceEdgeReservations: Equatable {
    /// The screen the receiver fills; zero: unknown (only the safe area is kept clear).
    var screen: CGRect = .zero
    /// The fixed controls (the control tray, the function tray, the shortcut column and other
    /// trays), folds, and Stage Peek's own edge handle.
    var controls: [CGRect] = []
}

@MainActor
final class WorkspaceModel: ObservableObject {
    @Published private(set) var available = false
    @Published private(set) var windowMode = false
    @Published private(set) var layout = WorkspaceLayout()
    @Published private(set) var stacked: [String] = []
    @Published private(set) var capacity = 1
    @Published private(set) var remote: WorkspaceStateMessage? {
        // Folded Mission Control notices last only while it stays open.
        didSet { if remote?.missionControlOpen != true, !missionControlFolded.isEmpty { missionControlFolded = [] } }
    }
    /// Shown for a few seconds after each connection: whether the Mac's Privacy Shield is on.
    @Published private(set) var privacyShieldNotice: Bool?
    private var privacyNoticeClear: DispatchWorkItem?
    @Published private(set) var catalog: WorkspaceCatalogMessage?
    /// The Mac's screen is locked (or switched to another user): nothing of it is kept or shown
    /// here until it unlocks (`macLockState`). The layout itself is kept.
    @Published private(set) var macLocked = false
    @Published private(set) var missing: Set<String> = []
    @Published var overviewOpen = false
    @Published private(set) var replacingTile: String?
    @Published var railExpanded = false { didSet { if railExpanded { startRefreshing() } } }
    /// Stage Peek is warming (finger holding the edge) or open: keeps the
    /// catalog and thumbnails fresh. Read-only requests; never a layout,
    /// capture or focus change.
    @Published var stagePeekOpen = false { didSet { if stagePeekOpen, !oldValue { startRefreshing() } } }
    @Published var railEdge: WorkspaceRailEdge { didSet { defaults.set(railEdge.rawValue, forKey: Self.railKey) } }
    @Published var arranging = false
    @Published private(set) var hovered: String?
    @Published private(set) var thumbnails: [UInt32: CGImage] = [:]
    /// When each tucked float's window was last asked for a still (`requestTuckedStills`).
    private var tuckedStillAskedAt: [UInt32: Date] = [:]
    /// Stills the Mac could only answer with an older capture (minimized now, say).
    @Published private(set) var staleThumbnails: Set<UInt32> = []
    /// No still possible yet (minimized with nothing cached, or capture failed): show the app icon.
    @Published private(set) var unavailableThumbnails: Set<UInt32> = []
    @Published private(set) var displayThumbnails: [UInt32: CGImage] = [:]
    @Published private(set) var icons: [String: CGImage] = [:]
    /// Which icons to ask the Mac for, and when to ask again (once per connection, with backoff).
    private var iconPlanner = AppIconRequestPlanner()
    /// Icons in the order they came, for making room past `AppIconRequestPlanner.keep`.
    private var iconArrival: [String] = []
    private var iconRetry: DispatchWorkItem?
    /// Admitted to this Mac: icon asks before that would be dropped by the Mac.
    private var iconsConnected = false
    /// Every launchable Mac app (Finder first), from `appCatalog`.
    @Published private(set) var apps: [MacAppItem] = []
    /// When to ask for `apps` again: on opening a browser, not on every refresh.
    private var inventory = AppInventoryRequestPlanner()
    /// Apps opened from this device that haven't shown a window yet.
    @Published private(set) var launching: Set<String> = []
    @Published private(set) var launchFailed: String?
    /// The Mac can close a listed window from Stage Peek (`windowClose`).
    @Published private(set) var canCloseWindows = false
    /// The Mac draws floating panes (`windowFloat`). Without it floats are kept, tucked, unsent.
    @Published private(set) var canFloat = false
    /// The Mac leaves out a float sent with `lift` (`floatLift`), so this device can draw it under
    /// the finger while it moves or resizes and it's never on screen twice.
    @Published private(set) var canLiftFloats = false
    /// Floats this device draws itself right now (a finger moves or resizes them): sent with `lift`.
    @Published private(set) var liftedFloats: Set<String> = []
    /// Floats just let go of: still drawn here until the Mac's picture shows them where they
    /// landed (its view echo, plus a moment for that frame to reach the screen), at most
    /// `landingHold` seconds.
    @Published private(set) var landingFloats: [String: Date] = [:]
    static let landingHold: TimeInterval = 1.0
    /// After the Mac says it composed the landed float: about the time its frame takes to arrive.
    static let landingSettle: TimeInterval = 0.1
    /// Floats a finger has started to move or resize, waiting for a still to be lifted with.
    private var liftWanted: Set<String> = []
    /// This receiver has floating-pane chrome (iPhone and iPad). The Mac Receiver doesn't yet:
    /// it says `ws` 1 and never floats a pane.
    nonisolated static let floatsDrawnHere: Bool = {
        #if os(iOS)
        return true
        #else
        return false
        #endif
    }()
    /// Per model, so tests on the Mac can exercise floats.
    var floatsDrawnHere = WorkspaceModel.floatsDrawnHere
    /// The Mac offers Lock This Mac (any mode); the last request's outcome.
    @Published private(set) var canLockMac = false
    @Published private(set) var lockMacStatus: LockMacStatus?
    enum LockMacStatus: Equatable { case locking, done(LockMacResult) }
    private var lockRequest = 0
    /// Windows asked to close that the Mac hasn't answered for yet.
    @Published private(set) var closingWindows: Set<UInt32> = []
    /// What happened to the last Close Window (shown briefly over Stage Peek).
    @Published var closeNotice: WindowCloseNotice?
    private var closeRequest = 0
    /// The Mac offers Fill Window on Mac / Restore Previous Size on Mac (`windowFrame`).
    @Published private(set) var canResizeWindowsOnMac = false
    /// What happened to the last Fill/Restore on Mac (shown on its pane for 8 s).
    @Published private(set) var windowFrameNotice: WindowFrameNotice?
    /// Panes whose Fill/Restore on Mac hasn't been answered yet.
    @Published private(set) var windowFramePending: Set<String> = []
    private var windowFrameRequest = 0
    private var windowFrameAsked: [Int: (tile: String, windowID: UInt32, op: WindowFrameOp)] = [:]
    private var windowFrameNoticeClear: DispatchWorkItem?
    /// Launchpad (full app grid) is open: keeps catalogs fresh like Stage Peek.
    @Published var launchpadOpen = false { didSet { if launchpadOpen, !oldValue { startRefreshing() } } }
    /// Cards on screen now, most important first: their stills are asked for first.
    var thumbnailPriority: [UInt32] = [] { didSet { if thumbnailPriority != oldValue { requestThumbnails() } } }
    private var planner = ThumbnailRequestPlanner()
    private var appRevision: Int?
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    /// Layouts saved by name for this Mac, newest first.
    @Published private(set) var savedLayouts: [WorkspaceSavedLayout] = []
    /// A window (from Stage Peek) or a pane label being dragged over the panes.
    @Published private(set) var drag: WorkspaceDrag?
    /// "Fullscreen on This Device": this pane fills the screen locally. The saved arrangement,
    /// dividers and every pane's view are kept and come back unchanged on exit. Not a Mac fullscreen.
    @Published private(set) var localFullscreen: String?
    /// Bumped by the video surface on any touch: reveals the fullscreen strip without taking the touch.
    @Published private(set) var touchPulse = 0
    func noteSurfaceTouch() { if localFullscreen != nil { touchPulse &+= 1 } }
    /// The picture's frame in global (screen) coordinates, reported by the pane chrome, so drags
    /// that start in Stage Peek can find the panes under the finger.
    var pictureGlobal: CGRect = .zero
    /// Mirror/Extend: the desktop picture's global frame (reported by Stage Peek's overlay), so a
    /// window dragged onto the desktop can land beside it.
    var desktopPictureGlobal: CGRect = .zero
    /// Each pane's tab labels on screen (global), by tab index: where a dragged tab is put back.
    var tabLabelFrames: [String: [Int: CGRect]] = [:]
    /// The "Cancel" drop zone shown during a drag (global). Dropping there changes nothing.
    var cancelZoneGlobal: CGRect = .zero
    /// The "Remove from Layout" drop zone (global), shown only while `canDropToRemove`.
    var removeZoneGlobal: CGRect = .zero
    /// While dragging in Pane placement: the Float zone beside Cancel (global). Releasing there
    /// floats the window instead (the way that needs no circling).
    var floatZoneGlobal: CGRect = .zero
    /// Where tucked floats' edge handles take touches (global): the dividers' holds above them
    /// leave them free. Stage Peek doesn't dodge them any more: they keep clear of it
    /// (`edgeReservationsGlobal`).
    @Published var floatHandlesGlobal: [CGRect] = []
    /// What tucked floats' edge handles keep clear of (global), set by the app next to where Stage
    /// Peek learns what to avoid: the screen (its top and bottom belong to the system's own edge
    /// gestures), then the fixed controls and Stage Peek's handle. Handles give way to all of it.
    @Published var edgeReservationsGlobal = WorkspaceEdgeReservations()
    /// The first-use tip about circling while dragging (shown once, ever, on this device).
    @Published private(set) var placementTipVisible = false
    /// How far circling while dragging has got toward switching Pane / Floating (0...1), for the
    /// ring at the finger. 0 while it can't switch.
    @Published private(set) var placementSwitchProgress = 0.0

    /// Sends one workspace message on the current, admitted connection.
    var send: ([String: Any]) -> Bool = { _ in false }
    /// Asks the Mac for Window mode (displayModeRequest "window").
    var requestWindowMode: () -> Void = {}
    /// Whether this session may change the Mac (launch apps, close windows).
    var inputAllowed: () -> Bool = { false }
    /// Whether this device shows the Mac in Mirror now (outside Window view), as the Mac confirmed.
    var mirroring: () -> Bool = { false }
    /// The Mac's manual Mirror display choice (nil: Automatic), so a float opened over the
    /// mirrored desktop keeps that same desktop behind it.
    var mirrorChoice: () -> MirrorDisplayEntry? = { nil }
    /// Whether this device extends the Mac now (outside Window view), as the Mac confirmed.
    var extending: () -> Bool = { false }
    /// Seconds, for waits measured here (tests step it). Not `systemUptime`: a required-reason API
    /// the iOS privacy manifest doesn't declare (the other planners here use the same clock).
    var clock: () -> TimeInterval = { Date().timeIntervalSinceReferenceDate }

    /// A step that would start Window view from Extend, waiting for the person to confirm it.
    struct LeaveExtendRequest: Identifiable {
        let id = UUID()
        let perform: () -> Void
    }
    /// Leaving Extend removes this device's extended display, and macOS moves the windows on it to
    /// the Mac's other displays, so a tap, a pick or a drop never does it by itself: it waits here
    /// until the person confirms (`confirmLeavingExtend`). Mirror and Window view never wait.
    @Published private(set) var leaveExtendRequest: LeaveExtendRequest?
    private var leavingExtendConfirmed = false

    /// True when `step` has to wait for confirmation (it is kept until then); false: go ahead.
    private func holdForLeavingExtend(_ step: @escaping () -> Void) -> Bool {
        guard !windowMode, extending(), !leavingExtendConfirmed else { return false }
        leaveExtendRequest = LeaveExtendRequest(perform: step)
        return true
    }

    /// The person chose to leave Extend for Window view: the step they took runs now.
    func confirmLeavingExtend() {
        guard let request = leaveExtendRequest else { return }
        leaveExtendRequest = nil
        leavingExtendConfirmed = true
        defer { leavingExtendConfirmed = false }
        request.perform()
    }

    /// Stay in Extend: nothing changes.
    func cancelLeavingExtend() { leaveExtendRequest = nil }

    private let defaults: UserDefaults
    private var saved = WorkspaceLayout()
    private var host: String?
    private var size = WorkspaceSize(width: 400, height: 800)
    private var hinge: WorkspaceHinge?
    private var history = WorkspaceHistory()
    private var nextTile = 1
    private var awaitingCatalogToSend = false
    private var sendTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var thumbAge: [UInt32: Date] = [:]
    /// Window generations from the latest catalog, by host and window id. The layout
    /// keeps host + id so it survives sessions; the Mac still rejects a reused id.
    private var generations: [String: UInt64] = [:]
    private func generation(_ s: WorkspaceSource) -> UInt64? { generations["\(s.host)#\(s.windowID)"] }
    private func setGeneration(_ s: WorkspaceSource, _ g: UInt64) { generations["\(s.host)#\(s.windowID)"] = g }

    /// Windows the Mac proved closed on this connection (`gone`), by `tabKey`: the generation that
    /// closed. A window held under another generation (its id reused) is never touched.
    private var closedOnMac: [String: UInt64] = [:]
    /// Windows listed on this connection (`tabKey`): only those are watched for closing, so a
    /// reconnect never acts on what an earlier connection knew.
    private var listedThisConnection: Set<String> = []
    private static let railKey = "workspace.railEdge"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        railEdge = defaults.string(forKey: Self.railKey).flatMap(WorkspaceRailEdge.init(rawValue:)) ?? .top
        files = RemoteFilesModel(defaults: defaults)
        menus = AppMenuModel(defaults: defaults)
        clipboard = ClipboardModel(defaults: defaults)
        clipboard.send = { [weak self] m in self?.send(m) ?? false }
        files.send = { [weak self] m in self?.send(m) ?? false }
        files.inputAllowed = { [weak self] in self?.inputAllowed() ?? false }
        files.macKey = { [weak self] in self?.host }
        menus.send = { [weak self] m in self?.send(m) ?? false }
    }

    /// The focused pane's app menus (a bar under its label).
    let menus: AppMenuModel

    /// Remote Finder: the Mac's approved folders, browsed here (Finder in the carousel opens it).
    let files: RemoteFilesModel

    /// Unified Clipboard with the connected Mac (off until turned on here and allowed there).
    let clipboard: ClipboardModel

    var active: String? { remote?.active }
    /// The connected Mac's name as paired (never a name the network claims).
    var hostName: String {
        host.flatMap { id in TrustStore.receiverRole.pinnedPeers().first { $0.peerID == id }?.displayName } ?? "your Mac"
    }
    var frames: WorkspaceFrames { WorkspaceGeometry.frames(for: layout, in: size, hinge: hinge) }
    /// The workspace's size in points (what float sizes and flings are measured in).
    var space: WorkspaceSize { size }
    func tileState(_ id: String) -> RemoteTileItem? { remote?.tiles.first { $0.id == id } }

    // MARK: Events

    func apply(_ event: WorkspaceEvent) {
        switch event {
        case .connected(let peer):
            if peer != host { load(for: peer) }
            // A new connection: every app shown here gets its icon asked for again if it's missing
            // (this device may have restarted while the Mac kept its session).
            iconsConnected = true
            iconPlanner.reset()
            requestShownIcons()
        case .macLock(let notice):
            macLockChanged(locked: notice.isLocked)
        case .privacyShield(let on):
            privacyShieldNotice = on
            privacyNoticeClear?.cancel()
            let clear = DispatchWorkItem { [weak self] in self?.privacyShieldNotice = nil }
            privacyNoticeClear = clear
            DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: clear)
        case .features(let f):
            available = f.contains(WindowWorkspaceWire.welcomeFeature)
            files.setAvailable(f.contains(RemoteFilesWire.welcomeFeature))
            menus.setAvailable(f.contains(AppMenuWire.welcomeFeature))
            canCloseWindows = f.contains(WindowCloseWire.welcomeFeature)
            canResizeWindowsOnMac = f.contains(WindowFrameWire.welcomeFeature)
            canFloat = floatsDrawnHere && f.contains(WindowWorkspaceWire.floatFeature)
            canLiftFloats = canFloat && f.contains(WindowWorkspaceWire.floatLiftFeature)
            publish()
            canLockMac = f.contains(LockMacWire.welcomeFeature)
            clipboard.setAvailable(f.contains(ClipboardWire.welcomeFeature))
        case .files(let reply):
            files.apply(reply)
        case .clip(let m):
            clipboard.handle(m)
        case .menu(let reply):
            menus.apply(reply)
        case .menuResult(let ok, let error):
            menus.applyResult(ok: ok, error: error)
        case .view(let tiles):
            composedViewEpochs.merge(tiles) { old, new in max(old, new) }
            // A float let go of is drawn here until the Mac shows it where it landed.
            for id in landingFloats.keys where tiles[id] != nil && viewComposed(id) {
                let at = landingFloats[id]
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.landingSettle) { [weak self] in
                    if let self, self.landingFloats[id] == at { self.landingFloats[id] = nil }
                }
            }
        case .backdrop(let tile, let window, let data, let stale):
            guard layout.tiles[tile]?.source?.windowID == window || window == 0,
                  let image = WorkspaceImageDecoder.image(data, maxSide: 1600) else { return }
            if let asked = backdropAskedAt[tile] {
                Log.info("workspace: backdrop \(tile) \(image.width)x\(image.height) after \(Int(Date().timeIntervalSince(asked) * 1000)) ms\(zoomGesture?.tile == tile ? " (mid-gesture)" : "")")
            }
            backdrops[tile] = WorkspaceBackdrop(windowID: window, image: image, stale: stale)
            // A float picked up before its still arrived is lifted now.
            if floatGesture == tile, liftWanted.contains(tile) { liftFloat(tile) }
        case .mode(let window):
            windowMode = window
            leaveExtendRequest = nil   // the mode changed underneath: the question no longer applies
            if !window { remote = nil }
            if window { awaitingCatalogToSend = true; requestCatalog() }
        case .catalog(let c):
            onCatalog(c)
        case .state(let s):
            remote = s
            if let r = requestedFocus, s.active == r || layout.tiles[r] == nil { requestedFocus = nil }
            // A live pane gets its whole-source still before the first pinch, so zooming out or
            // panning never shows an empty area while the fingers move (bounded: once a second).
            for item in s.tiles where item.status == .live && backdrop(item.id) == nil && zoomGesture == nil {
                requestBackdrop(item.id)
            }
            // The Mac refused a tile because its window already shows in another one
            // (e.g. a layout saved before that rule): empty the tile instead of leaving
            // it labelled with a window it will never show.
            let duplicates = s.rejected.filter { $0.value == "duplicateWindow" }.map(\.key).filter { layout.tiles[$0]?.source != nil }
            if !duplicates.isEmpty {
                edit { l in duplicates.reduce(l) { $0.replacingSource(of: $1, with: nil) } }
            }
            if !s.gone.isEmpty { windowsClosedOnMac(s.gone) }
        case .thumbnail(let id, _, let data, let stale):
            let now = Date().timeIntervalSinceReferenceDate
            guard let data, let image = WorkspaceImageDecoder.image(data, maxSide: 560) else {
                planner.failed(id, now: now)
                if thumbnails[id] == nil { unavailableThumbnails.insert(id) }
                return
            }
            planner.received(id, now: now)
            thumbAge[id] = Date()
            thumbnails[id] = image
            unavailableThumbnails.remove(id)
            if stale { staleThumbnails.insert(id) } else { staleThumbnails.remove(id) }
            // Bounded: ~70 stills; the least recently refreshed that isn't on screen goes first.
            if thumbnails.count > 72, let oldest = thumbAge.filter({ !thumbnailPriority.contains($0.key) }).min(by: { $0.value < $1.value })?.key {
                thumbnails[oldest] = nil; thumbAge[oldest] = nil; planner.forget(oldest)
            }
        case .icon(let bundle, let data):
            guard let image = WorkspaceImageDecoder.image(data, maxSide: 96) else { return }
            iconPlanner.received(bundle)
            if icons[bundle] == nil, icons.count >= AppIconRequestPlanner.keep {
                // Full: the oldest not shown in a pane or float makes room (asked again when it's wanted).
                guard let old = AppIconRequestPlanner.evict(arrival: iconArrival, shown: Set(shownAppBundles)) else { return }
                icons[old] = nil
                iconArrival.removeAll { $0 == old }
            }
            icons[bundle] = image
            iconArrival.removeAll { $0 == bundle }
            iconArrival.append(bundle)
        case .displayThumbnail(let id, let data):
            guard let image = WorkspaceImageDecoder.image(data, maxSide: 560) else { return }
            displayThumbnails[id] = image
        case .appCatalog(let rev, let list):
            inventory.answered(now: clock())
            appRevision = rev
            if let list {
                apps = WorkspaceSearch.carouselOrder(list)
                if let c = catalog, !c.unavailable, let live = WorkspaceSearch.reconciled(apps, windows: c.windows, running: c.apps) { apps = live }
            }
            requestIcons()
        case .launchResult(let bundle, let ok):
            if !ok { launching.remove(bundle); launchFailed = bundle }
            if var o = appOpening, o.bundleID == bundle {
                let step = o.launchAnswered(ok: ok, now: clock())
                Log.info("pickerOpen: launch answered bundle=\(bundle) ok=\(ok)")
                appOpening = o
                performAppOpening(step)
            }
            requestCatalog()
        case .closeResult(let id, let result):
            finishClose(id, result: result)
        case .lockResult(let result):
            lockMacStatus = .done(result)
        case .frameResult(let reply):
            finishWindowFrame(reply)
        case .disconnected:
            sendTask?.cancel()
            leaveExtendRequest = nil
            windowMode = false; remote = nil; available = false; arranging = false; stagePeekOpen = false
            launchpadOpen = false; launching = []; planner.reset(); inventory.reset()
            if var o = appOpening {
                let step = o.disconnected()
                appOpening = o
                performAppOpening(step)
            }
            iconsConnected = false; iconPlanner.reset(); iconRetry?.cancel(); iconRetry = nil
            canCloseWindows = false; closingWindows = []; closeNotice = nil
            canFloat = false; floatGesture = nil
            canLiftFloats = false; liftedFloats = []; landingFloats = [:]; liftWanted = []
            canLockMac = false; lockMacStatus = nil
            canResizeWindowsOnMac = false; windowFramePending = []; windowFrameAsked = [:]
            windowFrameNoticeClear?.cancel(); windowFrameNotice = nil
            files.setAvailable(false)
            menus.setAvailable(false)
            clipboard.setAvailable(false)
            // A new session's frames carry no echo of this one's views; stills are re-asked.
            composedViewEpochs = [:]; viewEpochs = [:]; viewSignatures = [:]; backdrops = [:]; backdropAskedAt = [:]
            tuckedStillAskedAt = [:]
            zoomGesture = nil; zoomPreview = nil
            requestedFocus = nil; floatGestureStart = nil; drag = nil
            floatMove = nil; dockingFloat = nil
            closedOnMac = [:]; listedThisConnection = []   // a new connection proves closings again
            macLocked = false
        }
    }

    /// Locked: every picture and name of the Mac's windows this device holds goes (stills, the
    /// window list with its titles, backdrops), and anything in progress stops (a drag, Stage
    /// Peek, the picker, an app drop's question): it can't carry on into, or show behind, the
    /// locked screen. The layout is kept. Unlocked: the window list is asked for again, and
    /// stills come back as they're asked for.
    private func macLockChanged(locked: Bool) {
        guard locked != macLocked else { return }
        macLocked = locked
        guard locked else {
            if windowMode { requestCatalog() }
            return
        }
        cancelDrag()
        appDrop = nil
        stagePeekOpen = false; launchpadOpen = false
        if overviewOpen { closeOverview() }
        catalog = nil
        thumbnails = [:]; thumbAge = [:]; displayThumbnails = [:]
        staleThumbnails = []; unavailableThumbnails = []; planner.reset()
        backdrops = [:]; backdropAskedAt = [:]
        zoomGesture = nil; zoomPreview = nil
        publish()
    }

    private func load(for peer: String) {
        host = peer
        saved = (defaults.data(forKey: "workspace.layout.\(peer)").flatMap(WorkspaceLayoutRecord.decode) ?? WorkspaceLayout()).compacted()
        nextTile = (saved.tiles.keys.compactMap { Int($0.dropFirst()) }.max() ?? 0) + 1
        history = WorkspaceHistory()
        savedLayouts = defaults.data(forKey: "workspace.saved.\(peer)").map(WorkspaceSavedLayout.decodeList) ?? []
        thumbnails = [:]; icons = [:]; iconArrival = []; iconPlanner.reset(); thumbAge = [:]; displayThumbnails = [:]
        staleThumbnails = []; unavailableThumbnails = []; planner.reset()
        apps = []; appRevision = nil; launching = []; inventory.reset()
        dismissAppOpening()
        generations = [:]; closedOnMac = [:]; listedThisConnection = []
        publish()
    }

    private func onCatalog(_ c: WorkspaceCatalogMessage) {
        Log.info("workspace: catalog received decoded=\(c.windows.count) apps=\(c.apps.count) unavailable=\(c.unavailable) starting=\(c.starting)")
        if c.starting { return }
        catalog = c
        if !c.unavailable, let live = WorkspaceSearch.reconciled(apps, windows: c.windows, running: c.apps) { apps = live }
        let byID = Dictionary(c.windows.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        if let host { listedThisConnection.formUnion(c.windows.map { WorkspaceSource(host: host, windowID: $0.id).tabKey }) }
        var missing = Set<String>()
        var rebased = saved
        for (id, tile) in saved.tiles {
            guard let source = tile.source else { continue }
            if source.isDisplay {
                if !c.displays.contains(where: { WorkspaceSource.displayKey($0.id) == source.windowID }) { missing.insert(id) }
                continue
            }
            // A new Mac session: keep a saved tile only for the same window id of the same app.
            guard let w = byID[source.windowID], source.bundleID == nil || source.bundleID == w.bundleID else { missing.insert(id); continue }
            setGeneration(source, w.generation)
            if source.bundleID == nil { rebased = rebased.replacingSource(of: id, with: WorkspaceSource(host: source.host, windowID: source.windowID, bundleID: w.bundleID, follow: source.follow)) }
        }
        // The other tabs too: every window held here can be watched for closing.
        for tile in saved.tiles.values {
            for s in tile.windows where s != tile.source && !s.isDisplay {
                if let w = byID[s.windowID], s.bundleID == nil || s.bundleID == w.bundleID { setGeneration(s, w.generation) }
            }
        }
        if rebased != saved { saved = rebased; persist() }
        self.missing = missing
        // An app opened from here showed a window: it's no longer "opening".
        if !launching.isEmpty { launching.subtract(c.windows.map(\.bundleID)) }
        publish()
        if awaitingCatalogToSend { awaitingCatalogToSend = false; scheduleSend(immediately: true) }
        requestTuckedStills()
        requestThumbnails()
        advanceAppOpening()
    }

    private var browsing: Bool { overviewOpen || railExpanded || stagePeekOpen || launchpadOpen }

    /// Visible cards first; nothing asked twice within a few seconds; failures back off.
    private func requestThumbnails() {
        guard browsing, let c = catalog else { return }
        let ids = planner.plan(priority: thumbnailPriority, all: c.windows.map(\.id), now: Date().timeIntervalSinceReferenceDate)
        let wantedIcons = iconPlanner.plan(c.windows.map(\.bundleID) + c.apps.map(\.bundleID), has: { icons[$0] != nil },
                                           now: Date().timeIntervalSinceReferenceDate)
        let displays = (stagePeekOpen || overviewOpen) ? c.displays.map(\.id) : []
        guard !ids.isEmpty || !wantedIcons.isEmpty || !displays.isEmpty else { return }
        // Stage Peek's gallery shows large cards: sharp stills.
        if !send(WorkspaceRequests.thumbnails(ids, maxWidth: stagePeekOpen ? 560 : 320, icons: wantedIcons, displays: displays)) {
            iconPlanner.unsent(wantedIcons)
        }
        scheduleIconRetry()
    }

    /// Icons for the app carousel and Launchpad, a page at a time.
    func requestIcons(_ bundles: [String]? = nil) {
        askForIcons(bundles ?? apps.prefix(64).map(\.bundleID))
    }

    /// Every app shown in a pane, a tab or a float (its title's icon), Stage Peek or not.
    private var shownAppBundles: [String] {
        saved.tiles.keys.sorted().flatMap { saved.tiles[$0]?.windows ?? [] }
            .filter { !$0.isDisplay }.compactMap { $0.bundleID ?? windowItem($0)?.bundleID }
    }

    /// The icons of the apps in panes and floats, when missing: asked for on connecting and as
    /// the layout changes, not only while browsing.
    private func requestShownIcons() {
        guard iconsConnected, available else { return }
        askForIcons(shownAppBundles)
    }

    /// Asks for the missing icons among `bundles` (each once per connection, then with backoff).
    private func askForIcons(_ bundles: [String]) {
        let wanted = iconPlanner.plan(bundles, has: { icons[$0] != nil }, now: Date().timeIntervalSinceReferenceDate)
        guard !wanted.isEmpty else { return }
        if !send(WorkspaceRequests.thumbnails([], maxWidth: 320, icons: wanted)) { iconPlanner.unsent(wanted) }
        scheduleIconRetry()
    }

    /// One timer for every unanswered ask (the Mac may have dropped it, or not have the icon).
    private func scheduleIconRetry() {
        guard iconRetry == nil, let due = iconPlanner.nextRetry(has: { icons[$0] != nil }) else { return }
        let retry = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.iconRetry = nil
            self.askForIcons(self.iconPlanner.outstanding(has: { self.icons[$0] != nil }))
            self.scheduleIconRetry()   // asks not due yet
        }
        iconRetry = retry
        DispatchQueue.main.asyncAfter(deadline: .now() + max(due - Date().timeIntervalSinceReferenceDate, 0.5), execute: retry)
    }

    func requestApps() { _ = send(WorkspaceRequests.appCatalog(revision: apps.isEmpty ? nil : appRevision)) }

    /// Windows, running apps and displays. Apps to open come from `appCatalog` (`requestApps`):
    /// current Macs don't answer the listing's old `installed` flag.
    func requestCatalog() { _ = send(WorkspaceRequests.catalog(installed: false)) }

    // MARK: Space

    func updateSpace(_ newSize: WorkspaceSize, hinge newHinge: WorkspaceHinge?) {
        guard newSize != size || newHinge != hinge else { return }
        // Floats keep their size in points across a rotation or a window resize (their frames are
        // shares of the picture, which would stretch a phone's float into a strip). Not an edit:
        // no undo step. Not while a finger holds one.
        if newSize != size, size.width > 0, size.height > 0, newSize.width > 0, newSize.height > 0,
           !saved.floats.isEmpty, floatGesture == nil {
            var carried = saved
            for i in carried.floats.indices {
                var f = WorkspaceFloatGeometry.carried(carried.floats[i].frame, from: size, to: newSize)
                if let t = carried.floats[i].tuck {
                    // A tucked float waits flush with its edge, where its strip is.
                    f = WorkspaceFloatGeometry.tuckedFrame(f, edge: t.edge, along: t.offset, in: newSize)
                    carried.floats[i].tuck?.offset = WorkspaceFloatMotion.along(f, t.edge)
                }
                carried.floats[i].frame = f
            }
            saved = carried
        }
        size = newSize; hinge = newHinge
        publish(); scheduleSend()
    }

    private func publish() {
        let adapted = WorkspaceAdaptation.adapt(saved, to: size, hinge: hinge, active: remote?.active, floatsShown: canFloat || !windowMode)
        if let full = localFullscreen, adapted.visible.tiles[full] == nil { localFullscreen = nil }
        // Local fullscreen is presentation only: the saved tree is untouched.
        arranged = adapted.visible
        layout = localFullscreen.map { adapted.visible.maximizing($0) } ?? adapted.visible
        stacked = adapted.stacked
        capacity = WorkspaceGeometry.capacity(for: size, hinge: hinge)
        canUndo = history.canUndo
        canRedo = history.canRedo
        // A window just put in a pane or float (or a layout restored) shows its app's icon.
        requestShownIcons()
    }

    // MARK: Editing

    // MARK: Per-tile zoom

    private var zoomGesture: (tile: String, start: WorkspacePaneZoom?, rect: WorkspaceRect, drawn: WorkspaceRect?,
                              rotation: WorkspaceRotation, turnFrom: Double?)?

    /// A twist this large (degrees) starts turning the pane, so a pinch's natural wobble never
    /// turns it; the turn then follows the fingers from there, without a jump.
    static let turnDeadZone = 8.0

    /// The instant local zoom of the pane under the fingers (nil when there is none): the receiver
    /// moves the picture it already has (and the pane's whole-source still where that doesn't
    /// reach) until a Mac frame with the same view arrives. Kept after the gesture ends until then.
    private(set) var zoomPreview: WorkspaceZoomPreview?

    /// Each pane's view counter: bumped when its zoom, fit, rotation or frame changes, sent with
    /// the request, echoed by the Mac once a frame with that view went out (`workspaceView`).
    private var viewEpochs: [String: Int] = [:]
    private var viewSignatures: [String: String] = [:]
    private var nextViewEpoch = 1
    private(set) var composedViewEpochs: [String: Int] = [:]

    /// Each pane's whole source as a still (from the Mac), for zooming out and panning instantly.
    private(set) var backdrops: [String: WorkspaceBackdrop] = [:]
    private var backdropReq = 0
    private var backdropAskedAt: [String: Date] = [:]

    /// The instant zoom to draw now (after a gesture: until the Mac's frame with its view is out).
    func liveZoom() -> WorkspaceLiveZoom? {
        guard let p = zoomPreview else { return nil }
        return WorkspaceLiveZoom(preview: p, backdrop: backdrop(p.tile)?.image, composed: zoomGesture == nil && viewComposed(p.tile))
    }

    /// The pane's newest view has reached the screen (or there is nothing to wait for).
    func viewComposed(_ tile: String) -> Bool {
        guard let want = viewEpochs[tile] else { return true }
        return (composedViewEpochs[tile] ?? 0) >= want
    }

    /// Two-finger pinch/pan in Window mode. Points are normalized to the picture.
    /// Only the pane under the fingers where the gesture began changes. A pinch zooms it from
    /// 0.7x to 8x of its Fit (or Fill) size around the fingers; a two-finger pan moves a pane
    /// that is zoomed or filled (otherwise it stays a scroll on the Mac).
    /// `turn`: how far the fingers have twisted since they came down (degrees, clockwise); a pinch
    /// also turns the pane freely, any angle, once past `turnDeadZone`. `snapTurn`: a turn ending
    /// near a right angle lands on it (the Snap Rotation setting).
    @discardableResult
    func pinch(began: Bool, ended: Bool, isPinch: Bool, initial: WorkspacePoint, current: WorkspacePoint, scale: Double,
               turn: Double = 0, snapTurn: Bool = true) -> Bool {
        if began || zoomGesture == nil {
            let f = frames
            guard let id = f.hitTest(initial), let rect = f.tiles[id],
                  let tile = layout.tiles[id], tile.source != nil,
                  isPinch || tile.zoom != nil || effectiveFit(id) == .fill,
                  windowSize(tile) != nil else { zoomGesture = nil; zoomPreview = nil; return false }
            zoomGesture = (id, tile.zoom, rect, drawnSourceRect(tile, in: rect), tile.rotation, nil)
            zoomPreview = nil
            if active != id { focus(id, raise: false) }   // zooming is this device's view only
            requestBackdrop(id)
        }
        guard var g = zoomGesture, let tile = layout.tiles[g.tile], let source = windowSize(tile) else { return false }
        let pane = WorkspaceSize(width: g.rect.width * size.width, height: g.rect.height * size.height)
        func inPane(_ p: WorkspacePoint) -> WorkspacePoint {
            WorkspacePoint(x: (p.x - g.rect.x) / max(g.rect.width, 1e-6), y: (p.y - g.rect.y) / max(g.rect.height, 1e-6))
        }
        if isPinch, g.turnFrom == nil, turn.isFinite, abs(turn) >= Self.turnDeadZone {
            g.turnFrom = turn
            zoomGesture = g
        }
        let degrees = g.turnFrom.map { turn - $0 } ?? 0
        let view = WorkspaceZoom.turned(g.start, rotation: g.rotation, by: degrees, snap: snapTurn,
                                        tile: pane, source: source, fit: effectiveFit(g.tile),
                                        ratio: scale, from: inPane(initial), to: inPane(current))
        let next = saved.viewing(g.tile, rotation: view.rotation, zoom: view.zoom)
        if next != saved {
            saved = next
            publish(); scheduleThrottledSend()
        }
        if size.width > 0, size.height > 0, let now = next.tiles[g.tile] {
            let px = WorkspaceRect(x: g.rect.x * size.width, y: g.rect.y * size.height, width: pane.width, height: pane.height)
            let t0 = TileContentTransform(tile: px, source: source, rotation: g.rotation, fit: effectiveFit(g.tile), zoom: g.start ?? .identity)
            let t1 = TileContentTransform(tile: px, source: source, rotation: now.rotation, fit: effectiveFit(g.tile), zoom: now.zoom ?? .identity)
            zoomPreview = WorkspaceZoomPreview(tile: g.tile, pane: g.rect, start: t0, now: t1, canvas: size,
                                               sourceKey: tile.source?.windowID ?? 0)
        } else {
            zoomPreview = nil
        }
        if ended {
            zoomGesture = nil
            persist()
            // The final view goes now (its epoch is what the preview waits for), not on the next tick.
            sendNow()
            if view.zoom != nil || view.rotation != .none { requestBackdrop(g.tile, refresh: true) }   // fresh for the next gesture
        }
        return true
    }

    /// Where the pane draws its whole source (picture-normalized; larger than the pane when
    /// filled or zoomed in, smaller when zoomed out), as the Mac composes it.
    private func drawnSourceRect(_ tile: WorkspaceTile, in rect: WorkspaceRect) -> WorkspaceRect? {
        guard let w = windowSize(tile), size.width > 0, size.height > 0 else { return nil }
        let c = TileContentTransform(tile: WorkspaceRect(x: rect.x * size.width, y: rect.y * size.height,
                                                         width: rect.width * size.width, height: rect.height * size.height),
                                     source: w, rotation: tile.rotation, fit: tile.fit, zoom: tile.zoom ?? .identity).contentRect
        return WorkspaceRect(x: c.x / size.width, y: c.y / size.height, width: c.width / size.width, height: c.height / size.height)
    }

    private func windowSize(_ tile: WorkspaceTile) -> WorkspaceSize? {
        guard let source = tile.source, let w = windowItem(source), w.width > 0, w.height > 0 else { return nil }
        return WorkspaceSize(width: Double(w.width), height: Double(w.height))
    }

    /// Fit (default) or Fill, as drawn.
    func effectiveFit(_ id: String) -> WorkspaceFit {
        layout.tiles[id]?.fit == .fill ? .fill : .fit
    }

    /// Asks the Mac for the pane's whole source (bounded: once a second unless refreshing after a gesture).
    func requestBackdrop(_ id: String, refresh: Bool = false) {
        guard windowMode, let tile = layout.tiles[id], tile.source != nil else { return }
        let now = Date()
        if !refresh, let at = backdropAskedAt[id], now.timeIntervalSince(at) < 1 { return }
        backdropAskedAt[id] = now
        backdropReq = backdropReq >= 1_000_000 ? 1 : backdropReq + 1
        _ = send(WorkspaceRequests.backdrop(id, max: 1280, req: backdropReq))
    }

    /// The pane's whole-source still, when it is of the window the pane shows now.
    func backdrop(_ id: String) -> WorkspaceBackdrop? {
        guard let b = backdrops[id], b.windowID == layout.tiles[id]?.source?.windowID else { return nil }
        return b
    }

    /// Bumps a pane's view epoch when what the Mac must draw for it changed.
    private func noteViews(_ layout: WorkspaceLayout, frames: WorkspaceFrames) {
        for (id, tile) in layout.tiles {
            let r = frames.tiles[id]
            let z = tile.zoom ?? .identity
            // Lifted or not is part of the view: a float let go of waits for the frame that draws it again.
            let sig = "\(tile.source?.windowID ?? 0)|\(tile.fit.rawValue)|\(tile.rotation.rawValue)|\(z.scale)|\(z.centerX)|\(z.centerY)|\(r?.x ?? 0)|\(r?.y ?? 0)|\(r?.width ?? 0)|\(r?.height ?? 0)|\(liftedFloats.contains(id))"
            if viewSignatures[id] != sig {
                viewSignatures[id] = sig
                viewEpochs[id] = nextViewEpoch
                nextViewEpoch = nextViewEpoch >= Int(Int32.max) ? 1 : nextViewEpoch + 1
            }
        }
        for id in Array(viewEpochs.keys) where layout.tiles[id] == nil { viewEpochs[id] = nil; viewSignatures[id] = nil }
    }

    func resetZoom(_ id: String) { edit { $0.zooming(id, to: nil) } }

    /// Two-finger double-tap: this pane back to 1x Fit, centred, no rotation. Other panes untouched.
    func resetView(_ id: String) {
        edit { l in
            guard var tile = l.tiles[id] else { return l }
            tile.zoom = nil; tile.rotation = .none; tile.fit = .fit
            var copy = l
            copy.tiles[id] = tile
            return copy
        }
    }

    /// Two-finger double-tap: the pane under the fingers back to its default view.
    func resetView(at p: WorkspacePoint) {
        guard let id = frames.hitTest(p), layout.tiles[id]?.source != nil else { return }
        resetView(id)
    }

    /// A pane whose capture failed (or stalled): ask the Mac to start it again now.
    func retryTile(_ id: String) { _ = send(WorkspaceRequests.retry(id)) }

    /// Turn Stage Manager off on the Mac while Window mode is used (confirmed here; control).
    func turnOffStageManager() {
        guard inputAllowed() else { return }
        _ = send(WorkspaceRequests.stageManager(on: false))
    }

    /// Mission Control is open on the Mac (Window mode).
    var missionControlOpen: Bool { remote?.missionControlOpen == true }

    /// Mission Control holds this pane's or float's picture: a window (never a display: Full
    /// Desktop keeps showing the Mac's screen, Mission Control and all) that the Mac reports
    /// paused, waiting or retrying while it is open. Only these show its notice.
    func missionControlPaused(_ id: String) -> Bool {
        guard missionControlOpen, let source = layout.tiles[id]?.source, !source.isDisplay,
              let status = tileState(id)?.status else { return false }
        return [.paused, .waiting, .retrying].contains(status)
    }

    /// A paused tile's notice: in full, or folded by its × to a small status that brings it back.
    enum MissionControlNotice: Equatable, Sendable { case full, folded }

    func missionControlNotice(_ id: String) -> MissionControlNotice? {
        guard missionControlPaused(id) else { return nil }
        return missionControlFolded.contains(id) ? .folded : .full
    }

    /// Notices folded by their ×, until Mission Control closes (see `remote`).
    @Published private(set) var missionControlFolded: Set<String> = []

    /// The notice's ×: folds it on this device only. Nothing is sent; Mission Control stays open.
    func foldMissionControlNotice(_ id: String) {
        if missionControlPaused(id) { missionControlFolded.insert(id) }
    }

    /// The folded status tapped: the notice again.
    func unfoldMissionControlNotice(_ id: String) { missionControlFolded.remove(id) }

    /// Where a float's notice goes (screen points): centred on the float's visible part, about the
    /// notice's size (compact; folded, just the status). nil when a float in front covers that spot:
    /// it hides the notice as it hides the window.
    nonisolated static func missionControlNoticeSpot(on float: CGRect, folded: Bool, within bounds: CGRect,
                                                     inFront: [CGRect]) -> CGRect? {
        let seen = float.intersection(bounds)
        let visible = seen.isNull || seen.isEmpty ? float : seen
        let size = folded ? CGSize(width: min(float.width, 190), height: 30)
                          : CGSize(width: max(min(float.width - 12, 300), 140), height: 96)
        let spot = CGRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2, width: size.width, height: size.height)
        return inFront.contains { $0.intersects(spot) } ? nil : spot
    }

    /// Exit Mission Control on the Mac (needs the Mac's grant; the Mac re-checks before Escape).
    func exitMissionControl() {
        guard canControlMac, missionControlOpen else { return }
        _ = send(WorkspaceRequests.exitMissionControl)
    }

    /// What a paused tile's notice (and its pane's menu and accessibility action) offers while
    /// Mission Control is open on the Mac (nil when it isn't).
    enum MissionControlAction: Equatable, Sendable {
        /// This device has control: Exit Mission Control (the Mac re-checks before it presses Escape).
        case exit
        /// No control yet: the normal Request Control flow, then Exit.
        case requestControl
        /// Asked; the Mac's owner hasn't answered.
        case awaitingApproval
        /// The Mac takes no control requests from this device: say how to close it there.
        case closeOnMac
    }

    var missionControlAction: MissionControlAction? {
        guard missionControlOpen else { return nil }
        if canControlMac { return .exit }
        switch controlState() {
        case .requesting: return .awaitingApproval
        case .requestsDisabled: return .closeOnMac
        case .off, .notAllowed, .allowed: return .requestControl
        }
    }

    /// The notice's button: Exit with control, else ask for control (never a blind Escape).
    func performMissionControlAction() {
        switch missionControlAction {
        case .exit?: exitMissionControl()
        case .requestControl?: requestControl()
        case .awaitingApproval?, .closeOnMac?, nil: break
        }
    }

    /// Turn Stage Manager on on the Mac (Settings; control).
    func turnOnStageManager() {
        guard inputAllowed() else { return }
        _ = send(WorkspaceRequests.stageManager(on: true))
    }

    /// Stage Manager on the Mac as Settings shows it: on, off, or nil when the Mac doesn't say
    /// (not in Window mode, or an older Mac).
    var stageManagerIsOn: Bool? {
        guard let r = remote else { return nil }
        return r.stageManagerOn ?? (r.stageManager ? true : nil)
    }

    /// Whether this device may switch Stage Manager now (it has control).
    /// The Mac's confirmed decision on control for this session (Request Control). `inputAllowed`
    /// only says the session is live: in View Only it's true too, and the Mac drops actions such
    /// as Stage Manager on/off (found 2026-10-30 21:3x: the button looked enabled and did nothing).
    /// Receivers without Request Control keep `.allowed`.
    var controlState: () -> SessionInputWireState = { .allowed }
    /// Asks the Mac for control: the same request as Settings ▸ Input.
    var requestControl: () -> Void = {}
    var canControlMac: Bool { inputAllowed() && controlState() == .allowed }

    /// A window macOS keeps paused (Stage Manager's strip): bring it forward on the Mac (control).
    /// Add to Current Stage: Stage Manager's own action on the strip item holding this pane's
    /// window (needs control; the Mac answers in its state).
    func addToStage(_ id: String) {
        guard let source = layout.tiles[id]?.source, !source.isDisplay, let gen = generation(source) else { return }
        _ = send(["type": WireMessage.windowAction, "action": "addToStage", "window": Int(source.windowID), "gen": Int(gen)])
    }

    /// What the Mac said about the last Add to Current Stage for this pane's window, if it failed.
    func stageAddProblem(_ id: String) -> String? {
        guard let source = layout.tiles[id]?.source, let add = remote?.stageAdd, add.window == source.windowID else { return nil }
        switch add.result {
        case "added": return nil
        case "accessibility": return String(localized: "The Mac can't do that: turn on MeowDisplay in System Settings ▸ Privacy & Security ▸ Accessibility on the Mac.")
        case "notInStrip": return String(localized: "That window isn't in Stage Manager's side strip any more.")
        case "ambiguous": return String(localized: "Stage Manager lists that window twice; add it on the Mac.")
        default: return String(localized: "macOS didn't add it to the stage. Try again, or add it on the Mac.")
        }
    }

    func showOnMac(_ id: String) {
        guard let source = layout.tiles[id]?.source, !source.isDisplay, let gen = generation(source) else { return }
        _ = send(WorkspaceRequests.activateWindow(source.windowID, generation: gen))
    }

    /// The first touch in a tile selects it, so typing and zoom go there (also in View Only).
    /// True when the touch chose another pane (selection only; nothing goes to the Mac).
    /// A float touched in its content comes to the front first (sent at once, so the Mac hits
    /// the same window), and that same touch goes on to it, as a click on a pane does.
    @discardableResult
    func selectTile(at p: WorkspacePoint) -> Bool {
        guard let id = frames.hitTest(p), layout.tiles[id]?.source != nil else { return false }
        if layout.isFloat(id) { raiseFloat(id) }
        guard active != id else { return false }
        focus(id)
        return true
    }

    /// The selected pane's frame (0–1 of the picture), for prompts shown inside it.
    var activePaneRect: WorkspaceRect? { active.flatMap { frames.tiles[$0] } }

    // MARK: Tabs and drops

    func switchTab(_ id: String, to index: Int) {
        edit { $0.switchingTab(of: id, to: index) }
        focus(id)
    }

    func removeTab(_ id: String, at index: Int) { edit { $0.removingTab(of: id, at: index) } }

    /// A window dropped from Stage Peek: replace a pane's window, add it as a tab, split a pane, or fill an empty slot.
    /// One window shows in one pane only: it leaves the pane (or tab) it was in.
    func drop(_ w: CatalogWindowItem, on target: WorkspaceWindowDrop) {
        guard let source = source(for: w) else { return }
        if holdForLeavingExtend({ [weak self] in self?.drop(w, on: target) }) { return }
        if !windowMode { requestWindowMode() }
        var focusTile: String?
        edit { l in
            let (next, focus) = dropping(source, on: target, in: l)
            focusTile = focus
            return next
        }
        if let focusTile { focus(focusTile) }
    }

    private func dropping(_ source: WorkspaceSource, on target: WorkspaceWindowDrop, in start: WorkspaceLayout) -> (WorkspaceLayout, String?) {
        var l = start
        if let holder = l.tile(holding: source.host, windowID: source.windowID) {
            if case .replace(let t, _) = target, t == holder { return (l, holder) }
            if case .tab(let t, _) = target, t == holder {
                if let i = l.tiles[holder]?.tabs.firstIndex(where: { $0.windowID == source.windowID }) { l = l.switchingTab(of: holder, to: i) }
                return (l, holder)
            }
            l = Self.detach(source, from: holder, in: l)
        }
        switch target {
        case .replace(let t, _):
            return (l.replacingSource(of: t, with: source), t)
        case .tab(let t, _):
            return (l.addingTab(source, to: t), t)
        case .split(let index, let edge, _):
            let id = "w\(nextTile)"; nextTile += 1
            if l.paneCount < capacity { return (l.insertingSplit(WorkspaceTile(id: id, source: source), at: index, edge: edge), id) }
            let holder = WorkspaceLayout.slotID(l.root, at: index).flatMap { $0 }
            return (holder.map { l.addingTab(source, to: $0) } ?? l, holder)
        case .emptySlot(let index, _):
            let id = "w\(nextTile)"; nextTile += 1
            return (l.filling(slot: index, with: WorkspaceTile(id: id, source: source)), id)
        }
    }

    /// The pane source for a catalog window (or a display's pseudo-window), remembering its generation.
    private func source(for w: CatalogWindowItem) -> WorkspaceSource? {
        guard let host else { return nil }
        let display = WorkspaceSource.isDisplayKey(w.id)
        let source = WorkspaceSource(host: host, windowID: w.id, bundleID: display ? nil : w.bundleID)
        if !display { setGeneration(source, w.generation) }
        return source
    }

    // MARK: Displays as pane sources (Full Desktop in a tile)

    /// A Mac display as a pane source: a pseudo-window Stage Peek, drops and pickers can use.
    func displayWindow(_ d: CatalogDisplayItem) -> CatalogWindowItem {
        CatalogWindowItem(id: WorkspaceSource.displayKey(d.id), generation: 0, bundleID: "", app: String(localized: "Desktop"),
                          title: d.isMain ? String(localized: "Full Desktop") : d.name,
                          width: d.width, height: d.height, minimized: false, active: false)
    }

    /// The display a display source shows (nil when it isn't one, or the display is gone).
    func display(for source: WorkspaceSource) -> CatalogDisplayItem? {
        guard source.isDisplay else { return nil }
        return catalog?.displays.first { WorkspaceSource.displayKey($0.id) == source.windowID }
    }

    /// The Mac's main real display: what Mirror shows as "the desktop".
    var mainDisplay: CatalogDisplayItem? {
        let all = catalog?.displays ?? []
        return all.first { $0.isMain && !$0.isVirtual } ?? all.first { !$0.isVirtual } ?? all.first
    }

    /// A card's picture: the window's still, or the display's.
    func still(for w: CatalogWindowItem) -> CGImage? {
        guard WorkspaceSource.isDisplayKey(w.id) else { return thumbnails[w.id] }
        return catalog?.displays.first { WorkspaceSource.displayKey($0.id) == w.id }.flatMap { displayThumbnails[$0.id] }
    }

    /// The catalog entry a pane source shows (a display's pseudo-window for displays).
    func windowItem(_ source: WorkspaceSource) -> CatalogWindowItem? {
        if source.isDisplay { return display(for: source).map(displayWindow) }
        return catalog?.windows.first { $0.id == source.windowID }
    }

    /// The desktop the picture shows outside Window view: in Mirror, the Mac's manual Mirror
    /// choice when exactly one listed display matches it; otherwise the main display.
    var desktopDisplay: CatalogDisplayItem? {
        if mirroring(), let d = Self.mirroredDisplay(in: catalog?.displays ?? [], choice: mirrorChoice()) { return d }
        return mainDisplay
    }

    /// The listed display a manual Mirror choice names (the two lists share names and point
    /// sizes, not ids). Nil for Automatic, or when no single display matches.
    nonisolated static func mirroredDisplay(in displays: [CatalogDisplayItem], choice: MirrorDisplayEntry?) -> CatalogDisplayItem? {
        guard let choice else { return nil }
        let matches = displays.filter { $0.name == choice.name && $0.width == choice.logicalWidth && $0.height == choice.logicalHeight }
        if matches.count == 1 { return matches[0] }
        let main = matches.filter { $0.isMain == choice.isMain }
        return main.count == 1 ? main[0] : nil
    }

    /// Mirror/Extend: the picture is one pane showing the desktop, so a window dragged onto it
    /// replaces it, joins it as a tab, or splits it (Window mode then starts with both).
    private func desktopLayout() -> WorkspaceLayout? {
        guard let host, let d = desktopDisplay else { return nil }
        let tile = WorkspaceTile(id: "w\(nextTile)", source: WorkspaceSource(host: host, windowID: WorkspaceSource.displayKey(d.id)))
        return WorkspaceLayout(preset: .single, tiles: [tile])
    }

    /// A pane's label dragged elsewhere: onto another pane's labels = merge as tabs, onto an
    /// edge = move the pane there, onto a pane's middle = swap. `tab` moves just that tab.
    func dropTile(_ id: String, tab: Int? = nil, on target: WorkspaceWindowDrop) {
        guard let moving = layout.tiles[id] else { return }
        let windows = tab.map { i in moving.tabs.indices.contains(i) ? [moving.tabs[i]] : [] } ?? moving.windows
        guard !windows.isEmpty else { return }
        edit { l in
            var l = l
            switch target {
            case .tab(let t, _) where t != id:
                for s in windows { l = Self.detach(s, from: id, in: l); l = l.addingTab(s, to: t) }
                return l
            case .replace(let t, _) where t != id:
                if tab != nil, let s = windows.first {
                    l = Self.detach(s, from: id, in: l)
                    return l.addingTab(s, to: t)
                }
                return l.swapping(id, t)
            case .split(let index, let edge, let preview):
                if tab != nil, let s = windows.first, l.paneCount < capacity {
                    l = Self.detach(s, from: id, in: l)
                    let newID = "w\(nextTile)"; nextTile += 1
                    return l.insertingSplit(WorkspaceTile(id: newID, source: s), at: index, edge: edge)
                }
                return l.materializing(hinge: hinge).moving(id, to: .split(index: index, edge: edge, preview: preview))
            case .emptySlot(let index, let preview):
                return l.materializing(hinge: hinge).moving(id, to: .slot(index: index, preview: preview))
            default:
                return l
            }
        }
    }

    /// Takes a window out of a pane (a tab leaves; a single-window pane is removed).
    private static func detach(_ s: WorkspaceSource, from id: String, in l: WorkspaceLayout) -> WorkspaceLayout {
        guard let tile = l.tiles[id] else { return l }
        if let i = tile.tabs.firstIndex(where: { $0.host == s.host && $0.windowID == s.windowID }) { return l.removingTab(of: id, at: i) }
        return tile.source?.windowID == s.windowID ? l.removing(id) : l
    }

    /// Where a dragged window or label would land (normalized picture point). Over a floating
    /// pane: that float (replace it, or swap with a dragged pane); a float being docked never
    /// lands on a float. Splits count the tree's panes only.
    func windowDrop(at p: WorkspacePoint, labelHeight: Double) -> WorkspaceWindowDrop? {
        let f = frames
        // A float being docked is drawn only as its card: what's under its old frame counts.
        var docked: String?
        if case .float(let id)? = drag?.item { docked = id }
        if let hit = f.floats.last(where: { $0 != docked && f.tiles[$0]?.contains(p) == true }) {
            if docked != nil { return nil }
            if case .pane(let id, _)? = drag?.item, id == hit { return nil }
            return f.tiles[hit].map { .replace(tile: hit, preview: $0) }
        }
        let drop = WorkspaceGeometry.windowDrop(at: p, layout: layout, frames: f, size: size, labelHeight: labelHeight,
                                                canSplit: layout.paneCount < capacity)
        // Docking never replaces a window: the middle of a pane adds it as a tab there.
        if case .float? = drag?.item, case .replace(let t, let r)? = drop { return .tab(tile: t, preview: r) }
        return drop
    }

    /// The arrangement without local fullscreen: what edits apply to.
    private var arranged = WorkspaceLayout()

    private func edit(_ change: (WorkspaceLayout) -> WorkspaceLayout) {
        // Never an empty pane: a window that leaves a pane closes it up and the rest grow.
        let changed = change(arranged).compacted()
        guard changed != arranged else { return }
        // A float tucked here only because the Mac can't draw floats isn't saved tucked by an
        // unrelated change: it shows again on a Mac that can.
        var next = changed
        for i in next.floats.indices {
            let id = next.floats[i].tile
            if saved.float(id).map({ $0.tuck == nil }) == true, let shown = arranged.float(id)?.tuck, next.floats[i].tuck == shown {
                next.floats[i].tuck = nil
            }
        }
        history.record(saved)
        var updated = next
        for id in stacked { if let t = saved.tiles[id] { updated = updated.adding(t, landscape: size.width >= size.height) } }
        saved = stacked.isEmpty ? next : updated
        refreshMissing()
        persist(); publish(); scheduleSend()
    }

    func undo() {
        guard let previous = history.undo(current: saved) else { return }
        saved = previous
        // A window that closed on the Mac doesn't come back with an older layout.
        saved = removingClosed(from: saved)
        refreshMissing()
        persist(); publish(); scheduleSend()
    }

    func redo() {
        guard let next = history.redo(current: saved) else { return }
        saved = next
        saved = removingClosed(from: saved)
        refreshMissing()
        persist(); publish(); scheduleSend()
    }

    // MARK: Saved layouts

    /// Keeps this arrangement under `name` for this Mac (a saved layout with the same name is replaced).
    func saveLayout(named name: String) {
        guard let host else { return }
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        var n = savedLayouts.count + 1
        while trimmed.isEmpty, savedLayouts.contains(where: { $0.name == "Layout \(n)" }) { n += 1 }
        let title = trimmed.isEmpty ? "Layout \(n)" : trimmed
        var list = savedLayouts.filter { $0.name != title }
        list.insert(WorkspaceSavedLayout(id: UUID().uuidString, name: title, record: WorkspaceLayoutRecord(saved)), at: 0)
        savedLayouts = Array(list.prefix(WorkspaceSavedLayout.maximum))
        defaults.set(WorkspaceSavedLayout.encodeList(savedLayouts), forKey: "workspace.saved.\(host)")
    }

    /// Puts a saved layout back, on the windows open now (one undo step).
    func applySaved(_ id: String) {
        guard let s = savedLayouts.first(where: { $0.id == id }) else { return }
        var layout = s.record.layout
        if let c = catalog { layout = layout.rebinding(to: c.windows.map { ($0.id, $0.bundleID) }) }
        layout = layout.compacted()
        guard layout != saved else { return }
        history.record(saved)
        saved = layout
        nextTile = max(nextTile, (saved.tiles.keys.compactMap { Int($0.dropFirst()) }.max() ?? 0) + 1)
        refreshMissing()
        persist(); publish(); scheduleSend()
    }

    func deleteSavedLayout(_ id: String) {
        guard let host else { return }
        savedLayouts.removeAll { $0.id == id }
        defaults.set(WorkspaceSavedLayout.encodeList(savedLayouts), forKey: "workspace.saved.\(host)")
    }

    /// After an edit: a tile is missing only while its window is unlisted, so
    /// choosing another window for it (or removing it) clears the mark.
    private func refreshMissing() {
        guard let c = catalog else { return }
        missing = Set(saved.tiles.compactMap { id, tile in
            guard let source = tile.source else { return nil }
            if source.isDisplay { return c.displays.contains { WorkspaceSource.displayKey($0.id) == source.windowID } ? nil : id }
            let listed = c.windows.contains { $0.id == source.windowID && (source.bundleID == nil || source.bundleID == $0.bundleID) }
            return listed ? nil : id
        })
    }

    func apply(_ preset: WorkspacePreset) {
        edit { l in
            var ordered = l.orderedTileIDs.compactMap { l.tiles[$0] }
            // 2x2 or 3x3 with fewer windows showing: the Mac's other open windows (front to back)
            // fill the rest, so the grid has no empty panes. Fewer windows than panes: it closes up.
            if ordered.count < preset.slotCount, let c = catalog {
                let shown = Set(l.tiles.values.flatMap(\.windows).map(\.windowID))
                for w in c.windows where !w.minimized && !shown.contains(w.id) && ordered.count < preset.slotCount {
                    guard let source = source(for: w) else { break }
                    ordered.append(WorkspaceTile(id: "w\(nextTile)", source: source))
                    nextTile += 1
                }
            }
            return l.replacingTree(with: ordered.count > preset.slotCount ? l.applying(preset).layout : WorkspaceLayout(preset: preset, tiles: ordered))
        }
    }
    func move(_ tile: String, to target: WorkspaceDropTarget) { edit { $0.materializing(hinge: hinge).moving(tile, to: target) } }
    /// A divider drag: every step resizes, the whole drag is one undo step. Call `endResize()` when it ends.
    func resize(_ divider: WorkspaceDivider, delta: Double) {
        history.beginGroup()
        edit { WorkspaceGeometry.resizing($0, divider: divider, delta: delta, in: size) }
    }

    func endResize() { history.endGroup() }
    func rotate(_ tile: String) { edit { $0.rotating(tile) } }
    /// Fill Tile / Show Whole Window, from what the tile shows now (`.auto` resolved). Clears zoom.
    func toggleFit(_ tile: String) {
        let next: WorkspaceFit = effectiveFit(tile) == .fill ? .fit : .fill
        edit { l in l.zooming(tile, to: nil).settingFit(next, for: tile) }
    }
    func toggleMaximize(_ tile: String) { edit { l in l.maximized == tile ? l.restoringMaximized() : l.maximizing(tile) } }
    /// Removes the tile only; the Mac window stays open.
    func removeTile(_ tile: String) { edit { $0.removing(tile) } }

    func closeRemoteWindow(_ tile: String) {
        guard let source = layout.tiles[tile]?.source, let gen = generation(source) else { return }
        _ = send(WorkspaceRequests.closeWindow(source.windowID, generation: gen))
    }

    func bringBack(_ tile: String) {
        guard saved.tiles[tile] != nil, let target = active.flatMap({ layout.tiles[$0] != nil ? $0 : nil }) ?? layout.orderedTileIDs.last else { return }
        history.record(saved)
        saved = saved.swapping(tile, target)
        persist(); publish(); scheduleSend()
    }

    /// Settings ▸ Controls, off by default: choosing a window that sits in Stage Manager's side
    /// strip also brings it forward on the Mac (it changes the Mac's stage), so it streams live.
    /// Needs control; the Mac refuses it otherwise.
    static let bringStripWindowsForwardKey = "workspace.bringStripWindowsForward"
    var bringStripWindowsForward: Bool {
        get { UserDefaults.standard.bool(forKey: Self.bringStripWindowsForwardKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.bringStripWindowsForwardKey); objectWillChange.send() }
    }

    func choose(_ w: CatalogWindowItem, asNewTile: Bool) {
        guard let host, let source = source(for: w) else { return }
        if holdForLeavingExtend({ [weak self] in self?.choose(w, asNewTile: asNewTile) }) { return }
        if w.inStageStrip, bringStripWindowsForward, inputAllowed() {
            _ = send(WorkspaceRequests.activateWindow(w.id, generation: w.generation))   // the person chose it, and opted in
        }
        let replacing = replacingTile
        closeOverview()
        if !windowMode { requestWindowMode() }
        let landscape = size.width >= size.height
        // One window, one tile: choosing a window that's already showing selects its tile,
        // or swaps the two tiles when replacing another one.
        if let holder = layout.tile(holding: host, windowID: w.id), layout.tiles[holder]?.source?.windowID != w.id,
           let i = layout.tiles[holder]?.tabs.firstIndex(where: { $0.windowID == w.id }) {
            // It's a background tab: show that tab.
            edit { $0.switchingTab(of: holder, to: i) }
            focus(holder)
            return
        }
        if let existing = layout.orderedTileIDs.first(where: { layout.tiles[$0]?.source?.host == host && layout.tiles[$0]?.source?.windowID == w.id }) {
            let target = replacing ?? (asNewTile ? nil : active)
            if let target, target != existing, let other = layout.tiles[target]?.source, layout.tiles[existing] != nil {
                edit { l in l.replacingSource(of: target, with: source).replacingSource(of: existing, with: other) }
            }
            focus(target ?? existing)
            return
        }
        edit { l in
            let target = replacing ?? (asNewTile ? nil : (active ?? (l.orderedTileIDs.count == 1 ? l.orderedTileIDs.first : nil)))
            if let target, l.tiles[target] != nil { return l.replacingSource(of: target, with: source) }
            if l.paneCount < capacity, l.tiles.count < WorkspaceLayout.maximumTiles {
                let tile = WorkspaceTile(id: "w\(nextTile)", source: source)
                nextTile += 1
                if l.paneCount == 0 { return l.replacingTree(with: WorkspaceLayout(preset: .single, tiles: [tile])) }
                let added = l.adding(tile, landscape: landscape)
                return added.replacingTree(with: WorkspaceLayout(preset: .natural(for: added.paneCount, landscape: landscape),
                                                         tiles: added.orderedTileIDs.compactMap { added.tiles[$0] }))
            }
            return l.orderedTileIDs.last.map { l.replacingSource(of: $0, with: source) } ?? l
        }
    }

    // MARK: Close Window (Stage Peek)

    /// Closes one Mac window as its close button would: never Quit, never the app's other windows.
    /// View Only can't: the Mac refuses without control, and this says so before asking.
    func closeWindow(_ w: CatalogWindowItem) {
        let name = w.title.isEmpty ? w.app : w.title
        guard canCloseWindows else { closeNotice = WindowCloseNotice(windowID: w.id, name: name, result: nil, unsupported: true); return }
        guard inputAllowed() else { closeNotice = WindowCloseNotice(windowID: w.id, name: name, result: .control); return }
        guard !closingWindows.contains(w.id) else { return }
        closeRequest += 1
        closingWindows.insert(w.id)
        closeNotice = nil
        closeNames[w.id] = name
        _ = send(WorkspaceRequests.windowClose(w.id, generation: w.generation, req: closeRequest))
        let id = w.id
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard let self, self.closingWindows.contains(id) else { return }
            self.closingWindows.remove(id)
            self.closeNotice = WindowCloseNotice(windowID: id, name: self.closeNames.removeValue(forKey: id) ?? name, result: nil)
        }
    }

    private var closeNames: [UInt32: String] = [:]

    /// Lock This Mac: the Mac shows macOS's lock screen (needs control; the Mac says what happened).
    func lockMac() {
        guard canLockMac, lockMacStatus != .locking else { return }
        lockRequest += 1
        let req = lockRequest
        guard send(["type": LockMacWire.request, "req": req]) else { lockMacStatus = .done(.failed); return }
        lockMacStatus = .locking
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self, self.lockRequest == req, self.lockMacStatus == .locking else { return }
            self.lockMacStatus = .done(.failed)
        }
    }

    func clearLockMacStatus() { if lockMacStatus != .locking { lockMacStatus = nil } }

    private func finishClose(_ id: UInt32, result: WindowCloseResult) {
        closingWindows.remove(id)
        let name = closeNames.removeValue(forKey: id) ?? catalog?.windows.first { $0.id == id }.map { $0.title.isEmpty ? $0.app : $0.title } ?? ""
        if result.removesCard, var c = catalog {
            c.windows.removeAll { $0.id == id }
            catalog = c
        }
        closeNotice = WindowCloseNotice(windowID: id, name: name, result: result)
    }

    /// Opens an app on the Mac (explicit action; the Mac refuses it without control and never activates it).
    /// False: nothing was sent.
    @discardableResult
    func launch(_ bundle: String) -> Bool {
        guard inputAllowed() else { return false }
        launchFailed = nil
        launching.insert(bundle)
        return send(WorkspaceRequests.appLaunch(bundle))
    }

    // MARK: Local fullscreen (receiver only)

    func enterLocalFullscreen(_ tile: String) {
        guard layout.tiles[tile] != nil else { return }
        localFullscreen = tile
        publish(); scheduleSend(immediately: true)
        focus(tile, raise: false)   // fullscreen on this device only: nothing changes on the Mac
    }

    func exitLocalFullscreen() {
        guard localFullscreen != nil else { return }
        localFullscreen = nil
        publish(); scheduleSend(immediately: true)
    }

    /// A double tap on a pane's label: that pane fills this device, or (already) the layout comes back.
    /// Presentation only, like the menu's Fullscreen on This Device: the saved arrangement is untouched.
    func toggleLocalFullscreen(_ tile: String) {
        localFullscreen == tile ? exitLocalFullscreen() : enterLocalFullscreen(tile)
    }

    // MARK: Dragging windows and labels onto panes

    func beginDrag(_ item: WorkspaceDrag.Item, at global: CGPoint, placement: WorkspacePlacement? = nil) {
        var d = WorkspaceDrag(item: item, location: global)
        d.placement = placement ?? initialPlacement(for: item)
        if d.placement == .float, !canPlace(item, .float) { d.placement = .pane }
        drag = d
        circling.reset()
        placementSwitchProgress = 0
        // A new tip for the new gesture (people who saw the old shake tip see this one once too).
        if canPlace(item, .float), !defaults.bool(forKey: Self.placementTipKey) {
            defaults.set(true, forKey: Self.placementTipKey)   // never repeated, even if dismissed unseen
            placementTipVisible = true
        }
    }

    static let placementTipKey = "workspace.circleTipShown"
    func dismissPlacementTip() { placementTipVisible = false }

    /// The Float zone is offered while dragging in Pane placement something that can float, in Window view.
    var canDropToFloat: Bool {
        guard windowMode, let d = drag, d.placement == .pane else { return false }
        if case .float = d.item { return false }
        return canPlace(d.item, .float)
    }

    func overFloatZone(_ p: CGPoint) -> Bool {
        canDropToFloat && floatZoneGlobal.width > 0 && floatZoneGlobal.insetBy(dx: -8, dy: -8).contains(p)
    }

    /// Moves the drag; circling while holding (a circle and a bit, about a second) switches its
    /// placement (true when it switched). Progress shows as a ring at the finger, only when it can switch.
    @discardableResult
    func moveDrag(to global: CGPoint, at time: TimeInterval = CACurrentMediaTime()) -> Bool {
        guard let d = drag else { return false }
        drag?.location = global
        let fired = circling.add(x: Double(global.x), y: Double(global.y), at: time)
        let other: WorkspacePlacement = d.placement == .pane ? .float : .pane
        let switchable = canPlace(d.item, other)
        placementSwitchProgress = switchable ? circling.progress : 0
        if placementSwitchProgress > 0 { fadeRingWhenQuiet() }
        guard fired, switchable else { return false }
        return toggleDragPlacement()
    }
    func cancelDrag() { drag = nil; placementSwitchProgress = 0 }

    /// A drag (or a float move) whose finger is gone without an end: the view carrying its gesture
    /// went away mid-gesture, the app left the foreground, or the screen turned. Undone as a
    /// cancel, whatever was dragged, so no preview, card, drop target or hidden float is left
    /// behind (owner, QA 9000024: an icon dragged from Stage Peek's search stayed frozen in
    /// Floating placement). Nothing on the Mac changes.
    func abandonDrag(reason: String) {
        guard drag != nil || dockingFloat != nil || floatGesture != nil else { return }
        Log.info("drag: abandoned (\(reason)) item=\(drag.map { String(describing: $0.item).prefix(40) } ?? "-") docking=\(dockingFloat ?? "-") float=\(floatGesture ?? "-")")
        if let id = dockingFloat { cancelDockingFloat(id) }
        if drag != nil { cancelDrag() }
        if let id = floatGesture { endFloatGesture(id) }
    }

    /// No samples come while the finger rests: the ring goes once the circling has gone quiet.
    private func fadeRingWhenQuiet() {
        ringFade?.cancel()
        let quiet = circling.quiet
        ringFade = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((quiet + 0.05) * 1_000_000_000))
            guard let self, !Task.isCancelled, self.circling.isQuiet(at: CACurrentMediaTime()) else { return }
            self.placementSwitchProgress = 0
        }
    }

    /// The drop under the finger, in picture terms. Nil outside the picture and over the Cancel zone.
    /// In Mirror/Extend the desktop counts as one pane (a window can land beside it).
    func dropTarget(forGlobal p: CGPoint, labelHeight: CGFloat = 30) -> WorkspaceWindowDrop? {
        if overCancelZone(p) || overRemoveZone(p) || overFloatZone(p) { return nil }
        if drag?.placement == .float { return nil }   // Floating placement: no pane targets
        if !windowMode {
            switch drag?.item { case .window?, .app?: break; default: return nil }
            guard desktopPictureGlobal.width > 0, desktopPictureGlobal.contains(p) else { return nil }
            // No display listed (an older Mac): the window simply shows in Window mode.
            guard let desk = desktopLayout() else { return .replace(tile: Self.noDesktop, preview: WorkspaceRect(x: 0, y: 0, width: 1, height: 1)) }
            let g = desktopPictureGlobal
            let s = WorkspaceSize(width: g.width, height: g.height)
            let n = WorkspacePoint(x: (p.x - g.minX) / g.width, y: (p.y - g.minY) / g.height)
            return WorkspaceGeometry.windowDrop(at: n, layout: desk, frames: WorkspaceGeometry.frames(for: desk, in: s, hinge: nil),
                                                size: s, labelHeight: Double(labelHeight / g.height), canSplit: true)
        }
        guard pictureGlobal.width > 0, pictureGlobal.contains(p) else { return nil }
        let n = WorkspacePoint(x: (p.x - pictureGlobal.minX) / pictureGlobal.width, y: (p.y - pictureGlobal.minY) / pictureGlobal.height)
        return windowDrop(at: n, labelHeight: Double(labelHeight / pictureGlobal.height))
    }

    /// The drop target when no display can join the window (it then shows alone).
    static let noDesktop = "\u{0}desktop"

    func overCancelZone(_ p: CGPoint) -> Bool { cancelZoneGlobal.width > 0 && cancelZoneGlobal.insetBy(dx: -8, dy: -8).contains(p) }

    /// Remove from Layout is offered only while repositioning a whole pane that is already in the
    /// layout (its label, not one of its tabs), with another pane left: never for a window or app
    /// from Stage Peek, a new pane or a tab. A float being docked (circled into a card) is offered
    /// Remove from This Device. Either removes it here only; the Mac window is untouched.
    var canDropToRemove: Bool {
        guard windowMode else { return false }
        switch drag?.item {
        case .pane(let id, nil)?, .float(let id)?: return canRemoveFromLayout(id)
        default: return false
        }
    }

    /// Whether a pane may come off this device's layout (its menu and the drop
    /// zone agree). Never the last one: that would leave an empty canvas, and
    /// the pane's menu offers Change Window… instead (#120).
    func canRemoveFromLayout(_ tile: String) -> Bool {
        arranged.tiles[tile] != nil && (arranged.isFloat(tile) || arranged.paneCount > 1)
    }

    /// Cancel wins where the two zones' touch margins meet (they sit 12 pt
    /// apart with 8 pt of slop each), so the highlight, the haptic and the
    /// drop always agree, and the uncertain case removes nothing.
    func overRemoveZone(_ p: CGPoint) -> Bool {
        canDropToRemove && removeZoneGlobal.width > 0 && removeZoneGlobal.insetBy(dx: -8, dy: -8).contains(p)
            && !overCancelZone(p)
    }

    /// Ends a drag: drops onto the pane under the finger. Dropped on Cancel or outside the
    /// picture: nothing changes. Returns whether anything changed.
    @discardableResult
    func endDrag() -> Bool {
        placementSwitchProgress = 0
        guard let d = drag else { return false }
        if d.placement == .float {
            drag = nil
            return dropFloating(d)
        }
        if overFloatZone(d.location), canPlace(d.item, .float) {
            drag = nil
            return floatItem(d.item, at: nil)
        }
        let target = dropTarget(forGlobal: d.location)
        let remove = overRemoveZone(d.location)
        drag = nil
        if remove, case .pane(let id, nil) = d.item {
            removeTile(id)   // one undo step; never a request to close the window on the Mac
            return true
        }
        if remove, case .float(let id) = d.item {
            removeFloat(id)   // the float's own Remove from This Device: the Mac window stays open
            return true
        }
        guard let target else { return false }
        switch d.item {
        case .window(let w):
            // Closed (or its id now names another window) while it was dragged: nothing to place.
            if let c = catalog, !c.windows.contains(where: { $0.id == w.id && $0.generation == w.generation }) { return false }
            return place(w, on: target)
        case .pane(let id, let tab):
            if let tab, case .tab(let t, _) = target, t == id { return reorderTab(id, from: tab, at: d.location) }
            dropTile(id, tab: tab, on: target)
            return true
        case .app(let app):
            let windows = (catalog?.windows ?? []).filter { $0.bundleID == app.bundleID }
            if windows.count == 1 { return place(windows[0], on: target) }
            // Several: which one. None: offer to open it, then place its first window there.
            appDrop = AppDrop(app: app, windows: windows, target: target)
            return windows.isEmpty ? false : true
        case .float(let id):
            dockFloat(id, to: target)
            return true
        }
    }

    /// A tab dropped back on its own pane's labels: it goes between the labels either side.
    private func reorderTab(_ id: String, from: Int, at p: CGPoint) -> Bool {
        guard let frames = tabLabelFrames[id], let count = layout.tiles[id]?.tabs.count, count > 1 else { return false }
        let mids: [Double] = (0..<count).compactMap { i in frames[i].map { Double($0.midX) } }
        guard mids.count == count else { return false }
        let to = WorkspaceTabOrder.index(from: from, dropX: Double(p.x), labelMidXs: mids)
        guard to != from else { return false }
        edit { $0.movingTab(of: id, from: from, to: to) }
        return true
    }

    /// An app dropped on a pane, waiting for the person: pick one of its windows, or open it.
    struct AppDrop: Identifiable, Equatable {
        let id = UUID()
        var app: MacAppItem
        var windows: [CatalogWindowItem]
        var target: WorkspaceWindowDrop
        /// Dropped in Floating placement: the window floats here instead (picture-normalized).
        var floatAt: WorkspacePoint? = nil
    }
    @Published var appDrop: AppDrop?
    /// Bumped to ask Stage Peek to close (an app dropped from it is opening: its progress, and
    /// then its window, show in the layout).
    @Published private(set) var stagePeekCloseRequest = 0

    /// The window picked for an app drop.
    func completeAppDrop(_ d: AppDrop, with w: CatalogWindowItem) {
        appDrop = nil
        if let at = d.floatAt { openFloating(w, at: at); return }
        _ = place(w, on: d.target)
    }

    /// Open the dropped app on the Mac (explicit), then put its new window where it was dropped.
    /// The same opening as the picker's (`WorkspaceAppOpening`): with control it launches now;
    /// without (or `requestingControl`) control is requested the usual way first. Stage Peek
    /// closes so the layout, with the opening's progress, shows; nothing else changes.
    func openAppForDrop(_ d: AppDrop, requestingControl: Bool = false) {
        appDrop = nil
        guard !d.app.bundleID.isEmpty, d.windows.isEmpty else { return }
        let tile = d.target.tile
        let drop = WorkspaceAppOpening.Drop(target: d.target, floatAt: d.floatAt, panes: paneOrder)
        beginAppOpening(bundleID: d.app.bundleID, name: d.app.name, tile: tile, drop: drop, requestingControl: requestingControl)
        stagePeekCloseRequest += 1
    }

    /// The layout's panes in order (floats aside): what a split or empty-slot drop is relative to.
    private var paneOrder: [String] { arranged.orderedTileIDs.filter { !arranged.isFloat($0) } }

    func cancelAppDrop() { appDrop = nil }

    // MARK: Opening an app from the window picker (WorkspaceAppOpening)

    /// An app opening from the picker into the tile it was opened for (nil: none). The picker
    /// shows its progress, the choice among several new windows, and what went wrong.
    @Published private(set) var appOpening: WorkspaceAppOpening?
    /// Still opening after a few seconds: the picker says it's taking a while.
    @Published private(set) var appOpeningSlow = false
    /// Bumped whenever the picker shows a new question about the opening (a choice, a failure),
    /// so a dialog dismissed without an answer stops only the question it showed.
    private(set) var appOpeningRound = 0
    private var appOpeningTask: Task<Void, Never>?

    /// The session's control as the opening needs it (live session and the Mac's grant).
    private var appOpeningControl: WorkspaceAppOpening.Control {
        WorkspaceAppOpening.Control(live: inputAllowed(), state: controlState())
    }

    private func appOpeningTileUnchanged(_ o: WorkspaceAppOpening) -> Bool {
        guard o.tileUnchanged(o.tile.flatMap { arranged.tiles[$0] }) else { return false }
        // A drop on a split edge or an empty slot names a position: only while the panes are the same.
        if let d = o.drop, d.floatAt == nil, d.target.tile == nil { return paneOrder == d.panes }
        return true
    }

    /// The person confirmed opening `app` (the picker asked). With control the Mac is asked to
    /// launch exactly that app now; without (or `requestingControl`: the picker offered Request
    /// Control), control is requested the usual way and the app opens once the Mac allows it. The
    /// picker shows it waiting; Cancel or closing the picker stops it.
    func openAppFromPicker(_ app: WorkspacePickerSearch.AppToOpen, requestingControl: Bool = false) {
        guard overviewOpen, !app.bundleID.isEmpty else { return }
        beginAppOpening(bundleID: app.bundleID, name: app.name, tile: replacingTile, drop: nil, requestingControl: requestingControl)
    }

    private func beginAppOpening(bundleID: String, name: String, tile: String?, drop: WorkspaceAppOpening.Drop?, requestingControl: Bool) {
        dismissAppOpening()
        let control = appOpeningControl
        let (o, step) = WorkspaceAppOpening.start(bundleID: bundleID, name: name, tile: tile,
                                                  tileSource: tile.flatMap { arranged.tiles[$0]?.source }, drop: drop,
                                                  control: requestingControl && control == .allowed ? .off : control,
                                                  windows: catalog?.windows ?? [], now: clock())
        Log.info("pickerOpen: requested bundle=\(bundleID) tile=\(tile ?? "-") drop=\(drop != nil) control=\(control) request=\(requestingControl)")
        appOpening = o
        appOpeningSlow = false
        appOpeningRound += 1
        if o.phase == .awaitingControl, control != .requesting {
            Log.info("pickerOpen: control requested bundle=\(bundleID)")
            requestControl()
        }
        performAppOpening(step)
        if appOpening?.isFinished == false { runAppOpeningTimer() }
    }

    /// One of several new windows, picked by the person.
    func pickOpenedWindow(_ w: CatalogWindowItem) {
        guard var o = appOpening else { return }
        let step = o.pick(w.id, generation: w.generation, windows: catalog?.windows ?? [], tileUnchanged: appOpeningTileUnchanged(o))
        appOpening = o
        performAppOpening(step)
    }

    /// Try Again after a failure: the same app, for the same tile.
    func retryAppOpening() {
        guard let o = appOpening, case .failed(let f) = o.phase, f.retryable else { return }
        Log.info("pickerOpen: retry bundle=\(o.bundleID) after=\(f.rawValue)")
        if let drop = o.drop {
            beginAppOpening(bundleID: o.bundleID, name: o.name, tile: o.tile, drop: drop, requestingControl: false)
            return
        }
        openAppFromPicker(WorkspacePickerSearch.AppToOpen(bundleID: o.bundleID, name: o.name, running: false))
    }

    /// Cancel, OK, or the picker closing: stop waiting; nothing is placed.
    func dismissAppOpening() {
        appOpeningTask?.cancel(); appOpeningTask = nil
        guard let o = appOpening else { return }
        if !o.isFinished { Log.info("pickerOpen: cancelled bundle=\(o.bundleID)") }
        appOpening = nil
        appOpeningSlow = false
    }

    /// A choice or failure dismissed without an answer: stops the opening if that is still the
    /// question showing (an answer given meanwhile moved it on).
    func dismissAppOpening(round: Int) {
        guard round == appOpeningRound, let o = appOpening, !o.isWaiting else { return }
        dismissAppOpening()
    }

    /// A new listing or a second passing: control granted, the app's window seen, or a wait over.
    func advanceAppOpening() {
        guard var o = appOpening, !o.isFinished else { return }
        let seen = o.firstSeenAt != nil
        let now = clock()
        let step = o.advance(windows: catalog?.windows ?? [], now: now, control: appOpeningControl,
                             tileUnchanged: appOpeningTileUnchanged(o))
        if !seen, o.firstSeenAt != nil {
            Log.info("pickerOpen: window seen bundle=\(o.bundleID) new=\(o.newWindows(catalog?.windows ?? []).map(\.id))")
        }
        if o != appOpening { appOpening = o }
        let slow = o.isSlow(now: now)
        if slow != appOpeningSlow { appOpeningSlow = slow }
        performAppOpening(step)
    }

    private func performAppOpening(_ step: WorkspaceAppOpening.Step) {
        guard var o = appOpening else { return }
        switch step {
        case .none:
            break
        case .launch:
            Log.info("pickerOpen: launch sent bundle=\(o.bundleID) tile=\(o.tile ?? "-") known=\(o.known.count)")
            if !launch(o.bundleID) {
                let next = o.launchNotSent()
                appOpening = o
                performAppOpening(next)
            }
        case .place(let w):
            Log.info("pickerOpen: placed bundle=\(o.bundleID) window=\(w.id) tile=\(o.tile ?? "-")")
            appOpeningTask?.cancel(); appOpeningTask = nil
            appOpening = nil
            appOpeningSlow = false
            if let drop = o.drop {
                // Exactly as if this window had been dropped there.
                if let at = drop.floatAt { openFloating(w, at: at) } else { _ = place(w, on: drop.target) }
                stagePeekCloseRequest += 1
                return
            }
            // Exactly as if the person had picked this window for that tile.
            replacingTile = o.tile
            choose(w, asNewTile: false)
        case .choose(let windows):
            Log.info("pickerOpen: several windows bundle=\(o.bundleID) windows=\(windows.map(\.id)) stale=\(o.pickWasStale)")
            appOpeningRound += 1
            appOpeningSlow = false
        case .fail(let f):
            Log.info("pickerOpen: failed bundle=\(o.bundleID) reason=\(f.rawValue)")
            appOpeningTask?.cancel(); appOpeningTask = nil
            appOpeningSlow = false
            appOpeningRound += 1
        }
    }

    /// While an opening waits: the window listing every second (the Mac answers at most twice a
    /// second) until it ends, at most `controlTimeout` + `answerTimeout` + `windowTimeout`.
    private func runAppOpeningTimer() {
        appOpeningTask?.cancel()
        appOpeningTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled, let self, let o = self.appOpening, !o.isFinished else { break }
                if o.phase == .launching || o.phase == .waitingForWindow { self.requestCatalog() }
                self.advanceAppOpening()
            }
        }
    }

    /// A window dropped on a pane (or, outside Window mode, beside the desktop).
    private func place(_ w: CatalogWindowItem, on target: WorkspaceWindowDrop) -> Bool {
        if !windowMode {
            // From Extend, only once the person confirms (it removes the extended display).
            if holdForLeavingExtend({ [weak self] in _ = self?.place(w, on: target) }) { return false }
            // Mirror/Extend: Window mode starts with the desktop and the window as dropped.
            guard let desk = desktopLayout() else { switchTo(w); return true }
            guard let source = source(for: w) else { return false }
            nextTile += 1   // the desktop pane's id
            let (next, focusTile) = dropping(source, on: target, in: desk)
            history.record(saved)
            saved = next.compacted()
            localFullscreen = nil
            refreshMissing(); persist(); publish()
            requestWindowMode()
            if let focusTile { focus(focusTile) }
            return true
        }
        drop(w, on: target)
        return true
    }

    func minimizeRemoteWindow(_ tile: String) {
        guard inputAllowed(), let source = layout.tiles[tile]?.source, let gen = generation(source) else { return }
        _ = send(WorkspaceRequests.minimizeWindow(source.windowID, generation: gen))
    }

    // MARK: Fill Window on Mac / Restore Previous Size on Mac

    /// The items belong in this pane's menu (or a float's ⋯ menu): the Mac offers them and the
    /// pane shows a Mac window in Window view. Whether they are enabled: `canControlMac`.
    func offersWindowFrameOnMac(_ tile: String) -> Bool {
        guard canResizeWindowsOnMac, windowMode, let source = layout.tiles[tile]?.source else { return false }
        return !source.isDisplay
    }

    /// Restore Previous Size on Mac: the Mac says it can put this pane's window back.
    func canRestoreOnMac(_ tile: String) -> Bool {
        guard offersWindowFrameOnMac(tile), let source = layout.tiles[tile]?.source, let state = tileState(tile) else { return false }
        return state.restorable && state.windowID == source.windowID
    }

    /// A Fill or Restore for this pane is waiting for the Mac's answer.
    func isResizingOnMac(_ tile: String) -> Bool { windowFramePending.contains(tile) }

    /// Fills the usable area of the window's display on the Mac (not full screen). Only from the
    /// explicit menu item: nothing about arranging, zooming or floating panes here calls it.
    func fillWindowOnMac(_ tile: String) { requestWindowFrame(.fill, tile: tile) }

    /// Puts the Mac window back to the frame it had before Fill Window on Mac.
    func restoreWindowOnMac(_ tile: String) { requestWindowFrame(.restore, tile: tile) }

    func clearWindowFrameNotice() { windowFrameNoticeClear?.cancel(); windowFrameNotice = nil }

    private func requestWindowFrame(_ op: WindowFrameOp, tile: String) {
        guard offersWindowFrameOnMac(tile), let source = layout.tiles[tile]?.source,
              let gen = generation(source) ?? tileState(tile).flatMap({ $0.windowID == source.windowID ? $0.generation : nil })
        else { return }
        // View Only: say why here instead of asking (the Mac would refuse it anyway).
        guard canControlMac else {
            showWindowFrameNotice(WindowFrameNotice(tile: tile, windowID: source.windowID, op: op, result: .control))
            return
        }
        guard !windowFramePending.contains(tile) else { return }
        windowFrameRequest += 1
        let req = windowFrameRequest
        guard send(WindowFrameWire.requestMessage(op, window: source.windowID, generation: gen, req: req)) else {
            showWindowFrameNotice(WindowFrameNotice(tile: tile, windowID: source.windowID, op: op, result: nil))
            return
        }
        windowFrameAsked[req] = (tile, source.windowID, op)
        windowFramePending.insert(tile)
        windowFrameNoticeClear?.cancel()
        windowFrameNotice = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self, let asked = self.windowFrameAsked.removeValue(forKey: req) else { return }
            self.windowFramePending.remove(asked.tile)
            self.showWindowFrameNotice(WindowFrameNotice(tile: asked.tile, windowID: asked.windowID, op: asked.op, result: nil))
        }
    }

    private func finishWindowFrame(_ reply: WindowFrameReply) {
        let key = reply.req.flatMap { windowFrameAsked[$0] != nil ? $0 : nil }
            ?? windowFrameAsked.first { $0.value.windowID == reply.windowID && $0.value.op == reply.op }?.key
        guard let key, let asked = windowFrameAsked.removeValue(forKey: key), asked.windowID == reply.windowID else { return }
        windowFramePending.remove(asked.tile)
        showWindowFrameNotice(WindowFrameNotice(tile: asked.tile, windowID: reply.windowID, op: reply.op, result: reply.result))
    }

    private func showWindowFrameNotice(_ notice: WindowFrameNotice) {
        windowFrameNotice = notice
        windowFrameNoticeClear?.cancel()
        let clear = DispatchWorkItem { [weak self] in
            guard let self, self.windowFrameNotice == notice else { return }
            self.windowFrameNotice = nil
        }
        windowFrameNoticeClear = clear
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: clear)
    }
    /// Makes `tile` the one typing goes to. `raise` false for anything that only arranges this
    /// device's view (moving, resizing, tucking, docking or zooming a window, fullscreen on this
    /// device): the Mac window then stays where it is, and comes forward only when a key or a
    /// press for it needs it to (never typing into another window meanwhile).
    func focus(_ tile: String, raise: Bool = true) {
        if layout.tiles[tile] != nil, !layout.isFloat(tile) { lastFocusedPane = tile }
        requestedFocus = tile
        _ = send(WorkspaceRequests.focus(tile, raise: raise))
    }

    /// The tree's pane focused last: where typing goes back to when a focused float is tucked or removed.
    private var lastFocusedPane: String?
    /// The pane this device asked to focus, until the Mac's state says so: the next layout request
    /// carries it, so a request in flight never puts the old focus back.
    private var requestedFocus: String?
    /// The floating pane being moved or resized by a finger now (its chrome draws the local preview).
    @Published private(set) var floatGesture: String?
    /// The layout before the current float gesture, recorded as one undo step once it changes something.
    private var floatGestureStart: WorkspaceLayout?
    /// Circling while dragging (pane label, Stage Peek window, float title).
    var circling = WorkspaceCircleGesture()
    private var ringFade: Task<Void, Never>?
    /// The float a finger is moving by its title or grabber: circling switches it into docking.
    private(set) var floatMove: WorkspaceFloatMove?
    /// The float being docked: folded into a card under the finger (a `.float` drag), drawn
    /// nowhere else, here or on the Mac, until it's dropped, cancelled or circled back.
    @Published private(set) var dockingFloat: String?

    /// The hardware pointer at a normalized canvas point: hover only, never focus.
    func hover(at p: CGPoint?) {
        let id = p.flatMap { p in frames.hitTest(WorkspacePoint(x: p.x, y: p.y)) }
        if hovered != id { hovered = id }
    }

    // MARK: Overview, rail

    func openOverview(replacing tile: String? = nil) {
        dismissAppOpening()   // an app opening for another tile stops here
        replacingTile = tile
        overviewOpen = true
        startRefreshing()
    }

    /// Closing the picker (Done, or a window chosen) also stops an app opening from it: nothing
    /// is placed later behind the person's back.
    func closeOverview() {
        dismissAppOpening()
        overviewOpen = false; replacingTile = nil
    }

    /// The tile a switcher (Stage Peek) replaces: the active tile, the only
    /// one, else the first tile still waiting for a window, else the last.
    var switchTarget: String? {
        let order = layout.orderedTileIDs
        if let active, layout.tiles[active] != nil { return active }
        if order.count == 1 { return order.first }
        return order.first { missing.contains($0) || layout.tiles[$0]?.source == nil } ?? order.last
    }

    /// The window shown in the tile a switcher would replace.
    var currentWindowID: UInt32? {
        switchTarget.flatMap { layout.tiles[$0]?.source?.windowID }
    }

    /// Stage Peek's tap: shows `w` in `switchTarget`; never adds a tile.
    func switchTo(_ w: CatalogWindowItem) {
        if windowMode, let host, let holder = layout.tile(holding: host, windowID: w.id), layout.isFloat(holder) {
            untuckFloat(holder)   // a float already shows it: bring that one back, never a second copy
            return
        }
        // Default Window Placement applies to windows not in the layout yet (in Mirror, any window:
        // it floats over the mirrored desktop).
        if canOpenFloats, defaultPlacement == .float, !WorkspaceSource.isDisplayKey(w.id),
           let host, !windowMode || layout.tile(holding: host, windowID: w.id) == nil {
            openFloating(w)
            return
        }
        replacingTile = switchTarget
        choose(w, asNewTile: false)
    }

    /// Whether another tile can be added (Stage Peek's "Add as Tile").
    var canAddTile: Bool { layout.paneCount < capacity && layout.tiles.count < WorkspaceLayout.maximumTiles }

    /// While any browser is open (in every display mode): catalog every few seconds,
    /// stills as cards appear, the app list once (then only when it changed).
    private func startRefreshing() {
        refreshTask?.cancel()
        requestCatalog()
        askForApps(opening: true)
        refreshTask = Task { [weak self] in
            while let self, self.browsing {
                try? await Task.sleep(nanoseconds: self.overviewOpen || self.stagePeekOpen || self.launchpadOpen ? 3_000_000_000 : 5_000_000_000)
                guard !Task.isCancelled, self.browsing else { break }
                self.requestCatalog()
                self.askForApps(opening: false)
            }
        }
    }

    /// The Mac's app list: asked when a browser opens (with this device's revision, so an
    /// unchanged list is a short `same` answer); a tick only repeats an unanswered ask.
    private func askForApps(opening: Bool) {
        let now = clock()
        guard opening ? inventory.opened(now: now) : inventory.tick(now: now) else { return }
        requestApps()
    }

    // MARK: Sending

    private var throttledSendPending = false

    /// Continuous changes (a pinch): send at a steady ~30/s while they keep coming,
    /// instead of waiting for them to stop.
    private func scheduleThrottledSend() {
        guard !throttledSendPending else { return }
        throttledSendPending = true
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 33_000_000)
            guard let self else { return }
            self.throttledSendPending = false
            self.sendNow()
        }
    }

    private func scheduleSend(immediately: Bool = false) {
        sendTask?.cancel()
        sendTask = Task { [weak self] in
            if !immediately { try? await Task.sleep(nanoseconds: 60_000_000) }
            guard !Task.isCancelled else { return }
            self?.sendNow()
        }
    }

    private func sendNow() {
        guard let host, windowMode else { return }
        guard catalog != nil else { awaitingCatalogToSend = true; requestCatalog(); return }
        var sendable = layout
        for id in missing { sendable = sendable.replacingSource(of: id, with: nil) }
        let sendFrames = WorkspaceGeometry.frames(for: sendable, in: size, hinge: hinge)
        noteViews(sendable, frames: sendFrames)
        let focusNow = requestedFocus.flatMap { sendFrames.tiles[$0] != nil ? $0 : nil } ?? active
        _ = send(WorkspaceRequests.workspace(sendable, frames: sendFrames,
                                             host: host, focus: focusNow, generation: generation,
                                             displayID: { [weak self] in self?.display(for: $0)?.id },
                                             viewEpoch: { [weak self] in self?.viewEpochs[$0] },
                                             floats: canFloat, lifted: canLiftFloats ? liftedFloats.filter { sendable.isFloat($0) } : [],
                                             watch: heldWindows(host: host)))
    }

    /// Every Mac window held here (shown, another tab, a float tucked or hidden) under the generation
    /// it was listed with. Windows not yet listed on this connection, whole displays and panes that
    /// follow an app aren't watched: nothing is taken out without the Mac's proof.
    private func heldWindows(host: String) -> [WorkspaceHeldWindow] {
        var seen = Set<String>()
        return saved.allTileIDs.flatMap { saved.tiles[$0]?.windows ?? [] }.compactMap { s in
            guard s.host == host, !s.isDisplay, s.follow == .window, listedThisConnection.contains(s.tabKey),
                  let g = generation(s), seen.insert(s.tabKey).inserted else { return nil }
            return WorkspaceHeldWindow(window: s.windowID, generation: g)
        }
    }

    /// The Mac proved these windows closed (`gone`): a floating pane holding one goes (tucked too),
    /// a tab goes and its pane shows the next, and a pane whose last window closed stays empty with
    /// Choose Window and Remove Pane. Only windows held under exactly that generation; anything
    /// in progress on a pane that goes or empties stops (a drag, a dock, a pinch). Not an edit the
    /// person made, so not undoable (the window is gone).
    private func windowsClosedOnMac(_ gone: [WorkspaceHeldWindow]) {
        guard let host else { return }
        var added = false
        for g in gone {
            let s = WorkspaceSource(host: host, windowID: g.window)
            guard listedThisConnection.contains(s.tabKey), generation(s) == g.generation,
                  closedOnMac[s.tabKey] != g.generation else { continue }
            closedOnMac[s.tabKey] = g.generation
            added = true
        }
        guard added else { return }
        let result = saved.removingClosedWindows(isClosedOnMac)
        guard result.layout != saved else { return }
        let touched = result.removed.union(result.emptied)
        Log.info("workspace: windows closed on the Mac: floats removed=\(result.removed.sorted()) panes emptied=\(result.emptied.sorted())")
        if touched.contains(where: { floatGesture == $0 || dockingFloat == $0 }) { abandonDrag(reason: "window closed on the Mac") }
        if let item = drag?.item {
            switch item {
            case .pane(let id, _) where touched.contains(id) || result.layout.tiles[id]?.windows != saved.tiles[id]?.windows:
                abandonDrag(reason: "window closed on the Mac")
            case .float(let id) where touched.contains(id):
                abandonDrag(reason: "window closed on the Mac")
            default: break
            }
        }
        if let z = zoomGesture, touched.contains(z.tile) { zoomGesture = nil; zoomPreview = nil }
        for id in result.removed { backdrops[id] = nil; liftedFloats.remove(id); liftWanted.remove(id) }
        saved = result.layout
        refreshMissing()
        persist(); publish(); scheduleSend(immediately: true)
        advanceAppOpening()
    }

    private func isClosedOnMac(_ s: WorkspaceSource) -> Bool {
        guard let g = closedOnMac[s.tabKey] else { return false }
        return generation(s) == g
    }

    private func removingClosed(from layout: WorkspaceLayout) -> WorkspaceLayout {
        closedOnMac.isEmpty ? layout : layout.removingClosedWindows(isClosedOnMac).layout
    }

    private func persist() {
        guard let host, let data = WorkspaceLayoutRecord(saved).encoded() else { return }
        defaults.set(data, forKey: "workspace.layout.\(host)")
    }
}

// MARK: - Floating panes (receiver-local; WorkspaceFloats.swift)
//
// Every action here changes only this device's workspace and the rectangles it asks the Mac
// to composite. None of them sends pointer input, `windowAction` or `windowClose`: the Mac
// window is never moved, resized, minimized, closed or activated by floating, moving,
// resizing, flinging, tucking, docking or local fullscreen.

extension WorkspaceModel {
    /// Settings ▸ Window View: where windows newly brought in (mostly from Stage Peek) land.
    /// Existing windows are never rearranged by it.
    static let defaultPlacementKey = "workspace.defaultPlacement"
    var defaultPlacement: WorkspacePlacement {
        get { defaults.string(forKey: Self.defaultPlacementKey).flatMap(WorkspacePlacement.init(rawValue:)) ?? .pane }
        set { defaults.set(newValue.rawValue, forKey: Self.defaultPlacementKey); objectWillChange.send() }
    }

    /// Floating panes can be shown now (the Mac draws them).
    var canFloatPanes: Bool { canFloat }

    /// The pane's window can float: the Mac draws floats, and the tree keeps at least one pane
    /// (a tab of a pane always can, its pane stays).
    func canFloat(pane id: String, tab: Int? = nil) -> Bool {
        guard canFloat, layout.tiles[id] != nil, !layout.isFloat(id), layout.tiles.count < WorkspaceLayout.maximumTiles || tab == nil else { return false }
        if let tab { return layout.tiles[id]?.tabs.indices.contains(tab) == true }
        return layout.tiles[id]?.source != nil && (layout.paneCount > 1 || (layout.tiles[id]?.tabs.count ?? 0) > 1)
    }

    /// The window's width / height as the pane draws it (turned a quarter: swapped).
    func windowAspect(_ id: String) -> Double? {
        guard let tile = layout.tiles[id], let source = windowSize(tile) else { return nil }
        // As drawn: a turned window's box (any angle).
        let r = TileContentTransform(tile: WorkspaceRect(x: 0, y: 0, width: 1, height: 1), source: source,
                                     rotation: tile.rotation, fit: .fit).rotatedSourceSize
        return r.width > 0 && r.height > 0 ? r.width / r.height : nil
    }

    /// Where a new float opens: where it was dropped, else the next place in the cascade that no
    /// shown float sits on (a phone shows several, like an iPad).
    private func newFloatFrame(aspect: Double?, at center: WorkspacePoint?, in space: WorkspaceSize? = nil) -> WorkspaceRect {
        if let center { return WorkspaceFloatGeometry.defaultFrame(aspect: aspect, in: space ?? size, center: center) }
        let shown = space == nil ? layout.floats.filter { $0.tuck == nil }.map(\.frame) : []
        return WorkspaceFloatGeometry.openingFrame(aspect: aspect, in: space ?? size, avoiding: shown)
    }

    /// A window can open floating from here: in Window view, or over the mirrored desktop (Window
    /// view then starts with that desktop as the pane underneath, as when a window is dropped
    /// onto it; the person isn't asked). Never from Extend: leaving Extend removes this device's
    /// extended display, and macOS moves the windows on it, which a float must never cause.
    var canOpenFloats: Bool { canFloat && (windowMode || (mirroring() && desktopDisplay != nil)) }

    // MARK: Opening, floating, docking

    /// Open as Floating Window (Stage Peek): a window already in the workspace floats from where
    /// it is (a float comes back to the front); a new one opens floating. In Mirror the mirrored
    /// desktop becomes the pane underneath and Window mode starts with both, without asking. Never
    /// from Extend (see `canOpenFloats`).
    func openFloating(_ w: CatalogWindowItem, at center: WorkspacePoint? = nil) {
        guard canOpenFloats, let host, let source = source(for: w) else { return }
        let aspect = w.width > 0 && w.height > 0 ? Double(w.width) / Double(w.height) : nil
        if !windowMode {
            guard let desk = desktopLayout() else { return }
            nextTile += 1   // the desktop pane's id
            let id = "w\(nextTile)"; nextTile += 1
            history.record(saved)
            // Sized in the picture shown now: Window view's own space isn't measured yet.
            let shown = desktopPictureGlobal.width > 0 && desktopPictureGlobal.height > 0
                ? WorkspaceSize(width: desktopPictureGlobal.width, height: desktopPictureGlobal.height) : nil
            saved = desk.addingFloat(WorkspaceTile(id: id, source: source), frame: newFloatFrame(aspect: aspect, at: center, in: shown)).compacted()
            localFullscreen = nil
            refreshMissing(); persist(); publish()
            requestWindowMode()
            focus(id, raise: false)
            return
        }
        if let holder = layout.tile(holding: host, windowID: w.id) {
            if layout.isFloat(holder) {
                untuckFloat(holder)
                return
            }
            let tab = layout.tiles[holder]?.tabs.firstIndex { $0.windowID == w.id }
            if canFloat(pane: holder, tab: tab.flatMap { (layout.tiles[holder]?.tabs.count ?? 0) > 1 ? $0 : nil }) {
                floatPane(holder, tab: tab.flatMap { (layout.tiles[holder]?.tabs.count ?? 0) > 1 ? $0 : nil }, at: center)
            } else {
                focus(holder, raise: false)   // the only pane: it stays a pane
            }
            return
        }
        guard layout.tiles.count < WorkspaceLayout.maximumTiles else { return }
        let id = "w\(nextTile)"; nextTile += 1
        let frame = newFloatFrame(aspect: aspect, at: center)
        edit { $0.addingFloat(WorkspaceTile(id: id, source: source), frame: frame) }
        focus(id, raise: false)
    }

    /// Float This Pane / Float This Tab, or a pane title dropped in Floating placement. The
    /// pane's window keeps its tile (and its capture); the layout closes up around it.
    func floatPane(_ id: String, tab: Int? = nil, at center: WorkspacePoint? = nil) {
        guard canFloat(pane: id, tab: tab), let tile = layout.tiles[id] else { return }
        let aspect: Double? = {
            guard let tab, tile.tabs.indices.contains(tab), let w = windowItem(tile.tabs[tab]), w.width > 0, w.height > 0 else { return windowAspect(id) }
            return Double(w.width) / Double(w.height)
        }()
        let frame = newFloatFrame(aspect: aspect, at: center)
        var floated = id
        if let tab, tile.tabs.count > 1 {
            let newID = "w\(nextTile)"; nextTile += 1
            if tile.tabs[tab] != tile.source { floated = newID }
            edit { $0.floatingTab(of: id, at: tab, frame: frame, newID: newID) }
        } else {
            if localFullscreen == id { localFullscreen = nil }
            edit { $0.floatingPane(id, frame: frame) }
        }
        focus(floated, raise: false)
    }

    /// A float docked where it was dropped in Pane placement: a tab, a new pane beside one, or an
    /// empty slot. Never replaces or drops another window.
    func dockFloat(_ id: String, to target: WorkspaceWindowDrop) {
        guard layout.isFloat(id) else { return }
        var drop = target
        if case .split(let index, _, _) = target, layout.paneCount >= capacity,
           let holder = WorkspaceLayout.slotID(layout.root, at: index).flatMap({ $0 }) {
            drop = .tab(tile: holder, preview: target.preview)   // no room for another pane: a tab of that one
        }
        if localFullscreen == id { localFullscreen = nil }
        edit { $0.docking(id, to: drop) }
        focus(id, raise: false)
    }

    /// Add to Layout: a new pane when there's room, else a tab of the focused (or last) pane.
    func addFloatToLayout(_ id: String) {
        guard layout.isFloat(id) else { return }
        if localFullscreen == id { localFullscreen = nil }
        if layout.paneCount < capacity {
            let landscape = size.width >= size.height
            edit { $0.dockingAsPane(id, landscape: landscape) }
        } else if let target = lastFocusedPane.flatMap({ layout.orderedTileIDs.contains($0) ? $0 : nil }) ?? layout.orderedTileIDs.last {
            edit { $0.dockingAsTab(id, into: target) }
        }
        focus(id, raise: false)
    }

    // MARK: Moving and resizing (one undo step per gesture)

    /// A finger took the float's title, grabber or resize grip: it comes to the front.
    func beginFloatGesture(_ id: String) {
        guard layout.isFloat(id) else { return }
        floatGesture = id
        floatGestureStart = saved
        if dockingFloat == nil { floatMove = WorkspaceFloatMove(id, in: saved) }   // before it's raised
        raiseFloat(id)
        if active != id { focus(id, raise: false) }   // arranging only: the Mac window stays put
        // A fresh still to draw under the finger (the one kept may be a while old).
        let age = backdrop(id).map { Date().timeIntervalSince($0.receivedAt) } ?? .infinity
        requestBackdrop(id, refresh: age > 1)
    }

    /// The finger started moving or resizing float `id`: from now this device draws it (its last
    /// still, in its own view) and the Mac leaves it out, so it's never drawn twice: once under
    /// the finger and once, a moment behind, by the Mac. Needs `floatLift` and a recent still;
    /// without them the Mac keeps drawing it, as before.
    func liftFloat(_ id: String) {
        guard layout.isFloat(id) else { return }
        liftWanted.insert(id)
        guard canLiftFloats, !liftedFloats.contains(id), hasFreshStill(id) else { return }
        liftedFloats.insert(id)
        landingFloats[id] = nil
        sendNow()
    }
    /// A still older than this isn't drawn in place of the live window.
    static let liftStillMaxAge: TimeInterval = 6

    private func hasFreshStill(_ id: String) -> Bool {
        backdrop(id).map { Date().timeIntervalSince($0.receivedAt) < Self.liftStillMaxAge } ?? false
    }

    /// Let go (or the gesture ended): the Mac draws it again where it is;
    /// this device keeps drawing it until the Mac's frame with it is out (or `landingHold` passes).
    /// The caller sends the layout (the lift's end changes the float's view epoch).
    func landFloat(_ id: String) {
        liftWanted.remove(id)
        guard liftedFloats.remove(id) != nil else { return }
        let at = Date()
        landingFloats[id] = at
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.landingHold) { [weak self] in
            if let self, self.landingFloats[id] == at { self.landingFloats[id] = nil }
        }
    }

    /// Whether this device draws float `id` itself now (lifted, or landing).
    func drawsFloatHere(_ id: String) -> Bool {
        liftedFloats.contains(id) || landingFloats[id] != nil
    }

    /// Float `id`'s view (Fit or Fill, zoom, rotation) at `width` x `height` points, placed as the
    /// Mac composes it: what this device draws while it holds the float.
    func floatContentTransform(_ id: String, width: Double, height: Double) -> TileContentTransform? {
        guard let tile = layout.tiles[id], let source = windowSize(tile), width > 0, height > 0 else { return nil }
        return TileContentTransform(tile: WorkspaceRect(x: 0, y: 0, width: width, height: height), source: source,
                                    rotation: tile.rotation, fit: effectiveFit(id), zoom: tile.zoom ?? .identity)
    }

    /// The float's frame while the finger moves (kept usable; the Mac follows at most ~30 times a second).
    func updateFloatFrame(_ id: String, _ frame: WorkspaceRect) {
        let next = saved.settingFloatFrame(id, WorkspaceFloatGeometry.clamped(frame, in: size))
        guard next != saved else { return }
        if let start = floatGestureStart { history.record(start); floatGestureStart = nil }
        saved = next
        publish(); scheduleThrottledSend()
    }

    /// The gesture ended (the float settled where `frame` says, if given).
    func endFloatGesture(_ id: String, frame: WorkspaceRect? = nil) {
        if let frame { updateFloatFrame(id, frame) }
        floatGesture = nil
        floatGestureStart = nil
        if floatMove?.id == id, dockingFloat != id { floatMove = nil }
        landFloat(id)
        persist(); publish(); sendNow()
    }

    /// In front of the other floats. Presentation only (not an undo step); sent at once so the
    /// Mac hits the same window the finger sees.
    func raiseFloat(_ id: String) {
        let next = saved.raisingFloat(id)
        guard next != saved else { return }
        saved = next
        persist(); publish(); sendNow()
    }

    /// Size presets and accessibility Make Larger / Smaller: about its centre, keeping its shape.
    func scaleFloat(_ id: String, by factor: Double) {
        guard let f = layout.float(id) else { return }
        edit { $0.settingFloatFrame(id, WorkspaceFloatGeometry.scaled(f.frame, by: factor, in: size)) }
    }

    /// Small / Medium / Large: a share of the picture's width at the window's shape.
    func sizeFloat(_ id: String, widthShare: Double) {
        guard let f = layout.float(id), size.width > 0 else { return }
        let aspect = windowAspect(id) ?? (f.frame.width * size.width) / max(f.frame.height * size.height, 1)
        let w = size.width * widthShare, h = w / aspect
        let r = WorkspaceRect(x: f.frame.midX - w / size.width / 2, y: f.frame.midY - h / size.height / 2,
                              width: w / size.width, height: h / size.height)
        edit { $0.settingFloatFrame(id, WorkspaceFloatGeometry.clamped(r, in: size)) }
    }

    /// Size > Match Window: the float takes the window's shape as drawn (same area and centre),
    /// so Fit shows the whole window with no bars. The view (zoom, rotation) is kept.
    func matchWindowShape(_ id: String) {
        guard let f = layout.float(id), let a = windowAspect(id), size.width > 0 else { return }
        edit { $0.settingFloatFrame(id, WorkspaceFloatGeometry.matched(f.frame, aspect: a, in: size)) }
    }

    /// Accessibility Move Left / Right / Up / Down: a tenth of the picture per step.
    func nudgeFloat(_ id: String, dx: Double, dy: Double) {
        guard let f = layout.float(id) else { return }
        var r = f.frame
        r.x += dx; r.y += dy
        edit { $0.settingFloatFrame(id, WorkspaceFloatGeometry.clamped(r, in: size)) }
    }

    // MARK: Docking by circling while it moves

    /// One finger position of float `id`'s move by its title or grabber (global points, `time` in
    /// seconds). Circling switches between moving it and docking it into the panes
    /// (`WorkspaceFloatMove`); a shake, a zig-zag or an ordinary move never does. While it docks
    /// the finger moves the drag. Returns the switch it made, if any (one haptic each).
    @discardableResult
    func moveFloatFinger(_ id: String, to global: CGPoint, at time: TimeInterval) -> WorkspaceFloatMove.Switch? {
        guard var move = floatMove, move.id == id, layout.isFloat(id) else { return nil }
        let step = move.add(x: Double(global.x), y: Double(global.y), at: time)
        floatMove = move
        switch step {
        case .dock?: startDocking(move, at: global)
        case .float?: resumeMoving(id)
        case nil: break
        }
        if dockingFloat == id, dragsFloat(id) { moveDrag(to: global) }
        return step
    }

    /// Circling while moving it: the float folds into a card under the finger and the pane drop
    /// targets show, as for a pane drag. It goes back to where the move began, and it's lifted
    /// even without a recent still: the Mac leaves it out of its picture and input, and nothing
    /// here draws it, so the card is the only thing shown for it.
    private func startDocking(_ move: WorkspaceFloatMove, at global: CGPoint) {
        let id = move.id
        dockingFloat = id
        saved = saved.settingFloatFrame(id, move.frame)
        liftWanted.insert(id)
        if canLiftFloats { liftedFloats.insert(id); landingFloats[id] = nil }
        publish(); sendNow()
        beginDrag(.float(id), at: global)
    }

    /// Circling again while it docks: the card opens back into the float under the finger, which
    /// moves on as before (drawn here from its still; without a recent one the Mac draws it again).
    private func resumeMoving(_ id: String) {
        dockingFloat = nil
        if dragsFloat(id) { cancelDrag() }
        if liftedFloats.contains(id), !hasFreshStill(id) { liftedFloats.remove(id); sendNow() }
    }

    /// The finger let go of float `id` while it docks. On a pane target it docks there as a pane
    /// drag would (a tab, a new pane or a split; never replacing a window); on Remove from This
    /// Device it's removed here only (the Mac window stays open). Anywhere else (Cancel, outside
    /// the picture) it's put back as it was (frame, size, view, place among the floats) and the
    /// Mac draws it again. A dock or a removal is one undo step, a cancel none. True when the
    /// layout changed.
    @discardableResult
    func endDockingFloat(_ id: String) -> Bool {
        guard dockingFloat == id, let move = floatMove, move.id == id else { return false }
        putBack(move)
        let changed = dragsFloat(id) ? endDrag() : false
        finishDocking(id)
        return changed
    }

    /// The system cancelled the move while it docks (a call, Control Center): put back as it was.
    func cancelDockingFloat(_ id: String) {
        guard dockingFloat == id, let move = floatMove, move.id == id else { return }
        if dragsFloat(id) { cancelDrag() }
        putBack(move)
        finishDocking(id)
    }

    private func dragsFloat(_ id: String) -> Bool {
        if case .float(let f)? = drag?.item { return f == id }
        return false
    }

    /// The float as the finger found it, and no undo step left for a move that came to nothing.
    private func putBack(_ move: WorkspaceFloatMove) {
        saved = move.restoring(saved)
        history.forget(saved)
        publish()
    }

    private func finishDocking(_ id: String) {
        dockingFloat = nil
        floatMove = nil
        if saved.isFloat(id) {
            endFloatGesture(id)   // the Mac draws it again; this device until its frame is out
        } else {
            // Docked or removed: no float left to land.
            liftedFloats.remove(id); liftWanted.remove(id); landingFloats[id] = nil
            floatGesture = nil; floatGestureStart = nil
            persist(); publish(); sendNow()
        }
    }

    // MARK: Tucking

    /// Hidden at an edge. Its capture stops while hidden; the Mac window is untouched. It waits
    /// at its own size flush with that edge where its strip is (`frame`, the view's place for it;
    /// nil: flush with the picture's edge at `offset`), so pulling it back out is a straight
    /// slide back to that place.
    func tuckFloat(_ id: String, edge: WorkspaceEdge, offset: Double, frame: WorkspaceRect? = nil) {
        guard let f = layout.float(id) else { return }
        // A fresh still for its strip at the edge, asked for while it's still sent (the Mac
        // answers from the capture that stops with the tuck).
        let age = backdrop(id).map { Date().timeIntervalSince($0.receivedAt) } ?? .infinity
        if age > 2 { requestBackdrop(id, refresh: true) }
        let waiting = frame ?? WorkspaceFloatGeometry.tuckedFrame(f.frame, edge: edge, along: offset, in: size)
        edit { $0.tuckingFloat(id, edge: edge, offset: WorkspaceFloatMotion.along(waiting, edge), frame: waiting) }
        refocus(after: id)
    }

    /// A tucked float isn't captured, so one without a still of its own (after a reconnect, which
    /// drops the stills) gets its window's thumbnail instead, as Stage Peek asks for them (read
    /// only): its strip then shows the window itself, not only its icon. Asked again only after a
    /// few seconds.
    private func requestTuckedStills() {
        guard windowMode, let c = catalog else { return }
        let now = Date()
        let ids = saved.floats.filter { $0.tuck != nil && backdrop($0.tile) == nil }
            .compactMap { saved.tiles[$0.tile]?.source }
            .filter { s in !s.isDisplay && thumbnails[s.windowID] == nil && c.windows.contains { $0.id == s.windowID } }
            .map(\.windowID)
            .filter { id in tuckedStillAskedAt[id].map { now.timeIntervalSince($0) > 5 } ?? true }
        guard !ids.isEmpty else { return }
        for id in ids { tuckedStillAskedAt[id] = now }
        _ = send(WorkspaceRequests.thumbnails(ids, maxWidth: 560, icons: []))
    }

    /// A tucked float comes back with a slide drawn on this device: it's shown again now (so its
    /// capture starts during the slide) but lifted where the Mac can lift floats, so the Mac
    /// leaves it out until it has landed (`endFloatGesture`) and it's never on screen twice.
    /// `frame`: where it comes back to (nil: where it waited). Its still may be old: it's only
    /// drawn for the moment of the slide.
    func beginRestoringFloat(_ id: String, frame: WorkspaceRect? = nil) {
        guard layout.isFloat(id) || saved.isFloat(id) else { return }
        untuckFloat(id, frame: frame)
        guard canLiftFloats, saved.float(id)?.tuck == nil, !liftedFloats.contains(id) else { return }
        liftedFloats.insert(id)
        landingFloats[id] = nil
        sendNow()
    }

    /// Back where it waited (or at `frame`), in front and focused. The other floats stay as they
    /// are, on a phone too.
    func untuckFloat(_ id: String, frame: WorkspaceRect? = nil) {
        guard layout.isFloat(id) || saved.isFloat(id) else { return }
        edit { $0.untuckingFloat(id, frame: frame) }
        focus(id, raise: false)
    }

    /// A strip slid along its edge (no undo step; tucked floats aren't sent): the float waits
    /// there now, as far from the edge as before, and comes back out there.
    func moveTuckTab(_ id: String, offset: Double) {
        guard let i = saved.floats.firstIndex(where: { $0.tile == id }), let tuck = saved.floats[i].tuck else { return }
        var f = saved.floats[i].frame
        let along = offset.isFinite ? min(max(offset, 0), 1) : 0.5
        if tuck.edge.axis == .horizontal { f.y = along - f.height / 2 } else { f.x = along - f.width / 2 }
        f = WorkspaceFloatGeometry.clamped(f, in: size)
        saved.floats[i].frame = f
        saved.floats[i].tuck?.offset = WorkspaceFloatMotion.along(f, tuck.edge)
        persist(); publish()
    }

    /// Removes a float from this device (Undo brings it back). The Mac window stays open.
    func removeFloat(_ id: String) {
        guard layout.isFloat(id) else { return }
        if localFullscreen == id { localFullscreen = nil }
        edit { $0.removing(id) }
        refocus(after: id)
    }

    /// The focused float went away (tucked, removed): typing goes to the frontmost shown float,
    /// else the pane focused before it. Nothing is sent to the Mac but the focus.
    private func refocus(after id: String) {
        guard active == id || requestedFocus == id else { return }
        let next = layout.visibleFloatIDs.last { $0 != id }
            ?? lastFocusedPane.flatMap { layout.orderedTileIDs.contains($0) ? $0 : nil }
            ?? layout.orderedTileIDs.first
        if let next { focus(next, raise: false) }
    }

    // MARK: Drag placement (Pane | Floating)

    private func initialPlacement(for item: WorkspaceDrag.Item) -> WorkspacePlacement {
        switch item {
        case .window, .app: return defaultPlacement
        case .pane: return .pane
        case .float: return .pane
        }
    }

    /// Whether `item` may land with `placement`.
    func canPlace(_ item: WorkspaceDrag.Item, _ placement: WorkspacePlacement) -> Bool {
        guard placement == .float else { return true }
        guard canOpenFloats else { return false }   // never from Extend
        switch item {
        case .window(let w): return !WorkspaceSource.isDisplayKey(w.id)
        case .app: return true
        case .pane(let id, let tab): return canFloat(pane: id, tab: tab)
        case .float: return false
        }
    }

    /// Switches the drag between Pane and Floating placement (circling, or the drag's control).
    /// True when it switched.
    @discardableResult
    func toggleDragPlacement() -> Bool {
        guard let d = drag else { return false }
        let next: WorkspacePlacement = d.placement == .pane ? .float : .pane
        guard canPlace(d.item, next) else { return false }
        drag?.placement = next
        return true
    }

    /// Where a Floating-placement drop would put the window (picture-normalized), for its preview.
    func floatDropPreview(forGlobal p: CGPoint) -> WorkspaceRect? {
        drag.flatMap { floatDropFrame($0, at: p) }
    }

    private func floatDropFrame(_ d: WorkspaceDrag, at p: CGPoint) -> WorkspaceRect? {
        guard d.placement == .float, !overCancelZone(p) else { return nil }
        let picture = windowMode ? pictureGlobal : desktopPictureGlobal
        guard picture.width > 0, picture.height > 0, picture.contains(p) else { return nil }
        let center = WorkspacePoint(x: (p.x - picture.minX) / picture.width, y: (p.y - picture.minY) / picture.height)
        let aspect: Double? = {
            switch d.item {
            case .window(let w): return w.width > 0 && w.height > 0 ? Double(w.width) / Double(w.height) : nil
            case .pane(let id, let tab):
                if let tab, let s = layout.tiles[id]?.tabs[safe: tab], let w = windowItem(s), w.width > 0, w.height > 0 { return Double(w.width) / Double(w.height) }
                return windowAspect(id)
            default: return nil
            }
        }()
        let space = windowMode ? size : WorkspaceSize(width: picture.width, height: picture.height)
        return WorkspaceFloatGeometry.defaultFrame(aspect: aspect, in: space, center: center)
    }

    /// A drop in Floating placement: the window floats where it was let go.
    fileprivate func dropFloating(_ d: WorkspaceDrag) -> Bool {
        guard let frame = floatDropFrame(d, at: d.location) else { return false }
        return floatItem(d.item, at: WorkspacePoint(x: frame.midX, y: frame.midY))
    }

    /// Floats a dragged item, centred at `center` (nil: where a new float opens).
    fileprivate func floatItem(_ item: WorkspaceDrag.Item, at center: WorkspacePoint?) -> Bool {
        switch item {
        case .window(let w):
            openFloating(w, at: center)
            return true
        case .app(let app):
            let windows = (catalog?.windows ?? []).filter { $0.bundleID == app.bundleID }
            if windows.count == 1 { openFloating(windows[0], at: center); return true }
            appDrop = AppDrop(app: app, windows: windows, target: .replace(tile: Self.noDesktop, preview: .unit),
                              floatAt: center ?? WorkspacePoint(x: 0.5, y: 0.5))
            return !windows.isEmpty
        case .pane(let id, let tab):
            floatPane(id, tab: tab, at: center)
            return true
        case .float:
            return false
        }
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

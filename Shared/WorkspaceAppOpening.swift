import Foundation

// The window picker ("Choose a window for this tile") and Mac apps that have no window to show:
// what a search lists, when to ask the Mac for its apps, and opening one into the tile the
// picker was opened for. Pure and tested; WorkspaceModel feeds it the Mac's replies, listings
// and the session's control state. The Mac launches (`appLaunch`, which it refuses without
// control); this only decides which window goes where, and never picks one of several itself.

/// What the picker lists for a search: the Mac's open windows, and apps to open.
enum WorkspacePickerSearch {
    /// An app with no listed window: not running, or running with no window that can be shown.
    struct AppToOpen: Equatable, Sendable, Identifiable {
        var bundleID: String
        var name: String
        /// Running, with no window to show (opening it asks it for a new one).
        var running: Bool
        var lastUsed: Date?
        var id: String { bundleID }
    }

    struct Results: Equatable, Sendable {
        var windows: [CatalogWindowItem]
        var apps: [AppToOpen]
        /// More apps match than are listed (search narrows them).
        var moreApps = false
    }

    /// Apps listed with an empty search: running ones without a window, then recently used.
    static let browseLimit = 12
    static let searchLimit = 40

    /// Windows by title and app name, as Stage Peek's search. Apps from the Mac's full list
    /// (`appCatalog`) and its running apps, once per bundle id, only when no window of theirs is
    /// listed (those show as windows). An empty search lists every window and a few apps.
    static func results(_ query: String, windows: [CatalogWindowItem], running: [CatalogAppItem],
                        installed: [MacAppItem]) -> Results {
        let withWindows = Set(windows.map(\.bundleID))
        var byBundle: [String: AppToOpen] = [:]
        for a in installed where !a.bundleID.isEmpty && !withWindows.contains(a.bundleID) {
            byBundle[a.bundleID] = AppToOpen(bundleID: a.bundleID, name: a.name.isEmpty ? a.bundleID : a.name,
                                             running: false, lastUsed: a.lastUsed)
        }
        // Running now (the window listing is fresher than the app list's flags).
        for r in running where !r.bundleID.isEmpty && !withWindows.contains(r.bundleID) {
            if byBundle[r.bundleID] == nil {
                byBundle[r.bundleID] = AppToOpen(bundleID: r.bundleID, name: r.name.isEmpty ? r.bundleID : r.name, running: true)
            } else {
                byBundle[r.bundleID]?.running = true
            }
        }
        let all = Array(byBundle.values)
        let q = WorkspaceSearch.normalize(query)
        guard !q.isEmpty else {
            let open = all.filter(\.running).sorted(by: byName)
            let recent = all.filter { !$0.running && $0.lastUsed != nil }.sorted { $0.lastUsed! > $1.lastUsed! }
            let listed = Array((open + recent).prefix(browseLimit))
            return Results(windows: windows, apps: listed, moreApps: all.count > listed.count)
        }
        let found = WorkspaceSearch.search(q, apps: [], windows: windows).windows
        var scored: [(AppToOpen, Int)] = []
        for a in all {
            let s = max(WorkspaceSearch.score(q, a.name), WorkspaceSearch.score(q, a.bundleID) * 6 / 10)
            if s > 0 { scored.append((a, s + (a.running ? 15 : 0))) }
        }
        scored.sort { l, r in l.1 != r.1 ? l.1 > r.1 : byName(l.0, r.0) }
        return Results(windows: found, apps: scored.prefix(searchLimit).map(\.0), moreApps: scored.count > searchLimit)
    }

    private static func byName(_ a: AppToOpen, _ b: AppToOpen) -> Bool {
        a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
    }
}

/// When to ask the Mac for its launchable apps (`appCatalogRequest`). Asked when a browser
/// opens (the window picker, Stage Peek, Launchpad), with the revision this device holds, so an
/// unchanged list costs only a `same` reply; never on the window listing's refresh ticks. An ask
/// that got no answer is repeated a few times while the browser stays open.
struct AppInventoryRequestPlanner: Equatable, Sendable {
    /// Opened again this soon after an answer: nothing is asked.
    static let recentEnough: TimeInterval = 10
    static let retryAfter: TimeInterval = 5
    static let maxRetries = 3

    /// The ask still waiting for its answer.
    private(set) var askedAt: TimeInterval?
    private(set) var answeredAt: TimeInterval?
    private(set) var retries = 0

    /// A browser opened: ask, unless an ask is already out or an answer just came.
    mutating func opened(now: TimeInterval) -> Bool {
        if let at = askedAt, now - at < Self.retryAfter { return false }
        if askedAt == nil, let a = answeredAt, now - a < Self.recentEnough { return false }
        askedAt = now
        retries = 0
        return true
    }

    /// A refresh tick while a browser is open: only an unanswered ask is repeated.
    mutating func tick(now: TimeInterval) -> Bool {
        guard let at = askedAt, retries < Self.maxRetries, now - at >= Self.retryAfter else { return false }
        askedAt = now
        retries += 1
        return true
    }

    mutating func answered(now: TimeInterval) {
        answeredAt = now
        askedAt = nil
        retries = 0
    }

    /// A new connection or another Mac: asked again on the next open.
    mutating func reset() { self = AppInventoryRequestPlanner() }
}

/// Opening an app from the picker into its tile: ask the Mac to launch exactly that app (once
/// control is granted), wait for a new window of that app, then put it in that tile. One new
/// window goes straight in; several: the person picks; none in time, a failure, control ending
/// before the Mac answered, or the tile changing meanwhile: it stops and says so. Nothing else in
/// the layout changes, and no other app's window is ever taken.
struct WorkspaceAppOpening: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        /// Control was asked for (Request Control); the app opens once the Mac allows it.
        case awaitingControl
        /// `appLaunch` sent; waiting for the Mac's answer.
        case launching
        /// The Mac opened it; waiting for its new window.
        case waitingForWindow
        /// Several new windows: the person picks one (never chosen here).
        case choosing([CatalogWindowItem])
        case placed(CatalogWindowItem)
        case failed(Failure)
    }

    enum Failure: String, Equatable, Sendable {
        /// The Mac answered that it couldn't open the app.
        case launchFailed
        /// No answer from the Mac in time (it ignores a launch without control).
        case noAnswer
        /// Opened, but no window it can show appeared in time.
        case noWindow
        /// Control wasn't given (declined, never answered, or requests are turned off).
        case controlDenied
        /// Control ended before the Mac opened the app.
        case controlEnded
        /// The tile was removed or shows another window now.
        case tileChanged
        case disconnected
        /// The Mac locked before the window could be placed: nothing is placed later, from an
        /// answer or a listing that comes after the unlock.
        case macLocked

        /// Worth asking again as it is (the same app, the same tile).
        var retryable: Bool { ![.tileChanged, .disconnected].contains(self) }
    }

    /// The session's control of the Mac, as Request Control reports it.
    enum Control: Equatable, Sendable {
        case allowed
        /// The Mac's owner is being asked.
        case requesting
        /// Not now (the owner said no, or the ask timed out).
        case denied
        /// This device's requests are turned off on the Mac.
        case refused
        /// No control and nothing asked (or no live session).
        case off
    }

    /// What the model does next.
    enum Step: Equatable, Sendable {
        case none
        /// Send `appLaunch` for `bundleID` now.
        case launch
        case place(CatalogWindowItem)
        case choose([CatalogWindowItem])
        case fail(Failure)
    }

    static let controlTimeout: TimeInterval = 60
    static let answerTimeout: TimeInterval = 15
    static let windowTimeout: TimeInterval = 20
    /// After the first new window: a moment for others opening with it, so one isn't taken
    /// while its siblings are still on their way.
    static let settle: TimeInterval = 1
    /// From here the picker says it's taking a while.
    static let slowAfter: TimeInterval = 5

    /// Where an app dragged from Stage Peek (or Launchpad) was dropped: its window goes there,
    /// exactly as a dropped window would. `panes`: the layout's panes when it was dropped, since a
    /// split or an empty slot names a position that only means the same while they're unchanged.
    struct Drop: Equatable, Sendable {
        var target: WorkspaceWindowDrop
        /// Dropped in Floating placement: it floats here (picture-normalized).
        var floatAt: WorkspacePoint?
        var panes: [String]
    }

    let bundleID: String
    let name: String
    /// The tile the picker was opened for (nil: the whole overview, where a window goes as a
    /// picked window would), or the pane a dropped app landed on.
    let tile: String?
    /// Set when the app was dropped rather than picked: where its window goes.
    var drop: Drop? = nil
    /// What that tile showed when the person asked.
    let tileSource: WorkspaceSource?
    private(set) var phase: Phase
    /// The app's windows listed when the launch went out: none of them is "its new window".
    private(set) var known: Set<UInt32> = []
    private(set) var startedAt: TimeInterval
    private(set) var phaseSince: TimeInterval
    private(set) var firstSeenAt: TimeInterval?
    private(set) var sawRequesting = false
    /// The last pick named a window that's gone: the choice was refreshed.
    private(set) var pickWasStale = false
    /// Show a Window on Mac: the launch asks the Mac to bring the app forward, which makes an app
    /// that's running without a window open one (a background open doesn't, e.g. Ghostty).
    private(set) var reveal = false

    /// The person confirmed opening `bundleID`. With control: launch now; otherwise wait for it.
    static func start(bundleID: String, name: String, tile: String?, tileSource: WorkspaceSource?, drop: Drop? = nil,
                      reveal: Bool = false, control: Control, windows: [CatalogWindowItem],
                      now: TimeInterval) -> (WorkspaceAppOpening, Step) {
        var o = WorkspaceAppOpening(bundleID: bundleID, name: name, tile: tile, drop: drop, tileSource: tileSource,
                                    phase: .awaitingControl, startedAt: now, phaseSince: now)
        o.reveal = reveal
        if control == .refused { o.phase = .failed(.controlDenied); return (o, .fail(.controlDenied)) }
        if control == .requesting { o.sawRequesting = true }
        guard control == .allowed else { return (o, .none) }
        o.beginLaunch(windows, now: now)
        return (o, .launch)
    }

    var isWaiting: Bool {
        switch phase {
        case .awaitingControl, .launching, .waitingForWindow: return true
        default: return false
        }
    }

    var isFinished: Bool {
        switch phase {
        case .placed, .failed: return true
        default: return false
        }
    }

    /// Still opening after `slowAfter`: the picker says the app is taking a while.
    func isSlow(now: TimeInterval) -> Bool {
        (phase == .launching || phase == .waitingForWindow) && now - startedAt >= Self.slowAfter
    }

    /// The tile still shows what it showed when the person asked (always true without a tile).
    func tileUnchanged(_ current: WorkspaceTile?) -> Bool {
        guard tile != nil else { return true }
        guard let current else { return false }
        return current.source?.host == tileSource?.host && current.source?.windowID == tileSource?.windowID
    }

    /// Windows of this app the Mac lists now that weren't listed when the launch went out.
    func newWindows(_ windows: [CatalogWindowItem]) -> [CatalogWindowItem] {
        windows.filter { $0.bundleID == bundleID && !known.contains($0.id) && !WorkspaceSource.isDisplayKey($0.id) }
    }

    /// The Mac's `appLaunchResult` for this app. `window` false: the app was already running
    /// without a window and a background open didn't give it one, so none is coming (no point
    /// waiting `windowTimeout`); Show a Window on Mac is what can. Nil (older Macs, a new launch,
    /// a reveal): wait for the window as before.
    mutating func launchAnswered(ok: Bool, window: Bool? = nil, now: TimeInterval) -> Step {
        guard phase == .launching else { return .none }
        guard ok else { return fail(.launchFailed) }
        if window == false, !reveal { return fail(.noWindow) }
        phase = .waitingForWindow
        phaseSince = now
        return .none
    }

    /// A new listing, or time passing (`windows`: the latest listing).
    mutating func advance(windows: [CatalogWindowItem], now: TimeInterval, control: Control, tileUnchanged: Bool) -> Step {
        guard !isFinished else { return .none }
        guard tileUnchanged else { return fail(.tileChanged) }
        switch phase {
        case .awaitingControl:
            switch control {
            case .allowed:
                beginLaunch(windows, now: now)
                return .launch
            case .requesting: sawRequesting = true
            case .refused: return fail(.controlDenied)
            case .denied: if sawRequesting { return fail(.controlDenied) }
            case .off: break
            }
            return now - phaseSince >= Self.controlTimeout ? fail(.controlDenied) : .none
        case .launching:
            let new = newWindows(windows)
            guard !new.isEmpty else {
                // Without control the Mac doesn't launch (and says nothing): stop waiting for it.
                if control != .allowed { return fail(.controlEnded) }
                return now - phaseSince >= Self.answerTimeout ? fail(.noAnswer) : .none
            }
            // Its window showed before the answer: it's open.
            phase = .waitingForWindow
            phaseSince = now
            return settled(new, now: now)
        case .waitingForWindow:
            // Opened already: control ending now changes nothing (showing a window needs none).
            let new = newWindows(windows)
            guard !new.isEmpty else {
                firstSeenAt = nil
                return now - phaseSince >= Self.windowTimeout ? fail(.noWindow) : .none
            }
            return settled(new, now: now)
        case .choosing(let shown):
            let new = newWindows(windows)
            guard !new.isEmpty else { return fail(.noWindow) }
            guard Self.identities(new) != Self.identities(shown) else { return .none }
            phase = .choosing(new)
            return .choose(new)
        case .placed, .failed:
            return .none
        }
    }

    /// The person picked one of the new windows: placed only if it's still that window (and the
    /// tile is still the one they asked for).
    mutating func pick(_ id: UInt32, generation: UInt64, windows: [CatalogWindowItem], tileUnchanged: Bool) -> Step {
        guard case .choosing = phase else { return .none }
        guard tileUnchanged else { return fail(.tileChanged) }
        let new = newWindows(windows)
        if let w = new.first(where: { $0.id == id && $0.generation == generation }) {
            phase = .placed(w)
            return .place(w)
        }
        pickWasStale = true
        guard !new.isEmpty else { return fail(.noWindow) }
        phase = .choosing(new)
        return .choose(new)
    }

    /// The launch couldn't be sent (no connection).
    mutating func launchNotSent() -> Step { phase == .launching ? fail(.noAnswer) : .none }

    /// The connection ended while waiting.
    mutating func disconnected() -> Step { isFinished ? .none : fail(.disconnected) }

    /// The Mac locked: waiting or asking which window (with its titles) ends.
    mutating func macLocked() -> Step { isFinished ? .none : fail(.macLocked) }

    private mutating func beginLaunch(_ windows: [CatalogWindowItem], now: TimeInterval) {
        known = Set(windows.filter { $0.bundleID == bundleID }.map(\.id))
        phase = .launching
        startedAt = now
        phaseSince = now
        firstSeenAt = nil
    }

    private mutating func settled(_ new: [CatalogWindowItem], now: TimeInterval) -> Step {
        if firstSeenAt == nil { firstSeenAt = now }
        guard let first = firstSeenAt, now - first >= Self.settle else { return .none }
        if new.count == 1 {
            phase = .placed(new[0])
            return .place(new[0])
        }
        phase = .choosing(new)
        return .choose(new)
    }

    private mutating func fail(_ f: Failure) -> Step {
        phase = .failed(f)
        return .fail(f)
    }

    private static func identities(_ ws: [CatalogWindowItem]) -> [String] { ws.map { "\($0.id)#\($0.generation)" } }
}

extension WorkspaceAppOpening.Control {
    /// From the session's live state and the Mac's decision on Request Control.
    init(live: Bool, state: SessionInputWireState) {
        guard live else { self = .off; return }
        switch state {
        case .allowed: self = .allowed
        case .requesting: self = .requesting
        case .notAllowed: self = .denied
        case .requestsDisabled: self = .refused
        case .off: self = .off
        }
    }
}

extension WorkspaceWindowDrop {
    /// The pane a drop lands on (replace or add a tab); nil for a new pane (split, empty slot).
    var tile: String? {
        switch self {
        case .replace(let t, _), .tab(let t, _): return t
        case .split, .emptySlot: return nil
        }
    }
}

extension WorkspaceSearch {
    /// The Mac's app list with each app's running state and window count taken from the latest
    /// window listing, which is fresher: the list is asked for once when a browser opens, so an
    /// app opened since still said "Not running" next to its own window (owner, 2026-11-07,
    /// IMG_2319). Order is kept so nothing jumps while someone browses. Nil: nothing changed.
    static func reconciled(_ apps: [MacAppItem], windows: [CatalogWindowItem], running: [CatalogAppItem]) -> [MacAppItem]? {
        let live = Set(running.map(\.bundleID))
        var counts: [String: Int] = [:]
        for w in windows where !WorkspaceSource.isDisplayKey(w.id) { counts[w.bundleID, default: 0] += 1 }
        var changed = false
        let out = apps.map { a -> MacAppItem in
            let n = counts[a.bundleID] ?? 0
            let isRunning = live.contains(a.bundleID) || n > 0
            guard a.running != isRunning || a.windowCount != n else { return a }
            changed = true
            return MacAppItem(bundleID: a.bundleID, name: a.name, running: isRunning, windowCount: n, lastUsed: a.lastUsed)
        }
        return changed ? out : nil
    }
}

import Foundation

// Pane menu bar (PROTOCOL.md 6.13): the menus of the app the focused Window-mode pane shows,
// read from the Mac one level at a time and pressed there. Control only; the Mac never sends
// the Apple menu.

struct AppMenuEntry: Equatable, Identifiable, Sendable {
    var index: Int
    var title: String
    var enabled = true
    var checked = false
    var separator = false
    var hasSubmenu = false
    var shortcut: String?
    var id: Int { index }
}

struct AppMenuReply: Sendable {
    var tile: String?
    var path: [Int]
    var app: String
    var items: [AppMenuEntry]
    var ok: Bool
    var error: String?
    var req: Int?

    static func parse(_ obj: [String: Any]) -> AppMenuReply? {
        let path = ((obj["path"] as? [Int]) ?? []).prefix(8).map { $0 }
        let items = ((obj["items"] as? [[String: Any]]) ?? []).prefix(160).compactMap { o -> AppMenuEntry? in
            guard let i = o["i"] as? Int, i >= 0, i < 500 else { return nil }
            if o["sep"] as? Bool == true { return AppMenuEntry(index: i, title: "", separator: true) }
            guard let t = o["t"] as? String, !t.isEmpty else { return nil }
            return AppMenuEntry(index: i, title: String(t.prefix(120)), enabled: o["on"] as? Bool ?? true,
                                checked: o["mark"] as? Bool ?? false, hasSubmenu: o["sub"] as? Bool ?? false,
                                shortcut: (o["key"] as? String).map { String($0.prefix(12)) })
        }
        return AppMenuReply(tile: (obj["tile"] as? String).map { String($0.prefix(32)) }, path: Array(path),
                            app: String((obj["app"] as? String ?? "").prefix(80)), items: Array(items),
                            ok: obj["ok"] as? Bool ?? true, error: (obj["error"] as? String).map { String($0.prefix(32)) },
                            req: obj["req"] as? Int)
    }
}

enum AppMenuRequests {
    static func read(tile: String, path: [Int], req: Int) -> [String: Any] {
        ["type": WireMessage.menuRequest, "tile": tile, "path": path, "req": req]
    }

    static func press(tile: String, path: [Int], titles: [String], req: Int) -> [String: Any] {
        ["type": WireMessage.menuPress, "tile": tile, "path": path, "titles": titles, "req": req]
    }
}

@MainActor
final class AppMenuModel: ObservableObject {
    /// One open menu (or submenu) in the drop-down.
    struct Level: Equatable {
        var path: [Int]
        var titles: [String]
        var title: String
        var items: [AppMenuEntry] = []
        var loading = true
        var error: String?
    }

    /// The Mac offers pane menus (welcome feature `menus`).
    @Published private(set) var available = false
    /// The user's choice: the bar shows on the focused pane (default on).
    @Published var barShown: Bool { didSet { defaults.set(barShown, forKey: Self.shownKey) } }
    /// The pane whose app's menus are shown (nil: none, e.g. no control or a desktop pane).
    @Published private(set) var tile: String?
    @Published private(set) var app = ""
    @Published private(set) var top: [AppMenuEntry] = []
    /// `control`, `accessibility`, `unavailable`, `notFound` for the menu bar itself.
    @Published private(set) var topError: String?
    /// The drop-down: the open menu, then any submenus. Empty when closed.
    @Published private(set) var open: [Level] = []
    /// A press that didn't happen (the menu changed, or control went away).
    @Published private(set) var failed: String?

    var send: ([String: Any]) -> Bool = { _ in false }

    private let defaults: UserDefaults
    private var bundle: String?
    private var req = 0
    private var topReq: Int?
    private var levelReq: Int?
    private var failedTask: Task<Void, Never>?

    static let shownKey = "workspace.menuBar"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        barShown = defaults.object(forKey: Self.shownKey) as? Bool ?? true
    }

    func setAvailable(_ value: Bool) {
        available = value
        if !value { reset() }
    }

    func reset() {
        tile = nil; bundle = nil; app = ""; top = []; topError = nil; open = []; topReq = nil; levelReq = nil
    }

    /// The focused pane (and its app) changed, or control came or went.
    /// The app the focused pane shows now (its name as the Mac lists it): a reply for another app is
    /// from before a tab switch reached the Mac, so it is asked again instead of shown.
    private var expectedApp: String?
    private var staleRetries = 0

    func sync(tile newTile: String?, bundle newBundle: String?, appName: String? = nil, enabled: Bool) {
        expectedApp = appName.flatMap { $0.isEmpty ? nil : $0 }
        guard available, enabled, let newTile, let newBundle, !newBundle.isEmpty else {
            if tile != nil { reset() }
            return
        }
        guard newTile != tile || newBundle != bundle else { return }
        tile = newTile
        bundle = newBundle
        staleRetries = 0
        top = []
        topError = nil
        open = []
        let r = nextReq()
        topReq = r
        _ = send(AppMenuRequests.read(tile: newTile, path: [], req: r))
    }

    /// Ask again (an app's menus can change, e.g. after its window changed).
    func refresh() {
        guard let tile else { return }
        let r = nextReq()
        topReq = r
        _ = send(AppMenuRequests.read(tile: tile, path: [], req: r))
    }

    func openMenu(_ e: AppMenuEntry) {
        guard tile != nil, !e.separator else { return }
        if open.first?.path == [e.index] { return close() }
        open = []
        push(path: [e.index], titles: [e.title], title: e.title)
    }

    func openSubmenu(_ e: AppMenuEntry) {
        guard let level = open.last, e.hasSubmenu, e.enabled else { return }
        push(path: level.path + [e.index], titles: level.titles + [e.title], title: e.title)
    }

    func back() { if open.count > 1 { open.removeLast(); levelReq = nil } else { close() } }
    func close() { open = []; levelReq = nil }

    /// Presses a menu item on the Mac (the Mac brings the pane's window forward first, like a click).
    func press(_ e: AppMenuEntry) {
        guard let tile, let level = open.last, e.enabled, !e.separator, !e.hasSubmenu else { return }
        _ = send(AppMenuRequests.press(tile: tile, path: level.path + [e.index], titles: level.titles + [e.title], req: nextReq()))
        close()
    }

    private func push(path: [Int], titles: [String], title: String) {
        guard let tile else { return }
        open.append(Level(path: path, titles: titles, title: title))
        let r = nextReq()
        levelReq = r
        _ = send(AppMenuRequests.read(tile: tile, path: path, req: r))
    }

    func apply(_ r: AppMenuReply) {
        guard r.tile == nil || r.tile == tile else { return }
        if r.path.isEmpty {
            guard r.req == nil || r.req == topReq else { return }
            if r.ok, AppMenuModel.isStale(replyApp: r.app, expected: expectedApp), staleRetries < 3 {
                // The Mac answered for the pane's previous tab: ask again once it has the new window.
                staleRetries += 1
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.refresh() }
                return
            }
            if r.ok { app = r.app; top = r.items; topError = nil } else { top = []; topError = r.error ?? "unavailable" }
            return
        }
        guard r.req == levelReq, let i = open.lastIndex(where: { $0.path == r.path }) else { return }
        open[i].loading = false
        if r.ok { open[i].items = r.items; open[i].error = nil } else { open[i].error = r.error ?? "unavailable" }
    }

    func applyResult(ok: Bool, error: String?) {
        guard !ok else { return }
        failed = error ?? "changed"
        failedTask?.cancel()
        failedTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else { return }
            self?.failed = nil
        }
        refresh()
    }

    /// A top-level reply names another app than the pane shows.
    static func isStale(replyApp: String, expected: String?) -> Bool {
        guard let expected, !replyApp.isEmpty else { return false }
        return replyApp.compare(expected, options: [.caseInsensitive, .diacriticInsensitive]) != .orderedSame
    }

    private func nextReq() -> Int { req &+= 1; if req > 1_000_000_000 { req = 1 }; return req }
}

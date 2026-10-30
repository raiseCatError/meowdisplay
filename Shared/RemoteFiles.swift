import CoreGraphics
import Foundation

// Remote Finder on the receiver (PROTOCOL.md 6.12): a Finder-like browser of what the Mac's
// owner allowed this device to reach. Everything is read and checked on the Mac; this side
// asks, draws, caches a bounded number of previews and moves files through `RemoteTransferQueue`.
// What it may change follows the Mac's grant (`state.grant`); the Mac refuses anything else.

enum RemoteFileKind: String, Sendable {
    case folder, app, image, video, audio, pdf, archive, text, document, file

    /// Quick Look can draw a useful still of it.
    var hasThumbnail: Bool { [.image, .video, .pdf, .document].contains(self) }
}

struct RemoteFileEntry: Equatable, Identifiable, Sendable {
    var name: String
    var isDirectory: Bool
    var kind: RemoteFileKind
    var size: Int?
    var modified: Date?
    /// Search results: the folder it is in, below `root`.
    var location: [String]?
    var root: String?
    var created: Date?
    var hidden = false
    /// The Mac can't write it.
    var readOnly = false

    var id: String { (root ?? "") + "/" + (location ?? []).joined(separator: "/") + "/" + name }
}

struct RemoteFileRootItem: Equatable, Identifiable, Sendable {
    var id: String
    var name: String
}

/// One `files` message from the Mac, parsed defensively and bounded.
struct RemoteFilesReply: Sendable {
    var op: String
    var req: Int?
    var ok: Bool
    var error: String?
    var state: String?
    var roots: [RemoteFileRootItem] = []
    var root: String?
    var path: [String] = []
    var entries: [RemoteFileEntry] = []
    var truncated = false
    var complete = true
    var query: String?
    var text: String?
    var image: Data?
    var name: String?
    /// Transfers (6.12): the Mac's transfer id, an offset, a size, a part, a range digest.
    var x: Int?
    var offset: Int64?
    var length: Int?
    var size: Int64?
    var data: Data?
    var sha: String?
    var mod: Int?
    var mime: String?
    var uti: String?
    var skipped = false
    var suggest: String?
    var need: String?
    var token: String?
    var grant: RemoteFilesGrant?
    var info: RemoteFileInfo?
    var apps: [RemoteOpenWithApp] = []

    static let maxBase64 = 3_000_000   // a 1600-sided JPEG preview

    /// One path component from the Mac that is safe to use on this device: not empty, not `.`
    /// or `..`, no separator or NUL.
    static func isSafeName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
    }

    /// A reply made here: the request failed before the Mac answered.
    static func failure(_ op: String, _ code: String) -> RemoteFilesReply {
        RemoteFilesReply(op: op, req: nil, ok: false, error: code, state: nil)
    }

    static func parse(_ obj: [String: Any]) -> RemoteFilesReply? {
        guard let op = obj["op"] as? String, op.count <= 16 else { return nil }
        func str(_ k: String, _ limit: Int = 255) -> String? { (obj[k] as? String).map { String($0.prefix(limit)) } }
        func names(_ v: Any?) -> [String] { ((v as? [String]) ?? []).prefix(64).map { String($0.prefix(255)) } }
        var r = RemoteFilesReply(op: op, req: obj["req"] as? Int, ok: obj["ok"] as? Bool ?? (obj["error"] == nil),
                                 error: str("error", 32), state: str("state", 16))
        r.roots = ((obj["roots"] as? [[String: Any]]) ?? []).prefix(32).compactMap { o in
            guard let id = o["id"] as? String, !id.isEmpty else { return nil }
            return RemoteFileRootItem(id: String(id.prefix(64)), name: String((o["name"] as? String ?? id).prefix(120)))
        }
        r.root = str("root", 64)
        r.path = names(obj["path"])
        r.entries = ((obj["entries"] as? [[String: Any]]) ?? []).prefix(2000).compactMap { e in
            // A name is used for local copies too: never one that could leave its folder.
            guard let name = e["name"] as? String, RemoteFilesReply.isSafeName(name) else { return nil }
            let dir = e["dir"] as? Bool ?? false
            return RemoteFileEntry(name: String(name.prefix(255)), isDirectory: dir,
                                   kind: (e["kind"] as? String).flatMap(RemoteFileKind.init(rawValue:)) ?? (dir ? .folder : .file),
                                   size: e["size"] as? Int, modified: (e["mod"] as? Int).map { Date(timeIntervalSince1970: TimeInterval($0)) },
                                   location: e["in"] == nil ? nil : names(e["in"]), root: e["in"] == nil ? nil : r.root,
                                   created: (e["made"] as? Int).map { Date(timeIntervalSince1970: TimeInterval($0)) },
                                   hidden: e["hidden"] as? Bool ?? false, readOnly: e["ro"] as? Bool ?? false)
        }
        r.truncated = obj["truncated"] as? Bool ?? false
        r.complete = obj["complete"] as? Bool ?? true
        r.query = str("q", 100)
        r.text = (obj["text"] as? String).map { String($0.prefix(40_000)) }
        r.image = (obj["jpeg"] as? String).flatMap { $0.count <= maxBase64 ? Data(base64Encoded: $0) : nil }
        r.name = str("name")
        r.x = obj["x"] as? Int
        r.offset = (obj["o"] as? NSNumber)?.int64Value
        r.length = obj["n"] as? Int
        r.size = (obj["size"] as? NSNumber)?.int64Value
        r.data = (obj["d"] as? String).flatMap { $0.count <= 40_000 ? Data(base64Encoded: $0) : nil }
        r.sha = str("sha", 64)
        r.mod = obj["mod"] as? Int
        r.mime = str("mime", 100)
        r.uti = str("uti", 200)
        r.skipped = obj["skipped"] as? Bool ?? false
        r.suggest = str("suggest")
        r.need = str("need", 16)
        r.token = str("token", 64)
        r.grant = (obj["grant"] as? [String: Any]).map(RemoteFilesGrant.init(wire:))
        r.info = (obj["info"] as? [String: Any]).map(RemoteFileInfo.init(wire:))
        r.apps = ((obj["apps"] as? [[String: Any]]) ?? []).prefix(24).compactMap { a in
            guard let b = a["bundle"] as? String, let n = a["name"] as? String else { return nil }
            return RemoteOpenWithApp(bundleID: String(b.prefix(255)), name: String(n.prefix(100)), isDefault: a["default"] as? Bool ?? false)
        }
        return r
    }
}

/// What this device may do on the Mac's files (`state.grant`), for the indicator and the menus.
struct RemoteFilesGrant: Equatable, Sendable {
    var always: Bool
    var allFiles: Bool
    var capabilities: Set<String>
    var hidden: Bool

    init(always: Bool = false, allFiles: Bool = false, capabilities: Set<String> = ["browse", "download"], hidden: Bool = false) {
        self.always = always; self.allFiles = allFiles; self.capabilities = capabilities; self.hidden = hidden
    }

    init(wire w: [String: Any]) {
        always = (w["duration"] as? String) == "always"
        allFiles = (w["scope"] as? String) == "allAccessible"
        capabilities = Set(((w["caps"] as? [String]) ?? []).prefix(8).map { String($0.prefix(16)) })
        hidden = w["hidden"] as? Bool ?? false
    }

    var canDownload: Bool { capabilities.contains("download") }
    var canUpload: Bool { capabilities.contains("upload") }
    var canModify: Bool { capabilities.contains("modify") }
    var canDelete: Bool { capabilities.contains("delete") }
    var readOnly: Bool { !canUpload && !canModify && !canDelete }
}

struct RemoteFileInfo: Equatable, Sendable {
    var name = "", kind = "", owner = "", permissions = ""
    var size: Int64?, items: Int?, complete = true
    var created: Date?, modified: Date?, opened: Date?
    var writable = false, locked = false
    var cloud: String?

    init(wire w: [String: Any]) {
        func date(_ k: String) -> Date? { (w[k] as? Int).map { Date(timeIntervalSince1970: TimeInterval($0)) } }
        name = String((w["name"] as? String ?? "").prefix(255)); kind = String((w["kind"] as? String ?? "").prefix(100))
        owner = String((w["owner"] as? String ?? "").prefix(64)); permissions = String((w["perm"] as? String ?? "").prefix(8))
        size = (w["size"] as? NSNumber)?.int64Value; items = w["items"] as? Int; complete = w["complete"] as? Bool ?? true
        created = date("made"); modified = date("mod"); opened = date("used")
        writable = w["writable"] as? Bool ?? false; locked = w["locked"] as? Bool ?? false
        cloud = (w["cloud"] as? String).map { String($0.prefix(16)) }
    }
}

struct RemoteOpenWithApp: Equatable, Identifiable, Sendable {
    var bundleID: String
    var name: String
    var isDefault: Bool
    var id: String { bundleID }
}

enum RemoteFilesRequests {
    static func make(_ op: String, req: Int, _ fields: [String: Any] = [:]) -> [String: Any] {
        var m = fields
        m["type"] = WireMessage.filesRequest
        m["op"] = op
        m["req"] = req
        return m
    }
}

/// What the browser shows: the approved folders, one folder, or the Mac's apps.
enum RemoteFilesLocation: Equatable, Sendable {
    case locations
    case folder(root: String, path: [String])
    case applications
}

@MainActor
final class RemoteFilesModel: ObservableObject {
    enum Access: Equatable { case unknown, off, asking, denied, noFolders, ready, revoked }
    enum Style: String { case list, grid }
    enum PreviewContent { case loading, image(CGImage), text(String, truncated: Bool), unavailable, failed(String) }
    struct Preview: Identifiable {
        var entry: RemoteFileEntry
        var root: String
        var path: [String]
        var content: PreviewContent
        var id: String { root + "/" + path.joined(separator: "/") }
    }
    enum Notice: Equatable {
        case opened(String), needsControl, openFailed, macRefused
        /// Something finished or failed (already worded).
        case text(String)
        /// Moved to the Trash, with Put Back tokens for Undo.
        case trashed(count: Int, tokens: [String])
        /// The Mac's grant doesn't include this capability: offer to ask for it.
        case needs(String)
    }

    /// The connected Mac offers Remote Finder (welcome feature `files`).
    @Published private(set) var available = false
    @Published private(set) var isOpen = false
    @Published private(set) var access = Access.unknown
    @Published private(set) var roots: [RemoteFileRootItem] = []
    @Published private(set) var location = RemoteFilesLocation.locations
    @Published private(set) var entries: [RemoteFileEntry] = [] { didSet { updateVisible() } }
    @Published private(set) var loading = false
    /// `notFound`, `permission` or another error code from the Mac, for the current folder.
    @Published private(set) var folderError: String?
    @Published private(set) var truncated = false
    @Published var query = "" { didSet { if query != oldValue { scheduleSearch() } } }
    @Published private(set) var results: [RemoteFileEntry] = []
    @Published private(set) var searching = false
    @Published private(set) var searchComplete = true
    @Published private(set) var preview: Preview?
    @Published private(set) var thumbnails: [String: CGImage] = [:]
    @Published private(set) var notice: Notice?
    /// The entry to point out after "Show in Folder".
    @Published var highlighted: String?
    @Published var style: Style { didSet { defaults.set(style.rawValue, forKey: Self.styleKey) } }

    /// What this device may do on the Mac (`state.grant`); nil until browsing is allowed.
    @Published var grant: RemoteFilesGrant?
    /// The current folder as shown: hidden files, kind filter and order applied.
    @Published var visibleEntries: [RemoteFileEntry] = []
    @Published var sort: RemoteFilesSort { didSet { defaults.set(sort.rawValue, forKey: Self.sortKey); updateVisible() } }
    @Published var ascending: Bool { didSet { defaults.set(ascending, forKey: Self.ascendingKey); updateVisible() } }
    /// Hidden files the Mac lists (only when its owner allows it) are shown.
    @Published var showHidden = false { didSet { updateVisible() } }
    @Published var kindFilter = RemoteFileKindFilter.all { didSet { updateVisible() } }
    @Published var selecting = false { didSet { if !selecting { selection = [] } } }
    /// Selected entries of the current folder, by `RemoteFileEntry.id`.
    @Published var selection: Set<String> = []
    /// Items copied or cut here, to paste into another folder on the Mac.
    @Published var clipboard: RemoteFilesClipboard?
    @Published var info: RemoteFileInfoSheet?
    /// A file downloaded for viewing in this app.
    @Published var viewer: RemoteFileViewer?
    /// Files ready to save to this device or share.
    @Published var export: RemoteFilesExport?
    /// An uploaded folder exists on the Mac: Merge, Keep Both or Skip.
    @Published var folderConflict: RemoteFolderConflict?
    @Published var favorites: [RemoteFavorite] = []
    /// Files opened this session (never stored).
    @Published var recents: [RemoteFileEntry] = []
    /// A file operation is waiting for the Mac.
    @Published var busy = false

    let transfers = RemoteTransferQueue()
    /// The connected Mac's paired identity, for favorites.
    var macKey: () -> String? = { nil }
    var waiters: [Int: CheckedContinuation<RemoteFilesReply, Never>] = [:]
    var viewerTransfer: (id: UUID, entry: RemoteFileEntry)?
    @Published var exportBatches: [UUID: RemoteFilesExportBatch] = [:]
    var streams: [Int: RemoteFileStream] = [:]
    var refreshTask: Task<Void, Never>?

    var send: ([String: Any]) -> Bool = { _ in false }
    var inputAllowed: () -> Bool = { false }

    private let defaults: UserDefaults
    private var back: [RemoteFilesLocation] = []
    private var req = 0
    private var listReq: Int?
    private var searchReq: Int?
    private var previewReq: Int?
    private var searchTask: Task<Void, Never>?
    private var pendingSearchRoots: [String] = []
    private var thumbTask: Task<Void, Never>?
    private var wantedThumbs: Set<String> = []
    private var thumbOrder: [String] = []
    private var unthumbable: Set<String> = []
    private var previewCache: [String: PreviewContent] = [:]
    private var previewOrder: [String] = []
    private var noticeTask: Task<Void, Never>?

    static let styleKey = "files.style"
    static let maxThumbnails = 240
    static let maxCachedPreviews = 12
    static let previewSide = 1600
    static let sortKey = "files.sort"
    static let ascendingKey = "files.ascending"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        style = defaults.string(forKey: Self.styleKey).flatMap(Style.init(rawValue:)) ?? .list
        sort = defaults.string(forKey: Self.sortKey).flatMap(RemoteFilesSort.init(rawValue:)) ?? .name
        ascending = defaults.object(forKey: Self.ascendingKey) as? Bool ?? true
        transfers.nextRequestID = { [weak self] in self?.nextReq() ?? 0 }
        transfers.send = { [weak self] m in self?.send(m) ?? false }
        transfers.onSettled = { [weak self] item in self?.transferSettled(item) }
        transfers.onRemoteChange = { [weak self] root, path in self?.remoteChanged(root: root, path: path) }
        RemoteTransferQueue.removeStaleCache()
    }

    var defaultsStore: UserDefaults { defaults }

    func updateVisible() {
        var list = entries
        if !showHidden { list.removeAll { $0.hidden } }
        if kindFilter != .all { list.removeAll { !kindFilter.matches($0) } }
        visibleEntries = RemoteFilesSorting.sorted(list, by: sort, ascending: ascending)
        if !selection.isEmpty { selection.formIntersection(visibleEntries.map(\.id)) }
    }

    var canGoBack: Bool { !back.isEmpty }
    var currentRoot: RemoteFileRootItem? {
        if case .folder(let root, _) = location { return roots.first { $0.id == root } }
        return nil
    }
    /// Locations › Folder › Sub › Sub.
    var breadcrumbs: [(title: String, location: RemoteFilesLocation)] {
        var crumbs: [(String, RemoteFilesLocation)] = [(String(localized: "Locations"), .locations)]
        switch location {
        case .locations: break
        case .applications: crumbs.append((String(localized: "Applications"), .applications))
        case .folder(let root, let path):
            crumbs.append((roots.first { $0.id == root }?.name ?? root, .folder(root: root, path: [])))
            for i in path.indices { crumbs.append((path[i], .folder(root: root, path: Array(path[...i])))) }
        }
        return crumbs
    }

    // MARK: Session

    func setAvailable(_ value: Bool) {
        available = value
        if !value { reset() }
    }

    /// The session ended: nothing from the old Mac is kept.
    func reset() {
        isOpen = false
        access = .unknown
        roots = []
        location = .locations
        back = []
        entries = []
        loading = false
        folderError = nil
        truncated = false
        results = []
        searching = false
        pendingSearchRoots = []
        searchTask?.cancel()
        thumbTask?.cancel()
        if !query.isEmpty { query = "" }
        preview = nil
        thumbnails = [:]
        thumbOrder = []
        wantedThumbs = []
        unthumbable = []
        previewCache = [:]
        previewOrder = []
        notice = nil
        highlighted = nil
        listReq = nil; searchReq = nil; previewReq = nil
        grant = nil
        selecting = false
        clipboard = nil
        info = nil
        viewer = nil
        viewerTransfer = nil
        folderConflict?.answer(nil)
        folderConflict = nil
        recents = []
        busy = false
        failWaiters("disconnected")
        stopStreams()
        transfers.disconnected()
        transfers.purgeViewCache()
    }

    /// Opens the browser. The first time in a session this asks the Mac, which shows its
    /// owner a prompt; nothing is listed before they allow it.
    func open(query initial: String? = nil) {
        guard available else { return }
        isOpen = true
        if let initial { query = initial }
        if access == .ready {
            refresh()
        } else {
            access = access == .denied ? .denied : .asking
            _ = send(RemoteFilesRequests.make("state", req: nextReq()))
        }
    }

    func close() {
        isOpen = false
        preview = nil
        previewReq = nil
        thumbTask?.cancel()
        wantedThumbs = []
        selecting = false
        viewer = nil
        viewerTransfer = nil
        stopStreams()
        transfers.purgeViewCache()
    }

    /// Ask again (the owner may have turned it on or added a folder).
    func retry() {
        _ = send(RemoteFilesRequests.make("state", req: nextReq()))
    }

    // MARK: Navigation

    func go(_ to: RemoteFilesLocation, remember: Bool = true) {
        guard to != location else { return refresh() }
        if remember { back.append(location); if back.count > 64 { back.removeFirst() } }
        location = to
        highlighted = nil
        if !query.isEmpty { query = "" }
        refresh()
    }

    func goBack() {
        guard let previous = back.popLast() else { return }
        location = previous
        highlighted = nil
        refresh()
    }

    func openEntry(_ entry: RemoteFileEntry) {
        if entry.isDirectory {
            let root = entry.root ?? currentRootID
            guard let root else { return }
            let base = entry.location ?? currentPath
            go(.folder(root: root, path: base + [entry.name]))
        } else {
            showPreview(entry)
        }
    }

    /// A search result: go to the folder it is in and point it out.
    func showInFolder(_ entry: RemoteFileEntry) {
        guard let root = entry.root ?? currentRootID else { return }
        preview = nil
        go(.folder(root: root, path: entry.location ?? currentPath))
        highlighted = entry.name
    }

    var currentRootID: String? { if case .folder(let r, _) = location { return r }; return nil }
    var currentPath: [String] { if case .folder(_, let p) = location { return p }; return [] }

    func refresh() {
        guard access == .ready else { return }
        guard case .folder(let root, let path) = location else {
            entries = []; loading = false; folderError = nil; truncated = false
            return
        }
        loading = true
        folderError = nil
        let r = nextReq()
        listReq = r
        guard send(RemoteFilesRequests.make("list", req: r, ["root": root, "path": path])) else {
            loading = false; folderError = "disconnected"; return
        }
        // No endless spinner: a folder the Mac doesn't answer for says so, with Try Again.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            guard let self, self.listReq == r, self.loading else { return }
            self.loading = false
            self.listReq = nil
            if self.entries.isEmpty { self.folderError = "timeout" } else { self.show(.text(String(localized: "The Mac didn't answer. Pull down or tap Refresh to try again."))) }
        }
    }

    // MARK: Search

    private func scheduleSearch() {
        searchTask?.cancel()
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            results = []; searching = false; searchComplete = true; searchReq = nil; pendingSearchRoots = []
            return
        }
        searching = true
        searchTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard let self, !Task.isCancelled else { return }
            self.startSearch(String(q.prefix(100)))
        }
    }

    private func startSearch(_ q: String) {
        guard access == .ready else { searching = false; return }
        results = []
        searchComplete = true
        // In a folder: below it. At Locations: every approved folder, one after another.
        if case .folder(let root, let path) = location {
            pendingSearchRoots = []
            sendSearch(q, root: root, path: path)
        } else {
            pendingSearchRoots = roots.map(\.id)
            guard !pendingSearchRoots.isEmpty else { searching = false; return }
            sendSearch(q, root: pendingSearchRoots.removeFirst(), path: [])
        }
    }

    private func sendSearch(_ q: String, root: String, path: [String]) {
        let r = nextReq()
        searchReq = r
        _ = send(RemoteFilesRequests.make("search", req: r, ["root": root, "path": path, "q": q]))
    }

    // MARK: Preview and thumbnails

    func showPreview(_ entry: RemoteFileEntry) {
        guard let root = entry.root ?? currentRootID else { return }
        let path = (entry.location ?? currentPath) + [entry.name]
        let key = root + "/" + path.joined(separator: "/")
        if let cached = previewCache[key] {
            preview = Preview(entry: entry, root: root, path: path, content: cached)
            noteRecent(entry, root: root)
            startViewer(entry, root: root, path: path)
            return
        }
        preview = Preview(entry: entry, root: root, path: path, content: .loading)
        noteRecent(entry, root: root)
        let r = nextReq()
        previewReq = r
        guard send(RemoteFilesRequests.make("preview", req: r, ["root": root, "path": path, "max": Self.previewSide])) else {
            preview?.content = .failed("disconnected"); return
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 25_000_000_000)
            guard let self, self.previewReq == r, var p = self.preview, case .loading = p.content else { return }
            p.content = .failed("timeout")
            self.preview = p
        }
        startViewer(entry, root: root, path: path)
    }

    /// Asks for the preview again (after a timeout or a failure).
    func retryPreview() {
        guard let p = preview else { return }
        previewCache[p.id] = nil
        showPreview(p.entry)
    }

    func closePreview() {
        preview = nil
        previewReq = nil
        closeViewer()
    }

    func thumbnailKey(_ entry: RemoteFileEntry) -> String? {
        guard entry.kind.hasThumbnail, let root = entry.root ?? currentRootID else { return nil }
        return root + "/" + (entry.location ?? currentPath).joined(separator: "/") + "/" + entry.name
    }

    /// A row or tile came on screen: ask for its still soon (batched, current folder only).
    func wantThumbnail(_ entry: RemoteFileEntry) {
        guard entry.location == nil, let key = thumbnailKey(entry), thumbnails[key] == nil, !unthumbable.contains(key) else { return }
        wantedThumbs.insert(entry.name)
        scheduleThumbs()
    }

    func dropThumbnail(_ entry: RemoteFileEntry) { wantedThumbs.remove(entry.name) }

    private func scheduleThumbs() {
        thumbTask?.cancel()
        thumbTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard let self, !Task.isCancelled, case .folder(let root, let path) = self.location else { return }
            let names = self.wantedThumbs.sorted().prefix(48)
            guard !names.isEmpty else { return }
            _ = self.send(RemoteFilesRequests.make("thumbs", req: self.nextReq(), ["root": root, "path": path, "names": Array(names), "max": 240]))
        }
    }

    // MARK: Open on the Mac

    /// Opens on the Mac (explicit action, needs control); `app` is a tile's app it was dropped on.
    func openOnMac(_ entry: RemoteFileEntry, inApp app: String? = nil) {
        guard let root = entry.root ?? currentRootID else { return }
        guard inputAllowed() else { return show(.needsControl) }
        var fields: [String: Any] = ["root": root, "path": (entry.location ?? currentPath) + [entry.name]]
        if let app { fields["with"] = app }
        pendingOpenName = entry.name
        _ = send(RemoteFilesRequests.make("open", req: nextReq(), fields))
    }

    private var pendingOpenName = ""

    func show(_ n: Notice) {
        notice = n
        noticeTask?.cancel()
        let seconds: UInt64
        switch n {
        case .trashed, .needs: seconds = 6
        case .text: seconds = 4
        default: seconds = 3
        }
        noticeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    // MARK: Replies

    func apply(_ r: RemoteFilesReply) {
        let accessError = r.error.flatMap { ["off", "asking", "denied", "revoked"].contains($0) ? $0 : nil }
        if let e = accessError {
            access = e == "off" ? .off : e == "denied" ? .denied : e == "revoked" ? .revoked : .asking
            loading = false; searching = false
            if e != "asking" { grant = nil; transfers.failRunning(e) }
        }
        // Transfers, streams and awaited operations take their own replies.
        if applyStream(r) || transfers.apply(r) { return }
        if let req = r.req, let waiter = waiters.removeValue(forKey: req) { return waiter.resume(returning: r) }
        if accessError != nil {
            if var p = preview, case .loading = p.content { p.content = .failed(accessError ?? "failed"); preview = p }
            return
        }
        switch r.op {
        case "state":
            if r.state != "ready" { grant = nil }
            switch r.state {
            case "off": access = .off
            case "denied": access = .denied
            case "revoked":
                access = .revoked
                transfers.failRunning("revoked")
                stopStreams()
                selecting = false
            case "noFolders": access = .noFolders; roots = []
            case "ready":
                let wasReady = access == .ready
                access = .ready
                grant = r.grant ?? RemoteFilesGrant()
                if !(grant?.hidden ?? false) { showHidden = false }
                roots = r.roots
                loadFavorites()
                if case .folder(let root, _) = location, !roots.contains(where: { $0.id == root }) {
                    location = .locations; back = []
                }
                if location == .locations, roots.count == 1, back.isEmpty, !wasReady {
                    location = .folder(root: roots[0].id, path: [])
                }
                if isOpen { refresh(); if !query.isEmpty { scheduleSearch() } }
            default: access = .asking
            }
        case "list":
            guard r.req == nil || r.req == listReq else { return }
            loading = false
            guard case .folder(let root, let path) = location, r.root == nil || r.root == root else { return }
            if r.ok {
                if r.path == path || r.path.isEmpty && path.isEmpty {
                    entries = r.entries
                    truncated = r.truncated
                    folderError = nil
                }
            } else {
                entries = []
                folderError = r.error ?? "notFound"
            }
        case "search":
            guard r.req == searchReq else { return }
            if r.ok {
                results.append(contentsOf: r.entries.prefix(max(0, 400 - results.count)))
                if !r.complete { searchComplete = false }
            }
            let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
            if !pendingSearchRoots.isEmpty, !q.isEmpty {
                sendSearch(String(q.prefix(100)), root: pendingSearchRoots.removeFirst(), path: [])
            } else {
                searching = false
            }
        case "preview":
            guard r.req == previewReq, var p = preview else { return }
            let content: PreviewContent
            if let text = r.text {
                content = .text(text, truncated: r.truncated)
            } else if let data = r.image, let image = WorkspaceImageDecoder.image(data, maxSide: Self.previewSide) {
                content = .image(image)
            } else if let e = r.error, e != "noPreview", e != "unsupported" {
                content = .failed(e)
            } else {
                content = .unavailable
            }
            p.content = content
            preview = p
            cachePreview(p.id, content)
        case "thumb":
            guard let name = r.name, let root = r.root, case .folder(let here, let path) = location, root == here, r.path == path else { return }
            let key = root + "/" + path.joined(separator: "/") + "/" + name
            wantedThumbs.remove(name)
            guard let data = r.image, let image = WorkspaceImageDecoder.image(data, maxSide: 256) else {
                unthumbable.insert(key)
                return
            }
            thumbnails[key] = image
            thumbOrder.append(key)
            while thumbOrder.count > Self.maxThumbnails { thumbnails[thumbOrder.removeFirst()] = nil }
        case "open":
            if r.ok { show(.opened(pendingOpenName)) } else { show(r.error == "control" ? .needsControl : .openFailed) }
        case "thumbs":
            break
        default:
            break
        }
    }

    private func cachePreview(_ key: String, _ content: PreviewContent) {
        switch content { case .loading, .failed: return; default: break }
        previewCache[key] = content
        previewOrder.removeAll { $0 == key }
        previewOrder.append(key)
        while previewOrder.count > Self.maxCachedPreviews { previewCache[previewOrder.removeFirst()] = nil }
    }

    func nextReq() -> Int { req &+= 1; if req > 1_000_000_000 { req = 1 }; return req }
}

/// Sizes and dates the way Finder shows them.
enum RemoteFilesFormat {
    static func size(_ bytes: Int?) -> String {
        guard let bytes else { return "--" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    static func date(_ date: Date?) -> String {
        guard let date else { return "" }
        let f = DateFormatter()
        f.doesRelativeDateFormatting = true
        f.dateStyle = .medium
        f.timeStyle = Calendar.current.isDateInToday(date) || Calendar.current.isDateInYesterday(date) ? .short : .none
        return f.string(from: date)
    }

    static func kindName(_ kind: RemoteFileKind) -> String {
        switch kind {
        case .folder: return String(localized: "Folder")
        case .app: return String(localized: "Application")
        case .image: return String(localized: "Image")
        case .video: return String(localized: "Movie")
        case .audio: return String(localized: "Audio")
        case .pdf: return String(localized: "PDF Document")
        case .archive: return String(localized: "Archive")
        case .text: return String(localized: "Text")
        case .document: return String(localized: "Document")
        case .file: return String(localized: "File")
        }
    }
}

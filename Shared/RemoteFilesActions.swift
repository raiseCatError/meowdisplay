import CryptoKit
import Foundation
import QuartzCore

// Remote Finder actions on the receiver (PROTOCOL.md 6.12): file operations, Save to Device,
// Share, uploads, in-app viewers and favorites. The Mac checks every request against its
// owner's grant; this side only hides what the grant doesn't include and words the answers.

enum RemoteFilesSort: String, CaseIterable, Sendable {
    case name, date, size, kind
}

enum RemoteFileKindFilter: String, CaseIterable, Sendable {
    case all, folders, images, movies, audio, documents, archives

    func matches(_ e: RemoteFileEntry) -> Bool {
        switch self {
        case .all: return true
        case .folders: return e.isDirectory && e.kind != .app
        case .images: return e.kind == .image
        case .movies: return e.kind == .video
        case .audio: return e.kind == .audio
        case .documents: return [.pdf, .text, .document].contains(e.kind)
        case .archives: return e.kind == .archive
        }
    }
}

enum RemoteFilesSorting {
    /// Finder's orders: names compare like Finder (numbers by value), ties fall back to the name.
    static func sorted(_ entries: [RemoteFileEntry], by sort: RemoteFilesSort, ascending: Bool) -> [RemoteFileEntry] {
        func byName(_ a: RemoteFileEntry, _ b: RemoteFileEntry) -> Bool {
            a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        let ordered = entries.sorted { a, b in
            switch sort {
            case .name:
                return byName(a, b)
            case .date:
                let x = a.modified ?? .distantPast, y = b.modified ?? .distantPast
                return x == y ? byName(a, b) : x < y
            case .size:
                // Folders have no size: they come before files.
                let x = a.isDirectory ? -1 : (a.size ?? 0), y = b.isDirectory ? -1 : (b.size ?? 0)
                return x == y ? byName(a, b) : x < y
            case .kind:
                let x = RemoteFilesFormat.kindName(a.kind), y = RemoteFilesFormat.kindName(b.kind)
                return x == y ? byName(a, b) : x.localizedStandardCompare(y) == .orderedAscending
            }
        }
        return ascending ? ordered : ordered.reversed()
    }
}

/// Items copied or cut in Remote Finder, to paste into another folder on the Mac.
struct RemoteFilesClipboard: Equatable, Sendable {
    var move: Bool
    var root: String
    var folder: [String]
    var names: [String]
}

struct RemoteFileInfoSheet: Identifiable {
    var entry: RemoteFileEntry
    var info: RemoteFileInfo
    var id: String { entry.id }
}

/// A file shown inside this app: streamed for playback, or a private copy for PDF pages, a
/// full-resolution image or Quick Look.
struct RemoteFileViewer: Identifiable {
    enum Content {
        case loading
        case stream(x: Int, size: Int64, uti: String?)
        case file(URL)
        case failed(String)
    }
    var previewID: String
    var entry: RemoteFileEntry
    var content: Content
    var id: String { previewID }
}

/// Files copied to this device, ready to save (document picker) or share (share sheet).
struct RemoteFilesExport: Identifiable {
    enum Mode: Sendable { case save, share }
    let id = UUID()
    var mode: Mode
    var urls: [URL]
    /// Removed once the picker or share sheet is done.
    var directory: URL
    var failed: Int
}

struct RemoteFilesExportBatch {
    var mode: RemoteFilesExport.Mode
    /// Transfer id → path inside the export (folders, then the file name).
    var paths: [UUID: [String]] = [:]
    var folders: [[String]] = []
    var tops: [String] = []
    var pending: Set<UUID> = []
    var walking = 0
    var failed = 0
    var truncated = false
}

/// An uploaded folder already exists on the Mac.
struct RemoteFolderConflict: Identifiable {
    enum Choice { case merge, keepBoth, skip }
    let id = UUID()
    var name: String
    var answer: (Choice?) -> Void
}

struct RemoteFavorite: Codable, Equatable, Identifiable, Sendable {
    var root: String
    var path: [String]
    var name: String
    var id: String { root + "/" + path.joined(separator: "/") }
}

// MARK: - Streaming reads (playback with seeking)

/// Random-access reads of one open Mac file (`download` with purpose `view`), for a player that
/// asks for byte ranges as it plays and seeks. The Mac answers reads in order, so parts are
/// matched first-in, first-out; each range is digest-checked; a stalled read fails.
@MainActor
final class RemoteFileStream {
    let x: Int
    let size: Int64
    let uti: String?
    private let send: ([String: Any]) -> Bool
    private let nextReq: () -> Int

    private final class Read {
        let o: Int64
        let n: Int
        var data = Data()
        var hasher = SHA256()
        let done: (Data?) -> Void
        let asked: TimeInterval
        init(o: Int64, n: Int, done: @escaping (Data?) -> Void, asked: TimeInterval) {
            self.o = o; self.n = n; self.done = done; self.asked = asked
        }
    }

    private var reads: [Read] = []
    private(set) var failed: String?
    private var watchdog: Task<Void, Never>?

    static let readBytes = 256 * 1024
    static let maxInFlight = 6
    static let timeout: TimeInterval = 20

    init(x: Int, size: Int64, uti: String?, send: @escaping ([String: Any]) -> Bool, nextReq: @escaping () -> Int) {
        self.x = x; self.size = size; self.uti = uti; self.send = send; self.nextReq = nextReq
    }

    var canRead: Bool { failed == nil && reads.count < Self.maxInFlight }

    /// Reads `n` bytes at `o` (clamped to the file); `done` gets nil when it failed.
    func read(_ o: Int64, _ n: Int, done: @escaping (Data?) -> Void) {
        guard failed == nil, o >= 0, o < size, n > 0 else { return done(failed == nil && o >= size ? Data() : nil) }
        let len = Int(min(Int64(min(n, 1 << 20)), size - o))
        reads.append(Read(o: o, n: len, done: done, asked: CACurrentMediaTime()))
        guard send(RemoteFilesRequests.make("read", req: nextReq(), ["x": x, "o": o, "n": len])) else { return fail("disconnected") }
        startWatchdog()
    }

    func apply(_ r: RemoteFilesReply) {
        guard failed == nil else { return }
        guard let first = reads.first else { return }
        switch r.op {
        case "data":
            guard let d = r.data, r.offset == first.o + Int64(first.data.count), first.data.count + d.count <= first.n else {
                return fail("badData")
            }
            first.data.append(d)
            first.hasher.update(data: d)
        case "read":
            guard r.ok else { return fail(r.error ?? "failed") }
            let digest = first.hasher.finalize().prefix(8).map { String(format: "%02x", $0) }.joined()
            guard r.offset == first.o, first.data.count == first.n, digest == r.sha else { return fail("digest") }
            reads.removeFirst()
            first.done(first.data)
        default:
            break
        }
    }

    func fail(_ code: String) {
        guard failed == nil else { return }
        failed = code
        let pending = reads
        reads = []
        watchdog?.cancel()
        for r in pending { r.done(nil) }
    }

    func close() {
        fail("closed")
        _ = send(RemoteFilesRequests.make("close", req: nextReq(), ["x": x]))
    }

    private func startWatchdog() {
        guard watchdog == nil else { return }
        watchdog = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self else { return }
                guard let first = self.reads.first else { self.watchdog = nil; return }
                if CACurrentMediaTime() - first.asked > Self.timeout { self.fail("timeout"); return }
            }
        }
    }
}

// MARK: - Model actions

extension RemoteFilesModel {
    /// Sends a request and waits for its answer (or `timeout`, or the session ending).
    func request(_ op: String, _ fields: [String: Any] = [:], timeout: TimeInterval = 30) async -> RemoteFilesReply {
        let r = nextReq()
        guard send(RemoteFilesRequests.make(op, req: r, fields)) else { return .failure(op, "disconnected") }
        return await withCheckedContinuation { (c: CheckedContinuation<RemoteFilesReply, Never>) in
            waiters[r] = c
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if let w = self?.waiters.removeValue(forKey: r) { w.resume(returning: .failure(op, "timeout")) }
            }
        }
    }

    func failWaiters(_ code: String) {
        let all = waiters
        waiters = [:]
        for (_, w) in all { w.resume(returning: .failure("", code)) }
    }

    /// Where an entry is on the Mac: its root and full path.
    func place(of entry: RemoteFileEntry) -> (root: String, path: [String])? {
        guard let root = entry.root ?? currentRootID else { return nil }
        return (root, (entry.location ?? currentPath) + [entry.name])
    }

    var selectedEntries: [RemoteFileEntry] { visibleEntries.filter { selection.contains($0.id) } }

    func toggleSelection(_ entry: RemoteFileEntry) {
        if selection.contains(entry.id) { selection.remove(entry.id) } else { selection.insert(entry.id) }
    }

    func selectAll() { selection = Set(visibleEntries.map(\.id)) }

    // MARK: Words

    static func capabilityName(_ need: String) -> String {
        switch need {
        case "download": return String(localized: "saving and sharing copies")
        case "upload": return String(localized: "uploading and new folders")
        case "modify": return String(localized: "renaming, moving and copying")
        case "delete": return String(localized: "moving to the Trash")
        default: return String(localized: "browsing")
        }
    }

    static func errorText(_ code: String?) -> String {
        switch code {
        case "exists": return String(localized: "An item with that name already exists.")
        case "noSpace": return String(localized: "There isn't enough space.")
        case "tooLarge": return String(localized: "That file is too large.")
        case "permission": return String(localized: "macOS didn't allow MeowDisplay to do that on the Mac.")
        case "notFound": return String(localized: "It isn't there any more.")
        case "readOnly": return String(localized: "That location can't be changed.")
        case "intoItself": return String(localized: "A folder can't go inside itself.")
        case "busy": return String(localized: "The Mac is busy with other transfers. Try again shortly.")
        case "changed": return String(localized: "The file changed on the Mac while it was copied.")
        case "digest", "badData", "short": return String(localized: "The copy didn't arrive intact. Try again.")
        case "timeout": return String(localized: "The Mac didn't answer.")
        case "disconnected": return String(localized: "The Mac disconnected.")
        case "revoked", "denied", "off": return String(localized: "Files access on the Mac ended.")
        case "storage": return String(localized: "This device couldn't store the copy.")
        case "unreadable": return String(localized: "This device couldn't read that file.")
        case "unsupported", "noPreview": return String(localized: "That isn't supported for this item.")
        case "control": return String(localized: "Ask for control of the Mac first.")
        default: return String(localized: "The Mac couldn't do that.")
        }
    }

    /// Words a failed reply; true when it was a success.
    @discardableResult
    func report(_ r: RemoteFilesReply, done: String? = nil) -> Bool {
        if r.ok {
            if let done { show(.text(done)) }
            return true
        }
        if r.error == "notAllowed" { show(.needs(r.need ?? "")) } else { show(.text(Self.errorText(r.error))) }
        return false
    }

    /// The grant allows it, else the notice offers to ask the Mac.
    func allowed(_ capability: String) -> Bool {
        guard let g = grant else { return false }
        if g.capabilities.contains(capability) { return true }
        show(.needs(capability))
        return false
    }

    // MARK: Folder operations

    func newFolder(named raw: String) async {
        guard allowed("upload"), case .folder(let root, let path) = location else { return }
        let name = Self.cleanName(raw) ?? String(localized: "untitled folder")
        busy = true; defer { busy = false }
        let r = await request("mkdir", ["root": root, "path": path, "name": name, "conflict": "rename"])
        if report(r) { refresh(); highlighted = r.name ?? name }
    }

    func rename(_ entry: RemoteFileEntry, to raw: String) async {
        guard allowed("modify"), let p = place(of: entry), let name = Self.cleanName(raw), name != entry.name else { return }
        busy = true; defer { busy = false }
        let r = await request("rename", ["root": p.root, "path": p.path, "name": name])
        if report(r) { refresh(); highlighted = r.name ?? name }
    }

    func duplicate(_ entries: [RemoteFileEntry]) async {
        guard allowed("modify") else { return }
        busy = true; defer { busy = false }
        var last: String?
        for e in entries {
            guard let p = place(of: e) else { continue }
            let r = await request("duplicate", ["root": p.root, "path": p.path], timeout: 600)
            guard report(r) else { break }
            last = r.name
        }
        refresh()
        highlighted = last
        selecting = false
    }

    func trash(_ entries: [RemoteFileEntry]) async {
        guard allowed("delete") else { return }
        busy = true; defer { busy = false }
        var tokens: [String] = []
        var moved = 0
        for e in entries {
            guard let p = place(of: e) else { continue }
            let r = await request("trash", ["root": p.root, "path": p.path], timeout: 120)
            guard report(r) else { break }
            moved += 1
            if let t = r.token { tokens.append(t) }
        }
        refresh()
        selecting = false
        if moved > 0 { show(.trashed(count: moved, tokens: tokens)) }
    }

    /// Undo of Move to Trash: Put Back, in this session.
    func putBack(_ tokens: [String]) async {
        guard allowed("modify") else { return }
        busy = true; defer { busy = false }
        for t in tokens {
            let r = await request("putBack", ["token": t], timeout: 120)
            guard report(r) else { break }
        }
        refresh()
    }

    func copyItems(_ entries: [RemoteFileEntry], move: Bool) {
        guard allowed("modify"), case .folder(let root, let path) = location, !entries.isEmpty else { return }
        clipboard = RemoteFilesClipboard(move: move, root: root, folder: path, names: entries.map(\.name))
        selecting = false
        show(.text(move ? String(localized: "Open the destination folder, then Paste to move.")
                        : String(localized: "Open the destination folder, then Paste.")))
    }

    var canPaste: Bool {
        guard let c = clipboard, case .folder(let root, let path) = location else { return false }
        return !(c.move && c.root == root && c.folder == path)
    }

    func paste() async {
        guard let c = clipboard, allowed("modify"), case .folder(let root, let path) = location else { return }
        busy = true; defer { busy = false }
        var last: String?
        for name in c.names {
            let r = await request(c.move ? "move" : "copy",
                                  ["root": c.root, "path": c.folder + [name], "toRoot": root, "toPath": path, "conflict": "rename"],
                                  timeout: 900)
            guard report(r) else { break }
            last = r.name
        }
        if c.move { clipboard = nil }
        refresh()
        highlighted = last
    }

    func compress(_ entries: [RemoteFileEntry]) async {
        guard allowed("modify"), case .folder(let root, let path) = location, !entries.isEmpty else { return }
        busy = true; defer { busy = false }
        let r = await request("zip", ["root": root, "path": path, "names": entries.map(\.name)], timeout: 900)
        if report(r) { refresh(); highlighted = r.name }
        selecting = false
    }

    func expand(_ entry: RemoteFileEntry) async {
        guard allowed("modify"), let p = place(of: entry) else { return }
        busy = true; defer { busy = false }
        let r = await request("unzip", ["root": p.root, "path": p.path], timeout: 900)
        if report(r) { refresh(); highlighted = r.name }
    }

    func getInfo(_ entry: RemoteFileEntry) async {
        guard let p = place(of: entry) else { return }
        let r = await request("info", ["root": p.root, "path": p.path], timeout: 60)
        guard report(r), let i = r.info else { return }
        info = RemoteFileInfoSheet(entry: entry, info: i)
    }

    func openWithApps(_ entry: RemoteFileEntry) async -> [RemoteOpenWithApp] {
        guard let p = place(of: entry) else { return [] }
        let r = await request("openWithApps", ["root": p.root, "path": p.path])
        return r.ok ? r.apps : []
    }

    /// Asks the Mac's owner for more (they see a prompt on the Mac).
    func requestAccess(_ capabilities: [String]) async {
        guard !capabilities.isEmpty else { return }
        show(.text(String(localized: "Asked the Mac. Its owner decides there.")))
        let r = await request("requestAccess", ["caps": capabilities], timeout: 300)
        if r.ok {
            show(.text(String(localized: "The Mac allowed it.")))
        } else if r.error == "denied" {
            show(.text(String(localized: "The Mac said Not Now.")))
        } else {
            report(r)
        }
    }

    /// Names a person typed: trimmed, no separators, not hidden by accident.
    static func cleanName(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        guard !name.isEmpty, name != ".", name != "..", !name.hasPrefix("."), name.count <= 255 else { return nil }
        return name
    }

    // MARK: Favorites and recents

    private var favoritesKey: String? { macKey().map { "files.favorites." + $0 } }

    func loadFavorites() {
        guard let key = favoritesKey, let data = defaultsStore.data(forKey: key),
              let list = try? JSONDecoder().decode([RemoteFavorite].self, from: data) else { favorites = []; return }
        favorites = Array(list.prefix(40))
    }

    private func saveFavorites() {
        guard let key = favoritesKey else { return }
        defaultsStore.set(try? JSONEncoder().encode(favorites), forKey: key)
    }

    func isFavorite(_ entry: RemoteFileEntry) -> Bool {
        guard let p = place(of: entry) else { return false }
        return favorites.contains { $0.root == p.root && $0.path == p.path }
    }

    func toggleFavorite(_ entry: RemoteFileEntry) {
        guard entry.isDirectory, let p = place(of: entry) else { return }
        if let i = favorites.firstIndex(where: { $0.root == p.root && $0.path == p.path }) {
            favorites.remove(at: i)
        } else {
            favorites.append(RemoteFavorite(root: p.root, path: p.path, name: entry.name))
        }
        saveFavorites()
    }

    func removeFavorite(_ f: RemoteFavorite) {
        favorites.removeAll { $0 == f }
        saveFavorites()
    }

    func noteRecent(_ entry: RemoteFileEntry, root: String) {
        var e = entry
        e.root = root
        if e.location == nil { e.location = currentPath }
        recents.removeAll { $0.id == e.id }
        recents.insert(e, at: 0)
        if recents.count > 12 { recents.removeLast(recents.count - 12) }
    }

    // MARK: Viewers

    /// Files shown in the app beyond the Mac's still: movies and audio stream with seeking,
    /// PDFs and images come as a private copy (PDF pages, full resolution).
    static let maxViewCopy: Int64 = 200 << 20
    static let maxImageCopy: Int64 = 60 << 20

    func startViewer(_ entry: RemoteFileEntry, root: String, path: [String]) {
        closeViewer()
        let id = root + "/" + path.joined(separator: "/")
        switch entry.kind {
        case .video, .audio:
            viewer = RemoteFileViewer(previewID: id, entry: entry, content: .loading)
            Task { @MainActor [weak self] in
                guard let self else { return }
                let r = await self.request("download", ["root": root, "path": path, "purpose": "view"])
                guard self.viewer?.previewID == id else {
                    if let x = r.x { _ = self.send(RemoteFilesRequests.make("close", req: self.nextReq(), ["x": x])) }
                    return
                }
                guard r.ok, let x = r.x, let size = r.size else {
                    self.viewer?.content = .failed(r.error ?? "failed"); return
                }
                self.streams[x] = RemoteFileStream(x: x, size: size, uti: r.uti, send: { [weak self] m in self?.send(m) ?? false },
                                                   nextReq: { [weak self] in self?.nextReq() ?? 0 })
                self.viewer?.content = .stream(x: x, size: size, uti: r.uti)
            }
        case .pdf, .image:
            let limit = entry.kind == .pdf ? Self.maxViewCopy : Self.maxImageCopy
            guard Int64(entry.size ?? 0) <= limit else { return }
            viewer = RemoteFileViewer(previewID: id, entry: entry, content: .loading)
            let t = transfers.download(root: root, path: path, name: entry.name, size: entry.size.map(Int64.init), purpose: .view)
            viewerTransfer = (t, entry)
        default:
            break
        }
    }

    /// Quick Look on this device for other documents: a private copy. Quick Look can share what
    /// it shows, so this needs the download capability.
    func quickLookCopy(_ entry: RemoteFileEntry) {
        guard allowed("download"), let p = place(of: entry), let prev = preview else { return }
        viewer = RemoteFileViewer(previewID: prev.id, entry: entry, content: .loading)
        let t = transfers.download(root: p.root, path: p.path, name: entry.name, size: entry.size.map(Int64.init), purpose: .view)
        viewerTransfer = (t, entry)
    }

    func retryViewer() {
        guard let p = preview else { return }
        startViewer(p.entry, root: p.root, path: p.path)
    }

    func closeViewer() {
        if let t = viewerTransfer { transfers.cancel(t.id) }
        viewerTransfer = nil
        viewer = nil
        stopStreams()
    }

    func stopStreams() {
        let all = streams
        streams = [:]
        for (_, s) in all { s.close() }
    }

    func stream(_ x: Int) -> RemoteFileStream? { streams[x] }

    func applyStream(_ r: RemoteFilesReply) -> Bool {
        guard r.op == "data" || r.op == "read", let x = r.x, let s = streams[x] else { return false }
        s.apply(r)
        return true
    }

    /// How far the viewer's copy has come (0...1).
    var viewerProgress: Double? {
        guard let t = viewerTransfer, let item = transfers.items.first(where: { $0.id == t.id }) else { return nil }
        return item.fraction
    }

    // MARK: Save, share, upload

    func save(_ entries: [RemoteFileEntry]) { startExport(entries, mode: .save) }
    func share(_ entries: [RemoteFileEntry]) { startExport(entries, mode: .share) }

    static let maxExportFiles = 5000

    private func startExport(_ entries: [RemoteFileEntry], mode: RemoteFilesExport.Mode) {
        guard allowed("download"), !entries.isEmpty else {
            Log.info("files export: \(mode) of \(entries.count) not started (download allowed: \(grant?.canDownload ?? false))")
            return
        }
        let batch = UUID()
        Log.info("files export: \(mode) of \(entries.count) started batch=\(batch.uuidString.prefix(8))")
        exportBatches[batch] = RemoteFilesExportBatch(mode: mode)
        for e in entries {
            guard let p = place(of: e) else { continue }
            exportBatches[batch]?.tops.append(e.name)
            if e.isDirectory {
                exportBatches[batch]?.walking += 1
                Task { @MainActor [weak self] in
                    await self?.walk(root: p.root, path: p.path, rel: [e.name], batch: batch, depth: 0)
                    self?.exportBatches[batch]?.walking -= 1
                    self?.checkBatch(batch)
                }
            } else {
                enqueueSave(root: p.root, path: p.path, rel: [e.name], size: e.size, batch: batch)
            }
        }
        selecting = false
        show(.text(mode == .save ? String(localized: "Copying to this device…") : String(localized: "Preparing to share…")))
        checkBatch(batch)
    }

    private func enqueueSave(root: String, path: [String], rel: [String], size: Int?, batch: UUID) {
        guard var b = exportBatches[batch] else { return }
        guard b.paths.count < Self.maxExportFiles else { b.truncated = true; exportBatches[batch] = b; return }
        let id = transfers.download(root: root, path: path, name: rel.last ?? "file", size: size.map(Int64.init), purpose: .save, batch: batch)
        b.paths[id] = rel
        b.pending.insert(id)
        exportBatches[batch] = b
    }

    /// Lists a folder on the Mac and queues every file in it (bounded depth and count).
    private func walk(root: String, path: [String], rel: [String], batch: UUID, depth: Int) async {
        guard depth < 32, exportBatches[batch] != nil else { return }
        exportBatches[batch]?.folders.append(rel)
        let r = await request("list", ["root": root, "path": path], timeout: 60)
        guard r.ok else { exportBatches[batch]?.failed += 1; return }
        if r.truncated { exportBatches[batch]?.truncated = true }
        for e in r.entries where !e.hidden || showHidden {
            if e.isDirectory && e.kind != .app {
                await walk(root: root, path: path + [e.name], rel: rel + [e.name], batch: batch, depth: depth + 1)
            } else if !e.isDirectory {
                enqueueSave(root: root, path: path + [e.name], rel: rel + [e.name], size: e.size, batch: batch)
            }
        }
    }

    func transferSettled(_ item: RemoteTransferItem) {
        if let v = viewerTransfer, v.id == item.id {
            switch item.state {
            case .done: if let url = item.localURL { viewer?.content = .file(url) }
            case .failed(let code): viewer?.content = .failed(code)
            default: break
            }
            if item.state != .done { viewerTransfer = nil }
        }
        if case .failed(let code) = item.state, code == "notAllowed" {
            show(.needs(item.direction == .upload ? "upload" : "download"))
        }
        guard case .download(.save) = item.direction else { return }
        Log.info("files export: copy settled state=\(item.state) batch=\(item.batch.uuidString.prefix(8)) inBatch=\(exportBatches[item.batch] != nil)")
        if var b = exportBatches[item.batch], b.pending.contains(item.id) {
            b.pending.remove(item.id)
            if item.state != .done { b.failed += 1 }
            exportBatches[item.batch] = b
            checkBatch(item.batch)
        } else if item.state == .done, let url = item.localURL {
            // A retried file of a batch that was already handed on.
            export = RemoteFilesExport(mode: .save, urls: [url], directory: url.deletingLastPathComponent(), failed: 0)
        }
    }

    private func checkBatch(_ batch: UUID) {
        guard let b = exportBatches[batch], b.pending.isEmpty, b.walking == 0 else { return }
        exportBatches[batch] = nil
        let fm = FileManager.default
        let dir = RemoteTransferQueue.cacheDirectory.appendingPathComponent("export-" + batch.uuidString, isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for f in b.folders where f.allSatisfy(RemoteFilesReply.isSafeName) {
            try? fm.createDirectory(at: f.reduce(dir) { $0.appendingPathComponent($1, isDirectory: true) }, withIntermediateDirectories: true)
        }
        var moved = 0
        for (id, rel) in b.paths {
            guard let item = transfers.items.first(where: { $0.id == id }), item.state == .done, let src = item.localURL else { continue }
            let dest = rel.reduce(dir) { $0.appendingPathComponent($1) }
            // Second guard: every copy stays inside the export folder.
            guard rel.allSatisfy(RemoteFilesReply.isSafeName), Self.isInside(dest, dir) else { continue }
            try? fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            if (try? fm.moveItem(at: src, to: dest)) != nil {
                moved += 1
                try? fm.removeItem(at: src.deletingLastPathComponent())
            }
        }
        var seen = Set<String>()
        let urls = b.tops.filter { RemoteFilesReply.isSafeName($0) && seen.insert($0).inserted }.map { dir.appendingPathComponent($0) }.filter { fm.fileExists(atPath: $0.path) }
        Log.info("files export: batch=\(batch.uuidString.prefix(8)) ready moved=\(moved) urls=\(urls.count) failed=\(b.failed)")
        guard !urls.isEmpty, moved > 0 || !b.folders.isEmpty else {
            try? fm.removeItem(at: dir)
            // Never silent: the person pressed Save or Share and must hear what happened.
            show(.text(String(localized: "Nothing could be copied from the Mac.")))
            return
        }
        if b.truncated { show(.text(String(localized: "Only the first \(Self.maxExportFiles) files are included."))) }
        export = RemoteFilesExport(mode: b.mode, urls: urls, directory: dir, failed: b.failed)
    }

    /// `dest` lies inside `dir`. Plain paths, never `standardizedFileURL`: on iOS the temporary
    /// folder is under /private/var, and standardizing drops "/private" only for paths that
    /// exist, so the folder (which exists) and a file not moved there yet never matched and
    /// every Save and Share ended with nothing (owner report 2026-10-31, iPad log moved=0).
    nonisolated static func isInside(_ dest: URL, _ dir: URL) -> Bool {
        let base = dir.path.hasSuffix("/") ? dir.path : dir.path + "/"
        return dest.path.hasPrefix(base) && !dest.pathComponents.contains("..")
    }

    /// Stops preparing copies for Save or Share; what was copied so far is removed.
    func cancelExports() {
        let ids = Set(exportBatches.keys)
        exportBatches = [:]
        for item in transfers.items where ids.contains(item.batch) && !item.state.isFinished { transfers.cancel(item.id) }
        for b in ids { try? FileManager.default.removeItem(at: RemoteTransferQueue.cacheDirectory.appendingPathComponent("export-" + b.uuidString, isDirectory: true)) }
    }

    /// The save or share sheet is done: the copies on this device go.
    func exportFinished(_ e: RemoteFilesExport, completed: Bool) {
        try? FileManager.default.removeItem(at: e.directory)
        if export?.id == e.id { export = nil }
        if completed, e.mode == .save {
            show(.text(e.failed > 0 ? String(localized: "Saved. \(e.failed) couldn't be copied.") : String(localized: "Saved to this device.")))
        } else if completed {
            show(.text(e.failed > 0 ? String(localized: "Shared. \(e.failed) couldn't be copied.") : String(localized: "Shared.")))
        }
    }

    /// Uploads files and folders the user picked into the current folder.
    func upload(_ urls: [URL]) {
        guard allowed("upload"), case .folder(let root, let path) = location, !urls.isEmpty else { return }
        let batch = UUID()
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let name = url.lastPathComponent
                Task { @MainActor [weak self] in await self?.uploadFolder(url, name: name, root: root, path: path, batch: batch) }
            } else {
                transfers.upload(url, root: root, path: path, batch: batch, scoped: url)
            }
        }
        show(.text(String(localized: "Uploading to the Mac…")))
    }

    private func askFolderConflict(_ name: String) async -> RemoteFolderConflict.Choice? {
        await withCheckedContinuation { (c: CheckedContinuation<RemoteFolderConflict.Choice?, Never>) in
            var answered = false
            folderConflict = RemoteFolderConflict(name: name) { [weak self] choice in
                guard !answered else { return }
                answered = true
                self?.folderConflict = nil
                c.resume(returning: choice)
            }
        }
    }

    private func uploadFolder(_ url: URL, name: String, root: String, path: [String], batch: UUID) async {
        guard let clean = Self.cleanName(name) else { return }
        var r = await request("mkdir", ["root": root, "path": path, "name": clean, "conflict": "ask"])
        if !r.ok, r.error == "exists" {
            switch await askFolderConflict(clean) {
            case .merge: r = await request("mkdir", ["root": root, "path": path, "name": clean, "conflict": "skip"])
            case .keepBoth: r = await request("mkdir", ["root": root, "path": path, "name": clean, "conflict": "rename"])
            case .skip, nil: return
            }
        }
        guard report(r) else { return }
        let top = path + [r.name ?? clean]
        refresh()

        // Everything inside, without following links; hidden files (.DS_Store and the like) stay here.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return }
        var folders: [[String]] = []
        var files: [(URL, [String])] = []
        let base = url.standardizedFileURL.pathComponents.count
        while let item = e.nextObject() as? URL, folders.count + files.count < Self.maxExportFiles {
            let v = try? item.resourceValues(forKeys: Set(keys))
            if v?.isSymbolicLink == true { continue }
            let rel = Array(item.standardizedFileURL.pathComponents.dropFirst(base))
            guard !rel.isEmpty, rel.allSatisfy({ Self.cleanName($0) == $0 }) else { continue }
            if v?.isDirectory == true { folders.append(rel) } else if v?.isRegularFile == true { files.append((item, rel)) }
        }
        for f in folders.sorted(by: { $0.count < $1.count }) {
            let m = await request("mkdir", ["root": root, "path": top + f.dropLast(), "name": f.last!, "conflict": "skip"])
            guard report(m) else { return }
        }
        for (file, rel) in files {
            transfers.upload(file, name: rel.last, root: root, path: top + rel.dropLast(), batch: batch, scoped: url)
        }
    }

    func remoteChanged(root: String, path: [String]) {
        guard case .folder(let r, let p) = location, r == root, p == path else { return }
        refreshSoon()
    }

    private func refreshSoon() {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }
}

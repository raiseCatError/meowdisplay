import AppKit
import Foundation
import ImageIO
import QuickLookThumbnailing
import UniformTypeIdentifiers

// Remote Finder (PROTOCOL.md 6.12): a receiver browses folders the owner of this
// Mac approved, read-only. Off by default; every session also needs the owner's
// approval on the Mac; turning it off refuses the very next request. Paths are
// resolved and checked on the Mac (canonical path inside an approved folder, no
// symlink escapes, nothing hidden, never ~/Library). Opening a file is the only
// action, and it needs control like any click. There is no write, delete, upload
// or transfer operation.

/// The owner's settings: the switch and the approved folders.
enum RemoteFilesPolicy {
    static let enabledKey = "remoteFilesEnabled"
    static let rootsKey = "remoteFilesRoots"

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: enabledKey)
    }

    /// Bumped whenever the owner flips the Files switch: approvals given before don't carry over.
    static let epochKey = "remoteFilesEpoch"
    static func epoch(defaults: UserDefaults = .standard) -> Int { defaults.integer(forKey: epochKey) }
    static func bumpEpoch(defaults: UserDefaults = .standard) { defaults.set(epoch(defaults: defaults) &+ 1, forKey: epochKey) }

    /// A folder the owner may approve: inside their home folder (never ~/Library) or on a
    /// mounted volume, and never a system location, another user's home or `/Users` itself.
    static func isAllowedRoot(_ url: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        let path = canonical(url).path
        let homePath = canonical(home).path
        if fold(path) == fold(homePath) { return path == homePath }
        if path.hasPrefix(homePath + "/") {
            return !isProtected(URL(fileURLWithPath: path), home: home)
                && !path.dropFirst(homePath.count + 1).split(separator: "/").contains { $0.hasPrefix(".") }
        }
        let parts = path.split(separator: "/")
        return parts.count >= 2 && parts[0] == "Volumes" && !parts.contains { $0.hasPrefix(".") }
            && !isProtected(URL(fileURLWithPath: path), home: home)
    }

    /// Mac volumes are usually case-insensitive: `library` is `Library`. Protected locations
    /// are compared case-folded so a different spelling can't reach them.
    static func fold(_ s: some StringProtocol) -> String { String(s).folding(options: [.caseInsensitive], locale: nil) }

    static func canonical(_ url: URL) -> URL { url.resolvingSymlinksInPath().standardizedFileURL }

    /// One path component from the wire: a plain name, never `.`/`..`, hidden, or with a separator.
    static func isValidComponent(_ c: String) -> Bool {
        !c.isEmpty && c.count <= 255 && !c.hasPrefix(".") && !c.contains("/") && !c.contains("\0") && !c.contains(":")
    }

    /// `components` inside `root`, canonical, or nil when it would leave the folder (through
    /// `..`, a symlink or anything else), is hidden, or lies in a protected location.
    static func resolve(root: URL, components: [String], home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        guard components.count <= 64, components.allSatisfy(isValidComponent) else { return nil }
        let base = canonical(root)
        var url = base
        for c in components { url.appendPathComponent(c) }
        let resolved = canonical(url)
        guard resolved.path == base.path || resolved.path.hasPrefix(base.path + "/") else { return nil }
        guard !isProtected(resolved, home: home) else { return nil }
        // Every step below the root is visible (no hidden folder on the way after symlinks).
        let rest = resolved.path.dropFirst(base.path.count).split(separator: "/")
        guard !rest.contains(where: { $0.hasPrefix(".") }) else { return nil }
        return resolved
    }

    /// Never shown, even inside an approved folder: the home folder's Library (Keychains,
    /// app data, mail, messages) and other users' homes.
    static func isProtected(_ url: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        let path = fold(url.path)
        let homePath = fold(canonical(home).path)
        if path == homePath + "/library" || path.hasPrefix(homePath + "/library/") { return true }
        let parts = path.split(separator: "/")
        if parts.count >= 2, parts[0] == "users", "/users/\(parts[1])" != homePath, parts[1] != "shared" { return true }
        return false
    }

    /// What a receiver needs to pick an icon and a preview.
    static func kind(of url: URL, isDirectory: Bool, isPackage: Bool) -> String {
        if isDirectory && !isPackage { return "folder" }
        guard let type = UTType(filenameExtension: url.pathExtension) else { return "file" }
        if type.conforms(to: .application) || type.conforms(to: .applicationBundle) { return "app" }
        if type.conforms(to: .image) { return "image" }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return "video" }
        if type.conforms(to: .audio) { return "audio" }
        if type.conforms(to: .pdf) { return "pdf" }
        if type.conforms(to: .archive) { return "archive" }
        if isText(type) { return "text" }
        if type.conforms(to: .presentation) || type.conforms(to: .spreadsheet) || type.conforms(to: .compositeContent) { return "document" }
        return "file"
    }

    static func isText(_ type: UTType) -> Bool {
        type.conforms(to: .text) || type.conforms(to: .sourceCode) || type.conforms(to: .json) || type.conforms(to: .xml)
            || type.conforms(to: .propertyList) || type.conforms(to: .yaml)
    }
}

/// An approved folder, kept by the owner in Settings.
struct RemoteFileRoot: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var path: String
    var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
    var name: String { FileManager.default.displayName(atPath: path) }

    static func load(defaults: UserDefaults = .standard) -> [RemoteFileRoot] {
        guard let data = defaults.data(forKey: RemoteFilesPolicy.rootsKey),
              let roots = try? JSONDecoder().decode([RemoteFileRoot].self, from: data) else { return [] }
        return roots.filter { RemoteFilesPolicy.isAllowedRoot($0.url) }
    }

    static func save(_ roots: [RemoteFileRoot], defaults: UserDefaults = .standard) {
        defaults.set(try? JSONEncoder().encode(roots), forKey: RemoteFilesPolicy.rootsKey)
    }
}

/// One session's Remote Finder. Requests are answered on a private queue; the owner's
/// approval comes from the Mac's prompt (`askConsent`), once per session.
final class RemoteFileBrowser: @unchecked Sendable {
    enum Consent: Equatable { case none, asking, granted, denied }

    /// A message for the receiver (the sender gates it on admission).
    var sendMessage: (([String: Any]) -> Void)?
    /// Show the owner's prompt; answer with `consentDecided(_:)`.
    var askConsent: (() -> Void)?
    var isEnabled: () -> Bool = { RemoteFilesPolicy.isEnabled() }
    var roots: () -> [RemoteFileRoot] = { RemoteFileRoot.load() }
    var home = FileManager.default.homeDirectoryForCurrentUser
    /// Opens a file on the Mac, in its default app or in the app with this bundle id
    /// (tests replace it). Never brings the app forward.
    var openOnMac: (URL, String?) -> Bool = { url, bundleID in
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        if let bundleID {
            guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return false }
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: configuration)
        } else {
            NSWorkspace.shared.open(url, configuration: configuration)
        }
        return true
    }

    private let queue = DispatchQueue(label: "meow.files", qos: .userInitiated)
    private let previewQueue = DispatchQueue(label: "meow.files.preview", qos: .userInitiated, attributes: .concurrent)
    private let previewSlots = DispatchSemaphore(value: 2)
    private let thumbQueue = DispatchQueue(label: "meow.files.thumbs", qos: .utility)
    private var thumbGeneration = 0
    private var consent = Consent.none
    private var searchGeneration = 0
    private var previewGeneration = 0
    private var stopped = false

    static let maxEntries = 2000
    static let maxSearchResults = 200
    static let maxSearchVisited = 40_000
    static let searchBudget: TimeInterval = 2.5
    static let textPreviewBytes = 32 * 1024
    static let maxPreviewSide = 1024
    static let maxThumbNames = 48
    static let maxThumbSide = 256

    // MARK: Requests

    func handle(_ obj: [String: Any], inputGranted: Bool) {
        let box = FilesMessageBox(value: obj)
        queue.async { [self] in handleOnQueue(box.value, inputGranted: inputGranted) }
    }

    /// The owner answered the prompt.
    func consentDecided(_ allowed: Bool) {
        queue.async { [self] in
            guard consent == .asking else { return }
            consent = allowed ? .granted : .denied
            Log.info("files: owner \(allowed ? "allowed" : "declined") browsing for this session")
            sendState(req: nil)
        }
    }

    /// The session ended (or the switch went off): nothing more is answered.
    func stop() {
        queue.sync { stopped = true; consent = .none; searchGeneration += 1; previewGeneration += 1; thumbGeneration += 1 }
    }

    private func handleOnQueue(_ obj: [String: Any], inputGranted: Bool) {
        guard !stopped else { return }
        let op = obj["op"] as? String ?? ""
        let req = obj["req"] as? Int
        guard isEnabled() else { return reply(op, req: req, error: "off") }
        switch consent {
        case .granted: break
        case .denied: return reply(op, req: req, error: "denied")
        case .asking: return reply(op, req: req, error: "asking")
        case .none:
            // Only an explicit request to start browsing asks the owner.
            guard op == "state" else { return reply(op, req: req, error: "asking") }
            consent = .asking
            Log.info("files: asking the owner to allow browsing")
            askConsent?()
            return sendState(req: req)
        }
        switch op {
        case "state": sendState(req: req)
        case "list": list(obj, req: req)
        case "search": search(obj, req: req)
        case "preview": preview(obj, req: req)
        case "thumbs": thumbs(obj, req: req)
        case "open": open(obj, req: req, inputGranted: inputGranted)
        default: reply(op, req: req, error: "unsupported")
        }
    }

    private func sendState(req: Int?) {
        var m: [String: Any] = ["type": WireMessage.files, "op": "state"]
        if let req { m["req"] = req }
        guard isEnabled() else {
            m["state"] = "off"
            return send(m)
        }
        switch consent {
        case .none, .asking: m["state"] = "asking"
        case .denied: m["state"] = "denied"
        case .granted:
            let roots = roots()
            m["state"] = roots.isEmpty ? "noFolders" : "ready"
            m["roots"] = roots.map { ["id": $0.id, "name": $0.name] }
        }
        send(m)
    }

    private func root(_ obj: [String: Any]) -> RemoteFileRoot? {
        guard let id = obj["root"] as? String else { return nil }
        return roots().first { $0.id == id }
    }

    private func components(_ obj: [String: Any]) -> [String] { (obj["path"] as? [String]) ?? [] }

    // MARK: List

    private func list(_ obj: [String: Any], req: Int?) {
        guard let root = root(obj), let dir = RemoteFilesPolicy.resolve(root: root.url, components: components(obj), home: home) else {
            return reply("list", req: req, error: "notFound")
        }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey, .isHiddenKey]
        let items: [URL]
        do {
            items = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        } catch {
            // Most often macOS privacy (Files and Folders) refusing this app.
            return reply("list", req: req, error: "permission")
        }
        var entries: [[String: Any]] = []
        let here = components(obj)
        for url in items where entries.count < Self.maxEntries {
            // Listed only if it could be opened: a symlink leading out of the folder isn't.
            guard RemoteFilesPolicy.resolve(root: root.url, components: here + [url.lastPathComponent], home: home) != nil else { continue }
            if let e = entry(url) { entries.append(e) }
        }
        entries.sort { a, b in
            let da = a["dir"] as? Bool ?? false, db = b["dir"] as? Bool ?? false
            if da != db { return da }
            return (a["name"] as? String ?? "").localizedStandardCompare(b["name"] as? String ?? "") == .orderedAscending
        }
        var m: [String: Any] = ["type": WireMessage.files, "op": "list", "ok": true, "root": root.id,
                                "path": components(obj), "entries": entries]
        if items.count > Self.maxEntries { m["truncated"] = true }
        if let req { m["req"] = req }
        send(m)
    }

    private func entry(_ url: URL, relativeTo base: URL? = nil) -> [String: Any]? {
        let name = url.lastPathComponent
        guard RemoteFilesPolicy.isValidComponent(name), !RemoteFilesPolicy.isProtected(url, home: home) else { return nil }
        let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey, .isHiddenKey])
        if v?.isHidden == true { return nil }
        let isDir = v?.isDirectory ?? false, isPackage = v?.isPackage ?? false
        var e: [String: Any] = ["name": name, "dir": isDir && !isPackage,
                                "kind": RemoteFilesPolicy.kind(of: url, isDirectory: isDir, isPackage: isPackage)]
        if !isDir || isPackage, let size = v?.fileSize { e["size"] = size }
        if let date = v?.contentModificationDate { e["mod"] = Int(date.timeIntervalSince1970) }
        if let base {
            // A search result: where it is, below the root.
            let parent = RemoteFilesPolicy.canonical(url.deletingLastPathComponent()).path
            let rest = parent.hasPrefix(base.path) ? parent.dropFirst(base.path.count).split(separator: "/").map(String.init) : []
            e["in"] = rest
        }
        return e
    }

    // MARK: Search

    private func search(_ obj: [String: Any], req: Int?) {
        guard let root = root(obj), let start = RemoteFilesPolicy.resolve(root: root.url, components: components(obj), home: home) else {
            return reply("search", req: req, error: "notFound")
        }
        let query = (obj["q"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, query.count <= 100 else { return reply("search", req: req, error: "badQuery") }
        searchGeneration += 1
        let generation = searchGeneration
        let base = RemoteFilesPolicy.canonical(root.url)
        let home = self.home
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let deadline = Date().addingTimeInterval(Self.searchBudget)
            var results: [URL] = []
            var visited = 0
            var complete = true
            let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
            if let walker = FileManager.default.enumerator(at: start, includingPropertiesForKeys: keys,
                                                          options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
                for case let url as URL in walker {
                    visited += 1
                    if visited % 256 == 0 {
                        let stale = self?.queue.sync { self?.searchGeneration != generation } ?? true
                        if stale { return }
                    }
                    if visited > Self.maxSearchVisited || Date() > deadline || results.count >= Self.maxSearchResults { complete = false; break }
                    if RemoteFilesPolicy.isProtected(url, home: home) { walker.skipDescendants(); continue }
                    guard url.lastPathComponent.localizedCaseInsensitiveContains(query) else { continue }
                    let path = RemoteFilesPolicy.canonical(url).path
                    let rel = path.hasPrefix(base.path + "/") ? path.dropFirst(base.path.count + 1).split(separator: "/").map(String.init) : []
                    if !rel.isEmpty, RemoteFilesPolicy.resolve(root: base, components: rel, home: home) != nil { results.append(url) }
                }
            }
            self?.queue.async {
                guard let self, self.searchGeneration == generation, !self.stopped else { return }
                let entries = results.compactMap { self.entry($0, relativeTo: base) }
                var m: [String: Any] = ["type": WireMessage.files, "op": "search", "ok": true, "root": root.id,
                                        "q": query, "entries": entries, "complete": complete]
                if let req { m["req"] = req }
                self.send(m)
            }
        }
    }

    // MARK: Preview

    private func preview(_ obj: [String: Any], req: Int?) {
        guard let root = root(obj), let url = RemoteFilesPolicy.resolve(root: root.url, components: components(obj), home: home) else {
            return reply("preview", req: req, error: "notFound")
        }
        previewGeneration += 1
        let generation = previewGeneration
        let side = min(max(obj["max"] as? Int ?? 640, 64), Self.maxPreviewSide)
        let path = components(obj)
        previewQueue.async { [weak self] in
            guard let self else { return }
            self.previewSlots.wait()
            defer { self.previewSlots.signal() }
            // Only the newest preview matters (the receiver moved on).
            guard self.queue.sync(execute: { self.previewGeneration == generation && !self.stopped }) else { return }
            var m: [String: Any] = ["type": WireMessage.files, "op": "preview", "root": root.id, "path": path]
            if let req { m["req"] = req }
            let type = UTType(filenameExtension: url.pathExtension)
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if let type, RemoteFilesPolicy.isText(type), size <= 8 * 1024 * 1024, let text = Self.textExcerpt(url) {
                m["ok"] = true
                m["text"] = text.text
                if text.truncated { m["truncated"] = true }
            } else if let jpeg = Self.thumbnail(url, side: side) {
                m["ok"] = true
                m["jpeg"] = jpeg.data.base64EncodedString()
                m["w"] = jpeg.width
                m["h"] = jpeg.height
            } else {
                m["ok"] = false
                m["error"] = "noPreview"
            }
            self.queue.async {
                guard self.previewGeneration == generation, !self.stopped else { return }
                self.send(m)
            }
        }
    }

    static func textExcerpt(_ url: URL) -> (text: String, truncated: Bool)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: textPreviewBytes + 1) else { return nil }
        let truncated = data.count > textPreviewBytes
        let text = String(decoding: data.prefix(textPreviewBytes), as: UTF8.self)
        return (text, truncated)
    }

    /// Quick Look's own thumbnail (images, video posters, PDFs, documents), as a JPEG.
    static func thumbnail(_ url: URL, side: Int) -> (data: Data, width: Int, height: Int)? {
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: side, height: side), scale: 1,
                                                   representationTypes: [.thumbnail])
        let done = DispatchSemaphore(value: 0)
        let box = ThumbnailBox()
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
            box.image = rep?.cgImage
            done.signal()
        }
        guard done.wait(timeout: .now() + 4) == .success, let image = box.image else {
            QLThumbnailGenerator.shared.cancel(request)
            return nil
        }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.72] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return (data as Data, image.width, image.height)
    }

    // MARK: Thumbnails (grid view)

    /// Small Quick Look thumbnails for files in one folder, one reply each. A newer request
    /// replaces the rest of an older one (the receiver scrolled or left the folder).
    private func thumbs(_ obj: [String: Any], req: Int?) {
        guard let root = root(obj), RemoteFilesPolicy.resolve(root: root.url, components: components(obj), home: home) != nil else {
            return reply("thumbs", req: req, error: "notFound")
        }
        let names = ((obj["names"] as? [String]) ?? []).prefix(Self.maxThumbNames).filter(RemoteFilesPolicy.isValidComponent)
        let side = min(max(obj["max"] as? Int ?? 160, 32), Self.maxThumbSide)
        let path = components(obj)
        let home = self.home
        thumbGeneration += 1
        let generation = thumbGeneration
        for name in names {
            thumbQueue.async { [weak self] in
                guard let self, self.queue.sync(execute: { self.thumbGeneration == generation && !self.stopped }) else { return }
                var m: [String: Any] = ["type": WireMessage.files, "op": "thumb", "root": root.id, "path": path, "name": name]
                if let url = RemoteFilesPolicy.resolve(root: root.url, components: path + [name], home: home),
                   let jpeg = Self.thumbnail(url, side: side) {
                    m["ok"] = true
                    m["jpeg"] = jpeg.data.base64EncodedString()
                    m["w"] = jpeg.width
                    m["h"] = jpeg.height
                } else {
                    m["ok"] = false
                }
                self.queue.async {
                    guard self.thumbGeneration == generation, !self.stopped else { return }
                    self.send(m)
                }
            }
        }
    }

    // MARK: Open

    private func open(_ obj: [String: Any], req: Int?, inputGranted: Bool) {
        // Opening runs an app on the Mac: the same control grant as any click.
        guard inputGranted else { return reply("open", req: req, error: "control") }
        guard let root = root(obj), let url = RemoteFilesPolicy.resolve(root: root.url, components: components(obj), home: home),
              !components(obj).isEmpty else {
            return reply("open", req: req, error: "notFound")
        }
        // Optional: open in the app a tile shows (dropped on that tile), by bundle id.
        let bundleID = (obj["with"] as? String).flatMap { $0.isEmpty || $0.count > 255 ? nil : $0 }
        let open = openOnMac
        DispatchQueue.main.async { [weak self] in
            let opened = open(url, bundleID)
            Log.info("files: open requested ok=\(opened)")
            self?.queue.async {
                var m: [String: Any] = ["type": WireMessage.files, "op": "open", "ok": opened]
                if let req { m["req"] = req }
                self?.send(m)
            }
        }
    }

    // MARK: Replies

    private func reply(_ op: String, req: Int?, error: String) {
        var m: [String: Any] = ["type": WireMessage.files, "op": op, "ok": false, "error": error]
        if let req { m["req"] = req }
        send(m)
    }

    private func send(_ m: [String: Any]) {
        guard !stopped else { return }
        sendMessage?(m)
    }
}

private final class ThumbnailBox: @unchecked Sendable { var image: CGImage? }
private struct FilesMessageBox: @unchecked Sendable { let value: [String: Any] }

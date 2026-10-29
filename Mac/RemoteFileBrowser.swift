import AppKit
import Foundation
import ImageIO
import QuickLookThumbnailing
import UniformTypeIdentifiers

// Remote Finder (PROTOCOL.md 6.12): a receiver browses, previews, downloads and (when the
// owner allows it) uploads and changes files on this Mac. Off by default; each device needs
// the owner's grant: per session from the Mac's prompt, or always (Settings ▸ Devices ▸
// Files, `FilesDevicePolicyStore`), separately for browse, download, upload, modify and
// delete, over the approved folders or every file this Mac user and macOS let MeowDisplay
// read. Every request is checked again against the live switch and policy; turning either
// off refuses the very next request and ends running transfers. Paths are resolved and
// checked on the Mac (canonical path inside a root, no symlink escapes, never ~/Library or
// secret dot-folders). Opening a file runs an app, so it also needs control like any click.

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

    /// One path component from the wire: a plain name, never `.`/`..`, hidden (unless allowed),
    /// or with a separator.
    static func isValidComponent(_ c: String) -> Bool { isValidComponent(c, allowHidden: false) }

    static func isValidComponent(_ c: String, allowHidden: Bool) -> Bool {
        !c.isEmpty && c.count <= 255 && c != "." && c != ".." && (allowHidden || !c.hasPrefix("."))
            && !c.contains("/") && !c.contains("\0") && !c.contains(":")
            && !c.hasPrefix(".meowdisplay-")   // an upload in progress
    }

    /// `components` inside `root`, canonical, or nil when it would leave the folder (through
    /// `..`, a symlink or anything else), is hidden (unless allowed), or lies in a protected location.
    static func resolve(root: URL, components: [String], home: URL = FileManager.default.homeDirectoryForCurrentUser,
                        allowHidden: Bool = false) -> URL? {
        guard components.count <= 64, components.allSatisfy({ isValidComponent($0, allowHidden: allowHidden) }) else { return nil }
        let base = canonical(root)
        var url = base
        for c in components { url.appendPathComponent(c) }
        let resolved = canonical(url)
        guard resolved.path == base.path || resolved.path.hasPrefix(base.path + "/") else { return nil }
        guard !isProtected(resolved, home: home) else { return nil }
        // Every step below the root is visible (no hidden folder on the way after symlinks).
        let rest = resolved.path.dropFirst(base.path.count).split(separator: "/")
        guard allowHidden || !rest.contains(where: { $0.hasPrefix(".") }) else { return nil }
        return resolved
    }

    /// The folder `components` names, for creating something in it: like `resolve`, and a directory.
    static func resolveFolder(root: URL, components: [String], home: URL, allowHidden: Bool) -> URL? {
        guard let url = resolve(root: root, components: components, home: home, allowHidden: allowHidden) else { return nil }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return nil }
        return url
    }

    /// Dot-folders and files in the home folder that hold credentials: never reachable, even
    /// with hidden files shown.
    static let secretHomeItems: Set<String> = [".ssh", ".gnupg", ".aws", ".azure", ".kube", ".docker", ".config",
                                               ".netrc", ".npmrc", ".pypirc", ".git-credentials", ".password-store",
                                               ".local", ".gcloud", ".terraform.d", ".vault-token", ".zsh_history",
                                               ".bash_history", ".Trash"]

    /// Never shown, even inside an approved folder: the home folder's Library (Keychains,
    /// app data, mail, messages) and other users' homes.
    static func isProtected(_ url: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        let path = fold(url.path)
        let homePath = fold(canonical(home).path)
        if path == homePath + "/library" || path.hasPrefix(homePath + "/library/") { return true }
        if path.hasPrefix(homePath + "/"), let first = path.dropFirst(homePath.count + 1).split(separator: "/").first,
           secretHomeItems.contains(where: { fold($0) == String(first) }) { return true }
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
/// grant comes from the Mac's prompt or the device's stored policy (`askConsent`).
final class RemoteFileBrowser: @unchecked Sendable {
    enum Consent: Equatable { case none, asking, granted(FilesGrant), denied }

    /// A message for the receiver (the sender gates it on admission).
    var sendMessage: (([String: Any]) -> Void)?
    /// Ask the owner (or the device's stored policy): `nil` for browsing at all, or the extra
    /// capabilities a receiver asked for. Answer with `consentDecided(_:)` / `accessDecided(_:)`.
    var askConsent: ((Set<FilesCapability>?) -> Void)?
    var isEnabled: () -> Bool = { RemoteFilesPolicy.isEnabled() }
    /// The approved folders (scope `selectedFolders`).
    var roots: () -> [RemoteFileRoot] = { RemoteFileRoot.load() }
    /// This device's stored policy, read on every request (nil: no identity, the default).
    var livePolicy: () -> FilesDevicePolicy? = { nil }
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
    /// Moves an item to the Trash (tests replace it); returns where it went.
    var moveToTrash: (URL) throws -> URL? = { url in
        var result: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &result)
        return result as URL?
    }

    private let queue = DispatchQueue(label: "meow.files", qos: .userInitiated)
    private let previewQueue = DispatchQueue(label: "meow.files.preview", qos: .userInitiated, attributes: .concurrent)
    private let previewSlots = DispatchSemaphore(value: 2)
    private let thumbQueue = DispatchQueue(label: "meow.files.thumbs", qos: .utility)
    /// Copies, moves, compression: one at a time, off the request queue.
    private let workQueue = DispatchQueue(label: "meow.files.work", qos: .utility)
    private var thumbGeneration = 0
    private var consent = Consent.none
    /// Capabilities the owner added for this session only (over the prompt's or the policy's).
    private var sessionCapabilities: Set<FilesCapability> = []
    /// Capabilities asked for and not yet answered.
    private var pendingAccess: (caps: Set<FilesCapability>, req: Int?)?
    private var searchGeneration = 0
    private var previewGeneration = 0
    private var stopped = false
    private lazy var transfers: RemoteFileTransfers = {
        let t = RemoteFileTransfers()
        t.trash = { [weak self] url in _ = try self?.moveToTrash(url) }
        return t
    }()
    /// The capability each open download was granted under (view: browse; save/share: download).
    private var downloadNeeds: [Int: FilesCapability] = [:]
    /// Items this session moved to the Trash, for Put Back: token → (in the Trash, where it was).
    private var trashed: [String: (trash: URL, original: URL)] = [:]

    static let maxEntries = 2000
    static let maxSearchResults = 200
    static let maxSearchVisited = 40_000
    static let searchBudget: TimeInterval = 2.5
    static let textPreviewBytes = 32 * 1024
    static let maxPreviewSide = 1600
    static let maxPreviewBase64 = 2_400_000
    static let maxThumbNames = 48
    static let maxThumbSide = 256

    // MARK: Requests

    func handle(_ obj: [String: Any], inputGranted: Bool) {
        let box = FilesMessageBox(value: obj)
        queue.async { [self] in handleOnQueue(box.value, inputGranted: inputGranted) }
    }

    /// The owner (or the stored policy) answered the browsing question: a grant, or nil for no.
    func consentDecided(_ grant: FilesGrant?) {
        queue.async { [self] in
            guard consent == .asking else { return }
            consent = grant.map(Consent.granted) ?? .denied
            Log.info("files: \(grant.map { "allowed (\($0.duration.rawValue), \($0.scope.rawValue), \($0.capabilities.sorted().map(\.rawValue)))" } ?? "declined")")
            sendState(req: nil)
        }
    }

    /// Older call sites and tests: allowed = read-only for this session.
    func consentDecided(_ allowed: Bool) { consentDecided(allowed ? FilesGrant.session() : nil) }

    /// The owner answered a request for more capabilities: those granted for this session (an
    /// Always answer is also stored in the device's policy), or nil for no.
    func accessDecided(_ granted: Set<FilesCapability>?) {
        queue.async { [self] in
            guard let pending = pendingAccess else { return }
            pendingAccess = nil
            if let granted { sessionCapabilities.formUnion(granted) }
            var m: [String: Any] = ["type": WireMessage.files, "op": "requestAccess"]
            if let req = pending.req { m["req"] = req }
            let ok = effectiveGrant().map { pending.caps.isSubset(of: $0.capabilities) } ?? false
            m["ok"] = ok
            if !ok { m["error"] = "denied" }
            send(m)
            sendState(req: nil)
        }
    }

    /// The owner revoked this session's access in Settings: transfers end, the next request asks again.
    func revoke() {
        queue.async { [self] in
            guard consent != .none else { return }
            consent = .none
            pendingAccess = nil
            sessionCapabilities = []
            transfers.stopAll()
            Log.info("files: access revoked by the owner")
            var m: [String: Any] = ["type": WireMessage.files, "op": "state", "state": "revoked"]
            m["ok"] = true
            send(m)
        }
    }

    /// The session ended (or the switch went off): nothing more is answered.
    func stop() {
        queue.sync {
            stopped = true; consent = .none; searchGeneration += 1; previewGeneration += 1; thumbGeneration += 1
            transfers.stopAll()
        }
    }

    /// The grant that applies now, re-checked against the switch and the device's live policy.
    private func effectiveGrant() -> FilesGrant? {
        guard case .granted(var g) = consent else { return nil }
        let p = livePolicy() ?? .default
        if p.access == .block {
            consent = .denied
            transfers.stopAll()
            return nil
        }
        if g.duration == .always {
            guard p.access == .always else {
                // Always Allow was turned off: this session asks again.
                consent = .none
                transfers.stopAll()
                return nil
            }
            g = .always(p)   // follows the owner's changes at once
            consent = .granted(g)
        }
        g.capabilities.formUnion(sessionCapabilities)
        return g
    }

    private func handleOnQueue(_ obj: [String: Any], inputGranted: Bool) {
        guard !stopped else { return }
        let op = obj["op"] as? String ?? ""
        let req = obj["req"] as? Int
        guard isEnabled() else {
            transfers.stopAll()
            return reply(op, req: req, error: "off")
        }
        switch consent {
        case .granted: break
        case .denied: return reply(op, req: req, error: "denied")
        case .asking: return reply(op, req: req, error: "asking")
        case .none:
            // Only an explicit request to start browsing asks the owner.
            guard op == "state" else { return reply(op, req: req, error: "asking") }
            if livePolicy()?.access == .block {
                consent = .denied
                return sendState(req: req)
            }
            consent = .asking
            Log.info("files: asking the owner to allow browsing")
            askConsent?(nil)
            return sendState(req: req)
        }
        guard let grant = effectiveGrant() else {
            return reply(op, req: req, error: consent == .denied ? "denied" : "revoked")
        }
        func need(_ c: FilesCapability) -> Bool {
            guard grant.allows(c) else { reply(op, req: req, error: "notAllowed", extra: ["need": c.rawValue]); return false }
            return true
        }
        switch op {
        case "state": sendState(req: req)
        case "list": if need(.browse) { list(obj, req: req, grant: grant) }
        case "search": if need(.browse) { search(obj, req: req, grant: grant) }
        case "preview": if need(.browse) { preview(obj, req: req, grant: grant) }
        case "thumbs": if need(.browse) { thumbs(obj, req: req, grant: grant) }
        case "info": if need(.browse) { info(obj, req: req, grant: grant) }
        case "openWithApps": if need(.browse) { openWithApps(obj, req: req, grant: grant) }
        case "open": if need(.browse) { open(obj, req: req, inputGranted: inputGranted, grant: grant) }
        case "requestAccess": requestAccess(obj, req: req, grant: grant)
        // Downloads: viewing in the receiver's app needs browse; saving or sharing a copy needs download.
        case "download":
            if need((obj["purpose"] as? String) == "view" ? .browse : .download) { download(obj, req: req, grant: grant) }
        case "read":
            // Re-checked on every range: a download stops as soon as its capability is withdrawn.
            if let x = obj["x"] as? Int, let c = downloadNeeds[x], !grant.allows(c) {
                transfers.close(x); downloadNeeds[x] = nil
                return reply(op, req: req, error: "notAllowed", extra: ["x": x, "need": c.rawValue])
            }
            read(obj, req: req)
        case "close": if let x = obj["x"] as? Int { transfers.close(x); downloadNeeds[x] = nil }
        case "uploadBegin":
            // Replacing moves the existing item to the Trash: that needs delete.
            if need(.upload), (obj["conflict"] as? String) != RemoteFileConflict.replace.rawValue || need(.delete) {
                uploadBegin(obj, req: req, grant: grant)
            }
        case "uploadData": if need(.upload) { uploadData(obj) }
        case "uploadEnd": if need(.upload) { uploadEnd(obj, req: req) }
        case "uploadCancel": if let x = obj["x"] as? Int { transfers.cancelUpload(x) }
        case "mkdir": if need(.upload) { mkdir(obj, req: req, grant: grant) }
        case "rename": if need(.modify) { rename(obj, req: req, grant: grant) }
        case "copy", "move", "duplicate":
            if need(.modify), (obj["conflict"] as? String) != RemoteFileConflict.replace.rawValue || need(.delete) {
                copyOrMove(op, obj, req: req, grant: grant)
            }
        case "zip": if need(.modify) { compress(obj, req: req, grant: grant) }
        case "unzip": if need(.modify) { expand(obj, req: req, grant: grant) }
        case "trash": if need(.delete) { trash(obj, req: req, grant: grant) }
        case "putBack": if need(.modify) { putBack(obj, req: req) }
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
            guard let g = effectiveGrant() else {
                m["state"] = consent == .denied ? "denied" : "asking"
                return send(m)
            }
            let roots = roots(for: g)
            m["state"] = roots.isEmpty ? "noFolders" : "ready"
            m["roots"] = roots.map { ["id": $0.id, "name": $0.name] }
            m["grant"] = g.wire
        }
        send(m)
    }

    /// Where this grant reaches: the approved folders, or the home folder's usual places and
    /// mounted volumes (only what this Mac user and macOS privacy let MeowDisplay read).
    private func roots(for g: FilesGrant) -> [RemoteFileRoot] {
        switch g.scope {
        case .selectedFolders: return roots()
        case .allAccessible: return Self.accessibleRoots(home: home)
        }
    }

    static func accessibleRoots(home: URL) -> [RemoteFileRoot] {
        var out = [RemoteFileRoot(id: "home", path: home.path)]
        for (id, name) in [("desktop", "Desktop"), ("documents", "Documents"), ("downloads", "Downloads"),
                           ("pictures", "Pictures"), ("movies", "Movies"), ("music", "Music")] {
            let url = home.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { out.append(RemoteFileRoot(id: id, path: url.path)) }
        }
        let volumes = (FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? [])
        for v in volumes where v.path.hasPrefix("/Volumes/") && RemoteFilesPolicy.isAllowedRoot(v, home: home) && out.count < 32 {
            out.append(RemoteFileRoot(id: "vol:" + v.lastPathComponent, path: v.path))
        }
        return out
    }

    private func root(_ obj: [String: Any], key: String = "root", grant: FilesGrant) -> RemoteFileRoot? {
        guard let id = obj[key] as? String else { return nil }
        return roots(for: grant).first { $0.id == id }
    }

    private func components(_ obj: [String: Any], key: String = "path") -> [String] { (obj[key] as? [String]) ?? [] }

    /// The item `obj` names (root + path), resolved and checked for this grant.
    private func item(_ obj: [String: Any], grant: FilesGrant, rootKey: String = "root", pathKey: String = "path") -> (root: RemoteFileRoot, url: URL, path: [String])? {
        guard let root = root(obj, key: rootKey, grant: grant) else { return nil }
        let path = components(obj, key: pathKey)
        guard let url = RemoteFilesPolicy.resolve(root: root.url, components: path, home: home, allowHidden: grant.showHidden) else { return nil }
        return (root, url, path)
    }

    private func requestAccess(_ obj: [String: Any], req: Int?, grant: FilesGrant) {
        let caps = Set(((obj["caps"] as? [String]) ?? []).compactMap(FilesCapability.init(rawValue:)))
        guard !caps.isEmpty else { return reply("requestAccess", req: req, error: "badRequest") }
        if caps.isSubset(of: grant.capabilities) {
            return send(["type": WireMessage.files, "op": "requestAccess", "ok": true, "req": req as Any])
        }
        guard pendingAccess == nil else { return reply("requestAccess", req: req, error: "asking") }
        pendingAccess = (caps, req)
        Log.info("files: asking the owner for \(caps.sorted().map(\.rawValue))")
        askConsent?(caps)
    }

    // MARK: List

    private func list(_ obj: [String: Any], req: Int?, grant: FilesGrant) {
        guard let (root, dir, _) = item(obj, grant: grant) else {
            return reply("list", req: req, error: "notFound")
        }
        let hidden = grant.showHidden
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey, .isHiddenKey]
        let items: [URL]
        do {
            items = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: hidden ? [] : [.skipsHiddenFiles])
        } catch {
            // Most often macOS privacy (Files and Folders) refusing this app.
            return reply("list", req: req, error: "permission")
        }
        var entries: [[String: Any]] = []
        let here = components(obj)
        for url in items where entries.count < Self.maxEntries {
            // Listed only if it could be opened: a symlink leading out of the folder isn't.
            guard RemoteFilesPolicy.resolve(root: root.url, components: here + [url.lastPathComponent], home: home, allowHidden: hidden) != nil else { continue }
            if let e = entry(url, allowHidden: hidden) { entries.append(e) }
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

    private func entry(_ url: URL, relativeTo base: URL? = nil, allowHidden: Bool = false) -> [String: Any]? {
        let name = url.lastPathComponent
        guard RemoteFilesPolicy.isValidComponent(name, allowHidden: allowHidden), !RemoteFilesPolicy.isProtected(url, home: home) else { return nil }
        let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey,
                                                  .isHiddenKey, .creationDateKey, .isWritableKey])
        if v?.isHidden == true && !allowHidden { return nil }
        let isDir = v?.isDirectory ?? false, isPackage = v?.isPackage ?? false
        var e: [String: Any] = ["name": name, "dir": isDir && !isPackage,
                                "kind": RemoteFilesPolicy.kind(of: url, isDirectory: isDir, isPackage: isPackage)]
        if !isDir || isPackage, let size = v?.fileSize { e["size"] = size }
        if let date = v?.contentModificationDate { e["mod"] = Int(date.timeIntervalSince1970) }
        if let date = v?.creationDate { e["made"] = Int(date.timeIntervalSince1970) }
        if v?.isHidden == true || name.hasPrefix(".") { e["hidden"] = true }
        if v?.isWritable == false { e["ro"] = true }
        if let base {
            // A search result: where it is, below the root.
            let parent = RemoteFilesPolicy.canonical(url.deletingLastPathComponent()).path
            let rest = parent.hasPrefix(base.path) ? parent.dropFirst(base.path.count).split(separator: "/").map(String.init) : []
            e["in"] = rest
        }
        return e
    }

    // MARK: Search

    private func search(_ obj: [String: Any], req: Int?, grant: FilesGrant) {
        guard let (root, start, _) = item(obj, grant: grant) else {
            return reply("search", req: req, error: "notFound")
        }
        let hidden = grant.showHidden
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
                                                          options: hidden ? [.skipsPackageDescendants] : [.skipsHiddenFiles, .skipsPackageDescendants]) {
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
                    if !rel.isEmpty, RemoteFilesPolicy.resolve(root: base, components: rel, home: home, allowHidden: hidden) != nil { results.append(url) }
                }
            }
            self?.queue.async {
                guard let self, self.searchGeneration == generation, !self.stopped else { return }
                let entries = results.compactMap { self.entry($0, relativeTo: base, allowHidden: hidden) }
                var m: [String: Any] = ["type": WireMessage.files, "op": "search", "ok": true, "root": root.id,
                                        "q": query, "entries": entries, "complete": complete]
                if let req { m["req"] = req }
                self.send(m)
            }
        }
    }

    // MARK: Preview

    private func preview(_ obj: [String: Any], req: Int?, grant: FilesGrant) {
        guard let (root, url, _) = item(obj, grant: grant) else {
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
        // Lower quality until the base64 fits well inside the 1 MiB control-message limit
        // (QUIC drops a connection that sends more; a noisy 1024-sided photo can get close).
        for quality in [0.72, 0.5, 0.35] {
            let data = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            guard CGImageDestinationFinalize(dest) else { return nil }
            if (data.length + 2) / 3 * 4 <= Self.maxPreviewBase64 { return (data as Data, image.width, image.height) }
        }
        return nil
    }

    // MARK: Thumbnails (grid view)

    /// Small Quick Look thumbnails for files in one folder, one reply each. A newer request
    /// replaces the rest of an older one (the receiver scrolled or left the folder).
    private func thumbs(_ obj: [String: Any], req: Int?, grant: FilesGrant) {
        guard let (root, _, _) = item(obj, grant: grant) else {
            return reply("thumbs", req: req, error: "notFound")
        }
        let hidden = grant.showHidden
        let names = ((obj["names"] as? [String]) ?? []).prefix(Self.maxThumbNames).filter { RemoteFilesPolicy.isValidComponent($0, allowHidden: hidden) }
        let side = min(max(obj["max"] as? Int ?? 160, 32), Self.maxThumbSide)
        let path = components(obj)
        let home = self.home
        thumbGeneration += 1
        let generation = thumbGeneration
        for name in names {
            thumbQueue.async { [weak self] in
                guard let self, self.queue.sync(execute: { self.thumbGeneration == generation && !self.stopped }) else { return }
                var m: [String: Any] = ["type": WireMessage.files, "op": "thumb", "root": root.id, "path": path, "name": name]
                if let url = RemoteFilesPolicy.resolve(root: root.url, components: path + [name], home: home, allowHidden: hidden),
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

    private func open(_ obj: [String: Any], req: Int?, inputGranted: Bool, grant: FilesGrant) {
        // Opening runs an app on the Mac: the same control grant as any click.
        guard inputGranted else { return reply("open", req: req, error: "control") }
        guard let (_, url, path) = item(obj, grant: grant), !path.isEmpty else {
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

    // MARK: Downloads (bounded ranges the receiver asks for)

    private func download(_ obj: [String: Any], req: Int?, grant: FilesGrant) {
        guard let (_, url, path) = item(obj, grant: grant), !path.isEmpty else { return reply("download", req: req, error: "notFound") }
        do {
            let (x, size) = try transfers.openDownload(url)
            downloadNeeds[x] = (obj["purpose"] as? String) == "view" ? .browse : .download
            var fields: [String: Any] = ["x": x, "size": size, "name": url.lastPathComponent]
            if let m = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate {
                fields["mod"] = Int(m.timeIntervalSince1970)
            }
            if let type = UTType(filenameExtension: url.pathExtension) { fields["uti"] = type.identifier; fields["mime"] = type.preferredMIMEType ?? "" }
            replyOK("download", req: req, fields)
        } catch let e as RemoteFileTransfers.TransferError {
            reply("download", req: req, error: e.code)
        } catch {
            reply("download", req: req, error: "readFailed")
        }
    }

    /// One range: its bytes as `data` parts, then `read` with the range's digest.
    private func read(_ obj: [String: Any], req: Int?) {
        guard let x = obj["x"] as? Int, let o = (obj["o"] as? NSNumber)?.int64Value, let n = obj["n"] as? Int else {
            return reply("read", req: req, error: "badRequest")
        }
        do {
            let (parts, digest) = try transfers.read(x, offset: o, length: n)
            var at = o
            for part in parts {
                send(["type": WireMessage.files, "op": "data", "x": x, "o": at, "d": part.base64EncodedString()])
                at += Int64(part.count)
            }
            replyOK("read", req: req, ["x": x, "o": o, "n": Int(at - o), "sha": digest])
        } catch let e as RemoteFileTransfers.TransferError {
            reply("read", req: req, error: e.code, extra: ["x": x, "o": o])
        } catch {
            reply("read", req: req, error: "readFailed", extra: ["x": x])
        }
    }

    // MARK: Uploads

    private func uploadBegin(_ obj: [String: Any], req: Int?, grant: FilesGrant) {
        guard let root = root(obj, grant: grant),
              let folder = RemoteFilesPolicy.resolveFolder(root: root.url, components: components(obj), home: home, allowHidden: grant.showHidden),
              let name = obj["name"] as? String, RemoteFilesPolicy.isValidComponent(name, allowHidden: grant.showHidden),
              let size = (obj["size"] as? NSNumber)?.int64Value else {
            return reply("uploadBegin", req: req, error: "notFound")
        }
        let conflict = (obj["conflict"] as? String).flatMap(RemoteFileConflict.init(rawValue:)) ?? .ask
        let digest = (obj["sha"] as? String).flatMap { $0.count >= 16 && $0.count <= 64 && $0.allSatisfy(\.isHexDigit) ? $0 : nil }
        let modified = (obj["mod"] as? Int).map { Date(timeIntervalSince1970: TimeInterval($0)) }
        do {
            guard let (x, finalName) = try transfers.beginUpload(folder: folder, name: name, size: size, conflict: conflict,
                                                                 digest: digest, modified: modified) else {
                return replyOK("uploadBegin", req: req, ["skipped": true, "name": name])
            }
            replyOK("uploadBegin", req: req, ["x": x, "name": finalName])
        } catch let e as RemoteFileTransfers.TransferError {
            var extra: [String: Any] = [:]
            if e.code == "exists" { extra["suggest"] = RemoteFileTransfers.uniqueName(in: folder, name: name) }
            reply("uploadBegin", req: req, error: e.code, extra: extra)
        } catch {
            reply("uploadBegin", req: req, error: "writeFailed")
        }
    }

    private func uploadData(_ obj: [String: Any]) {
        guard let x = obj["x"] as? Int, let o = (obj["o"] as? NSNumber)?.int64Value, let d = obj["d"] as? String,
              d.count <= RemoteFileTransfers.maxUploadPart * 4 / 3 + 8, let data = Data(base64Encoded: d) else {
            if let x = obj["x"] as? Int { transfers.cancelUpload(x) }
            return send(["type": WireMessage.files, "op": "uploadAck", "ok": false, "error": "badRequest", "x": obj["x"] ?? 0])
        }
        do {
            let written = try transfers.write(x, offset: o, data: data)
            send(["type": WireMessage.files, "op": "uploadAck", "ok": true, "x": x, "o": written])
        } catch let e as RemoteFileTransfers.TransferError {
            send(["type": WireMessage.files, "op": "uploadAck", "ok": false, "x": x, "error": e.code])
        } catch {
            send(["type": WireMessage.files, "op": "uploadAck", "ok": false, "x": x, "error": "writeFailed"])
        }
    }

    private func uploadEnd(_ obj: [String: Any], req: Int?) {
        guard let x = obj["x"] as? Int else { return reply("uploadEnd", req: req, error: "badRequest") }
        do {
            let name = try transfers.finishUpload(x)
            Log.info("files: upload finished")
            replyOK("uploadEnd", req: req, ["x": x, "name": name])
        } catch let e as RemoteFileTransfers.TransferError {
            reply("uploadEnd", req: req, error: e.code, extra: ["x": x])
        } catch {
            reply("uploadEnd", req: req, error: "writeFailed", extra: ["x": x])
        }
    }

    // MARK: File management

    private func errorCode(_ error: Error) -> String {
        if let e = error as? RemoteFileTransfers.TransferError { return e.code }
        let ns = error as NSError
        switch (ns.domain, ns.code) {
        case (NSCocoaErrorDomain, NSFileWriteNoPermissionError), (NSCocoaErrorDomain, NSFileReadNoPermissionError),
             (NSPOSIXErrorDomain, Int(EPERM)), (NSPOSIXErrorDomain, Int(EACCES)): return "permission"
        case (NSCocoaErrorDomain, NSFileWriteOutOfSpaceError), (NSPOSIXErrorDomain, Int(ENOSPC)): return "noSpace"
        case (NSCocoaErrorDomain, NSFileWriteFileExistsError): return "exists"
        case (NSCocoaErrorDomain, NSFileNoSuchFileError), (NSCocoaErrorDomain, NSFileReadNoSuchFileError): return "notFound"
        case (NSCocoaErrorDomain, NSFileWriteVolumeReadOnlyError): return "readOnly"
        default:
            if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSPOSIXErrorDomain {
                if underlying.code == Int(EPERM) || underlying.code == Int(EACCES) { return "permission" }
                if underlying.code == Int(ENOSPC) { return "noSpace" }
            }
            return "failed"
        }
    }

    private func mkdir(_ obj: [String: Any], req: Int?, grant: FilesGrant) {
        guard let root = root(obj, grant: grant),
              let folder = RemoteFilesPolicy.resolveFolder(root: root.url, components: components(obj), home: home, allowHidden: grant.showHidden),
              let name = obj["name"] as? String, RemoteFilesPolicy.isValidComponent(name, allowHidden: grant.showHidden) else {
            return reply("mkdir", req: req, error: "notFound")
        }
        let conflict = (obj["conflict"] as? String).flatMap(RemoteFileConflict.init(rawValue:)) ?? .ask
        let target = folder.appendingPathComponent(name)
        var isDir: ObjCBool = false
        // Uploading a folder into one of the same name merges into it ("skip" = use the existing folder).
        if FileManager.default.fileExists(atPath: target.path, isDirectory: &isDir), isDir.boolValue, conflict == .skip {
            return replyOK("mkdir", req: req, ["name": name, "existed": true])
        }
        do {
            guard let final = try RemoteFileTransfers.targetName(in: folder, name: name, conflict: conflict == .replace ? .ask : conflict) else {
                return replyOK("mkdir", req: req, ["name": name, "existed": true])
            }
            try FileManager.default.createDirectory(at: folder.appendingPathComponent(final), withIntermediateDirectories: false)
            replyOK("mkdir", req: req, ["name": final])
        } catch {
            reply("mkdir", req: req, error: errorCode(error))
        }
    }

    private func rename(_ obj: [String: Any], req: Int?, grant: FilesGrant) {
        guard let (_, url, path) = item(obj, grant: grant), !path.isEmpty,
              let name = obj["name"] as? String, RemoteFilesPolicy.isValidComponent(name, allowHidden: grant.showHidden) else {
            return reply("rename", req: req, error: "notFound")
        }
        let dest = url.deletingLastPathComponent().appendingPathComponent(name)
        // A change of case only is a rename too; any other existing name is a conflict.
        if FileManager.default.fileExists(atPath: dest.path), RemoteFilesPolicy.fold(name) != RemoteFilesPolicy.fold(url.lastPathComponent) {
            return reply("rename", req: req, error: "exists")
        }
        do {
            try FileManager.default.moveItem(at: url, to: dest)
            replyOK("rename", req: req, ["name": name])
        } catch {
            reply("rename", req: req, error: errorCode(error))
        }
    }

    /// Copy or move an item into a folder (possibly under another root), or duplicate it beside itself.
    private func copyOrMove(_ op: String, _ obj: [String: Any], req: Int?, grant: FilesGrant) {
        guard let (_, src, path) = item(obj, grant: grant), !path.isEmpty else { return reply(op, req: req, error: "notFound") }
        let folder: URL
        if op == "duplicate" {
            folder = src.deletingLastPathComponent()
        } else {
            guard let toRoot = root(obj, key: "toRoot", grant: grant),
                  let f = RemoteFilesPolicy.resolveFolder(root: toRoot.url, components: components(obj, key: "toPath"), home: home, allowHidden: grant.showHidden) else {
                return reply(op, req: req, error: "notFound")
            }
            folder = f
        }
        // Never into itself.
        if folder.path == src.path || folder.path.hasPrefix(src.path + "/") { return reply(op, req: req, error: "intoItself") }
        let conflict: RemoteFileConflict = op == "duplicate" ? .rename : (obj["conflict"] as? String).flatMap(RemoteFileConflict.init(rawValue:)) ?? .ask
        workQueue.async { [weak self] in
            guard let self else { return }
            var result: [String: Any] = ["type": WireMessage.files, "op": op]
            if let req { result["req"] = req }
            do {
                if op == "move", folder.path == src.deletingLastPathComponent().path {
                    result["ok"] = true; result["name"] = src.lastPathComponent
                } else if let name = try RemoteFileTransfers.targetName(in: folder, name: src.lastPathComponent, conflict: conflict) {
                    let dest = folder.appendingPathComponent(name)
                    if conflict == .replace, FileManager.default.fileExists(atPath: dest.path) {
                        // Replaced items go to the Trash, never deleted outright.
                        _ = try self.moveToTrash(dest)
                    }
                    if op == "move" { try FileManager.default.moveItem(at: src, to: dest) } else { try FileManager.default.copyItem(at: src, to: dest) }
                    result["ok"] = true; result["name"] = name
                } else {
                    result["ok"] = true; result["skipped"] = true
                }
            } catch {
                result["ok"] = false; result["error"] = self.errorCode(error)
                if result["error"] as? String == "exists" { result["suggest"] = RemoteFileTransfers.uniqueName(in: folder, name: src.lastPathComponent) }
            }
            self.queue.async { self.send(result) }
        }
    }

    private func trash(_ obj: [String: Any], req: Int?, grant: FilesGrant) {
        guard let (root, url, path) = item(obj, grant: grant), !path.isEmpty, url.path != RemoteFilesPolicy.canonical(root.url).path else {
            return reply("trash", req: req, error: "notFound")
        }
        do {
            let inTrash = try moveToTrash(url)
            let token = UUID().uuidString
            if let inTrash {
                trashed[token] = (inTrash, url)
                if trashed.count > 200, let first = trashed.keys.first { trashed[first] = nil }
            }
            replyOK("trash", req: req, inTrash == nil ? [:] : ["token": token])
        } catch {
            reply("trash", req: req, error: errorCode(error))
        }
    }

    /// Put Back: only items this session moved to the Trash, to where they were, never over another.
    private func putBack(_ obj: [String: Any], req: Int?) {
        guard let token = obj["token"] as? String, let t = trashed[token] else { return reply("putBack", req: req, error: "notFound") }
        guard !FileManager.default.fileExists(atPath: t.original.path) else { return reply("putBack", req: req, error: "exists") }
        do {
            try FileManager.default.moveItem(at: t.trash, to: t.original)
            trashed[token] = nil
            replyOK("putBack", req: req, ["name": t.original.lastPathComponent])
        } catch {
            reply("putBack", req: req, error: errorCode(error))
        }
    }

    /// Compress items of one folder into a ZIP beside them (bsdtar keeps links as links).
    private func compress(_ obj: [String: Any], req: Int?, grant: FilesGrant) {
        guard let root = root(obj, grant: grant),
              let folder = RemoteFilesPolicy.resolveFolder(root: root.url, components: components(obj), home: home, allowHidden: grant.showHidden) else {
            return reply("zip", req: req, error: "notFound")
        }
        let names = ((obj["names"] as? [String]) ?? []).prefix(500)
        let path = components(obj)
        guard !names.isEmpty, names.allSatisfy({ RemoteFilesPolicy.resolve(root: root.url, components: path + [$0], home: home, allowHidden: grant.showHidden) != nil }) else {
            return reply("zip", req: req, error: "notFound")
        }
        let base = names.count == 1 ? names[0] : "Archive"
        let archive = (try? RemoteFileTransfers.targetName(in: folder, name: base + ".zip", conflict: .rename)).flatMap { $0 } ?? base + ".zip"
        let args = ["-a", "-cf", archive, "--"] + names
        run("/usr/bin/bsdtar", args, in: folder) { [weak self] ok in
            ok ? self?.replyOK("zip", req: req, ["name": archive]) : self?.reply("zip", req: req, error: "failed")
        }
    }

    /// Expand an archive into a new folder beside it. bsdtar refuses `..` and writing through
    /// symlinks unless told otherwise, so nothing lands outside that folder.
    private func expand(_ obj: [String: Any], req: Int?, grant: FilesGrant) {
        guard let (_, url, path) = item(obj, grant: grant), !path.isEmpty else { return reply("unzip", req: req, error: "notFound") }
        let folder = url.deletingLastPathComponent()
        let stem = (url.lastPathComponent as NSString).deletingPathExtension
        let name = (try? RemoteFileTransfers.targetName(in: folder, name: stem, conflict: .rename)).flatMap { $0 } ?? stem
        let target = folder.appendingPathComponent(name)
        do { try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false) } catch {
            return reply("unzip", req: req, error: errorCode(error))
        }
        run("/usr/bin/bsdtar", ["-xf", url.path, "--no-same-owner", "-C", target.path], in: folder) { [weak self] ok in
            if ok { self?.replyOK("unzip", req: req, ["name": name]) } else {
                try? FileManager.default.removeItem(at: target)
                self?.reply("unzip", req: req, error: "failed")
            }
        }
    }

    /// Runs a tool on the work queue (bounded to 10 minutes); answers on the request queue.
    private func run(_ tool: String, _ args: [String], in dir: URL, done: @escaping (Bool) -> Void) {
        workQueue.async { [weak self] in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: tool)
            p.arguments = args
            p.currentDirectoryURL = dir
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            var ok = false
            do {
                try p.run()
                let deadline = Date().addingTimeInterval(600)
                while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
                if p.isRunning { p.terminate() }
                p.waitUntilExit()
                ok = p.terminationStatus == 0
            } catch { ok = false }
            self?.queue.async { done(ok) }
        }
    }

    private func info(_ obj: [String: Any], req: Int?, grant: FilesGrant) {
        guard let (_, url, _) = item(obj, grant: grant) else { return reply("info", req: req, error: "notFound") }
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey, .fileSizeKey, .totalFileAllocatedSizeKey, .creationDateKey,
                                         .contentModificationDateKey, .contentAccessDateKey, .isWritableKey, .isReadableKey,
                                         .localizedTypeDescriptionKey, .isUserImmutableKey, .isAliasFileKey, .isSymbolicLinkKey,
                                         .ubiquitousItemDownloadingStatusKey, .isUbiquitousItemKey]
        let v = try? url.resourceValues(forKeys: keys)
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        var i: [String: Any] = ["name": url.lastPathComponent, "kind": v?.localizedTypeDescription ?? "",
                                "writable": v?.isWritable ?? false, "locked": v?.isUserImmutable ?? false]
        if let d = v?.creationDate { i["made"] = Int(d.timeIntervalSince1970) }
        if let d = v?.contentModificationDate { i["mod"] = Int(d.timeIntervalSince1970) }
        if let d = v?.contentAccessDate { i["used"] = Int(d.timeIntervalSince1970) }
        if let p = attrs?[.posixPermissions] as? Int { i["perm"] = String(p, radix: 8) }
        if let o = attrs?[.ownerAccountName] as? String { i["owner"] = o }
        if v?.isUbiquitousItem == true {
            i["cloud"] = v?.ubiquitousItemDownloadingStatus == .current ? "downloaded" : "notDownloaded"
        }
        let isFolder = (v?.isDirectory ?? false) && !(v?.isPackage ?? false)
        if !isFolder {
            if let s = v?.fileSize { i["size"] = s }
            return replyOK("info", req: req, ["info": i])
        }
        // A folder's size and count, bounded in time.
        workQueue.async { [weak self] in
            var total: Int64 = 0, count = 0, complete = true
            let deadline = Date().addingTimeInterval(2)
            if let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey], options: []) {
                for case let f as URL in walker {
                    count += 1
                    total += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
                    if count % 512 == 0, Date() > deadline { complete = false; break }
                }
            }
            i["size"] = total; i["items"] = count; i["complete"] = complete
            self?.queue.async { self?.replyOK("info", req: req, ["info": i]) }
        }
    }

    /// The Mac apps that can open this file (Open With).
    private func openWithApps(_ obj: [String: Any], req: Int?, grant: FilesGrant) {
        guard let (_, url, path) = item(obj, grant: grant), !path.isEmpty else { return reply("openWithApps", req: req, error: "notFound") }
        let defaultApp = NSWorkspace.shared.urlForApplication(toOpen: url)
        var seen = Set<String>()
        let apps: [[String: Any]] = NSWorkspace.shared.urlsForApplications(toOpen: url).compactMap { app in
            guard let bundle = Bundle(url: app)?.bundleIdentifier, seen.insert(bundle).inserted else { return nil }
            return ["bundle": bundle, "name": FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: ""),
                    "default": app == defaultApp]
        }
        replyOK("openWithApps", req: req, ["apps": Array(apps.prefix(24))])
    }

    // MARK: Replies

    private func reply(_ op: String, req: Int?, error: String, extra: [String: Any] = [:]) {
        var m: [String: Any] = ["type": WireMessage.files, "op": op, "ok": false, "error": error]
        if let req { m["req"] = req }
        for (k, v) in extra { m[k] = v }
        send(m)
    }

    private func replyOK(_ op: String, req: Int?, _ fields: [String: Any] = [:]) {
        var m: [String: Any] = ["type": WireMessage.files, "op": op, "ok": true]
        if let req { m["req"] = req }
        for (k, v) in fields { m[k] = v }
        send(m)
    }

    private func send(_ m: [String: Any]) {
        guard !stopped else { return }
        sendMessage?(m)
    }
}

private final class ThumbnailBox: @unchecked Sendable { var image: CGImage? }
private struct FilesMessageBox: @unchecked Sendable { let value: [String: Any] }

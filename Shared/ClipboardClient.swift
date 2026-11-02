import Foundation

// The receiver's side of the Unified Clipboard (PROTOCOL.md 6.15): its own settings (off until
// turned on), the Mac's answer, copies both ways through the shared ordering rules, verified
// ranged transfers, and files the Mac copied (saved or shared only when asked). The platform
// (UIPasteboard on iOS) is behind `ClipboardPlatform`. Content is never logged or kept after
// it is replaced; nothing is stored across launches but the settings and two counters.

/// A `clip` message as it arrived (parsed by the model, bounded).
struct ClipboardMessage: @unchecked Sendable { let obj: [String: Any] }

/// Content read from this device's clipboard.
struct ClipLocalContent {
    var items: [[(kind: ClipKind, data: Data)]]
    /// Copied files (names only travel; the bytes are read when the Mac asks).
    var files: [(name: String, url: URL, size: Int)]
}

@MainActor
protocol ClipboardPlatform: AnyObject {
    /// Changes whenever anything is copied; reading it never asks the person.
    var changeCount: Int { get }
    /// Puts a copy from another device on this device's clipboard, for this device only.
    /// Returns the change count it caused.
    func write(_ items: [[(kind: ClipKind, data: Data)]]) -> Int
    /// Reads what is copied (the system may ask the person first).
    func read(textOnly: Bool, maxBytes: Int, completion: @escaping @MainActor (ClipLocalContent?) -> Void)
}

struct ClipTransferNote: Equatable {
    var at: Date
    var fromMac: Bool
    var summary: String
    var failure: String?
}

@MainActor
final class ClipboardModel: ObservableObject {
    enum MacState: String { case unavailable, off, idle, asking, denied, ready, paused, revoked }

    private enum K {
        static let enabled = "clipboard.enabled", direction = "clipboard.direction", types = "clipboard.types"
        static let files = "clipboard.files", auto = "clipboard.autoSend", max = "clipboard.maxBytes"
        static let seq = "clipboard.sync.seq", lamport = "clipboard.sync.lamport"
    }

    // MARK: This device's settings (Settings ▸ Clipboard)

    @Published var enabled: Bool { didSet { defaults.set(enabled, forKey: K.enabled); settingsChanged() } }
    @Published var direction: ClipDirection { didSet { defaults.set(direction.rawValue, forKey: K.direction); settingsChanged() } }
    @Published var types: ClipTypes { didSet { defaults.set(types.rawValue, forKey: K.types); settingsChanged() } }
    @Published var syncFiles: Bool { didSet { defaults.set(syncFiles, forKey: K.files); settingsChanged() } }
    /// Send copies made in other apps when MeowDisplay comes back (iOS may ask each time).
    @Published var autoSend: Bool { didSet { defaults.set(autoSend, forKey: K.auto) } }
    @Published var maxBytes: Int { didSet { defaults.set(maxBytes, forKey: K.max); settingsChanged() } }

    // MARK: The Mac's answer

    @Published private(set) var macState: MacState = .unavailable
    @Published private(set) var toDevice = false
    @Published private(set) var toMac = false
    @Published private(set) var macAllowsFiles = false
    @Published private(set) var always = false
    @Published private(set) var macRead = "allowed"

    // MARK: Status

    @Published private(set) var lastTransfer: ClipTransferNote?
    @Published private(set) var progress: (done: Int, total: Int)?
    /// The Mac copied files: saved or shared here only when asked.
    @Published private(set) var macFiles: ClipEvent?
    /// A Mac copy made at the same moment as this device's: kept to choose.
    @Published private(set) var alternativeWaiting = false
    /// Something was copied in another app and not sent yet (send it with Send to Mac).
    @Published private(set) var localChangePending = false
    @Published var export: RemoteFilesExport?
    @Published private(set) var notice: String?

    var send: ([String: Any]) -> Bool = { _ in false }
    weak var platform: ClipboardPlatform?
    private let defaults: UserDefaults
    private let origin: String
    private var sync: ClipboardSync
    private var available = false
    private var joined = false
    private var macMax = ClipboardWire.defaultMaxBytes
    private var macTypes = ClipTypes.all
    private var lastChange: Int?
    private var ownChange: Int?
    private var served: [ClipEventID: [Int: Source]] = [:]
    private var servedOrder: [ClipEventID] = []
    private var alternative: ClipEvent?
    private var job: Job?
    private var nextReq = 1
    private let tempRoot: URL
    private let io = DispatchQueue(label: "meow.clipboard.client.io", qos: .utility)

    private enum Source { case data(Data), file(URL, size: Int) }

    private final class Job {
        enum Purpose { case apply, save(RemoteFilesExport.Mode), alternative }
        let event: ClipEvent
        let purpose: Purpose
        var queue: [(blob: Int, size: Int, hash: String?, file: [String]?)]
        var fetch: ClipBlobFetch?
        var reps: [Int: Data] = [:]
        var dir: URL?
        var handle: FileHandle?
        var total: Int
        var done = 0
        var failed = 0
        var lastActivity = Date()
        init(event: ClipEvent, purpose: Purpose, queue: [(Int, Int, String?, [String]?)]) {
            self.event = event; self.purpose = purpose
            self.queue = queue.map { (blob: $0.0, size: $0.1, hash: $0.2, file: $0.3) }
            total = queue.reduce(0) { $0 + $1.1 }
        }
    }

    init(defaults: UserDefaults = .standard, origin: String? = nil, tempRoot: URL? = nil) {
        self.defaults = defaults
        self.origin = origin ?? TrustStore.receiverRole.installID() ?? "device"
        enabled = defaults.bool(forKey: K.enabled)
        direction = ClipDirection(rawValue: defaults.string(forKey: K.direction) ?? "") ?? .both
        types = ClipTypes(rawValue: defaults.string(forKey: K.types) ?? "") ?? .all
        syncFiles = defaults.object(forKey: K.files) as? Bool ?? true
        #if os(iOS)
        autoSend = defaults.object(forKey: K.auto) as? Bool ?? false   // iOS asks before each read unless allowed
        #else
        autoSend = defaults.object(forKey: K.auto) as? Bool ?? true
        #endif
        let m = defaults.integer(forKey: K.max)
        maxBytes = ClipboardWire.sizeChoices.contains(m) ? m : ClipboardWire.defaultMaxBytes
        sync = ClipboardSync(origin: self.origin, seq: UInt64(max(0, defaults.integer(forKey: K.seq))),
                             lamport: UInt64(max(0, defaults.integer(forKey: K.lamport))))
        self.tempRoot = tempRoot ?? FileManager.default.temporaryDirectory.appendingPathComponent("MeowDisplay-Clipboard", isDirectory: true)
        try? FileManager.default.removeItem(at: self.tempRoot)
    }

    var ready: Bool { available && enabled && macState == .ready }
    var canSendToMac: Bool { ready && toMac && direction.toMacAllowed }
    private var canReceive: Bool { ready && toDevice && direction.toDeviceAllowed }
    private var effectiveTypes: ClipTypes { types == .text || macTypes == .text ? .text : .all }
    private var effectiveMax: Int { min(maxBytes, macMax) }
    private var filesAllowed: Bool { syncFiles && macAllowsFiles && effectiveTypes == .all }

    // MARK: Connection

    /// The Mac's welcome lists `clipboard` (true) or the session ended (false).
    func setAvailable(_ on: Bool) {
        available = on
        joined = false
        if on {
            lastChange = platform?.changeCount   // what is copied now is not a new copy
            sendJoin()
        } else {
            macState = .unavailable
            toDevice = false; toMac = false
            cancelJob()
            served = [:]; servedOrder = []
            macFiles = nil; alternative = nil; alternativeWaiting = false; localChangePending = false
            try? FileManager.default.removeItem(at: tempRoot)
        }
    }

    private func settingsChanged() {
        if !enabled { cancelJob(); macFiles = nil; localChangePending = false }
        sendJoin()
    }

    private func sendJoin() {
        guard available else { return }
        if !enabled {
            if joined { _ = send(["type": ClipboardWire.type, "op": "leave"]) }
            joined = false
            macState = .idle
            return
        }
        joined = send(["type": ClipboardWire.type, "op": "join", "on": true, "dir": direction.rawValue, "types": types.rawValue,
                       "files": syncFiles, "max": maxBytes, "seen": sync.seen.mapValues { Int($0) }])
    }

    // MARK: Messages from the Mac

    func handle(_ message: ClipboardMessage) {
        let m = message.obj
        switch m["op"] as? String {
        case "state": applyState(m)
        case "event": if let e = ClipEvent.parse(m) { receive(e) }
        case "read": serveRead(m)
        case "data", "readEnd": jobMessage(m)
        default: break
        }
    }

    private func applyState(_ m: [String: Any]) {
        macState = (m["state"] as? String).flatMap(MacState.init(rawValue:)) ?? .off
        let r = macState == .ready
        toDevice = r && (m["toDevice"] as? Bool ?? false)
        toMac = r && (m["toMac"] as? Bool ?? false)
        macTypes = (m["types"] as? String).flatMap(ClipTypes.init(rawValue:)) ?? .all
        macAllowsFiles = r && (m["files"] as? Bool ?? false)
        macMax = min(max(m["max"] as? Int ?? ClipboardWire.defaultMaxBytes, 0), ClipboardWire.sizeChoices.last!)
        always = (m["duration"] as? String) == "always"
        macRead = m["macRead"] as? String ?? "allowed"
        if let seen = m["seen"] as? [String: Any] {
            sync.merge(seen: seen.compactMapValues { ($0 as? Int).map { UInt64(max(0, $0)) } })   // a reconnect is never a copy
            persist()
        }
        if !r { cancelJob() }
        if r { checkLocal(automatic: true) }
    }

    private func receive(_ e: ClipEvent) {
        guard canReceive else { return }
        switch sync.receive(e.header) {
        case .apply:
            persist()
            alternative = nil; alternativeWaiting = false
            apply(e)
        case .alternative:
            persist()
            alternative = e
            alternativeWaiting = true
        case .duplicate, .echo, .older:
            break
        }
    }

    private func apply(_ e: ClipEvent) {
        let textOnly = effectiveTypes == .text
        var event = e
        event.items = e.items.compactMap { item in
            let reps = item.reps.filter { (!textOnly || $0.kind.isText) && ($0.inline != nil || $0.size <= effectiveMax) }
            return reps.isEmpty ? nil : ClipItem(reps: reps)
        }
        macFiles = filesAllowed && !e.files.isEmpty ? e : nil
        guard !event.items.isEmpty else {
            lastTransfer = ClipTransferNote(at: Date(), fromMac: true, summary: e.summary,
                                            failure: macFiles == nil ? String(localized: "Too large or not a type this device syncs") : nil)
            return
        }
        var queue: [(Int, Int, String?, [String]?)] = []
        for item in event.items { for r in item.reps where r.inline == nil { if let b = r.blob { queue.append((b, r.size, r.hash, nil)) } } }
        event.files = []
        start(Job(event: event, purpose: .apply, queue: queue))
    }

    // MARK: Fetching from the Mac

    private func start(_ job: Job) {
        cancelJob()
        self.job = job
        progress = job.total > 0 ? (0, job.total) : nil
        advance()
    }

    private func cancelJob() {
        guard let j = job else { return }
        try? j.handle?.close()
        if let d = j.dir { try? FileManager.default.removeItem(at: d) }
        job = nil
        progress = nil
    }

    private func advance() {
        guard let j = job else { return }
        if var f = j.fetch, let read = f.nextRead() {
            j.fetch = f
            sendRead(read, j)
            return
        }
        try? j.handle?.close(); j.handle = nil
        guard !j.queue.isEmpty else { return finish(j, failure: nil) }
        let next = j.queue.removeFirst()
        if let path = next.file, let dir = j.dir {
            let url = path.reduce(dir) { $0.appendingPathComponent($1) }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: url.path, contents: nil)
            j.handle = try? FileHandle(forWritingTo: url)
            if j.handle == nil { return finish(j, failure: "noSpace") }
        }
        if next.size == 0 { j.fetch = nil; return advance() }
        var f = ClipBlobFetch(req: nextReq, id: j.event.id, blob: next.blob, size: next.size, expectedHash: next.hash)
        nextReq += 1
        let read = f.nextRead()!
        j.fetch = f
        sendRead(read, j)
    }

    private func sendRead(_ read: [String: Any], _ j: Job) {
        j.lastActivity = Date()
        guard send(read) else { return finish(j, failure: "gone") }
        let id = ObjectIdentifier(j)
        DispatchQueue.main.asyncAfter(deadline: .now() + 16) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let cur = self.job, ObjectIdentifier(cur) == id, Date().timeIntervalSince(cur.lastActivity) >= 15 else { return }
                self.finish(cur, failure: "timeout")
            }
        }
    }

    private func jobMessage(_ m: [String: Any]) {
        guard let j = job, var f = j.fetch, m["req"] as? Int == f.req else { return }
        j.lastActivity = Date()
        switch f.handle(m) {
        case .more:
            j.fetch = f
        case .rangeDone(let bytes):
            j.fetch = f.done ? nil : f
            j.done += bytes.count
            if let h = j.handle { h.write(bytes) } else { j.reps[f.blob, default: Data()].append(bytes) }
            progress = (j.done, j.total)
            advance()
        case .failed(let code):
            finish(j, failure: code)
        }
    }

    private func finish(_ j: Job, failure: String?) {
        guard job === j else { return }
        try? j.handle?.close(); j.handle = nil
        job = nil
        progress = nil
        if let failure {
            if let d = j.dir { try? FileManager.default.removeItem(at: d) }
            lastTransfer = ClipTransferNote(at: Date(), fromMac: true, summary: j.event.summary, failure: Self.failureText(failure))
            return
        }
        switch j.purpose {
        case .apply:
            guard sync.isCurrent(j.event.id) else { return }   // a newer copy happened meanwhile
            writeToDevice(j.event, reps: j.reps, own: true)
            lastTransfer = ClipTransferNote(at: Date(), fromMac: true, summary: j.event.summary)
        case .alternative:
            // Chosen by the person: a new copy here, sent on to the Mac.
            let items = writeToDevice(j.event, reps: j.reps, own: false)
            sendLocal(ClipLocalContent(items: items, files: []))
        case .save(let mode):
            guard let dir = j.dir else { return }
            let tops = j.event.files.filter { $0.path.count == 1 }.map { dir.appendingPathComponent($0.path[0]) }
            export = RemoteFilesExport(mode: mode, urls: tops, directory: dir, failed: j.failed)
        }
    }

    @discardableResult
    private func writeToDevice(_ e: ClipEvent, reps: [Int: Data], own: Bool) -> [[(kind: ClipKind, data: Data)]] {
        let items = e.items.map { item in
            item.reps.compactMap { r -> (kind: ClipKind, data: Data)? in
                guard let d = r.inline ?? r.blob.flatMap({ reps[$0] }) else { return nil }
                return (r.kind, d)
            }
        }.filter { !$0.isEmpty }
        guard let platform, !items.isEmpty else { return items }
        let cc = platform.write(items)
        if own { ownChange = cc; lastChange = cc }
        return items
    }

    // MARK: This device's copies

    /// The app came to the front, or the Mac said ready: was something copied meanwhile?
    func checkLocal(automatic: Bool) {
        guard canSendToMac, let platform else { return }
        let cc = platform.changeCount
        guard cc != lastChange else { return }
        if cc == ownChange { lastChange = cc; return }
        if automatic && !autoSend {
            localChangePending = true
            return
        }
        lastChange = cc
        localChangePending = false
        platform.read(textOnly: effectiveTypes == .text, maxBytes: effectiveMax) { [weak self] content in
            guard let self, let content else { return }
            self.sendLocal(content)
        }
    }

    /// Content the person chose to send (the system Paste button, or a read).
    func sendLocal(_ content: ClipLocalContent) {
        guard canSendToMac else { return }
        localChangePending = false
        lastChange = platform?.changeCount
        var sources: [Int: Source] = [:]
        var blob = 0
        var inlineLeft = ClipboardWire.inlineBytes
        let textOnly = effectiveTypes == .text
        let items: [ClipItem] = content.items.prefix(ClipboardWire.maxItems).compactMap { reps in
            let out = reps.prefix(ClipboardWire.maxReps).compactMap { r -> ClipRep? in
                guard (!textOnly || r.kind.isText), r.data.count <= effectiveMax else { return nil }
                var rep = ClipRep(kind: r.kind, size: r.data.count, hash: ClipHash.of(r.data))
                if r.data.count <= inlineLeft { rep.inline = r.data; inlineLeft -= r.data.count } else { rep.blob = blob; sources[blob] = .data(r.data); blob += 1 }
                return rep
            }
            return out.isEmpty ? nil : ClipItem(reps: out)
        }
        var files: [ClipFile] = []
        if filesAllowed {
            // Names travel; a list too long for one message is cut (the event must stay small).
            for f in content.files.prefix(64) where ClipFiles.isSafeName(f.name) {
                files.append(ClipFile(path: [f.name], size: f.size, dir: false, blob: blob))
                sources[blob] = .file(f.url, size: f.size)
                blob += 1
            }
        }
        guard !items.isEmpty || !files.isEmpty else {
            lastTransfer = ClipTransferNote(at: Date(), fromMac: false, summary: String(localized: "Copy"),
                                            failure: String(localized: "Too large or not a type that syncs"))
            return
        }
        guard let header = sync.localCopy(contentHash: ClipEvent.contentHash(items: items, files: files)) else { return }
        persist()
        alternative = nil; alternativeWaiting = false
        let event = ClipEvent(header: header, at: Int64(Date().timeIntervalSince1970 * 1000), items: items, files: files)
        served[event.id] = sources
        servedOrder.append(event.id)
        while servedOrder.count > 2 { served.removeValue(forKey: servedOrder.removeFirst()) }
        _ = send(event.wire)
        lastTransfer = ClipTransferNote(at: Date(), fromMac: false, summary: event.summary)
    }

    private func serveRead(_ m: [String: Any]) {
        guard let req = m["req"] as? Int, let o = m["o"] as? String, let s = m["s"] as? Int, s > 0, let b = m["b"] as? Int,
              let off = m["off"] as? Int, off >= 0, let n = m["n"] as? Int, n > 0, n <= ClipboardWire.readMax else { return }
        let send = self.send
        guard canSendToMac, let source = served[ClipEventID(origin: o, seq: UInt64(s))]?[b] else {
            ClipBlobWire.answer(req: req, offset: off, bytes: nil, error: "gone").forEach { _ = send($0) }
            return
        }
        switch source {
        case .data(let d):
            let frames = off <= d.count ? ClipBlobWire.answer(req: req, offset: off, bytes: d.subdata(in: off..<min(d.count, off + n)))
                                        : ClipBlobWire.answer(req: req, offset: off, bytes: nil, error: "badRange")
            frames.forEach { _ = send($0) }
        case .file(let url, let size):
            let box = ClipSendBox(send)
            io.async {
                let frames: [[String: Any]]
                let now = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
                if now != size { frames = ClipBlobWire.answer(req: req, offset: off, bytes: nil, error: now == nil ? "gone" : "changed") }
                else if let h = try? FileHandle(forReadingFrom: url) {
                    defer { try? h.close() }
                    try? h.seek(toOffset: UInt64(off))
                    frames = ClipBlobWire.answer(req: req, offset: off, bytes: (try? h.read(upToCount: n)) ?? Data())
                } else { frames = ClipBlobWire.answer(req: req, offset: off, bytes: nil, error: "gone") }
                let out = ClipFramesBox(frames)
                DispatchQueue.main.async { out.frames.forEach { _ = box.send($0) } }
            }
        }
    }

    // MARK: Actions

    /// Save or share the files the Mac copied (fetched now, kept only until the sheet closes).
    func getMacFiles(_ mode: RemoteFilesExport.Mode) {
        guard let e = macFiles, canReceive else { return }
        let dir = tempRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for f in e.files where f.dir {
            try? FileManager.default.createDirectory(at: f.path.reduce(dir) { $0.appendingPathComponent($1) }, withIntermediateDirectories: true)
        }
        let queue = e.files.filter { !$0.dir }.compactMap { f in f.blob.map { ($0, f.size, String?.none, Optional(f.path)) } }
        let job = Job(event: e, purpose: .save(mode), queue: queue)
        job.dir = dir
        start(job)
    }

    /// Use the Mac's copy made at the same moment instead of this device's.
    func useAlternative() {
        guard let e = alternative, canReceive else { return }
        alternative = nil; alternativeWaiting = false
        sync.dropAlternative()
        var queue: [(Int, Int, String?, [String]?)] = []
        for item in e.items { for r in item.reps where r.inline == nil && r.size <= effectiveMax { if let b = r.blob { queue.append((b, r.size, r.hash, nil)) } } }
        var event = e
        event.files = []
        start(Job(event: event, purpose: .alternative, queue: queue))
    }

    func exportFinished(_ e: RemoteFilesExport, completed: Bool) {
        try? FileManager.default.removeItem(at: e.directory)
        if export?.id == e.id { export = nil }
        if completed, e.mode == .save { notice = String(localized: "Saved to this device.") }
    }

    func dismissMacFiles() { macFiles = nil }
    func dismissNotice() { notice = nil }
    func cancelTransfer() { cancelJob() }

    private func persist() {
        defaults.set(Int(sync.seq), forKey: K.seq)
        defaults.set(Int(sync.lamport), forKey: K.lamport)
    }

    static func failureText(_ code: String) -> String {
        switch code {
        case "timeout": return String(localized: "The Mac stopped answering")
        case "changed": return String(localized: "The file changed on the Mac")
        case "gone": return String(localized: "No longer available on the Mac")
        case "denied": return String(localized: "The Mac doesn't allow this")
        case "digest": return String(localized: "The data arrived damaged")
        case "noSpace": return String(localized: "Not enough space on this device")
        default: return String(localized: "Transfer failed")
        }
    }
}

private final class ClipSendBox: @unchecked Sendable {
    let send: ([String: Any]) -> Bool
    init(_ send: @escaping ([String: Any]) -> Bool) { self.send = send }
}

private final class ClipFramesBox: @unchecked Sendable {
    let frames: [[String: Any]]
    init(_ frames: [[String: Any]]) { self.frames = frames }
}

import CryptoKit
import Foundation

// Remote Finder transfers on the receiver (PROTOCOL.md 6.12): downloads into this app's private
// cache (to view in the app, save to Files or share) and uploads from files the user picked.
// Everything is bounded: a few transfers at a time, at most ~1 MiB in flight each, digests
// checked per range, a stall fails after a timeout with Retry, cancel removes partial files.
// Nothing here decides permissions: the Mac checks every request.

enum RemoteTransferPurpose: String, Sendable { case view, save }

struct RemoteTransferItem: Identifiable, Equatable, Sendable {
    enum Direction: Equatable, Sendable { case download(RemoteTransferPurpose), upload }
    enum State: Equatable, Sendable {
        case waiting, running
        /// An item with that name exists on the Mac: Replace, Keep Both or Skip.
        case conflict(suggest: String?)
        case done, skipped
        case failed(String)
        case cancelled
        var isFinished: Bool { [.done, .skipped, .cancelled].contains(self) || { if case .failed = self { return true }; return false }() }
    }

    let id: UUID
    var direction: Direction
    var name: String
    var size: Int64
    var transferred: Int64 = 0
    var state: State = .waiting
    var bytesPerSecond: Double = 0
    /// Download: the finished local copy. Upload: the source.
    var localURL: URL?
    /// Upload: the name it got on the Mac.
    var resultName: String?
    /// One user action (several files, a folder): conflicts can be answered for all of it.
    var batch: UUID
    var root: String
    /// Download: the file. Upload: the destination folder.
    var path: [String]

    var fraction: Double { size > 0 ? min(1, Double(transferred) / Double(size)) : (state == .done ? 1 : 0) }
}

@MainActor
final class RemoteTransferQueue: ObservableObject {
    @Published private(set) var items: [RemoteTransferItem] = []

    var send: ([String: Any]) -> Bool = { _ in false }
    /// Request ids come from the Finder model so they never collide with its own.
    var nextRequestID: () -> Int = { 0 }
    var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    /// Called when an item finished in any way (a finished download carries `localURL`).
    var onSettled: ((RemoteTransferItem) -> Void)?
    /// Called when an upload or folder step changed something on the Mac (refresh the folder).
    var onRemoteChange: ((_ root: String, _ path: [String]) -> Void)?

    static let rangeBytes = 512 * 1024
    static let rangesInFlight = 2
    /// Each `uploadData` stays under the 32 KB control-message limit once in base64.
    static let uploadPart = 22_000
    static let uploadWindow = 16
    static let maxRunning = 2
    static let stallTimeout: TimeInterval = 20

    /// Conflict answers given "for all" in a batch.
    private var batchConflict: [UUID: RemoteFileConflictChoice] = [:]

    private final class Job {
        var x: Int?
        var req: Int?
        var file: FileHandle?
        var source: FileHandle?
        var scoped: URL?
        var nextRead: Int64 = 0
        var rangesOut: [(o: Int64, n: Int, hasher: SHA256)] = []
        /// Bytes of the first range in `rangesOut` written so far.
        var rangesOutWritten = 0
        var acked: Int64 = 0
        var sent: Int64 = 0
        var hasher = SHA256()
        var lastActivity: TimeInterval = 0
        var started: TimeInterval = 0
        var conflict: RemoteFileConflictChoice = .ask
        /// Download: the Mac's size and date at the first open, so a resume only continues the same version.
        var version: (size: Int64, mod: Int?)?
        var mod: Int?
    }

    private var jobs: [UUID: Job] = [:]
    private var ticker: Task<Void, Never>?

    static var cacheDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("RemoteFinder", isDirectory: true)
    }

    /// Copies left by an earlier run (the app was stopped mid-transfer) are never reused.
    static func removeStaleCache() {
        try? FileManager.default.removeItem(at: cacheDirectory)
    }

    var activeCount: Int { items.filter { !$0.state.isFinished }.count }
    var firstConflict: RemoteTransferItem? { items.first { if case .conflict = $0.state { return true }; return false } }

    // MARK: Adding

    @discardableResult
    func download(root: String, path: [String], name: String, size: Int64?, purpose: RemoteTransferPurpose, batch: UUID = UUID()) -> UUID {
        if purpose == .view, let existing = items.first(where: {
            $0.direction == .download(.view) && $0.root == root && $0.path == path && !$0.state.isFinished
        }) { return existing.id }
        let item = RemoteTransferItem(id: UUID(), direction: .download(purpose), name: name, size: size ?? 0, batch: batch, root: root, path: path)
        items.append(item)
        jobs[item.id] = Job()
        pump()
        return item.id
    }

    /// Uploads a local file into `path` (a folder) on the Mac. `scoped`: a security-scoped URL
    /// to hold open while reading (a folder the user picked).
    @discardableResult
    func upload(_ url: URL, name: String? = nil, root: String, path: [String], batch: UUID = UUID(), scoped: URL? = nil) -> UUID? {
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
        let item = RemoteTransferItem(id: UUID(), direction: .upload, name: name ?? url.lastPathComponent, size: size,
                                      localURL: url, batch: batch, root: root, path: path)
        items.append(item)
        let job = Job()
        job.scoped = scoped
        job.mod = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date).map { Int($0.timeIntervalSince1970) }
        jobs[item.id] = job
        pump()
        return item.id
    }

    func cancel(_ id: UUID) {
        guard let i = index(id), !items[i].state.isFinished else { return }
        finish(id, .cancelled)
    }

    func cancelAll() { for item in items where !item.state.isFinished { cancel(item.id) } }

    func retry(_ id: UUID) {
        guard let i = index(id) else { return }
        guard case .failed = items[i].state else { return }
        items[i].state = .waiting
        items[i].bytesPerSecond = 0
        let old = jobs[id]
        let job = Job()
        job.scoped = old?.scoped
        job.mod = old?.mod
        job.version = old?.version
        // A download resumes where it stopped if the Mac's file is the same version.
        if case .download = items[i].direction, let path = items[i].localURL ?? partialURL(id), FileManager.default.fileExists(atPath: path.path) {
            job.nextRead = items[i].transferred
        } else {
            items[i].transferred = 0
        }
        jobs[id] = job
        pump()
    }

    /// The user's answer to a name conflict (for this item, or every one in its batch).
    func resolveConflict(_ id: UUID, _ choice: RemoteFileConflictChoice, forAll: Bool) {
        guard let i = index(id), case .conflict = items[i].state else { return }
        let batch = items[i].batch
        if forAll { batchConflict[batch] = choice }
        for j in items.indices where items[j].id == id || (forAll && items[j].batch == batch) {
            guard case .conflict = items[j].state else { continue }
            jobs[items[j].id]?.conflict = choice
            items[j].state = .waiting
        }
        pump()
    }

    func clearFinished() {
        for item in items where item.state.isFinished && item.direction != .download(.view) { jobs[item.id] = nil }
        items.removeAll { $0.state.isFinished && $0.direction != .download(.view) }
    }

    /// The session ended: every unfinished transfer fails (Retry after reconnecting).
    func disconnected() { failRunning("disconnected") }

    /// Access ended or the connection went: unfinished transfers fail with `code`.
    func failRunning(_ code: String) {
        for item in items where !item.state.isFinished { fail(item.id, code) }
    }

    /// Removes a finished item from the list (and its local copy, unless it was handed on).
    func remove(_ id: UUID) {
        guard let i = index(id), items[i].state.isFinished else { return }
        jobs[id] = nil
        items.remove(at: i)
    }

    /// Cached copies for viewing go when the browser closes or the session ends.
    func purgeViewCache() {
        for item in items where item.direction == .download(.view) {
            if !item.state.isFinished { cancel(item.id) }
            if let url = item.localURL { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        }
        items.removeAll { $0.direction == .download(.view) }
    }

    // MARK: Scheduling

    private func index(_ id: UUID) -> Int? { items.firstIndex { $0.id == id } }

    private func nextReq() -> Int { nextRequestID() }

    private func pump() {
        let running = items.filter { $0.state == .running }.count
        var slots = Self.maxRunning - running
        for item in items where item.state == .waiting && slots > 0 {
            start(item.id)
            slots -= 1
        }
        startTicker()
    }

    private func startTicker() {
        guard ticker == nil, items.contains(where: { $0.state == .running }) else { return }
        ticker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self else { return }
                let t = self.now()
                for item in self.items where item.state == .running {
                    guard let job = self.jobs[item.id] else { continue }
                    if t - job.lastActivity > Self.stallTimeout { self.fail(item.id, "timeout") }
                }
                if !self.items.contains(where: { $0.state == .running }) { self.ticker = nil; return }
            }
        }
    }

    private func start(_ id: UUID) {
        guard let i = index(id), let job = jobs[id] else { return }
        items[i].state = .running
        job.started = now()
        job.lastActivity = now()
        let item = items[i]
        let r = nextReq()
        job.req = r
        switch item.direction {
        case .download(let purpose):
            _ = send(RemoteFilesRequests.make("download", req: r, ["root": item.root, "path": item.path, "purpose": purpose.rawValue]))
        case .upload:
            if job.conflict == .ask, let c = batchConflict[item.batch] { job.conflict = c }
            if let s = job.scoped { _ = s.startAccessingSecurityScopedResource() }
            guard let url = item.localURL, let h = try? FileHandle(forReadingFrom: url) else { return fail(id, "unreadable") }
            job.source = h
            var fields: [String: Any] = ["root": item.root, "path": item.path, "name": item.name, "size": item.size,
                                         "conflict": job.conflict.wire]
            if let m = job.mod { fields["mod"] = m }
            _ = send(RemoteFilesRequests.make("uploadBegin", req: r, fields))
        }
    }

    private func finish(_ id: UUID, _ state: RemoteTransferItem.State) {
        guard let i = index(id) else { return }
        let job = jobs[id]
        if let x = job?.x {
            switch items[i].direction {
            case .download: _ = send(RemoteFilesRequests.make("close", req: nextReq(), ["x": x]))
            case .upload: if state != .done { _ = send(RemoteFilesRequests.make("uploadCancel", req: nextReq(), ["x": x])) }
            }
        }
        try? job?.file?.close()
        try? job?.source?.close()
        job?.scoped?.stopAccessingSecurityScopedResource()
        items[i].state = state
        if case .download = items[i].direction {
            switch state {
            case .done, .failed: break   // a failed download keeps its part for Retry to resume
            default:
                if let p = partialURL(id) { try? FileManager.default.removeItem(at: p.deletingLastPathComponent()) }
                items[i].localURL = nil
            }
        }
        jobs[id]?.x = nil
        jobs[id]?.rangesOut = []
        jobs[id]?.rangesOutWritten = 0
        let settled = items[i]
        pump()
        onSettled?(settled)
    }

    private func fail(_ id: UUID, _ code: String) {
        guard let i = index(id), !items[i].state.isFinished else { return }
        Log.info("files: transfer \(items[i].direction == .upload ? "up" : "down") failed: \(code)")
        finish(id, .failed(code))
    }

    private func partialURL(_ id: UUID) -> URL? {
        guard let item = items.first(where: { $0.id == id }) else { return nil }
        let safe = item.name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        return Self.cacheDirectory.appendingPathComponent(id.uuidString, isDirectory: true).appendingPathComponent(safe.isEmpty ? "file" : safe)
    }

    private func touch(_ id: UUID, bytes: Int) {
        guard let i = index(id), let job = jobs[id] else { return }
        job.lastActivity = now()
        items[i].transferred += Int64(bytes)
        let elapsed = max(now() - job.started, 0.25)
        items[i].bytesPerSecond = Double(items[i].transferred) / elapsed
    }

    // MARK: Replies

    /// A Files reply that belongs to a transfer. Returns true when it was one.
    func apply(_ r: RemoteFilesReply) -> Bool {
        switch r.op {
        case "download": return onDownloadOpened(r)
        case "data": return onData(r)
        case "read": return onRangeDone(r)
        case "uploadBegin": return onUploadBegun(r)
        case "uploadAck": return onUploadAck(r)
        case "uploadEnd": return onUploadEnded(r)
        default: return false
        }
    }

    private func job(req: Int?) -> (UUID, Job)? {
        guard let req else { return nil }
        return jobs.first { $0.value.req == req }.map { ($0.key, $0.value) }
    }

    private func job(x: Int?) -> (UUID, Job)? {
        guard let x else { return nil }
        return jobs.first { $0.value.x == x }.map { ($0.key, $0.value) }
    }

    private func onDownloadOpened(_ r: RemoteFilesReply) -> Bool {
        guard let (id, job) = job(req: r.req) else { return false }   // not ours (a stream or a request)
        guard let i = index(id), items[i].state == .running else { return true }
        guard r.ok, let x = r.x, let size = r.size else { fail(id, r.error ?? "failed"); return true }
        // Resuming: only the same version continues; anything else starts over.
        if let v = job.version, (v.size != size || v.mod != r.mod) { job.nextRead = 0; items[i].transferred = 0 }
        job.version = (size, r.mod)
        job.x = x
        items[i].size = size
        guard let url = partialURL(id) else { fail(id, "failed"); return true }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if job.nextRead == 0 || !FileManager.default.fileExists(atPath: url.path) {
                job.nextRead = 0; items[i].transferred = 0
                #if os(iOS)
                FileManager.default.createFile(atPath: url.path, contents: nil,
                                               attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
                #else
                FileManager.default.createFile(atPath: url.path, contents: nil)
                #endif
            }
            let h = try FileHandle(forWritingTo: url)
            try h.truncate(atOffset: UInt64(job.nextRead))
            try h.seekToEnd()
            job.file = h
        } catch { fail(id, "storage"); return true }
        items[i].localURL = url
        if size == 0 { finishDownload(id) } else { requestRanges(id) }
        return true
    }

    private func requestRanges(_ id: UUID) {
        guard let i = index(id), let job = jobs[id], let x = job.x else { return }
        while job.rangesOut.count < Self.rangesInFlight, job.nextRead < items[i].size {
            let n = Int(min(Int64(Self.rangeBytes), items[i].size - job.nextRead))
            job.rangesOut.append((job.nextRead, n, SHA256()))
            _ = send(RemoteFilesRequests.make("read", req: nextReq(), ["x": x, "o": job.nextRead, "n": n]))
            job.nextRead += Int64(n)
        }
    }

    private func onData(_ r: RemoteFilesReply) -> Bool {
        guard let (id, job) = job(x: r.x), case .download = items.first(where: { $0.id == id })?.direction else { return false }
        guard let o = r.offset, let data = r.data, var range = job.rangesOut.first else { fail(id, "badData"); return true }
        let expected = range.o + Int64(job.rangesOutWritten)
        guard o == expected, Int64(data.count) + Int64(job.rangesOutWritten) <= Int64(range.n) else { fail(id, "badData"); return true }
        do { try job.file?.write(contentsOf: data) } catch { fail(id, "storage"); return true }
        range.hasher.update(data: data)
        job.rangesOut[0] = range
        job.rangesOutWritten += data.count
        touch(id, bytes: data.count)
        return true
    }

    private func onRangeDone(_ r: RemoteFilesReply) -> Bool {
        guard let (id, job) = job(x: r.x), case .download = items.first(where: { $0.id == id })?.direction else { return false }
        guard r.ok else { fail(id, r.error ?? "failed"); return true }
        guard let range = job.rangesOut.first, r.offset == range.o, job.rangesOutWritten == range.n else { fail(id, "badData"); return true }
        let digest = range.hasher.finalize().prefix(8).map { String(format: "%02x", $0) }.joined()
        guard digest == r.sha else { fail(id, "digest"); return true }
        job.rangesOut.removeFirst()
        job.rangesOutWritten = 0
        guard let i = index(id) else { return true }
        if items[i].transferred >= items[i].size, job.rangesOut.isEmpty { finishDownload(id) } else { requestRanges(id) }
        return true
    }

    private func finishDownload(_ id: UUID) {
        try? jobs[id]?.file?.synchronize()
        finish(id, .done)
    }

    private func onUploadBegun(_ r: RemoteFilesReply) -> Bool {
        guard let (id, job) = job(req: r.req) else { return false }
        guard let i = index(id), items[i].state == .running else { return true }
        if r.skipped {
            items[i].resultName = r.name
            finish(id, .skipped)
            return true
        }
        guard r.ok, let x = r.x else {
            if r.error == "exists" {
                try? job.source?.close(); job.source = nil
                job.scoped?.stopAccessingSecurityScopedResource()
                items[i].state = .conflict(suggest: r.suggest)
                pump()
            } else {
                fail(id, r.error ?? "failed")
            }
            return true
        }
        job.x = x
        items[i].resultName = r.name
        sendParts(id)
        return true
    }

    private func sendParts(_ id: UUID) {
        guard let i = index(id), let job = jobs[id], let x = job.x, let source = job.source else { return }
        while job.sent < items[i].size, job.sent - job.acked < Int64(Self.uploadPart * Self.uploadWindow) {
            guard let data = try? source.read(upToCount: Self.uploadPart), !data.isEmpty else { return fail(id, "unreadable") }
            job.hasher.update(data: data)
            _ = send(RemoteFilesRequests.make("uploadData", req: nextReq(), ["x": x, "o": job.sent, "d": data.base64EncodedString()]))
            job.sent += Int64(data.count)
        }
        if items[i].size == 0 || (job.sent >= items[i].size && job.acked >= items[i].size) {
            let sha = job.hasher.finalize().map { String(format: "%02x", $0) }.joined()
            job.req = nextReq()
            _ = send(RemoteFilesRequests.make("uploadEnd", req: job.req!, ["x": x, "sha": sha]))
        }
    }

    private func onUploadAck(_ r: RemoteFilesReply) -> Bool {
        guard let (id, job) = job(x: r.x), case .upload = items.first(where: { $0.id == id })?.direction else { return false }
        guard r.ok, let o = r.offset else { fail(id, r.error ?? "failed"); return true }
        let delta = Int(o - job.acked)
        job.acked = o
        touch(id, bytes: max(0, delta))
        sendParts(id)
        return true
    }

    private func onUploadEnded(_ r: RemoteFilesReply) -> Bool {
        guard let (id, _) = job(req: r.req), let i = index(id) else { return false }
        guard r.ok else { fail(id, r.error ?? "failed"); return true }
        items[i].resultName = r.name ?? items[i].resultName
        let root = items[i].root, path = items[i].path
        finish(id, .done)
        onRemoteChange?(root, path)
        return true
    }
}

/// How a name conflict on the Mac is answered.
enum RemoteFileConflictChoice: String, Sendable {
    case ask, replace, keepBoth, skip
    var wire: String {
        switch self {
        case .ask: return "ask"
        case .replace: return "replace"
        case .keepBoth: return "rename"
        case .skip: return "skip"
        }
    }
}

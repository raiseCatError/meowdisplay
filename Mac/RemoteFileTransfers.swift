import CryptoKit
import Foundation

// Remote Finder transfers for one session (PROTOCOL.md 6.12): bounded, cancellable, checked.
// Paths reach this type already resolved and authorized by `RemoteFileBrowser`; it only does
// the I/O. Downloads are read in ranges the receiver asks for (it paces them) and sent in
// parts under the control-frame limit, each range with its digest; a file that changes while
// it is read fails the transfer. Uploads go into a hidden temporary file in the destination
// folder and become the real file only when complete and matching their digest; nothing is
// overwritten unless the receiver asked to replace (and was allowed to).

enum RemoteFileConflict: String, Sendable {
    /// Fail with `exists` and let the receiver ask its user.
    case ask
    /// Keep both: "Name 2.ext".
    case rename
    /// Replace the existing item (needs `modify`).
    case replace
    /// Leave the existing item; nothing is written.
    case skip
}

final class RemoteFileTransfers: @unchecked Sendable {
    struct TransferError: Error, Equatable { let code: String }

    static let maxDownloads = 6
    static let maxUploads = 4
    static let maxReadLength = 1 << 20
    static let partBytes = 22_000
    static let maxUploadPart = 96 * 1024
    static let maxUploadSize: Int64 = 32 << 30
    /// Free space kept on the Mac's volume beyond an upload.
    static let spaceMargin: Int64 = 256 << 20
    static let idleTimeout: TimeInterval = 120

    private struct Download {
        let url: URL
        let handle: FileHandle
        let size: Int64
        let stamp: FileStamp
        var used: TimeInterval
    }

    /// What identifies one version of a file: read fresh from the file system (URL resource
    /// values are cached), including the inode, so a replaced file counts as changed.
    struct FileStamp: Equatable {
        let size: Int64
        let modified: Date?
        let inode: UInt64

        init?(path: String) {
            guard let a = try? FileManager.default.attributesOfItem(atPath: path),
                  let size = (a[.size] as? NSNumber)?.int64Value else { return nil }
            self.size = size
            modified = a[.modificationDate] as? Date
            inode = (a[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        }
    }

    private struct Upload {
        let folder: URL
        let name: String
        let temp: URL
        let handle: FileHandle
        let size: Int64
        var written: Int64
        var hasher: SHA256
        let expectedDigest: String?
        let conflict: RemoteFileConflict
        let modified: Date?
        var used: TimeInterval
    }

    private var downloads: [Int: Download] = [:]
    private var uploads: [Int: Upload] = [:]
    private var nextID = 0
    var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    /// Moves an existing item out of the way when an upload replaces it (never deleted outright).
    var trash: (URL) throws -> Void = { url in try FileManager.default.trashItem(at: url, resultingItemURL: nil) }
    var freeSpace: (URL) -> Int64? = { url in
        (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
    }

    var activeDownloads: Int { downloads.count }
    var activeUploads: Int { uploads.count }

    private func newID() -> Int { nextID = nextID >= 1_000_000_000 ? 1 : nextID + 1; return nextID }

    private func expire() {
        let t = now()
        for (id, d) in downloads where t - d.used > Self.idleTimeout { try? d.handle.close(); downloads[id] = nil }
        for (id, u) in uploads where t - u.used > Self.idleTimeout { discard(u); uploads[id] = nil }
    }

    // MARK: Downloads

    /// Opens a regular file for reading; returns its transfer id and size.
    func openDownload(_ url: URL) throws -> (id: Int, size: Int64) {
        expire()
        guard downloads.count < Self.maxDownloads else { throw TransferError(code: "busy") }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue,
              let stamp = FileStamp(path: url.path) else { throw TransferError(code: "notFile") }
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw TransferError(code: "permission") }
        let id = newID()
        downloads[id] = Download(url: url, handle: handle, size: stamp.size, stamp: stamp, used: now())
        return (id, stamp.size)
    }

    /// Reads `length` bytes at `offset` as parts (each ≤ `partBytes`), plus the range's digest.
    func read(_ id: Int, offset: Int64, length: Int) throws -> (parts: [Data], digest: String) {
        guard var d = downloads[id] else { throw TransferError(code: "noTransfer") }
        guard offset >= 0, length > 0, length <= Self.maxReadLength, offset < d.size else { throw TransferError(code: "badRange") }
        // The file must still be the one that was opened.
        guard FileStamp(path: d.url.path) == d.stamp else {
            close(id)
            throw TransferError(code: "changed")
        }
        do {
            try d.handle.seek(toOffset: UInt64(offset))
            let data = try d.handle.read(upToCount: min(length, Int(d.size - offset))) ?? Data()
            d.used = now()
            downloads[id] = d
            var parts: [Data] = []
            var i = data.startIndex
            while i < data.endIndex {
                let j = min(i + Self.partBytes, data.endIndex)
                parts.append(data[i..<j])
                i = j
            }
            return (parts, ControlChunkWire.digest(data))
        } catch {
            close(id)
            throw TransferError(code: "readFailed")
        }
    }

    func close(_ id: Int) {
        if let d = downloads.removeValue(forKey: id) { try? d.handle.close() }
    }

    // MARK: Uploads

    /// Starts an upload of `size` bytes named `name` into `folder`. Returns the final name it
    /// will get, or nil for `.skip` of an existing item.
    func beginUpload(folder: URL, name: String, size: Int64, conflict: RemoteFileConflict, digest: String?,
                     modified: Date?) throws -> (id: Int, name: String)? {
        expire()
        guard uploads.count < Self.maxUploads else { throw TransferError(code: "busy") }
        guard size >= 0, size <= Self.maxUploadSize else { throw TransferError(code: "tooLarge") }
        if let free = freeSpace(folder), free < size + Self.spaceMargin { throw TransferError(code: "noSpace") }
        guard let target = try Self.targetName(in: folder, name: name, conflict: conflict) else { return nil }
        let temp = folder.appendingPathComponent(".meowdisplay-\(UUID().uuidString).upload")
        guard FileManager.default.createFile(atPath: temp.path, contents: nil, attributes: [.posixPermissions: 0o600]),
              let handle = try? FileHandle(forWritingTo: temp) else { throw TransferError(code: "permission") }
        let id = newID()
        uploads[id] = Upload(folder: folder, name: target, temp: temp, handle: handle, size: size, written: 0,
                             hasher: SHA256(), expectedDigest: digest, conflict: conflict, modified: modified, used: now())
        return (id, target)
    }

    /// Appends the part at `offset` (which must be where the file ends now). Returns bytes written so far.
    func write(_ id: Int, offset: Int64, data: Data) throws -> Int64 {
        guard var u = uploads[id] else { throw TransferError(code: "noTransfer") }
        guard offset == u.written, data.count <= Self.maxUploadPart, u.written + Int64(data.count) <= u.size else {
            cancelUpload(id)
            throw TransferError(code: "badRange")
        }
        do { try u.handle.write(contentsOf: data) } catch {
            cancelUpload(id)
            throw TransferError(code: (error as NSError).code == Int(ENOSPC) ? "noSpace" : "writeFailed")
        }
        u.hasher.update(data: data)
        u.written += Int64(data.count)
        u.used = now()
        uploads[id] = u
        return u.written
    }

    /// Checks size and digest, then puts the file in place (never silently over another).
    func finishUpload(_ id: Int) throws -> String {
        guard let u = uploads.removeValue(forKey: id) else { throw TransferError(code: "noTransfer") }
        try? u.handle.synchronize()
        try? u.handle.close()
        guard u.written == u.size else { discard(u); throw TransferError(code: "short") }
        if let want = u.expectedDigest {
            let got = u.hasher.finalize().map { String(format: "%02x", $0) }.joined()
            guard got.hasPrefix(want.lowercased()), want.count >= 16 else { discard(u); throw TransferError(code: "digest") }
        }
        if let m = u.modified { try? FileManager.default.setAttributes([.modificationDate: m], ofItemAtPath: u.temp.path) }
        do {
            // Another item may have appeared with that name meanwhile: decide again.
            guard let name = try Self.targetName(in: u.folder, name: u.name, conflict: u.conflict == .replace ? .replace : .rename) else {
                discard(u); return u.name
            }
            let dest = u.folder.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: dest.path) { try trash(dest) }   // replace: the old one goes to the Trash
            try FileManager.default.moveItem(at: u.temp, to: dest)
            return name
        } catch let e as TransferError {
            discard(u); throw e
        } catch {
            discard(u); throw TransferError(code: "writeFailed")
        }
    }

    func cancelUpload(_ id: Int) {
        if let u = uploads.removeValue(forKey: id) { discard(u) }
    }

    private func discard(_ u: Upload) {
        try? u.handle.close()
        try? FileManager.default.removeItem(at: u.temp)
    }

    /// Ends everything (session over, access revoked): downloads close, partial uploads are removed.
    func stopAll() {
        for (_, d) in downloads { try? d.handle.close() }
        downloads.removeAll()
        for (_, u) in uploads { discard(u) }
        uploads.removeAll()
    }

    // MARK: Names

    /// The name to write `name` under in `folder`: nil to skip; throws `exists` for `.ask`.
    static func targetName(in folder: URL, name: String, conflict: RemoteFileConflict) throws -> String? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: folder.appendingPathComponent(name).path) else { return name }
        switch conflict {
        case .ask: throw TransferError(code: "exists")
        case .skip: return nil
        case .replace: return name
        case .rename: return uniqueName(in: folder, name: name)
        }
    }

    /// "Report.pdf" → "Report 2.pdf", "Report 3.pdf", … (Finder's own pattern).
    static func uniqueName(in folder: URL, name: String) -> String {
        let fm = FileManager.default
        let ext = (name as NSString).pathExtension
        var stem = (name as NSString).deletingPathExtension
        var n = 2
        // "Report 2" copied again becomes "Report 3", not "Report 2 2".
        if let r = stem.range(of: #" (\d+)$"#, options: .regularExpression), let k = Int(stem[r].dropFirst()) {
            stem = String(stem[..<r.lowerBound]); n = k + 1
        }
        while true {
            let candidate = ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)"
            if !fm.fileExists(atPath: folder.appendingPathComponent(candidate).path) { return candidate }
            n += 1
            if n > 10_000 { return "\(stem) \(UUID().uuidString.prefix(8))" + (ext.isEmpty ? "" : ".\(ext)") }
        }
    }
}

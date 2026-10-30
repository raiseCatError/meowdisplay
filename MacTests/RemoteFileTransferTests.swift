import XCTest

/// Remote Finder's permissions and transfers on the Mac (Mac/RemoteFilesAuthorization.swift,
/// Mac/RemoteFileTransfers.swift, Mac/RemoteFileBrowser.swift).
final class RemoteFileTransferTests: XCTestCase {
    private var dir: URL!
    private var home: URL!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("RemoteXfer-\(UUID().uuidString)")
        home = dir.appendingPathComponent("home")
        let fm = FileManager.default
        try fm.createDirectory(at: home.appendingPathComponent("Shared/Inbox"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent("outside"), withIntermediateDirectories: true)
        try fm.createDirectory(at: home.appendingPathComponent(".ssh"), withIntermediateDirectories: true)
        try "key".write(to: home.appendingPathComponent(".ssh/id_ed25519"), atomically: true, encoding: .utf8)
        try "note".write(to: home.appendingPathComponent("Shared/.hidden-note"), atomically: true, encoding: .utf8)
        try fm.createSymbolicLink(at: home.appendingPathComponent("Shared/escape"), withDestinationURL: dir.appendingPathComponent("outside"))
        defaults = UserDefaults(suiteName: "RemoteXfer-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: Policy

    func testPoliciesAreNeverWidenedWhileADeviceHasControl() {
        var p = FilesDevicePolicy()
        XCTAssertEqual(FilesDevicePolicyStore.policy(peerID: "a", defaults: defaults), .default, "nothing stored: Ask, read-only")
        p.access = .always
        XCTAssertFalse(FilesDevicePolicyStore.setPolicy(p, peerID: "a", anySessionHasEffectiveInput: true, defaults: defaults))
        XCTAssertEqual(FilesDevicePolicyStore.policy(peerID: "a", defaults: defaults).access, .ask)
        XCTAssertTrue(FilesDevicePolicyStore.setPolicy(p, peerID: "a", anySessionHasEffectiveInput: false, defaults: defaults))
        var wider = p; wider.capabilities.insert(.delete)
        XCTAssertFalse(FilesDevicePolicyStore.setPolicy(wider, peerID: "a", anySessionHasEffectiveInput: true, defaults: defaults))
        var all = p; all.scope = .allAccessible
        XCTAssertFalse(FilesDevicePolicyStore.setPolicy(all, peerID: "a", anySessionHasEffectiveInput: true, defaults: defaults))
        var narrower = p; narrower.capabilities = [.browse]
        XCTAssertTrue(FilesDevicePolicyStore.setPolicy(narrower, peerID: "a", anySessionHasEffectiveInput: true, defaults: defaults), "narrowing always works")
        var blocked = narrower; blocked.access = .block
        XCTAssertTrue(FilesDevicePolicyStore.setPolicy(blocked, peerID: "a", anySessionHasEffectiveInput: true, defaults: defaults))
        XCTAssertEqual(FilesDevicePolicyStore.policy(peerID: "b", defaults: defaults), .default, "each device on its own")
        FilesDevicePolicyStore.removePolicy(peerID: "a", defaults: defaults)
        XCTAssertEqual(FilesDevicePolicyStore.policy(peerID: "a", defaults: defaults), .default, "Forget removes it")
        let after = FilesDevicePolicyStore.policy(after: .alwaysAllAccessible, from: .default)
        XCTAssertEqual(after?.access, .always)
        XCTAssertEqual(after?.scope, .allAccessible)
        XCTAssertEqual(after?.capabilities, FilesCapability.readOnly, "the broad choice is still read-only")
        XCTAssertNil(FilesDevicePolicyStore.policy(after: .session, from: .default))
    }

    // MARK: Transfers

    func testDownloadsReadRangesWithDigestsAndStopWhenTheFileChanges() throws {
        let file = home.appendingPathComponent("Shared/big.bin")
        let bytes = Data((0..<100_000).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        try bytes.write(to: file)
        let t = RemoteFileTransfers()
        let (x, size) = try t.openDownload(file)
        XCTAssertEqual(size, 100_000)
        var got = Data()
        var o: Int64 = 0
        while o < size {
            let (parts, digest) = try t.read(x, offset: o, length: 40_000)
            XCTAssertTrue(parts.allSatisfy { $0.count <= RemoteFileTransfers.partBytes })
            let range = parts.reduce(Data(), +)
            XCTAssertEqual(digest, ControlChunkWire.digest(range))
            got.append(range); o += Int64(range.count)
        }
        XCTAssertEqual(got, bytes)
        XCTAssertThrowsError(try t.read(x, offset: -1, length: 10))
        XCTAssertThrowsError(try t.read(x, offset: 0, length: RemoteFileTransfers.maxReadLength + 1))
        // The file changes under the transfer: it fails rather than mixing versions.
        Thread.sleep(forTimeInterval: 1.1)
        try Data(count: 100_001).write(to: file)
        XCTAssertThrowsError(try t.read(x, offset: 0, length: 10)) { XCTAssertEqual(($0 as? RemoteFileTransfers.TransferError)?.code, "changed") }
        XCTAssertThrowsError(try t.openDownload(home.appendingPathComponent("Shared"))) { _ in }   // a folder isn't downloaded
    }

    func testUploadsLandOnlyWhenCompleteAndNeverOverwriteSilently() throws {
        let folder = home.appendingPathComponent("Shared/Inbox")
        let t = RemoteFileTransfers()
        var trashed: [String] = []
        t.trash = { trashed.append($0.lastPathComponent); try FileManager.default.removeItem(at: $0) }
        let payload = Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0) })
        let sha = SHA256Hex.of(payload)
        func upload(_ name: String, _ conflict: RemoteFileConflict, digest: String? = nil, data: Data = payload) throws -> String? {
            guard let (x, _) = try t.beginUpload(folder: folder, name: name, size: Int64(data.count), conflict: conflict, digest: digest, modified: nil) else { return nil }
            var o = 0
            while o < data.count {
                let n = min(RemoteFileTransfers.maxUploadPart, data.count - o)
                _ = try t.write(x, offset: Int64(o), data: data[o..<(o + n)])
                o += n
            }
            return try t.finishUpload(x)
        }
        XCTAssertEqual(try upload("photo.jpg", .ask, digest: sha), "photo.jpg")
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("photo.jpg")), payload)
        XCTAssertThrowsError(try upload("photo.jpg", .ask)) { XCTAssertEqual(($0 as? RemoteFileTransfers.TransferError)?.code, "exists") }
        XCTAssertEqual(try upload("photo.jpg", .rename), "photo 2.jpg")
        XCTAssertNil(try upload("photo.jpg", .skip))
        XCTAssertEqual(try upload("photo.jpg", .replace, data: Data("new".utf8)), "photo.jpg")
        XCTAssertEqual(trashed, ["photo.jpg"], "a replaced file goes to the Trash")
        XCTAssertThrowsError(try upload("bad.bin", .ask, digest: String(repeating: "0", count: 64))) {
            XCTAssertEqual(($0 as? RemoteFileTransfers.TransferError)?.code, "digest")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("bad.bin").path), "a bad upload leaves nothing")

        // Out of order, too long, cancelled: nothing stays behind.
        let (x, _) = try XCTUnwrap(t.beginUpload(folder: folder, name: "part.bin", size: 10, conflict: .ask, digest: nil, modified: nil))
        XCTAssertThrowsError(try t.write(x, offset: 5, data: Data(count: 5)))
        let (y, _) = try XCTUnwrap(t.beginUpload(folder: folder, name: "part.bin", size: 10, conflict: .ask, digest: nil, modified: nil))
        _ = try t.write(y, offset: 0, data: Data(count: 4))
        t.cancelUpload(y)
        let (z, _) = try XCTUnwrap(t.beginUpload(folder: folder, name: "short.bin", size: 10, conflict: .ask, digest: nil, modified: nil))
        _ = try t.write(z, offset: 0, data: Data(count: 4))
        XCTAssertThrowsError(try t.finishUpload(z)) { XCTAssertEqual(($0 as? RemoteFileTransfers.TransferError)?.code, "short") }
        let left = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix(".meowdisplay-") }
        XCTAssertEqual(left, [], "no temporary files left")
        // Not enough space: refused before anything is written.
        t.freeSpace = { _ in 1000 }
        XCTAssertThrowsError(try t.beginUpload(folder: folder, name: "huge.bin", size: 10_000, conflict: .ask, digest: nil, modified: nil)) {
            XCTAssertEqual(($0 as? RemoteFileTransfers.TransferError)?.code, "noSpace")
        }
        XCTAssertEqual(RemoteFileTransfers.uniqueName(in: folder, name: "photo 2.jpg"), "photo 3.jpg")
    }

    // MARK: Browser: capabilities, scope, revocation

    private func browser(_ sent: @escaping ([String: Any]) -> Void) -> RemoteFileBrowser {
        let b = RemoteFileBrowser()
        b.home = home
        b.isEnabled = { true }
        b.roots = { [home] in [RemoteFileRoot(id: "r1", path: home!.appendingPathComponent("Shared").path)] }
        b.sendMessage = sent
        b.moveToTrash = { url in
            let t = self.dir.appendingPathComponent("Trash", isDirectory: true)
            try FileManager.default.createDirectory(at: t, withIntermediateDirectories: true)
            let dest = t.appendingPathComponent(url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: dest)
            return dest
        }
        return b
    }

    private final class Box: @unchecked Sendable {
        let lock = NSLock(); var sent: [[String: Any]] = []
        func add(_ m: [String: Any]) { lock.lock(); sent.append(m); lock.unlock() }
        var all: [[String: Any]] { lock.lock(); defer { lock.unlock() }; return sent }
        func reply(_ op: String, req: Int) -> [String: Any]? { all.last { $0["op"] as? String == op && $0["req"] as? Int == req } }
    }

    private func waitReply(_ box: Box, _ op: String, req: Int, file: StaticString = #filePath, line: UInt = #line) -> [String: Any] {
        let deadline = Date().addingTimeInterval(10)
        while box.reply(op, req: req) == nil, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        return box.reply(op, req: req) ?? { XCTFail("no \(op) reply", file: file, line: line); return [:] }()
    }

    func testCapabilitiesAreCheckedPerRequestAndRevocationIsImmediate() throws {
        let box = Box()
        let b = browser(box.add)
        var policy = FilesDevicePolicy()
        b.livePolicy = { policy }
        var asked: [Set<FilesCapability>?] = []
        b.askConsent = { asked.append($0) }
        b.handle(["op": "state", "req": 1], inputGranted: false)
        b.consentDecided(FilesGrant.session())
        XCTAssertEqual((waitReply(box, "state", req: 1)["state"] as? String), "asking")
        // Read-only: browsing and downloading work, writing doesn't.
        b.handle(["op": "mkdir", "root": "r1", "path": [], "name": "New", "req": 2], inputGranted: true)
        XCTAssertEqual(waitReply(box, "mkdir", req: 2)["error"] as? String, "notAllowed")
        XCTAssertEqual(waitReply(box, "mkdir", req: 2)["need"] as? String, "upload")
        b.handle(["op": "uploadBegin", "root": "r1", "path": ["Inbox"], "name": "a.txt", "size": 3, "req": 3], inputGranted: true)
        XCTAssertEqual(waitReply(box, "uploadBegin", req: 3)["error"] as? String, "notAllowed")
        // Asking for more: the owner allows upload for this session.
        b.handle(["op": "requestAccess", "caps": ["upload"], "req": 4], inputGranted: false)
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(asked.last ?? nil, [.upload])
        b.accessDecided([.upload])
        XCTAssertEqual(waitReply(box, "requestAccess", req: 4)["ok"] as? Bool, true)
        b.handle(["op": "mkdir", "root": "r1", "path": ["Inbox"], "name": "New", "req": 5], inputGranted: false)
        XCTAssertEqual(waitReply(box, "mkdir", req: 5)["name"] as? String, "New")
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.appendingPathComponent("Shared/Inbox/New").path))
        // Names and destinations stay inside: no traversal, no escaping symlink, no hidden names.
        for (n, (path, name)) in [(["Inbox"], "../x"), (["escape"], "x.txt"), (["Inbox"], ".profile"), (["Inbox"], "..")].enumerated() {
            b.handle(["op": "uploadBegin", "root": "r1", "path": path, "name": name, "size": 1, "req": 10 + n], inputGranted: false)
            XCTAssertEqual(waitReply(box, "uploadBegin", req: 10 + n)["error"] as? String, "notFound", "\(path) \(name)")
        }
        // Rename needs modify; trash needs delete.
        b.handle(["op": "trash", "root": "r1", "path": ["Inbox", "New"], "req": 20], inputGranted: false)
        XCTAssertEqual(waitReply(box, "trash", req: 20)["need"] as? String, "delete")
        // The device is blocked in Settings: the very next request is refused.
        policy.access = .block
        b.handle(["op": "list", "root": "r1", "path": [], "req": 21], inputGranted: false)
        XCTAssertEqual(waitReply(box, "list", req: 21)["error"] as? String, "denied")
    }

    func testAlwaysAllowFollowsThePolicyAndFileOperationsUseTheTrash() throws {
        let box = Box()
        let b = browser(box.add)
        var policy = FilesDevicePolicy(access: .always, scope: .selectedFolders, capabilities: [.browse, .download, .upload, .modify, .delete])
        b.livePolicy = { policy }
        b.askConsent = { _ in }
        b.handle(["op": "state", "req": 1], inputGranted: false)
        b.consentDecided(FilesGrant.always(policy))
        let ready = box.all.last { $0["op"] as? String == "state" && $0["state"] as? String == "ready" }
        _ = waitReply(box, "state", req: 1)
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        let grant = (box.all.last { $0["grant"] != nil }?["grant"] as? [String: Any]) ?? ready?["grant"] as? [String: Any]
        XCTAssertEqual(grant?["duration"] as? String, "always")
        try "x".write(to: home.appendingPathComponent("Shared/Inbox/doc.txt"), atomically: true, encoding: .utf8)
        b.handle(["op": "rename", "root": "r1", "path": ["Inbox", "doc.txt"], "name": "Doc.txt", "req": 2], inputGranted: false)
        XCTAssertEqual(waitReply(box, "rename", req: 2)["ok"] as? Bool, true, "a change of case is a rename")
        b.handle(["op": "duplicate", "root": "r1", "path": ["Inbox", "Doc.txt"], "req": 3], inputGranted: false)
        XCTAssertEqual(waitReply(box, "duplicate", req: 3)["name"] as? String, "Doc 2.txt")
        b.handle(["op": "move", "root": "r1", "path": ["Inbox", "Doc 2.txt"], "toRoot": "r1", "toPath": [], "req": 4], inputGranted: false)
        XCTAssertEqual(waitReply(box, "move", req: 4)["name"] as? String, "Doc 2.txt")
        b.handle(["op": "move", "root": "r1", "path": ["Inbox"], "toRoot": "r1", "toPath": ["Inbox", "New"], "req": 5], inputGranted: false)
        XCTAssertEqual(waitReply(box, "move", req: 5)["error"] as? String, "notFound", "the destination must exist")
        b.handle(["op": "trash", "root": "r1", "path": ["Doc 2.txt"], "req": 6], inputGranted: false)
        let token = try XCTUnwrap(waitReply(box, "trash", req: 6)["token"] as? String)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("Shared/Doc 2.txt").path))
        b.handle(["op": "putBack", "token": token, "req": 7], inputGranted: false)
        XCTAssertEqual(waitReply(box, "putBack", req: 7)["ok"] as? Bool, true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.appendingPathComponent("Shared/Doc 2.txt").path))
        b.handle(["op": "zip", "root": "r1", "path": ["Inbox"], "names": ["Doc.txt"], "req": 8], inputGranted: false)
        XCTAssertEqual(waitReply(box, "zip", req: 8)["name"] as? String, "Doc.txt.zip")
        b.handle(["op": "unzip", "root": "r1", "path": ["Inbox", "Doc.txt.zip"], "req": 9], inputGranted: false)
        let folder = try XCTUnwrap(waitReply(box, "unzip", req: 9)["name"] as? String)
        XCTAssertEqual(try String(contentsOf: home.appendingPathComponent("Shared/Inbox/\(folder)/Doc.txt"), encoding: .utf8), "x")
        // Hidden files only when the policy shows them, and secret folders never.
        b.handle(["op": "list", "root": "r1", "path": [], "req": 10], inputGranted: false)
        XCTAssertFalse(((waitReply(box, "list", req: 10)["entries"] as? [[String: Any]]) ?? []).contains { $0["name"] as? String == ".hidden-note" })
        policy.showHidden = true
        b.handle(["op": "list", "root": "r1", "path": [], "req": 11], inputGranted: false)
        XCTAssertTrue(((waitReply(box, "list", req: 11)["entries"] as? [[String: Any]]) ?? []).contains { $0["name"] as? String == ".hidden-note" })
        XCTAssertNil(RemoteFilesPolicy.resolve(root: home, components: [".ssh", "id_ed25519"], home: home, allowHidden: true))
        // Always Allow switched off in Settings: the session must ask again.
        policy.access = .ask
        b.handle(["op": "list", "root": "r1", "path": [], "req": 12], inputGranted: false)
        XCTAssertEqual(waitReply(box, "list", req: 12)["error"] as? String, "revoked")
        b.handle(["op": "list", "root": "r1", "path": [], "req": 13], inputGranted: false)
        XCTAssertEqual(waitReply(box, "list", req: 13)["error"] as? String, "asking")
    }

    func testDownloadOverTheWireAndRevokeStopsIt() throws {
        let box = Box()
        let b = browser(box.add)
        b.askConsent = { _ in }
        try Data(count: 50_000).write(to: home.appendingPathComponent("Shared/file.bin"))
        b.handle(["op": "state", "req": 1], inputGranted: false)
        b.consentDecided(FilesGrant.session([.browse]))
        _ = waitReply(box, "state", req: 1)
        b.handle(["op": "download", "root": "r1", "path": ["file.bin"], "purpose": "save", "req": 2], inputGranted: false)
        XCTAssertEqual(waitReply(box, "download", req: 2)["need"] as? String, "download", "saving a copy needs download")
        b.handle(["op": "download", "root": "r1", "path": ["file.bin"], "purpose": "view", "req": 3], inputGranted: false)
        let open = waitReply(box, "download", req: 3)
        let x = try XCTUnwrap(open["x"] as? Int)
        XCTAssertEqual(open["size"] as? Int64 ?? (open["size"] as? NSNumber)?.int64Value, 50_000)
        b.handle(["op": "read", "x": x, "o": 0, "n": 50_000, "req": 4], inputGranted: false)
        let done = waitReply(box, "read", req: 4)
        XCTAssertEqual(done["n"] as? Int, 50_000)
        let parts = box.all.filter { $0["op"] as? String == "data" }
        XCTAssertEqual(parts.count, 3)
        for p in parts { XCTAssertLessThan(try JSONSerialization.data(withJSONObject: p).count, 32_768) }
        b.revoke()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(box.all.last?["state"] as? String, "revoked")
        b.handle(["op": "read", "x": x, "o": 0, "n": 10, "req": 5], inputGranted: false)
        XCTAssertEqual(waitReply(box, "read", req: 5)["error"] as? String, "asking", "revoked: nothing more is read")
    }
}

/// Test helper: full SHA-256 hex.
enum SHA256Hex {
    static func of(_ d: Data) -> String {
        var h = Sha256Box()
        h.update(d)
        return h.hex
    }
}

import CryptoKit
private struct Sha256Box {
    var h = SHA256()
    mutating func update(_ d: Data) { h.update(data: d) }
    var hex: String { h.finalize().map { String(format: "%02x", $0) }.joined() }

    // MARK: Write policy (Show Hidden Files is read-only; writes re-check where they land)

    private func alwaysAllBrowser(_ box: Box, showHidden: Bool = true) -> RemoteFileBrowser {
        let b = browser(box.add)
        var policy = FilesDevicePolicy(access: .always, scope: .selectedFolders, capabilities: [.browse, .download, .upload, .modify, .delete])
        policy.showHidden = showHidden
        b.livePolicy = { policy }
        b.askConsent = { _ in }
        b.handle(["op": "state", "req": 1], inputGranted: false)
        b.consentDecided(FilesGrant.always(policy))
        _ = waitReply(box, "state", req: 1)
        return b
    }

    func testHiddenItemsAreNeverWrittenEvenWithHiddenFilesShown() throws {
        let box = Box()
        let b = alwaysAllBrowser(box)
        let fm = FileManager.default
        try fm.createDirectory(at: home.appendingPathComponent("Shared/.hooks"), withIntermediateDirectories: true)
        try "x".write(to: home.appendingPathComponent("Shared/doc.txt"), atomically: true, encoding: .utf8)
        let refused: [[String: Any]] = [
            ["op": "uploadBegin", "root": "r1", "path": [], "name": ".zshenv", "size": 1],
            ["op": "uploadBegin", "root": "r1", "path": [".hooks"], "name": "pre-commit", "size": 1],
            ["op": "mkdir", "root": "r1", "path": [], "name": ".git"],
            ["op": "rename", "root": "r1", "path": ["doc.txt"], "name": ".zshrc"],
            ["op": "rename", "root": "r1", "path": [".hidden-note"], "name": "visible.txt"],
            ["op": "move", "root": "r1", "path": ["doc.txt"], "toRoot": "r1", "toPath": [".hooks"]],
            ["op": "copy", "root": "r1", "path": [".hidden-note"], "toRoot": "r1", "toPath": ["Inbox"]],
            ["op": "duplicate", "root": "r1", "path": [".hidden-note"]],
            ["op": "trash", "root": "r1", "path": [".hidden-note"]],
            ["op": "zip", "root": "r1", "path": [], "names": [".hidden-note"]],
        ]
        for (n, var request) in refused.enumerated() {
            request["req"] = 100 + n
            b.handle(request, inputGranted: false)
            let op = request["op"] as! String
            XCTAssertEqual(waitReply(box, op, req: 100 + n)["error"] as? String, "notFound", "\(request)")
        }
        XCTAssertFalse(fm.fileExists(atPath: home.appendingPathComponent("Shared/.zshenv").path))
        XCTAssertFalse(fm.fileExists(atPath: home.appendingPathComponent("Shared/.git").path))
        XCTAssertTrue(fm.fileExists(atPath: home.appendingPathComponent("Shared/.hidden-note").path), "left alone")
        // Hidden files can still be read when shown.
        try "shown".write(to: home.appendingPathComponent("Shared/.notes.txt"), atomically: true, encoding: .utf8)
        b.handle(["op": "preview", "root": "r1", "path": [".notes.txt"], "req": 200], inputGranted: false)
        XCTAssertEqual(waitReply(box, "preview", req: 200)["text"] as? String, "shown")
    }

    func testAFinishedUploadIsQuarantinedAndLandsOnlyWhereItBegan() throws {
        let box = Box()
        let b = alwaysAllBrowser(box, showHidden: false)
        let payload = Data("hello".utf8)
        func upload(_ name: String, req: Int, between: () throws -> Void = {}) throws -> [String: Any] {
            b.handle(["op": "uploadBegin", "root": "r1", "path": ["Inbox"], "name": name, "size": payload.count, "req": req], inputGranted: false)
            let x = try XCTUnwrap(waitReply(box, "uploadBegin", req: req)["x"] as? Int)
            try between()
            b.handle(["op": "uploadData", "x": x, "o": 0, "d": payload.base64EncodedString()], inputGranted: false)
            let deadline = Date().addingTimeInterval(5)
            while !box.all.contains(where: { $0["op"] as? String == "uploadAck" && $0["x"] as? Int == x }), Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            }
            b.handle(["op": "uploadEnd", "x": x, "req": req + 1], inputGranted: false)
            return waitReply(box, "uploadEnd", req: req + 1)
        }
        XCTAssertEqual(try upload("a.txt", req: 10)["name"] as? String, "a.txt")
        let landed = home.appendingPathComponent("Shared/Inbox/a.txt")
        let quarantine = try landed.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties
        XCTAssertEqual(quarantine?["LSQuarantineAgentName"] as? String, "MeowDisplay", "uploads carry the quarantine mark")

        // The folder is replaced by a symlink to a folder outside while the upload runs.
        let fm = FileManager.default
        let reply = try upload("b.txt", req: 20) {
            try fm.moveItem(at: home.appendingPathComponent("Shared/Inbox"), to: home.appendingPathComponent("Shared/Moved"))
            try fm.createSymbolicLink(at: home.appendingPathComponent("Shared/Inbox"), withDestinationURL: dir.appendingPathComponent("outside"))
        }
        XCTAssertEqual(reply["error"] as? String, "notFound")
        XCTAssertFalse(fm.fileExists(atPath: dir.appendingPathComponent("outside/b.txt").path), "nothing written outside")
        XCTAssertFalse(fm.fileExists(atPath: home.appendingPathComponent("Shared/Moved/b.txt").path))
    }

    func testExpandedArchivesLoseSymlinksAndAreQuarantined() throws {
        let box = Box()
        let b = alwaysAllBrowser(box, showHidden: false)
        let fm = FileManager.default
        // An archive holding a symlink to a secret outside the folder, made with the same tool.
        let staging = dir.appendingPathComponent("staging")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        try "data".write(to: staging.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        try fm.createSymbolicLink(at: staging.appendingPathComponent("key"), withDestinationURL: home.appendingPathComponent(".ssh/id_ed25519"))
        let zip = home.appendingPathComponent("Shared/Inbox/bundle.zip")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/bsdtar")
        p.arguments = ["-a", "-cf", zip.path, "--", "file.txt", "key"]
        p.currentDirectoryURL = staging
        try p.run(); p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)

        b.handle(["op": "unzip", "root": "r1", "path": ["Inbox", "bundle.zip"], "req": 30], inputGranted: false)
        let folder = try XCTUnwrap(waitReply(box, "unzip", req: 30)["name"] as? String)
        let out = home.appendingPathComponent("Shared/Inbox/\(folder)")
        XCTAssertEqual(try String(contentsOf: out.appendingPathComponent("file.txt"), encoding: .utf8), "data")
        XCTAssertNil(try? fm.destinationOfSymbolicLink(atPath: out.appendingPathComponent("key").path), "no symlink survives")
        let q = try out.appendingPathComponent("file.txt").resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties
        XCTAssertEqual(q?["LSQuarantineAgentName"] as? String, "MeowDisplay")
    }

}

import CryptoKit
import XCTest

/// Remote Finder end to end: the receiver's model and transfer queue (Shared/RemoteFiles*.swift,
/// Shared/RemoteTransferQueue.swift) talking to the Mac's browser (Mac/RemoteFileBrowser.swift)
/// over JSON, on a disposable folder. Every message is checked against the control-frame limit.
@MainActor
final class RemoteFinderLoopTests: XCTestCase {
    private var dir: URL!
    private var shared: URL!
    private var browser: RemoteFileBrowser!
    private var model: RemoteFilesModel!
    private var oversized = 0

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("RemoteFinderLoop-\(UUID().uuidString)")
        shared = dir.appendingPathComponent("home/Shared")
        try FileManager.default.createDirectory(at: shared.appendingPathComponent("Album/Inner"), withIntermediateDirectories: true)
        let trash = dir.appendingPathComponent("Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)

        let b = RemoteFileBrowser()
        b.home = dir.appendingPathComponent("home")
        b.isEnabled = { true }
        b.roots = { [shared] in [RemoteFileRoot(id: "r1", path: shared!.path)] }
        b.askConsent = { _ in }
        b.moveToTrash = { url in
            let dest = trash.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: dest)
            return dest
        }
        let m = RemoteFilesModel(defaults: UserDefaults(suiteName: "RemoteFinderLoop-\(UUID().uuidString)")!)
        // The wire: JSON both ways, replies handed to the main actor in order.
        b.sendMessage = { [weak self] obj in
            guard let data = try? JSONSerialization.data(withJSONObject: obj),
                  let back = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if data.count >= 32_768, back["op"] as? String != "preview" { self?.oversized += 1 }
                    if let r = RemoteFilesReply.parse(back) { self?.model?.apply(r) }
                }
            }
        }
        m.send = { [weak b] obj in
            guard let data = try? JSONSerialization.data(withJSONObject: obj),
                  let back = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
            XCTAssertLessThan(data.count, 32_768, "requests stay under the control limit")
            b?.handle(back, inputGranted: false)
            return true
        }
        m.setAvailable(true)
        browser = b
        model = m
    }

    override func tearDown() async throws {
        browser?.stop()
        model?.reset()
        try? FileManager.default.removeItem(at: dir)
    }

    private func until(_ what: String, timeout: TimeInterval = 15, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(condition(), "timed out waiting for \(what)")
    }

    private func allow(_ caps: Set<FilesCapability>) async {
        model.open()
        try? await Task.sleep(nanoseconds: 50_000_000)
        browser.consentDecided(FilesGrant.session(caps))
        await until("ready") { model.access == .ready }
        await until("listing") { !model.loading }
    }

    private func random(_ n: Int) -> Data { Data((0..<n).map { _ in UInt8.random(in: 0...255) }) }

    func testSaveAndShareCopyFilesAndFoldersIntact() async throws {
        let big = random(1_300_000)
        try big.write(to: shared.appendingPathComponent("movie.bin"))
        try random(70_000).write(to: shared.appendingPathComponent("Album/a.jpg"))
        try random(10).write(to: shared.appendingPathComponent("Album/Inner/b.txt"))
        try Data().write(to: shared.appendingPathComponent("Album/empty.txt"))
        await allow([.browse, .download])
        XCTAssertEqual(model.grant?.canDownload, true)
        XCTAssertEqual(model.grant?.readOnly, true)
        let movie = try XCTUnwrap(model.entries.first { $0.name == "movie.bin" })
        let album = try XCTUnwrap(model.entries.first { $0.name == "Album" })

        model.save([movie, album])
        await until("export", timeout: 30) { model.export != nil }
        let e = try XCTUnwrap(model.export)
        XCTAssertEqual(e.mode, .save)
        XCTAssertEqual(e.failed, 0)
        XCTAssertEqual(Set(e.urls.map(\.lastPathComponent)), ["movie.bin", "Album"])
        let root = e.directory
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("movie.bin")), big)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Album/a.jpg")),
                       try Data(contentsOf: shared.appendingPathComponent("Album/a.jpg")))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Album/Inner/b.txt")).count, 10)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Album/empty.txt")).count, 0, "zero-byte files come too")
        model.exportFinished(e, completed: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path), "copies go once saved")
        XCTAssertEqual(oversized, 0)
    }

    func testReadOnlyGrantRefusesWritesAndAskingForMoreWorks() async throws {
        await allow([.browse])
        let local = dir.appendingPathComponent("local.txt")
        try Data("hello".utf8).write(to: local)
        model.upload([local])
        XCTAssertEqual(model.notice, .needs("upload"), "hidden by the grant before anything is sent")
        XCTAssertTrue(model.transfers.items.isEmpty)
        // A request the grant doesn't cover is refused by the Mac too.
        let r = await model.request("mkdir", ["root": "r1", "path": [], "name": "X", "conflict": "rename"])
        XCTAssertEqual(r.error, "notAllowed")
        XCTAssertEqual(r.need, "upload")
        // Ask for upload; the owner allows it on the Mac.
        let ask = Task { await model.requestAccess(["upload"]) }
        try await Task.sleep(nanoseconds: 100_000_000)
        browser.accessDecided([.upload])
        await ask.value
        await until("grant updated") { model.grant?.canUpload == true }
        XCTAssertEqual(model.notice, .text(String(localized: "The Mac allowed it.")))
    }

    func testUploadsLandIntactWithConflictsAndFolders() async throws {
        try Data("old".utf8).write(to: shared.appendingPathComponent("report.txt"))
        await allow([.browse, .download, .upload, .modify, .delete])
        let src = dir.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: src.appendingPathComponent("Project/Sub"), withIntermediateDirectories: true)
        let payload = random(600_000)
        try payload.write(to: src.appendingPathComponent("report.txt"))
        try random(1000).write(to: src.appendingPathComponent("Project/one.bin"))
        try random(2000).write(to: src.appendingPathComponent("Project/Sub/two.bin"))
        try Data().write(to: src.appendingPathComponent("Project/zero.txt"))
        try Data("x".utf8).write(to: src.appendingPathComponent("Project/.DS_Store"))

        // A name that exists: the queue asks; Keep Both makes "report 2.txt".
        model.upload([src.appendingPathComponent("report.txt")])
        await until("conflict") { model.transfers.firstConflict != nil }
        let c = try XCTUnwrap(model.transfers.firstConflict)
        model.transfers.resolveConflict(c.id, .keepBoth, forAll: false)
        await until("upload done", timeout: 30) { model.transfers.items.first?.state == .done }
        XCTAssertEqual(model.transfers.items.first?.resultName, "report 2.txt")
        XCTAssertEqual(try Data(contentsOf: shared.appendingPathComponent("report 2.txt")), payload)
        XCTAssertEqual(try String(contentsOf: shared.appendingPathComponent("report.txt")), "old", "never overwritten without Replace")

        // Replace: the old one goes to the Trash.
        model.upload([src.appendingPathComponent("report.txt")])
        await until("conflict 2") { model.transfers.firstConflict != nil }
        model.transfers.resolveConflict(try XCTUnwrap(model.transfers.firstConflict).id, .replace, forAll: false)
        await until("replace done", timeout: 30) { model.transfers.items.allSatisfy { $0.state.isFinished } }
        XCTAssertEqual(try Data(contentsOf: shared.appendingPathComponent("report.txt")), payload)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("Trash").path).count, 1)

        // A folder keeps its structure; hidden files stay behind; an existing folder can merge.
        model.upload([src.appendingPathComponent("Project")])
        await until("folder upload", timeout: 30) {
            model.transfers.items.count == 5 && model.transfers.items.allSatisfy { $0.state.isFinished }
        }
        let up = shared.appendingPathComponent("Project")
        XCTAssertTrue(FileManager.default.fileExists(atPath: up.appendingPathComponent("Sub/two.bin").path))
        XCTAssertEqual(try Data(contentsOf: up.appendingPathComponent("zero.txt")).count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: up.appendingPathComponent(".DS_Store").path))
        model.upload([src.appendingPathComponent("Project")])
        await until("folder conflict") { model.folderConflict != nil }
        model.folderConflict?.answer(.keepBoth)
        await until("second folder", timeout: 30) {
            FileManager.default.fileExists(atPath: shared.appendingPathComponent("Project 2/Sub/two.bin").path)
                && model.transfers.items.allSatisfy { $0.state.isFinished }
        }
        let leftovers = try FileManager.default.subpathsOfDirectory(atPath: shared.path).filter { $0.contains(".meowdisplay-") }
        XCTAssertEqual(leftovers, [], "no temporary upload files remain")
        XCTAssertEqual(oversized, 0)
    }

    func testFileOperationsAndUndo() async throws {
        try Data("a".utf8).write(to: shared.appendingPathComponent("note.txt"))
        await allow([.browse, .modify, .upload, .delete])
        await model.newFolder(named: "Drafts")
        XCTAssertTrue(FileManager.default.fileExists(atPath: shared.appendingPathComponent("Drafts").path))
        await until("list") { model.entries.contains { $0.name == "Drafts" } }

        let note = try XCTUnwrap(model.entries.first { $0.name == "note.txt" })
        await model.rename(note, to: "memo.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: shared.appendingPathComponent("memo.txt").path))
        await until("renamed") { model.entries.contains { $0.name == "memo.txt" } }
        let memo = try XCTUnwrap(model.entries.first { $0.name == "memo.txt" })
        await model.rename(memo, to: "../escape.txt")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("home/escape.txt").path),
                       "a typed separator never leaves the folder")

        await model.duplicate([try XCTUnwrap(model.entries.first { $0.name.hasPrefix("..-escape") || $0.name == "memo.txt" })])
        await until("duplicated") { model.entries.count >= 3 }

        // Copy into Drafts, then Move to Trash with Undo.
        let first = try XCTUnwrap(model.entries.first { !$0.isDirectory })
        model.copyItems([first], move: false)
        model.go(.folder(root: "r1", path: ["Drafts"]))
        await until("in Drafts") { !model.loading }
        XCTAssertTrue(model.canPaste)
        await model.paste()
        XCTAssertTrue(FileManager.default.fileExists(atPath: shared.appendingPathComponent("Drafts/" + first.name).path))
        await until("pasted") { model.entries.count == 1 }
        let copy = try XCTUnwrap(model.entries.first)
        await model.trash([copy])
        XCTAssertFalse(FileManager.default.fileExists(atPath: shared.appendingPathComponent("Drafts/" + first.name).path))
        guard case .trashed(1, let tokens)? = model.notice else { return XCTFail("no undo offered: \(String(describing: model.notice))") }
        await model.putBack(tokens)
        XCTAssertTrue(FileManager.default.fileExists(atPath: shared.appendingPathComponent("Drafts/" + first.name).path), "Undo puts it back")

        // Compress and expand.
        await until("listed again") { model.entries.count == 1 }
        await model.compress([try XCTUnwrap(model.entries.first)])
        await until("zip") { model.entries.contains { $0.name.hasSuffix(".zip") } }
        let zip = try XCTUnwrap(model.entries.first { $0.name.hasSuffix(".zip") })
        try FileManager.default.removeItem(at: shared.appendingPathComponent("Drafts/" + first.name))
        await model.expand(zip)
        // Expanded into a folder named after the archive, never over anything.
        await until("expanded") {
            FileManager.default.fileExists(atPath: self.shared.appendingPathComponent("Drafts/\(first.name)/\(first.name)").path)
        }

        let info = try XCTUnwrap(model.entries.first)
        await model.getInfo(info)
        XCTAssertNotNil(model.info)
    }

    func testStreamingReadsAnyRangeAndRevokeStopsTransfers() async throws {
        let movie = random(3_000_000)
        try movie.write(to: shared.appendingPathComponent("clip.mov"))
        await allow([.browse, .download])
        // Playback: open for viewing, then ranges in any order (seeking).
        let r = await model.request("download", ["root": "r1", "path": ["clip.mov"], "purpose": "view"])
        let x = try XCTUnwrap(r.x)
        let stream = RemoteFileStream(x: x, size: try XCTUnwrap(r.size), uti: r.uti,
                                      send: { [weak model] m in model?.send(m) ?? false }, nextReq: { [weak model] in model?.nextReq() ?? 0 })
        model.streams[x] = stream
        var got: [Int64: Data] = [:]
        for o: Int64 in [2_500_000, 0, 1_000_000, 2_999_990] {
            stream.read(o, 300_000) { got[o] = $0 }
        }
        await until("ranges") { got.count == 4 }
        for (o, d) in got { XCTAssertEqual(d, movie.subdata(in: Int(o)..<min(Int(o) + 300_000, movie.count)), "range at \(o)") }

        // A save in progress fails at once when the owner revokes access.
        let big = random(8_000_000)
        try big.write(to: shared.appendingPathComponent("big.bin"))
        model.refresh()
        await until("listed") { model.entries.contains { $0.name == "big.bin" } }
        model.save([try XCTUnwrap(model.entries.first { $0.name == "big.bin" })])
        await until("started") { (model.transfers.items.first?.transferred ?? 0) > 0 }
        browser.revoke()
        await until("revoked") { model.access == .revoked }
        XCTAssertEqual(model.transfers.items.first?.state, .failed("revoked"))
        XCTAssertNil(model.grant)
        XCTAssertNil(model.export, "nothing is handed on")
    }

    /// A damaged range fails the download; Retry resumes after the last range that matched its digest.
    func testRetryResumesAfterTheLastVerifiedRange() async throws {
        let q = RemoteTransferQueue()
        var sent: [[String: Any]] = []
        var r = 0
        q.send = { sent.append($0); return true }
        q.nextRequestID = { r += 1; return r }
        let bytes = Data((0..<600_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        func reply(_ o: [String: Any]) { _ = q.apply(RemoteFilesReply.parse(o)!) }
        func answerReads(corruptFrom: Int64?) {
            for m in sent where m["op"] as? String == "read" {
                let o = (m["o"] as! NSNumber).int64Value, n = m["n"] as! Int
                var range = bytes.subdata(in: Int(o)..<Int(o) + n)
                let sha = SHA256.hash(data: range).prefix(8).map { String(format: "%02x", $0) }.joined()
                if let c = corruptFrom, o >= c { range[range.startIndex] ^= 0xFF }
                var i = 0
                while i < range.count {
                    let j = min(i + 22_000, range.count)
                    reply(["op": "data", "x": 7, "o": o + Int64(i), "d": range.subdata(in: i..<j).base64EncodedString()])
                    i = j
                }
                reply(["op": "read", "x": 7, "o": o, "n": n, "sha": sha, "ok": true])
            }
            sent.removeAll()
        }
        let id = q.download(root: "r1", path: ["a.bin"], name: "a.bin", size: 600_000, purpose: .save)
        reply(["op": "download", "req": sent.last!["req"] as! Int, "ok": true, "x": 7, "size": 600_000, "mod": 1])
        answerReads(corruptFrom: 524_288)
        XCTAssertEqual(q.items.first?.state, .failed("digest"))
        q.retry(id)
        XCTAssertEqual(q.items.first?.transferred, 524_288, "the verified first range is kept")
        reply(["op": "download", "req": sent.last!["req"] as! Int, "ok": true, "x": 7, "size": 600_000, "mod": 1])
        XCTAssertEqual(sent.first { $0["op"] as? String == "read" }?["o"] as? Int64 ?? (sent.first { $0["op"] as? String == "read" }?["o"] as? NSNumber)?.int64Value, 524_288)
        answerReads(corruptFrom: nil)
        XCTAssertEqual(q.items.first?.state, .done)
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(q.items.first?.localURL)), bytes)
        q.purgeViewCache()
        try? FileManager.default.removeItem(at: q.items.first!.localURL!.deletingLastPathComponent())
    }

    func testSortingAndFilters() {
        func e(_ n: String, dir: Bool = false, size: Int? = nil, kind: RemoteFileKind = .file, days: Double = 0) -> RemoteFileEntry {
            RemoteFileEntry(name: n, isDirectory: dir, kind: dir ? .folder : kind, size: size, modified: Date(timeIntervalSince1970: days * 86_400))
        }
        let list = [e("File 10.txt", size: 5, kind: .text, days: 3), e("File 2.txt", size: 50, kind: .text, days: 1),
                    e("Photos", dir: true, days: 2), e("a.png", size: 7, kind: .image, days: 4)]
        XCTAssertEqual(RemoteFilesSorting.sorted(list, by: .name, ascending: true).map(\.name), ["a.png", "File 2.txt", "File 10.txt", "Photos"])
        XCTAssertEqual(RemoteFilesSorting.sorted(list, by: .size, ascending: true).map(\.name), ["Photos", "File 10.txt", "a.png", "File 2.txt"])
        XCTAssertEqual(RemoteFilesSorting.sorted(list, by: .date, ascending: false).map(\.name), ["a.png", "File 10.txt", "Photos", "File 2.txt"])
        XCTAssertEqual(list.filter(RemoteFileKindFilter.images.matches).map(\.name), ["a.png"])
        XCTAssertEqual(list.filter(RemoteFileKindFilter.folders.matches).map(\.name), ["Photos"])
        XCTAssertEqual(RemoteFilesModel.cleanName(" a/b:c "), "a-b-c")
        XCTAssertNil(RemoteFilesModel.cleanName(".."))
        XCTAssertNil(RemoteFilesModel.cleanName(".hidden"))
    }

    func testNamesThatCouldLeaveTheirFolderAreDropped() throws {
        let names = ["..", ".", "a/b", "../../x", "nul\0x", "", "ok.txt", "..hidden"]
        let reply = try XCTUnwrap(RemoteFilesReply.parse(["op": "list", "ok": true, "entries": names.map { ["name": $0] }]))
        XCTAssertEqual(reply.entries.map(\.name), ["ok.txt", "..hidden"])
    }
}

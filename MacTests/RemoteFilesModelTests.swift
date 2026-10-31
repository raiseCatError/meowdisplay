import XCTest

/// Remote Finder on the receiver (Shared/RemoteFiles.swift): what it asks and what it shows.
@MainActor
final class RemoteFilesModelTests: XCTestCase {
    private var sent: [[String: Any]] = []
    private var control = false

    private func model() -> RemoteFilesModel {
        let defaults = UserDefaults(suiteName: "RemoteFilesModelTests-\(UUID().uuidString)")!
        let m = RemoteFilesModel(defaults: defaults)
        m.send = { [unowned self] in sent.append($0); return true }
        m.inputAllowed = { [unowned self] in control }
        m.setAvailable(true)
        return m
    }

    private func reply(_ o: [String: Any]) -> RemoteFilesReply {
        var o = o
        o["type"] = "files"
        return RemoteFilesReply.parse(o)!
    }

    private func last(_ op: String) -> [String: Any]? { sent.last { $0["op"] as? String == op } }

    func testAsksTheMacFirstAndOpensTheOnlyFolder() {
        let m = model()
        m.open()
        XCTAssertEqual(m.access, .asking)
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent[0]["type"] as? String, "filesRequest")
        XCTAssertEqual(sent[0]["op"] as? String, "state")
        // Waiting for the owner.
        m.apply(reply(["op": "state", "state": "asking", "req": 1]))
        XCTAssertEqual(m.access, .asking)
        XCTAssertTrue(m.entries.isEmpty)
        // Allowed, one folder: straight into it.
        m.apply(reply(["op": "state", "state": "ready", "roots": [["id": "r1", "name": "Projects"]]]))
        XCTAssertEqual(m.access, .ready)
        XCTAssertEqual(m.location, .folder(root: "r1", path: []))
        let list = last("list")!
        XCTAssertEqual(list["root"] as? String, "r1")
        XCTAssertEqual(list["path"] as? [String], [])
        XCTAssertTrue(m.loading)
        m.apply(reply(["op": "list", "ok": true, "root": "r1", "path": [], "req": list["req"]!,
                       "entries": [["name": "App", "dir": true, "kind": "folder"],
                                   ["name": "photo.jpg", "dir": false, "kind": "image", "size": 2048, "mod": 1_700_000_000]]]))
        XCTAssertFalse(m.loading)
        XCTAssertEqual(m.entries.map(\.name), ["App", "photo.jpg"])
        XCTAssertEqual(m.entries[1].kind, .image)
        XCTAssertEqual(m.entries[1].size, 2048)
        XCTAssertEqual(m.breadcrumbs.map(\.title), ["Locations", "Projects"])
    }

    func testFoldersBackAndStaleReplies() {
        let m = model()
        m.open()
        m.apply(reply(["op": "state", "state": "ready", "roots": [["id": "r1", "name": "Projects"], ["id": "r2", "name": "Photos"]]]))
        XCTAssertEqual(m.location, .locations, "two folders: pick one")
        m.go(.folder(root: "r1", path: []))
        let first = last("list")!["req"]!
        m.openEntry(RemoteFileEntry(name: "App", isDirectory: true, kind: .folder))
        XCTAssertEqual(m.location, .folder(root: "r1", path: ["App"]))
        XCTAssertEqual(m.breadcrumbs.map(\.title), ["Locations", "Projects", "App"])
        // The folder we left answers late: ignored.
        m.apply(reply(["op": "list", "ok": true, "root": "r1", "path": [], "req": first, "entries": [["name": "old", "dir": true]]]))
        XCTAssertTrue(m.entries.isEmpty)
        m.goBack()
        XCTAssertEqual(m.location, .folder(root: "r1", path: []))
        m.goBack()
        XCTAssertEqual(m.location, .locations)
        XCTAssertFalse(m.canGoBack)
        // macOS refused the app: shown as a folder error, not as empty.
        m.go(.folder(root: "r2", path: []))
        m.apply(reply(["op": "list", "ok": false, "error": "permission", "req": last("list")!["req"]!]))
        XCTAssertEqual(m.folderError, "permission")
    }

    func testOwnerSaysNoOrTurnsItOff() {
        let m = model()
        m.open()
        m.apply(reply(["op": "state", "state": "denied"]))
        XCTAssertEqual(m.access, .denied)
        m.apply(reply(["op": "list", "ok": false, "error": "off"]))
        XCTAssertEqual(m.access, .off)
        m.setAvailable(false)
        XCTAssertFalse(m.isOpen)
        XCTAssertEqual(m.access, .unknown)
    }

    func testSearchEveryFolderFromLocationsAndShowInFolder() async throws {
        let m = model()
        m.open()
        m.apply(reply(["op": "state", "state": "ready", "roots": [["id": "r1", "name": "Projects"], ["id": "r2", "name": "Photos"]]]))
        m.query = "rea"
        m.query = "readme"
        // The debounce fires once; a busy runner may take longer than its delay to run it.
        let by = Date().addingTimeInterval(3)
        while Date() < by, !sent.contains(where: { $0["op"] as? String == "search" }) {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try await Task.sleep(nanoseconds: 300_000_000)   // and nothing else follows
        let searches = sent.filter { $0["op"] as? String == "search" }
        XCTAssertEqual(searches.count, 1, "typing is debounced")
        XCTAssertEqual(searches[0]["root"] as? String, "r1")
        XCTAssertEqual(searches[0]["q"] as? String, "readme")
        m.apply(reply(["op": "search", "ok": true, "root": "r1", "q": "readme", "req": searches[0]["req"]!, "complete": true,
                       "entries": [["name": "readme.txt", "dir": false, "kind": "text", "in": ["App", "docs"]]]]))
        let second = last("search")!
        XCTAssertEqual(second["root"] as? String, "r2", "then the next folder")
        XCTAssertTrue(m.searching)
        m.apply(reply(["op": "search", "ok": true, "root": "r2", "q": "readme", "req": second["req"]!, "complete": false, "entries": []]))
        XCTAssertFalse(m.searching)
        XCTAssertFalse(m.searchComplete)
        XCTAssertEqual(m.results.map(\.name), ["readme.txt"])
        XCTAssertEqual(m.results[0].root, "r1")
        m.showInFolder(m.results[0])
        XCTAssertEqual(m.location, .folder(root: "r1", path: ["App", "docs"]))
        XCTAssertEqual(m.highlighted, "readme.txt")
        XCTAssertEqual(m.query, "")
    }

    func testPreviewThumbnailsAndOpen() async throws {
        let m = model()
        m.open()
        m.apply(reply(["op": "state", "state": "ready", "roots": [["id": "r1", "name": "Projects"]]]))
        let note = RemoteFileEntry(name: "notes.md", isDirectory: false, kind: .text)
        m.openEntry(note)
        let p = last("preview")!
        XCTAssertEqual(p["path"] as? [String], ["notes.md"])
        m.apply(reply(["op": "preview", "ok": true, "root": "r1", "path": ["notes.md"], "req": p["req"]!, "text": "# Hi"]))
        guard case .text(let text, _)? = m.preview?.content else { return XCTFail("text preview") }
        XCTAssertEqual(text, "# Hi")
        // Seen before: no second request.
        m.closePreview()
        let count = sent.count
        m.showPreview(note)
        XCTAssertEqual(sent.count, count)

        // Grid stills: batched, only for kinds Quick Look can draw.
        m.wantThumbnail(RemoteFileEntry(name: "a.png", isDirectory: false, kind: .image))
        m.wantThumbnail(RemoteFileEntry(name: "b.pdf", isDirectory: false, kind: .pdf))
        m.wantThumbnail(RemoteFileEntry(name: "c.zip", isDirectory: false, kind: .archive))
        try await Task.sleep(nanoseconds: 300_000_000)
        let thumbs = sent.filter { $0["op"] as? String == "thumbs" }
        XCTAssertEqual(thumbs.count, 1)
        XCTAssertEqual(thumbs[0]["names"] as? [String], ["a.png", "b.pdf"])

        // Opening on the Mac needs control; without it nothing is sent.
        let before = sent.count
        m.openOnMac(note)
        XCTAssertEqual(sent.count, before)
        XCTAssertEqual(m.notice, .needsControl)
        control = true
        m.openOnMac(note, inApp: "com.apple.TextEdit")
        let open = last("open")!
        XCTAssertEqual(open["path"] as? [String], ["notes.md"])
        XCTAssertEqual(open["with"] as? String, "com.apple.TextEdit")
        m.apply(reply(["op": "open", "ok": true]))
        XCTAssertEqual(m.notice, .opened("notes.md"))
    }

    func testParsingIsBounded() {
        let long = String(repeating: "x", count: 5000)
        let r = RemoteFilesReply.parse(["op": "list", "ok": true, "root": long,
                                        "entries": [["name": long, "dir": false, "kind": "nonsense"], ["dir": true]],
                                        "jpeg": String(repeating: "A", count: RemoteFilesReply.maxBase64 + 4)])!
        XCTAssertEqual(r.root?.count, 64)
        XCTAssertEqual(r.entries.count, 1)
        XCTAssertEqual(r.entries[0].name.count, 255)
        XCTAssertEqual(r.entries[0].kind, .file)
        XCTAssertNil(r.image)
        XCTAssertNil(RemoteFilesReply.parse(["ok": true]))
    }

    /// Regression (owner's iPad, 2026-10-31): every Save and Share ended with nothing because
    /// the export folder (existing, under /private/var) and the file not yet moved there were
    /// compared after standardizing, which drops "/private" only for paths that exist.
    func testAnExportCopyInsideTheFolderIsAcceptedWhateverThePathPrefix() {
        let dir = URL(fileURLWithPath: "/private/var/mobile/Containers/Data/Application/X/tmp/RemoteFinder/export-1", isDirectory: true)
        XCTAssertTrue(RemoteFilesModel.isInside(dir.appendingPathComponent("IMG_2192.PNG"), dir))
        XCTAssertTrue(RemoteFilesModel.isInside(dir.appendingPathComponent("Folder").appendingPathComponent("a.txt"), dir))
        XCTAssertFalse(RemoteFilesModel.isInside(URL(fileURLWithPath: dir.path + "x/file"), dir), "a sibling sharing the prefix")
        XCTAssertFalse(RemoteFilesModel.isInside(dir.appendingPathComponent("..").appendingPathComponent("escape"), dir))
    }
}

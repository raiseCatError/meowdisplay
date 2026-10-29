import XCTest

/// Remote Finder on the Mac (Mac/RemoteFileBrowser.swift): what a receiver can reach.
final class RemoteFileBrowserTests: XCTestCase {
    private var dir: URL!
    private var home: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("RemoteFiles-\(UUID().uuidString)")
        home = dir.appendingPathComponent("home")
        let fm = FileManager.default
        try fm.createDirectory(at: home.appendingPathComponent("Projects/App"), withIntermediateDirectories: true)
        try fm.createDirectory(at: home.appendingPathComponent("Library/Keychains"), withIntermediateDirectories: true)
        try fm.createDirectory(at: home.appendingPathComponent(".ssh"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent("outside"), withIntermediateDirectories: true)
        try "secret".write(to: dir.appendingPathComponent("outside/secret.txt"), atomically: true, encoding: .utf8)
        try "hello".write(to: home.appendingPathComponent("Projects/readme.txt"), atomically: true, encoding: .utf8)
        try "x".write(to: home.appendingPathComponent("Projects/.env"), atomically: true, encoding: .utf8)
        try "k".write(to: home.appendingPathComponent("Library/Keychains/login.keychain-db"), atomically: true, encoding: .utf8)
        // A symlink inside the approved folder pointing outside it.
        try fm.createSymbolicLink(at: home.appendingPathComponent("Projects/escape"), withDestinationURL: dir.appendingPathComponent("outside"))
        try fm.createSymbolicLink(at: home.appendingPathComponent("Projects/lib"), withDestinationURL: home.appendingPathComponent("Library"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testOnlyHomeFoldersAndVolumesCanBeApproved() {
        XCTAssertTrue(RemoteFilesPolicy.isAllowedRoot(home, home: home))
        XCTAssertTrue(RemoteFilesPolicy.isAllowedRoot(home.appendingPathComponent("Projects"), home: home))
        XCTAssertFalse(RemoteFilesPolicy.isAllowedRoot(home.appendingPathComponent("Library"), home: home))
        XCTAssertFalse(RemoteFilesPolicy.isAllowedRoot(home.appendingPathComponent("Library/Keychains"), home: home))
        XCTAssertFalse(RemoteFilesPolicy.isAllowedRoot(home.appendingPathComponent(".ssh"), home: home))
        XCTAssertFalse(RemoteFilesPolicy.isAllowedRoot(URL(fileURLWithPath: "/"), home: home))
        XCTAssertFalse(RemoteFilesPolicy.isAllowedRoot(URL(fileURLWithPath: "/Users"), home: home))
        XCTAssertFalse(RemoteFilesPolicy.isAllowedRoot(URL(fileURLWithPath: "/System/Library"), home: home))
        XCTAssertFalse(RemoteFilesPolicy.isAllowedRoot(URL(fileURLWithPath: "/Volumes"), home: home))
        XCTAssertTrue(RemoteFilesPolicy.isAllowedRoot(URL(fileURLWithPath: "/Volumes/Backup/Photos"), home: home))
    }

    func testPathsStayInsideTheApprovedFolder() {
        let root = home.appendingPathComponent("Projects")
        XCTAssertNotNil(RemoteFilesPolicy.resolve(root: root, components: [], home: home))
        XCTAssertNotNil(RemoteFilesPolicy.resolve(root: root, components: ["readme.txt"], home: home))
        XCTAssertNil(RemoteFilesPolicy.resolve(root: root, components: [".."], home: home), "no parent")
        XCTAssertNil(RemoteFilesPolicy.resolve(root: root, components: ["App", "..", ".."], home: home))
        XCTAssertNil(RemoteFilesPolicy.resolve(root: root, components: ["../outside"], home: home), "no separators")
        XCTAssertNil(RemoteFilesPolicy.resolve(root: root, components: ["escape"], home: home), "a symlink can't leave the folder")
        XCTAssertNil(RemoteFilesPolicy.resolve(root: root, components: ["escape", "secret.txt"], home: home))
        XCTAssertNil(RemoteFilesPolicy.resolve(root: root, components: ["lib", "Keychains"], home: home), "never ~/Library")
        XCTAssertNil(RemoteFilesPolicy.resolve(root: root, components: [".env"], home: home), "nothing hidden")
        // Approving the whole home folder still hides ~/Library and dot folders.
        XCTAssertNil(RemoteFilesPolicy.resolve(root: home, components: ["Library", "Keychains"], home: home))
        XCTAssertNil(RemoteFilesPolicy.resolve(root: home, components: [".ssh"], home: home))
        XCTAssertNotNil(RemoteFilesPolicy.resolve(root: home, components: ["Projects", "App"], home: home))
    }

    private func browser(_ sent: @escaping ([String: Any]) -> Void) -> RemoteFileBrowser {
        let b = RemoteFileBrowser()
        b.home = home
        b.isEnabled = { true }
        b.roots = { [home] in [RemoteFileRoot(id: "r1", path: home!.path)] }
        b.sendMessage = sent
        return b
    }

    private func wait(_ messages: @escaping () -> [[String: Any]], for count: Int, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(5)
        while messages().count < count, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertGreaterThanOrEqual(messages().count, count, file: file, line: line)
    }

    func testNothingIsAnsweredUntilTheOwnerAllowsIt() {
        let lock = NSLock()
        var sent: [[String: Any]] = []
        let b = browser { m in lock.lock(); sent.append(m); lock.unlock() }
        func all() -> [[String: Any]] { lock.lock(); defer { lock.unlock() }; return sent }
        var asked = 0
        b.askConsent = { asked += 1 }
        b.handle(["op": "list", "root": "r1", "path": ["Projects"], "req": 1], inputGranted: true)
        wait(all, for: 1)
        XCTAssertEqual(all()[0]["error"] as? String, "asking", "a list never asks the owner by itself")
        XCTAssertEqual(asked, 0)
        b.handle(["op": "state", "req": 2], inputGranted: false)
        wait(all, for: 2)
        XCTAssertEqual(asked, 1)
        XCTAssertEqual(all()[1]["state"] as? String, "asking")
        b.consentDecided(true)
        wait(all, for: 3)
        XCTAssertEqual(all()[2]["state"] as? String, "ready")
        XCTAssertEqual((all()[2]["roots"] as? [[String: Any]])?.first?["id"] as? String, "r1")

        b.handle(["op": "list", "root": "r1", "path": ["Projects"], "req": 3], inputGranted: false)
        wait(all, for: 4)
        let names = (all()[3]["entries"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        XCTAssertEqual(names, ["App", "readme.txt"], "no hidden files, no symlinks leading out of the folder or into ~/Library")

        b.handle(["op": "list", "root": "r1", "path": [], "req": 4], inputGranted: false)
        wait(all, for: 5)
        let top = (all()[4]["entries"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        XCTAssertFalse(top.contains("Library"), "~/Library is never listed")
        XCTAssertTrue(top.contains("Projects"))

        // Opening needs control; without it nothing opens.
        var opened: [URL] = []
        var openedWith: [String?] = []
        b.openOnMac = { opened.append($0); openedWith.append($1); return true }
        b.handle(["op": "open", "root": "r1", "path": ["Projects", "readme.txt"], "req": 5], inputGranted: false)
        wait(all, for: 6)
        XCTAssertEqual(all()[5]["error"] as? String, "control")
        b.handle(["op": "open", "root": "r1", "path": ["Projects", "readme.txt"], "req": 6], inputGranted: true)
        wait(all, for: 7)
        XCTAssertEqual(opened.map(\.lastPathComponent), ["readme.txt"])
        b.handle(["op": "open", "root": "r1", "path": ["Projects", "readme.txt"], "with": "com.apple.TextEdit", "req": 61], inputGranted: true)
        wait(all, for: 8)
        XCTAssertEqual(openedWith, [nil, "com.apple.TextEdit"], "dropped on a tile: that tile's app")
        lock.lock(); sent.removeLast(); lock.unlock()

        // A text preview is an excerpt, read on the Mac.
        b.handle(["op": "preview", "root": "r1", "path": ["Projects", "readme.txt"], "req": 7], inputGranted: false)
        wait(all, for: 8)
        XCTAssertEqual(all()[7]["text"] as? String, "hello")

        // Grid thumbnails: one reply per valid name, never for a path that leaves the folder.
        b.handle(["op": "thumbs", "root": "r1", "path": ["Projects"], "names": ["readme.txt", "../escape", "..", "escape"], "req": 71], inputGranted: false)
        wait({ all().filter { ($0["op"] as? String) == "thumb" } }, for: 2)
        let thumbs = all().filter { ($0["op"] as? String) == "thumb" }
        XCTAssertEqual(thumbs.compactMap { $0["name"] as? String }, ["readme.txt", "escape"])
        XCTAssertEqual(thumbs.last?["ok"] as? Bool, false, "the escaping symlink gets nothing")
        lock.lock(); sent.removeAll { ($0["op"] as? String) == "thumb" }; lock.unlock()

        // Search finds by name below the folder, never inside ~/Library.
        b.handle(["op": "search", "root": "r1", "path": [], "q": "keychain", "req": 8], inputGranted: false)
        b.handle(["op": "search", "root": "r1", "path": [], "q": "readme", "req": 9], inputGranted: false)
        wait(all, for: 9)
        let last = all().last { ($0["op"] as? String) == "search" }
        XCTAssertEqual(last?["q"] as? String, "readme", "an older search is dropped")
        XCTAssertEqual((last?["entries"] as? [[String: Any]])?.compactMap { $0["name"] as? String }, ["readme.txt"], "\(String(describing: last))")
        XCTAssertEqual((last?["entries"] as? [[String: Any]])?.first?["in"] as? [String], ["Projects"])
    }

    func testTurningItOffRefusesTheNextRequest() {
        let lock = NSLock()
        var sent: [[String: Any]] = []
        let b = browser { m in lock.lock(); sent.append(m); lock.unlock() }
        func all() -> [[String: Any]] { lock.lock(); defer { lock.unlock() }; return sent }
        var enabled = true
        b.isEnabled = { enabled }
        b.handle(["op": "state"], inputGranted: false)
        b.consentDecided(true)
        wait(all, for: 2)
        enabled = false
        b.handle(["op": "list", "root": "r1", "path": [], "req": 1], inputGranted: true)
        wait(all, for: 3)
        XCTAssertEqual(all()[2]["error"] as? String, "off")
        b.stop()
        enabled = true
        b.handle(["op": "list", "root": "r1", "path": [], "req": 2], inputGranted: true)
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(all().count, 3, "a stopped session answers nothing")
    }
}

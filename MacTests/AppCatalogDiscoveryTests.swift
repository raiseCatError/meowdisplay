import XCTest

/// Where the Mac's app list looks and what it keeps: external drives' Applications folders,
/// links to apps, drives that go away, same-named apps, and where an app opens from. Volumes
/// are made up; links and bundles are tiny ones in a scratch folder (no external drive needed).
final class AppCatalogDiscoveryTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/someone")
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("AppCatalogDiscoveryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    // MARK: Search folders

    func testExternalDrivesApplicationsFolderIsSearchedButNotTheWholeDrive() {
        let volumes = [
            AppCatalogVolume(path: "/Volumes/Games SSD", isLocal: true, isBrowsable: true),     // App Store installs here
            AppCatalogVolume(path: "/Volumes/Photos", isLocal: true, isBrowsable: true),        // no Applications folder
            AppCatalogVolume(path: "/Volumes/NAS", isLocal: false, isBrowsable: true),          // network share: never
            AppCatalogVolume(path: "/Volumes/Hidden", isLocal: true, isBrowsable: false),
            AppCatalogVolume(path: "/", isLocal: true, isBrowsable: true),                      // the startup disk
            AppCatalogVolume(path: "/Volumes/Installer", isLocal: true, isBrowsable: true),     // its Applications links to /Applications
        ]
        let existing: [String: String] = [
            "/Applications": "/Applications",
            "/Volumes/Games SSD/Applications": "/Volumes/Games SSD/Applications",
            "/Volumes/NAS/Applications": "/Volumes/NAS/Applications",
            "/Volumes/Hidden/Applications": "/Volumes/Hidden/Applications",
            "/Volumes/Installer/Applications": "/Applications",
        ]
        let folders = AppCatalog.searchFolders(home: home, volumes: volumes) { url in
            existing[url.path].map(URL.init(fileURLWithPath:))
        }.map(\.path)

        XCTAssertEqual(Array(folders.prefix(5)), AppCatalog.standardFolders + ["/Users/someone/Applications"], "the usual folders, ~/Applications too")
        XCTAssertEqual(Array(folders.dropFirst(5)), ["/Volumes/Games SSD/Applications"],
                       "only a local drive's own top-level Applications folder; never a network share, a hidden volume or a link back to /Applications")
        XCTAssertFalse(folders.contains("/Volumes/Games SSD"), "the drive itself is never searched")
        XCTAssertEqual(AppCatalog.externalFolders(folders.map(URL.init(fileURLWithPath:))).map(\.path), ["/Volumes/Games SSD/Applications"],
                       "listed as well as searched, in case Spotlight doesn't index the drive")
    }

    func testFoldersFollowTheDrivesThatAreMounted() {
        let drive = AppCatalogVolume(path: "/Volumes/Work", isLocal: true, isBrowsable: true)
        let exists: (URL) -> URL? = { $0.path == "/Volumes/Work/Applications" ? $0 : nil }
        XCTAssertTrue(AppCatalog.searchFolders(home: home, volumes: [drive], directory: exists).map(\.path).contains("/Volumes/Work/Applications"))
        XCTAssertFalse(AppCatalog.searchFolders(home: home, volumes: [], directory: exists).map(\.path).contains("/Volumes/Work/Applications"),
                       "unplugged: no longer searched")
    }

    // MARK: Unmounted drives

    func testAnUnpluggedDrivesAppsLeaveTheListWithoutTouchingIt() {
        let entries: [String: AppCatalog.Entry] = [
            "com.example.game": .init(bundleID: "com.example.game", name: "Game", path: "/Volumes/Games SSD/Applications/Game.app"),
            "com.example.tool": .init(bundleID: "com.example.tool", name: "Tool", path: "/Volumes/Work/Applications/Tool.app"),
            "com.apple.Safari": .init(bundleID: "com.apple.Safari", name: "Safari", path: "/Applications/Safari.app"),
            "com.example.home": .init(bundleID: "com.example.home", name: "Home App", path: "/Users/someone/Applications/Home App.app"),
        ]
        let kept = AppCatalog.available(entries, mounted: ["/Volumes/Work"])
        XCTAssertEqual(Set(kept.keys), ["com.example.tool", "com.apple.Safari", "com.example.home"])
        XCTAssertEqual(AppCatalog.volumeRoot(of: "/Volumes/Games SSD/Applications/Game.app"), "/Volumes/Games SSD")
        XCTAssertNil(AppCatalog.volumeRoot(of: "/Applications/Safari.app"))
        XCTAssertNil(AppCatalog.volumeRoot(of: "/Volumes"))
    }

    // MARK: Duplicates

    func testSameAppOnTheMacAndAnExternalDriveIsOneEntryFromTheMac() {
        let found: [AppCatalog.Entry] = [
            .init(bundleID: "com.example.editor", name: "Editor", path: "/Volumes/Work/Applications/Editor.app", lastUsed: Date(timeIntervalSince1970: 9)),
            .init(bundleID: "com.example.editor", name: "Editor", path: "/Applications/Editor.app"),
        ]
        for order in [found, found.reversed()] {
            let merged = AppCatalog.merge(order, ownBundle: nil)
            XCTAssertEqual(merged.count, 1)
            XCTAssertEqual(merged["com.example.editor"]?.path, "/Applications/Editor.app", "the copy that stays when the drive is unplugged")
            XCTAssertEqual(merged["com.example.editor"]?.lastUsed, Date(timeIntervalSince1970: 9))
        }
    }

    func testCopiesOnTwoDrivesPickTheSameOneWhateverOrderSpotlightAnswers() {
        let a = AppCatalog.Entry(bundleID: "com.example.game", name: "Game", path: "/Volumes/B/Applications/Game.app")
        let b = AppCatalog.Entry(bundleID: "com.example.game", name: "Game", path: "/Volumes/A/Applications/Game.app")
        XCTAssertEqual(AppCatalog.merge([a, b], ownBundle: nil), AppCatalog.merge([b, a], ownBundle: nil))
        XCTAssertEqual(AppCatalog.merge([a, b], ownBundle: nil)["com.example.game"]?.path, "/Volumes/A/Applications/Game.app")
    }

    func testTwoDifferentAppsWithTheSameNameBothStayInAFixedOrder() {
        let found: [AppCatalog.Entry] = [
            .init(bundleID: "com.vendor-b.notes", name: "Notes", path: "/Volumes/Work/Applications/Notes.app"),
            .init(bundleID: "com.apple.Notes", name: "Notes", path: "/System/Applications/Notes.app"),
            AppCatalog.finderEntry,
        ]
        let merged = AppCatalog.merge(found, ownBundle: nil)
        XCTAssertEqual(Set(merged.keys), ["com.vendor-b.notes", "com.apple.Notes", AppCatalog.finderBundle], "never merged by name")
        let sorted = AppCatalog.sorted(Array(merged.values)).map(\.bundleID)
        XCTAssertEqual(sorted, [AppCatalog.finderBundle, "com.apple.Notes", "com.vendor-b.notes"])
        XCTAssertEqual(AppCatalog.sorted(Array(merged.values).reversed()).map(\.bundleID), sorted)
    }

    // MARK: Opening

    func testOpensTheListedCopyWhileItIsThere() {
        let url = AppCatalog.openURL(listed: "/Volumes/Work/Applications/Tool.app", running: false, mounted: ["/Volumes/Work"],
                                     exists: { _ in true }, registered: { XCTFail("not asked"); return nil })
        XCTAssertEqual(url?.path, "/Volumes/Work/Applications/Tool.app")
    }

    func testUnpluggedDriveOpensAnotherCopyOrNothing() {
        // Never touches the unplugged drive's paths.
        let exists: (String) -> Bool = { p in
            XCTAssertFalse(p.hasPrefix("/Volumes/Work/"), "looked at an unplugged drive")
            return p == "/Applications/Tool.app"
        }
        XCTAssertEqual(AppCatalog.openURL(listed: "/Volumes/Work/Applications/Tool.app", running: false, mounted: [], exists: exists,
                                          registered: { URL(fileURLWithPath: "/Applications/Tool.app") })?.path,
                       "/Applications/Tool.app", "another copy Launch Services knows")
        XCTAssertNil(AppCatalog.openURL(listed: "/Volumes/Work/Applications/Tool.app", running: false, mounted: [], exists: exists,
                                        registered: { URL(fileURLWithPath: "/Volumes/Work/Applications/Tool.app") }),
                     "Launch Services only knows the unplugged copy: nothing opens")
        XCTAssertNil(AppCatalog.openURL(listed: "/Applications/Deleted.app", running: false, mounted: [], exists: { _ in false },
                                        registered: { nil }), "deleted")
    }

    func testAnAppNeitherListedNorRunningNeverOpens() {
        XCTAssertNil(AppCatalog.openURL(listed: nil, running: false, mounted: [], exists: { _ in true },
                                        registered: { URL(fileURLWithPath: "/Users/someone/Downloads/Anything.app") }))
        XCTAssertEqual(AppCatalog.openURL(listed: nil, running: true, mounted: [], exists: { _ in true },
                                          registered: { URL(fileURLWithPath: "/Users/someone/Downloads/Dev.app") })?.path,
                       "/Users/someone/Downloads/Dev.app", "a running app opens from where it runs")
    }

    // MARK: Links (on disk)

    func testSymlinksAndFinderAliasesToAppsAreFollowed() throws {
        let elsewhere = scratch.appendingPathComponent("Elsewhere", isDirectory: true)
        let folder = scratch.appendingPathComponent("Applications", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let linked = try makeApp("Linked", id: "com.example.linked", in: elsewhere)
        let aliased = try makeApp("Aliased", id: "com.example.aliased", in: elsewhere)
        let direct = try makeApp("Direct", id: "com.example.direct", in: folder)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("Linked.app"), withDestinationURL: linked)
        let alias = folder.appendingPathComponent("Aliased")
        try URL.writeBookmarkData(try aliased.bookmarkData(options: .suitableForBookmarkFile), to: alias)
        // A link into a drive that isn't there, and one to something that isn't an app.
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("Gone.app"),
                                                   withDestinationURL: URL(fileURLWithPath: "/Volumes/NoSuchDrive-\(UUID().uuidString)/Applications/Gone.app"))
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("Docs"), withDestinationURL: elsewhere)

        XCTAssertEqual(AppCatalog.linkedApp(folder.appendingPathComponent("Linked.app")).map(resolved), resolved(linked))
        XCTAssertEqual(AppCatalog.linkedApp(alias).map(resolved), resolved(aliased), "a Finder alias")
        XCTAssertNil(AppCatalog.linkedApp(direct), "an app itself isn't a link")
        XCTAssertNil(AppCatalog.linkedApp(folder.appendingPathComponent("Gone.app")), "a dangling link: skipped, nothing hangs")
        XCTAssertNil(AppCatalog.linkedApp(folder.appendingPathComponent("Docs")), "a link to a folder that isn't an app")

        let viaLinks = AppCatalog.linkedApps(in: [folder])
        XCTAssertEqual(Set(viaLinks.map(\.bundleID)), ["com.example.linked", "com.example.aliased"])
        XCTAssertEqual(viaLinks.first { $0.bundleID == "com.example.linked" }.map { resolved(URL(fileURLWithPath: $0.path)) }, resolved(linked),
                       "listed at the app's own path, so it opens from there")

        let scanned = AppCatalog.merge(AppCatalog.scanFolders([folder]), ownBundle: nil)
        XCTAssertEqual(Set(scanned.keys), ["com.example.linked", "com.example.aliased", "com.example.direct", AppCatalog.finderBundle],
                       "Spotlight off: the folder scan finds the same")
    }

    func testAnAliasWhoseAppWasDeletedIsSkipped() throws {
        let folder = scratch.appendingPathComponent("Applications", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let app = try makeApp("Temporary", id: "com.example.temporary", in: scratch.appendingPathComponent("Elsewhere"))
        let alias = folder.appendingPathComponent("Temporary")
        try URL.writeBookmarkData(try app.bookmarkData(options: .suitableForBookmarkFile), to: alias)
        try FileManager.default.removeItem(at: app)
        XCTAssertNil(AppCatalog.linkedApp(alias))
        XCTAssertTrue(AppCatalog.linkedApps(in: [folder]).isEmpty)
    }

    func testABundleWithoutAnIdentifierIsNotAnApp() throws {
        let app = scratch.appendingPathComponent("NoID.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        XCTAssertNil(AppCatalog.entry(app: app))
    }

    // MARK: Helpers

    private func makeApp(_ name: String, id: String, in folder: URL) throws -> URL {
        let app = folder.appendingPathComponent("\(name).app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": id, "CFBundleName": name, "CFBundlePackageType": "APPL"]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        return app
    }

    private func resolved(_ url: URL) -> String { url.resolvingSymlinksInPath().standardizedFileURL.path }
}

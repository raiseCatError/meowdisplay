import CoreGraphics
import XCTest

final class WindowBrowserServiceTests: XCTestCase {
    func testTrackpadWindowRecordOnlyContainsIdentityAndText() {
        let window = WindowCatalogEntry(
            windowID: 14, generation: 3, pid: 620, bundleID: "com.example.editor",
            appName: "Editor", title: "Notes",
            frame: CGRect(x: 15, y: 100, width: 640, height: 480),
            availability: .offscreen, isActive: true, inStageStrip: true)
        XCTAssertEqual(Set(window.trackpadWire.keys), ["id", "gen", "bundle", "app", "title"])
        XCTAssertEqual(window.trackpadWire["id"] as? Int, 14)
        XCTAssertEqual(window.trackpadWire["gen"] as? Int, 3)
        XCTAssertEqual(window.trackpadWire["bundle"] as? String, "com.example.editor")
        XCTAssertEqual(window.trackpadWire["app"] as? String, "Editor")
        XCTAssertEqual(window.trackpadWire["title"] as? String, "Notes")
    }

    func testLatestRequestGoesFirstAndOlderPendingIdsAreNotDropped() {
        var s = ThumbnailScheduler()
        let gens: [UInt32: UInt64] = [1: 1, 2: 1, 3: 1, 30: 1]
        _ = s.enqueue([1, 2, 3], generations: gens, width: 320, now: 0)
        XCTAssertEqual(s.next(), 1)
        // A new request while a batch runs is merged, never dropped; window 30 (late in a long list) isn't starved.
        _ = s.enqueue([30, 2], generations: gens, width: 320, now: 0.1)
        XCTAssertEqual(s.pending, [30, 2, 3])
    }

    func testFreshCachedStillsAreAnsweredWithoutCapturing() {
        var s = ThumbnailScheduler()
        let gens: [UInt32: UInt64] = [7: 4]
        s.stored(7, generation: 4, width: 640, at: 10)
        XCTAssertEqual(s.enqueue([7], generations: gens, width: 320, now: 11), [7])
        XCTAssertTrue(s.pending.isEmpty)
        // Too old, too small or another window identity: capture again.
        XCTAssertEqual(s.enqueue([7], generations: gens, width: 320, now: 10 + ThumbnailScheduler.freshFor + 1), [])
        var t = ThumbnailScheduler()
        t.stored(7, generation: 3, width: 640, at: 10)
        XCTAssertEqual(t.enqueue([7], generations: gens, width: 320, now: 11), [])
        XCTAssertEqual(t.pending, [7])
    }

    func testAppCatalogDeduplicatesByBundleAndPrefersApplicationsFolder() {
        let found = [
            AppCatalog.Entry(bundleID: "com.google.Chrome", name: "Chrome copy", path: "/Users/x/Applications/Google Chrome.app", lastUsed: Date(timeIntervalSince1970: 5)),
            AppCatalog.Entry(bundleID: "com.google.Chrome", name: "Google Chrome", path: "/Applications/Google Chrome.app", lastUsed: nil),
            AppCatalog.Entry(bundleID: "dev.zed.Zed", name: "Zed", path: "/Applications/Zed.app", lastUsed: nil),
            AppCatalog.Entry(bundleID: "com.helper", name: "Helper", path: "/Applications/Big.app/Contents/Helpers/Helper.app", lastUsed: nil),
            AppCatalog.Entry(bundleID: "me.own", name: "MeowDisplay", path: "/Applications/MeowDisplay.app", lastUsed: nil),
            AppCatalog.finderEntry,
        ]
        let merged = AppCatalog.merge(found, ownBundle: "me.own")
        XCTAssertEqual(Set(merged.keys), ["com.google.Chrome", "dev.zed.Zed", "com.apple.finder"])
        XCTAssertEqual(merged["com.google.Chrome"]?.path, "/Applications/Google Chrome.app")
        XCTAssertEqual(merged["com.google.Chrome"]?.lastUsed, Date(timeIntervalSince1970: 5), "keeps the last-used date")
        XCTAssertEqual(AppCatalog.sorted(Array(merged.values)).first?.bundleID, AppCatalog.finderBundle, "Finder first")
    }
}

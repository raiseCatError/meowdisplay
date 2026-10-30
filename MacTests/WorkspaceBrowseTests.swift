import XCTest

/// Stage Peek search and still scheduling (Shared/WorkspaceBrowse.swift). The
/// vectors are shared with the Android port.
final class WorkspaceBrowseTests: XCTestCase {
    private struct Vectors: Decodable {
        struct App: Decodable { var bundle: String; var name: String; var running: Bool?; var windows: Int? }
        struct Window: Decodable { var id: UInt32; var bundle: String; var app: String; var title: String }
        struct Case: Decodable { var q: String; var apps: [String]; var windows: [UInt32] }
        var apps: [App]; var windows: [Window]; var cases: [Case]
    }

    private func vectors() throws -> Vectors {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/workspace/search-vectors.json")
        return try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
    }

    func testSearchVectorsRankAppsAndWindows() throws {
        let v = try vectors()
        let apps = v.apps.map { MacAppItem(bundleID: $0.bundle, name: $0.name, running: $0.running ?? false, windowCount: $0.windows ?? 0, lastUsed: nil) }
        let windows = v.windows.map { CatalogWindowItem(id: $0.id, generation: 1, bundleID: $0.bundle, app: $0.app, title: $0.title,
                                                        width: 800, height: 600, minimized: false, active: false) }
        for c in v.cases {
            let r = WorkspaceSearch.search(c.q, apps: apps, windows: windows)
            XCTAssertEqual(r.apps.map(\.bundleID), c.apps, "apps for \(c.q)")
            XCTAssertEqual(r.windows.map(\.id), c.windows, "windows for \(c.q)")
        }
    }

    func testInstalledAppsWithoutWindowsAreFoundAndFinderLeadsTheCarousel() {
        let apps = [MacAppItem(bundleID: "b.zed", name: "Zed", running: true, windowCount: 1, lastUsed: nil),
                    MacAppItem(bundleID: "a.notes", name: "Notes", running: false, windowCount: 0, lastUsed: nil),
                    MacAppItem(bundleID: MacAppItem.finderBundle, name: "Finder", running: true, windowCount: 0, lastUsed: nil)]
        XCTAssertEqual(WorkspaceSearch.carouselOrder(apps).map(\.name), ["Finder", "Zed", "Notes"])
        XCTAssertEqual(WorkspaceSearch.search("not", apps: apps, windows: []).apps.map(\.name), ["Notes"], "not running, no windows, still found")
    }

    func testStillPlannerAsksVisibleCardsFirstAndBacksOffFailures() {
        var p = ThumbnailRequestPlanner()
        let all = (1...40).map(UInt32.init)
        XCTAssertEqual(p.plan(priority: [35, 36], all: all, now: 0).prefix(3), [35, 36, 1])
        // Asked a moment ago: not again yet; the next batch moves on (no starvation past #24).
        let second = p.plan(priority: [35], all: all, now: 1)
        XCTAssertFalse(second.contains(35))
        XCTAssertTrue(second.contains(40))
        p.failed(2, now: 1)
        XCTAssertFalse(p.plan(priority: [2], all: [2], now: 5).contains(2), "failures back off")
        XCTAssertEqual(p.plan(priority: [2], all: [2], now: 1 + ThumbnailRequestPlanner.failureBackoff + 0.1), [2])
        p.received(3, now: 10)
        XCTAssertEqual(p.plan(priority: [3], all: [3], now: 12), [])
        XCTAssertEqual(p.plan(priority: [3], all: [3], now: 10 + ThumbnailRequestPlanner.refreshAfter + 0.1), [3])
    }
}

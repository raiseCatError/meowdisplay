import CoreGraphics
import Foundation
import XCTest

/// Pure-logic coverage for the arrangement map's layout (Shared/DisplayArrangementLayout.swift)
/// and the catalog plumbing behind it: arrangement data on parsed catalog items and the
/// display-thumbnail request filter.
final class DisplayArrangementLayoutTests: XCTestCase {
    private typealias Layout = DisplayArrangementLayout

    private func display(_ id: UInt32, _ x: Double, _ y: Double, _ w: Double = 1000, _ h: Double = 600,
                         main: Bool = false, own: Bool = false, meow: Bool = false,
                         mirrorOf: UInt32? = nil) -> OverviewDisplay {
        OverviewDisplay(id: id, frame: CGRect(x: x, y: y, width: w, height: h), isMain: main,
                        isMeow: meow, isOwn: own, mirrorOf: mirrorOf)
    }

    private func model(_ displays: [OverviewDisplay]) -> DisplayOverviewModel {
        DisplayOverviewModel(displays: displays)
    }

    private func tile(_ id: UInt32, in tiles: [Layout.Tile]) throws -> Layout.Tile {
        try XCTUnwrap(tiles.first { $0.id == id }, "no tile for display \(id)")
    }

    private let size = CGSize(width: 320, height: 200)

    // MARK: Arrangements

    func testSideBySideDisplaysShareARowAndKeepTheirOrder() throws {
        let tiles = Layout.tiles(for: model([display(1, 0, 0, main: true), display(2, 1000, 0)]), in: size)
        XCTAssertEqual(tiles.map(\.id), [1, 2])
        let a = tiles[0].rect, b = tiles[1].rect
        XCTAssertEqual(a.minY, b.minY, accuracy: 1e-6)
        XCTAssertEqual(a.maxX, b.minX, accuracy: 1e-6, "touching displays touch")
        XCTAssertEqual(a.width, b.width, accuracy: 1e-6)
    }

    func testStaggeredDisplaysKeepTheirVerticalOffset() throws {
        // Display 2 is 300 pt lower than display 1.
        let tiles = Layout.tiles(for: model([display(1, 0, 0), display(2, 1000, 300)]), in: size)
        let a = try tile(1, in: tiles).rect, b = try tile(2, in: tiles).rect
        let scale = a.width / 1000
        XCTAssertEqual(b.minY - a.minY, 300 * scale, accuracy: 1e-6)
        XCTAssertEqual(b.minX - a.minX, 1000 * scale, accuracy: 1e-6)
    }

    func testVerticalStackReadsTopToBottom() throws {
        let tiles = Layout.tiles(for: model([display(1, 0, 600), display(2, 0, 0)]), in: size)
        XCTAssertEqual(tiles.map(\.id), [2, 1], "reading order, top first")
        XCTAssertEqual(tiles[0].rect.maxY, tiles[1].rect.minY, accuracy: 1e-6)
        XCTAssertEqual(tiles[0].rect.minX, tiles[1].rect.minX, accuracy: 1e-6)
    }

    func testNegativeOriginsLayOutLikePositiveOnes() throws {
        let shifted = Layout.tiles(for: model([display(1, -1000, -300), display(2, 0, 0)]), in: size)
        let plain = Layout.tiles(for: model([display(1, 0, 300), display(2, 1000, 600)]), in: size)
        XCTAssertEqual(shifted.count, plain.count)
        for (s, p) in zip(shifted, plain) {
            XCTAssertEqual(s.id, p.id)
            XCTAssertEqual(s.rect.minX, p.rect.minX, accuracy: 1e-6)
            XCTAssertEqual(s.rect.minY, p.rect.minY, accuracy: 1e-6)
            XCTAssertEqual(s.rect.width, p.rect.width, accuracy: 1e-6)
            XCTAssertEqual(s.rect.height, p.rect.height, accuracy: 1e-6)
        }
    }

    // MARK: Geometry

    func testTilesStayInsideTheSizeInsetByTheMargin() {
        let margin = CGFloat(8)
        let layouts = [
            model([display(1, 0, 0), display(2, 1000, 0)]),
            model([display(1, -2000, 500, 2560, 1440), display(2, 0, 0, 1512, 982), display(3, 1512, -900, 1080, 1920)]),
            model([display(1, 0, 0), display(2, 0, 600)]),
        ]
        for m in layouts {
            for s in [CGSize(width: 320, height: 200), CGSize(width: 120, height: 260), CGSize(width: 700, height: 120)] {
                let inner = CGRect(origin: .zero, size: s).insetBy(dx: margin, dy: margin)
                for t in Layout.tiles(for: m, in: s, margin: margin) {
                    XCTAssertGreaterThanOrEqual(t.rect.minX, inner.minX - 1e-6)
                    XCTAssertGreaterThanOrEqual(t.rect.minY, inner.minY - 1e-6)
                    XCTAssertLessThanOrEqual(t.rect.maxX, inner.maxX + 1e-6)
                    XCTAssertLessThanOrEqual(t.rect.maxY, inner.maxY + 1e-6)
                }
            }
        }
    }

    func testTheArrangementIsCenteredInTheView() {
        let tiles = Layout.tiles(for: model([display(1, 0, 0), display(2, 1000, 0)]), in: size)
        let union = tiles.dropFirst().reduce(tiles[0].rect) { $0.union($1.rect) }
        XCTAssertEqual(union.midX, size.width / 2, accuracy: 1e-6)
        XCTAssertEqual(union.midY, size.height / 2, accuracy: 1e-6)
    }

    func testProportionsArePreservedExactly() throws {
        let tiles = Layout.tiles(for: model([display(1, 0, 0, 2560, 1440), display(2, 2560, 200, 1512, 982)]), in: size)
        let a = try tile(1, in: tiles).rect, b = try tile(2, in: tiles).rect
        XCTAssertEqual(a.width / b.width, CGFloat(2560) / CGFloat(1512), accuracy: 1e-6)
        XCTAssertEqual(a.height / b.height, CGFloat(1440) / CGFloat(982), accuracy: 1e-6)
        XCTAssertEqual(a.width / a.height, CGFloat(2560) / CGFloat(1440), accuracy: 1e-6)
    }

    func testGapsArePreservedProportionally() throws {
        // A 400 pt gap between the two displays, next to a 1000 pt wide one.
        let tiles = Layout.tiles(for: model([display(1, 0, 0), display(2, 1400, 0)]), in: size)
        let a = try tile(1, in: tiles).rect, b = try tile(2, in: tiles).rect
        XCTAssertEqual((b.minX - a.maxX) / a.width, CGFloat(0.4), accuracy: 1e-6)
    }

    func testLayoutIsUniformlyScaledForAnyViewShape() throws {
        let m = model([display(1, 0, 0), display(2, 1000, 300)])
        for s in [CGSize(width: 320, height: 200), CGSize(width: 200, height: 320)] {
            let rect = try tile(1, in: Layout.tiles(for: m, in: s)).rect
            XCTAssertEqual(rect.width / 1000, rect.height / 600, accuracy: 1e-6)
        }
    }

    // MARK: Mirror groups and placeholders

    func testMirrorGroupIsDrawnOnceWithItsCount() throws {
        let m = model([display(1, 0, 0, main: true), display(2, 0, 0, mirrorOf: 1), display(3, 0, 0, mirrorOf: 1),
                       display(4, 1000, 0)])
        let tiles = Layout.tiles(for: m, in: size)
        XCTAssertEqual(tiles.map(\.id), [1, 4])
        XCTAssertEqual(try tile(1, in: tiles).mirrorCount, 3)
        XCTAssertEqual(try tile(4, in: tiles).mirrorCount, 1)
    }

    func testPlaceholderKinds() throws {
        let m = model([display(1, 0, 0, main: true), display(2, 1000, 0, own: true), display(3, 2000, 0, meow: true)])
        let tiles = Layout.tiles(for: m, in: size)
        XCTAssertEqual(try tile(1, in: tiles).kind, .display)
        XCTAssertEqual(try tile(2, in: tiles).kind, .thisDevice)
        XCTAssertEqual(try tile(3, in: tiles).kind, .otherMeow)
        XCTAssertTrue(try tile(1, in: tiles).isMain)
        XCTAssertFalse(try tile(2, in: tiles).isMain)
    }

    func testReadingOrderIsTopToBottomThenLeftToRight() {
        let m = model([display(1, 1000, 600), display(2, 0, 600), display(3, 1000, 0), display(4, 0, 0)])
        XCTAssertEqual(Layout.tiles(for: m, in: size).map(\.id), m.drawnDisplays.map(\.id))
        XCTAssertEqual(Layout.tiles(for: m, in: size).map(\.id), [4, 3, 2, 1])
    }

    // MARK: Degenerate input and height

    func testEmptyModelAndUnusableSizesYieldNoTiles() {
        XCTAssertEqual(Layout.tiles(for: model([]), in: size), [])
        let m = model([display(1, 0, 0)])
        XCTAssertEqual(Layout.tiles(for: m, in: .zero), [])
        XCTAssertEqual(Layout.tiles(for: m, in: CGSize(width: 100, height: -1)), [])
    }

    func testAMarginLargerThanTheViewStillProducesInsideTiles() {
        let s = CGSize(width: 30, height: 20)
        for t in Layout.tiles(for: model([display(1, 0, 0), display(2, 1000, 0)]), in: s, margin: 50) {
            XCTAssertTrue(CGRect(origin: .zero, size: s).insetBy(dx: -1e-6, dy: -1e-6).contains(t.rect))
        }
    }

    func testHeightFollowsTheAspectRatioWithinTheLimits() {
        let wide = model([display(1, 0, 0, 1000, 500), display(2, 1000, 0, 1000, 500)])  // 4:1
        XCTAssertEqual(Layout.height(forWidth: 400, model: wide, minimum: 0, maximum: 1000, margin: 0), 100, accuracy: 1e-6)
        let tall = model([display(1, 0, 0, 1000, 1000), display(2, 0, 1000, 1000, 1000)])  // 1:2
        XCTAssertEqual(Layout.height(forWidth: 400, model: tall, minimum: 0, maximum: 1000, margin: 0), 800, accuracy: 1e-6)
    }

    func testHeightIsClamped() {
        let wide = model([display(1, 0, 0, 1000, 500), display(2, 1000, 0, 1000, 500)])
        XCTAssertEqual(Layout.height(forWidth: 400, model: wide, margin: 0), 120, "default minimum")
        let tall = model([display(1, 0, 0, 1000, 1000), display(2, 0, 1000, 1000, 1000)])
        XCTAssertEqual(Layout.height(forWidth: 400, model: tall, margin: 0), 260, "default maximum")
        XCTAssertEqual(Layout.height(forWidth: 400, model: model([]), minimum: 90), 90, "empty model: the minimum")
    }

    func testHeightLeavesRoomForTheMargin() throws {
        let m = model([display(1, 0, 0, 1000, 500), display(2, 1000, 0, 1000, 500)])
        let width = CGFloat(400)
        let height = Layout.height(forWidth: width, model: m, minimum: 0, maximum: 1000, margin: 8)
        let tiles = Layout.tiles(for: m, in: CGSize(width: width, height: height), margin: 8)
        let union = tiles.dropFirst().reduce(tiles[0].rect) { $0.union($1.rect) }
        XCTAssertEqual(union.minX, 8, accuracy: 1e-6)
        XCTAssertEqual(union.minY, 8, accuracy: 1e-6, "the map fills the height it asked for")
    }

    // MARK: Catalog

    private func parsedDisplays(_ entries: [[String: Any]]) throws -> [CatalogDisplayItem] {
        let event = WorkspaceEvent.parse(type: WireMessage.windowCatalog, [
            "type": WireMessage.windowCatalog, "host": "mac-a", "windows": [], "apps": [], "displays": entries,
        ])
        guard case .catalog(let message)? = event else { throw XCTSkip("not a catalog") }
        return message.displays
    }

    func testParsedCatalogItemCarriesTheArrangementWhenTheMacSentIt() throws {
        let items = try parsedDisplays([["id": 7, "name": "Studio", "w": 2560, "h": 1440, "main": true, "x": -2560, "y": 120,
                                         "scale": 2.0, "meow": false]])
        let overview = try XCTUnwrap(items.first?.overview)
        XCTAssertEqual(overview.id, 7)
        XCTAssertEqual(overview.frame, CGRect(x: -2560, y: 120, width: 2560, height: 1440))
        XCTAssertTrue(overview.hasArrangement)
        XCTAssertTrue(overview.isMain)
        XCTAssertEqual(items.first?.width, 2560, "the existing fields are unchanged")
    }

    func testParsedCatalogItemFromAnOlderMacHasNoArrangement() throws {
        let items = try parsedDisplays([["id": 1, "name": "Built-in", "w": 1512, "h": 982, "main": true],
                                        ["id": 2, "name": "Side", "w": 1920, "h": 1080]])
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].overview?.hasArrangement, false)
        let model = DisplayOverviewModel(catalog: items)
        XCTAssertFalse(model.hasArrangement)
        XCTAssertEqual(model.drawnDisplays.map(\.id), [1, 2])
        XCTAssertEqual(model.display(withID: 2)?.frame.minX, 1512, "the fallback row, left to right")
    }

    func testModelFromCatalogItemsWithoutOverviewUsesTheItemFields() {
        let items = [CatalogDisplayItem(id: 1, name: "Built-in", width: 1512, height: 982, isMain: true, isVirtual: false),
                     CatalogDisplayItem(id: 2, name: "Virtual", width: 1920, height: 1080, isMain: false, isVirtual: true),
                     CatalogDisplayItem(id: 3, name: "Broken", width: 0, height: 0, isMain: false, isVirtual: false)]
        let model = DisplayOverviewModel(catalog: items)
        XCTAssertEqual(model.displays.map(\.id), [1, 2], "an item without a size is dropped")
        XCTAssertFalse(model.hasArrangement)
        XCTAssertEqual(model.display(withID: 1)?.isMain, true)
        XCTAssertEqual(model.display(withID: 2)?.isVirtual, true)
        XCTAssertEqual(model.display(withID: 2)?.frame.size, CGSize(width: 1920, height: 1080))
    }

    func testModelFromParsedCatalogKeepsTheRealArrangement() throws {
        let items = try parsedDisplays([["id": 1, "name": "A", "w": 1000, "h": 600, "main": true, "x": 0, "y": 0],
                                        ["id": 2, "name": "B", "w": 1000, "h": 600, "x": 1000, "y": 0]])
        let model = DisplayOverviewModel(catalog: items)
        XCTAssertTrue(model.hasArrangement)
        XCTAssertEqual(Layout.tiles(for: model, in: size).count, 2)
    }

    // MARK: Thumbnail requests

    func testPlaceholdersAreNeverRequestedAsThumbnails() throws {
        let items = try parsedDisplays([
            ["id": 1, "name": "Built-in", "w": 1512, "h": 982, "main": true, "x": 0, "y": 0],
            ["id": 2, "name": "This iPad", "w": 1180, "h": 820, "virtual": true, "x": 1512, "y": 0, "meow": true, "own": true],
            ["id": 3, "name": "Other", "w": 1180, "h": 820, "virtual": true, "x": 2692, "y": 0, "meow": true],
            ["id": 4, "name": "External", "w": 1920, "h": 1080, "x": 0, "y": 982],
        ])
        XCTAssertEqual(WorkspaceModel.thumbnailDisplayIDs(items), [1, 4])
    }

    func testDisplaysWithoutArrangementDataAreStillRequestedAsThumbnails() {
        let items = [CatalogDisplayItem(id: 5, name: "Old", width: 1440, height: 900, isMain: true, isVirtual: false)]
        XCTAssertEqual(WorkspaceModel.thumbnailDisplayIDs(items), [5])
    }
}

import CoreGraphics
import Foundation
import XCTest

/// Pure-logic coverage for the Multi-Display Overview model: catalog
/// parsing, arrangement bounds, mirror grouping, hit-testing, placeholders
/// and reading-order selection.
final class DisplayOverviewModelTests: XCTestCase {

    /// A catalog entry shaped like `DisplayCatalogEntry.wire`.
    private func entry(_ id: Int, x: Int? = 0, y: Int? = 0, w: Int = 1920, h: Int = 1080,
                       main: Bool = false, virtual: Bool = false,
                       extra: [String: Any] = [:]) -> [String: Any] {
        var out: [String: Any] = ["id": id, "name": "Display \(id)", "w": w, "h": h,
                                  "main": main, "virtual": virtual]
        if let x { out["x"] = x }
        if let y { out["y"] = y }
        for (key, value) in extra { out[key] = value }
        return out
    }

    private func display(_ id: UInt32, _ x: Double, _ y: Double, _ w: Double = 100, _ h: Double = 100,
                         main: Bool = false, own: Bool = false, meow: Bool = false,
                         mirrorOf: UInt32? = nil) -> OverviewDisplay {
        OverviewDisplay(id: id, frame: CGRect(x: x, y: y, width: w, height: h), isMain: main,
                        isMeow: meow, isOwn: own, mirrorOf: mirrorOf)
    }

    // MARK: Parsing

    func testParsesEveryKeyOfAFullEntry() throws {
        let parsed = try XCTUnwrap(OverviewDisplay(wire: entry(
            42, x: 1920, y: 100, w: 2560, h: 1440, main: true, virtual: true,
            extra: ["scale": 2.0, "hz": 120, "mirrorOf": 7, "meow": true, "own": false])))
        XCTAssertEqual(parsed.id, 42)
        XCTAssertEqual(parsed.name, "Display 42")
        XCTAssertEqual(parsed.frame, CGRect(x: 1920, y: 100, width: 2560, height: 1440))
        XCTAssertEqual(parsed.scale, 2.0)
        XCTAssertEqual(parsed.hz, 120)
        XCTAssertTrue(parsed.isMain)
        XCTAssertTrue(parsed.isVirtual)
        XCTAssertTrue(parsed.isMeow)
        XCTAssertFalse(parsed.isOwn)
        XCTAssertEqual(parsed.mirrorOf, 7)
        XCTAssertTrue(parsed.hasArrangement)
    }

    func testParsesNegativeOrigin() throws {
        let parsed = try XCTUnwrap(OverviewDisplay(wire: entry(5, x: -2560, y: -300, w: 2560, h: 1440)))
        XCTAssertEqual(parsed.frame.origin, CGPoint(x: -2560, y: -300))
        XCTAssertTrue(parsed.hasArrangement)
    }

    func testOwnImpliesMeow() throws {
        let parsed = try XCTUnwrap(OverviewDisplay(wire: entry(5, extra: ["own": true])))
        XCTAssertTrue(parsed.isOwn)
        XCTAssertTrue(parsed.isMeow)
    }

    func testAcceptsDoubleAndNSNumberValues() throws {
        let parsed = try XCTUnwrap(OverviewDisplay(wire: [
            "id": NSNumber(value: 9), "w": 1512.0, "h": NSNumber(value: 982),
            "x": -10.5, "y": NSNumber(value: 3), "hz": 60.0,
        ]))
        XCTAssertEqual(parsed.id, 9)
        XCTAssertEqual(parsed.frame, CGRect(x: -10.5, y: 3, width: 1512, height: 982))
        XCTAssertEqual(parsed.hz, 60)
        XCTAssertFalse(parsed.isMain)
        XCTAssertFalse(parsed.isVirtual)
        XCTAssertEqual(parsed.name, "")
    }

    func testInvalidOptionalKeysAreTreatedAsAbsent() throws {
        let parsed = try XCTUnwrap(OverviewDisplay(wire: entry(
            3, extra: ["scale": 0.0, "hz": 0, "mirrorOf": 3])))
        XCTAssertNil(parsed.scale)
        XCTAssertNil(parsed.hz)
        XCTAssertNil(parsed.mirrorOf, "a display cannot mirror itself")

        let negative = try XCTUnwrap(OverviewDisplay(wire: entry(
            3, extra: ["scale": -2.0, "hz": -60, "mirrorOf": -1])))
        XCTAssertNil(negative.scale)
        XCTAssertNil(negative.hz)
        XCTAssertNil(negative.mirrorOf)
    }

    func testLongNameIsTruncated() throws {
        let parsed = try XCTUnwrap(OverviewDisplay(wire: entry(3, extra: ["name": String(repeating: "A", count: 300)])))
        XCTAssertEqual(parsed.name.count, OverviewDisplay.maxNameLength)
    }

    func testMalformedEntriesAreRejected() {
        XCTAssertNil(OverviewDisplay(wire: [:]))
        XCTAssertNil(OverviewDisplay(wire: entry(1, w: 0)), "zero width")
        XCTAssertNil(OverviewDisplay(wire: entry(1, h: 0)), "zero height")
        XCTAssertNil(OverviewDisplay(wire: entry(1, w: -1920)), "negative width")
        XCTAssertNil(OverviewDisplay(wire: entry(1, h: -1)), "negative height")
        XCTAssertNil(OverviewDisplay(wire: entry(1, extra: ["w": Double.nan])), "NaN width")
        XCTAssertNil(OverviewDisplay(wire: entry(1, extra: ["h": Double.infinity])), "infinite height")
        XCTAssertNil(OverviewDisplay(wire: entry(1, extra: ["w": "wide"])), "string width")
        XCTAssertNil(OverviewDisplay(wire: entry(1, extra: ["id": -4])), "negative id")
        XCTAssertNil(OverviewDisplay(wire: entry(1, extra: ["id": 1.5])), "fractional id")
        XCTAssertNil(OverviewDisplay(wire: entry(1, extra: ["id": "7"])), "string id")
        XCTAssertNil(OverviewDisplay(wire: entry(1, extra: ["id": Int(UInt32.max) + 1])), "id beyond UInt32")
        var noID = entry(1)
        noID["id"] = nil
        XCTAssertNil(OverviewDisplay(wire: noID))
    }

    func testNonFiniteOriginIsTreatedAsMissingArrangement() throws {
        let parsed = try XCTUnwrap(OverviewDisplay(wire: entry(1, extra: ["x": Double.nan])))
        XCTAssertFalse(parsed.hasArrangement)
        XCTAssertEqual(parsed.frame.origin, .zero)
    }

    func testModelDropsMalformedAndDuplicateEntries() {
        let model = DisplayOverviewModel(catalog: [
            entry(1, x: 0, y: 0), entry(2, w: 0), entry(1, x: 5000, y: 5000), entry(3, x: 1920, y: 0),
        ])
        XCTAssertEqual(model.displays.map(\.id), [1, 3])
        XCTAssertEqual(model.displays.first?.frame.origin, .zero, "the first of a repeated id wins")
    }

    func testModelCapsAtSixteenDisplays() {
        let catalog = (0 ..< 20).map { entry($0 + 1, x: $0 * 100, y: 0, w: 100, h: 100) }
        let model = DisplayOverviewModel(catalog: catalog)
        XCTAssertEqual(DisplayOverviewModel.maxDisplays, 16)
        XCTAssertEqual(model.displays.count, 16)
        XCTAssertEqual(model.displays.last?.id, 16)
    }

    func testCapCountsOnlyValidEntries() {
        var catalog = (0 ..< 5).map { entry($0 + 1, w: 0) }
        catalog += (0 ..< 16).map { entry($0 + 100, x: $0 * 100, y: 0, w: 100, h: 100) }
        XCTAssertEqual(DisplayOverviewModel(catalog: catalog).displays.count, 16)
    }

    func testCatalogValueHandlesUntypedJSON() {
        let value: Any = [entry(1), "junk", entry(2, x: 1920, y: 0)] as [Any]
        XCTAssertEqual(DisplayOverviewModel(catalogValue: value).displays.map(\.id), [1, 2])
        XCTAssertTrue(DisplayOverviewModel(catalogValue: "nope").displays.isEmpty)
        XCTAssertTrue(DisplayOverviewModel(catalogValue: nil).displays.isEmpty)
    }

    // MARK: Fallback layout

    func testMissingXYFallsBackToLeftToRightRow() {
        let model = DisplayOverviewModel(catalog: [
            entry(1, x: nil, y: nil, w: 1920, h: 1080, main: true),
            entry(2, x: nil, y: nil, w: 1440, h: 900),
            entry(3, x: nil, y: nil, w: 800, h: 600),
        ])
        XCTAssertFalse(model.hasArrangement)
        XCTAssertTrue(model.displays.allSatisfy { !$0.hasArrangement })
        XCTAssertEqual(model.display(withID: 1)?.frame, CGRect(x: 0, y: 0, width: 1920, height: 1080))
        XCTAssertEqual(model.display(withID: 2)?.frame, CGRect(x: 1920, y: 0, width: 1440, height: 900))
        XCTAssertEqual(model.display(withID: 3)?.frame, CGRect(x: 3360, y: 0, width: 800, height: 600))
        XCTAssertEqual(model.arrangementBounds, CGRect(x: 0, y: 0, width: 4160, height: 1080))
    }

    func testFullArrangementReportsHasArrangement() {
        let model = DisplayOverviewModel(catalog: [entry(1), entry(2, x: 1920, y: 0)])
        XCTAssertTrue(model.hasArrangement)
    }

    func testMixedCatalogPlacesUnpositionedEntriesAfterPositionedOnes() {
        let model = DisplayOverviewModel(catalog: [
            entry(1, x: -1920, y: -100, w: 1920, h: 1080),
            entry(2, x: nil, y: nil, w: 1000, h: 600),
        ])
        XCTAssertFalse(model.hasArrangement)
        XCTAssertEqual(model.display(withID: 1)?.frame, CGRect(x: -1920, y: -100, width: 1920, height: 1080))
        XCTAssertEqual(model.display(withID: 2)?.frame, CGRect(x: 0, y: -100, width: 1000, height: 600))
    }

    func testUnpositionedMirrorMemberSharesItsPrimaryOrigin() {
        let model = DisplayOverviewModel(catalog: [
            entry(1, x: nil, y: nil, main: true),
            entry(2, x: nil, y: nil, w: 1280, h: 720, extra: ["mirrorOf": 1]),
            entry(3, x: nil, y: nil, w: 1000, h: 500),
        ])
        XCTAssertEqual(model.display(withID: 2)?.frame.origin, model.display(withID: 1)?.frame.origin)
        XCTAssertEqual(model.display(withID: 3)?.frame.origin, CGPoint(x: 1920, y: 0), "the member takes no row slot")
        XCTAssertEqual(model.arrangementBounds, CGRect(x: 0, y: 0, width: 2920, height: 1080))
    }

    // MARK: Bounds

    func testEmptyModelHasZeroBounds() {
        let model = DisplayOverviewModel(displays: [])
        XCTAssertEqual(model.arrangementBounds, .zero)
        XCTAssertNil(model.selected)
        XCTAssertTrue(model.mirrorGroups.isEmpty)
    }

    func testBoundsOfStaggeredLayoutWithNegativeOrigin() {
        let model = DisplayOverviewModel(catalog: [
            entry(1, x: 0, y: 0, w: 1920, h: 1080, main: true),
            entry(2, x: 1920, y: -300, w: 2560, h: 1440),
            entry(3, x: -1280, y: 200, w: 1280, h: 800),
        ])
        XCTAssertEqual(model.arrangementBounds, CGRect(x: -1280, y: -300, width: 5760, height: 1440))
    }

    func testBoundsOfVerticalLayout() {
        let model = DisplayOverviewModel(catalog: [
            entry(1, x: 0, y: 0, w: 1920, h: 1080, main: true),
            entry(2, x: 0, y: -1440, w: 2560, h: 1440),
            entry(3, x: 320, y: 1080, w: 1280, h: 720),
        ])
        XCTAssertEqual(model.arrangementBounds, CGRect(x: 0, y: -1440, width: 2560, height: 3240))
    }

    func testMirroredDisplaysCountOnceInBounds() {
        let model = DisplayOverviewModel(catalog: [
            entry(1, x: 0, y: 0, w: 1920, h: 1080, main: true),
            // The member reports a larger frame; it must not enlarge the bounds.
            entry(2, x: -500, y: -500, w: 4000, h: 3000, extra: ["mirrorOf": 1]),
            entry(3, x: 1920, y: 0, w: 1920, h: 1080),
        ])
        XCTAssertEqual(model.arrangementBounds, CGRect(x: 0, y: 0, width: 3840, height: 1080))
        XCTAssertEqual(model.displays.count, 3)
        XCTAssertEqual(model.drawnDisplays.map(\.id), [1, 3])
    }

    // MARK: Mirror groups

    func testMirrorGroupIsDrawnAtThePrimaryFrame() {
        let model = DisplayOverviewModel(catalog: [
            entry(1, x: 100, y: 50, w: 1920, h: 1080, main: true),
            entry(2, x: 100, y: 50, w: 1920, h: 1080, extra: ["mirrorOf": 1]),
            entry(4, x: 100, y: 50, w: 1920, h: 1080, extra: ["mirrorOf": 1]),
            entry(3, x: 2020, y: 50),
        ])
        XCTAssertEqual(model.mirrorGroups, [
            OverviewMirrorGroup(primaryID: 1, memberIDs: [2, 4], frame: CGRect(x: 100, y: 50, width: 1920, height: 1080)),
        ])
        XCTAssertEqual(model.drawnID(for: 2), 1)
        XCTAssertEqual(model.drawnID(for: 1), 1)
        XCTAssertEqual(model.drawnID(for: 3), 3)
        XCTAssertNil(model.drawnID(for: 99))
    }

    func testMirrorOfAnUnlistedDisplayStaysStandalone() {
        let model = DisplayOverviewModel(catalog: [
            entry(1, x: 0, y: 0),
            entry(2, x: 1920, y: 0, extra: ["mirrorOf": 99]),
        ])
        XCTAssertTrue(model.mirrorGroups.isEmpty)
        XCTAssertEqual(model.drawnDisplays.count, 2)
    }

    func testMirrorChainResolvesToTheEndOfTheChain() {
        let model = DisplayOverviewModel(catalog: [
            entry(1, x: 0, y: 0),
            entry(2, x: 0, y: 0, extra: ["mirrorOf": 1]),
            entry(3, x: 0, y: 0, extra: ["mirrorOf": 2]),
        ])
        XCTAssertEqual(model.mirrorGroups.count, 1)
        XCTAssertEqual(model.mirrorGroups.first?.primaryID, 1)
        XCTAssertEqual(model.mirrorGroups.first?.memberIDs, [2, 3])
        XCTAssertEqual(model.drawnDisplays.map(\.id), [1])
    }

    func testMirrorCycleDoesNotHangAndPicksOnePrimary() {
        let model = DisplayOverviewModel(catalog: [
            entry(7, x: 0, y: 0, extra: ["mirrorOf": 4]),
            entry(4, x: 0, y: 0, extra: ["mirrorOf": 7]),
        ])
        XCTAssertEqual(model.drawnDisplays.map(\.id), [4])
        XCTAssertEqual(model.mirrorGroups.first?.memberIDs, [7])
    }

    // MARK: Hit testing

    func testHitTestFindsTheDisplayUnderAWorldPoint() {
        let model = DisplayOverviewModel(displays: [
            display(1, 0, 0, 1920, 1080, main: true),
            display(2, -1280, -200, 1280, 800),
        ])
        XCTAssertEqual(model.display(at: CGPoint(x: 960, y: 540))?.id, 1)
        XCTAssertEqual(model.display(at: CGPoint(x: -640, y: 100))?.id, 2, "a negative-origin display")
    }

    func testHitTestInAGapReturnsNil() {
        let model = DisplayOverviewModel(displays: [
            display(1, 0, 0, 100, 100),
            display(2, 200, 0, 100, 100),
            display(3, 200, 300, 100, 100),
        ])
        XCTAssertNil(model.display(at: CGPoint(x: 150, y: 50)), "between side-by-side displays")
        XCTAssertNil(model.display(at: CGPoint(x: 250, y: 200)), "between stacked displays")
        XCTAssertNil(model.display(at: CGPoint(x: -10, y: 50)), "outside the arrangement")
        XCTAssertNil(model.display(at: CGPoint(x: 50, y: 250)), "inside the bounds but on no display")
    }

    func testHitTestOverAMirrorGroupReturnsThePrimary() {
        let model = DisplayOverviewModel(displays: [
            display(1, 0, 0, 100, 100, main: true),
            display(2, 0, 0, 100, 100, mirrorOf: 1),
        ])
        XCTAssertEqual(model.display(at: CGPoint(x: 50, y: 50))?.id, 1)
    }

    // MARK: Placeholders

    func testOwnAndMeowDisplaysArePlaceholders() {
        let model = DisplayOverviewModel(displays: [
            display(1, 0, 0, main: true),
            display(2, 100, 0, own: true),
            display(3, 200, 0, meow: true),
            display(4, 300, 0, mirrorOf: 1, own: true),
        ])
        XCTAssertFalse(model.isPlaceholder(1))
        XCTAssertTrue(model.isPlaceholder(2), "own")
        XCTAssertTrue(model.isPlaceholder(3), "another session's meow display")
        XCTAssertTrue(model.isPlaceholder(4), "a placeholder mirror member")
        XCTAssertFalse(model.isPlaceholder(99), "unknown ids are not placeholders")
    }

    func testPlaceholderFlagsComeFromTheCatalogNotTheName() {
        let model = DisplayOverviewModel(catalog: [
            entry(1, extra: ["name": "MeowDisplay virtual"]),
            entry(2, x: 1920, y: 0, extra: ["meow": true]),
            entry(3, x: 3840, y: 0, extra: ["own": true]),
        ])
        XCTAssertFalse(model.isPlaceholder(1))
        XCTAssertTrue(model.isPlaceholder(2))
        XCTAssertTrue(model.isPlaceholder(3))
    }

    // MARK: Selection

    /// Reading order: top row left to right, then the next row.
    private func gridModel() -> DisplayOverviewModel {
        DisplayOverviewModel(displays: [
            display(1, 1920, 0, 1920, 1080, main: true),
            display(2, 0, 0, 1920, 1080),
            display(3, 0, 1080, 1920, 1080),
            display(4, 1920, 1080, 1920, 1080),
        ])
    }

    func testDrawnDisplaysAreInReadingOrder() {
        XCTAssertEqual(gridModel().drawnDisplays.map(\.id), [2, 1, 3, 4])
    }

    func testReadingOrderUsesOriginYBeforeX() {
        let model = DisplayOverviewModel(displays: [
            display(1, 0, 50),
            display(2, 500, 0),
            display(3, -500, 50),
        ])
        XCTAssertEqual(model.drawnDisplays.map(\.id), [2, 3, 1])
    }

    func testInitialSelectionIsTheMainDisplay() {
        XCTAssertEqual(gridModel().selected, 1)
        let noMain = DisplayOverviewModel(displays: [display(5, 100, 0), display(6, 0, 0)])
        XCTAssertEqual(noMain.selected, 6, "first in reading order when none is main")
    }

    func testSelectNextCyclesInReadingOrderAndWraps() {
        var model = gridModel()
        var visited: [UInt32] = []
        for _ in 0 ..< 4 {
            model.select(.next)
            visited.append(model.selected ?? 0)
        }
        XCTAssertEqual(visited, [3, 4, 2, 1])
    }

    func testSelectPreviousCyclesBackwardAndWraps() {
        var model = gridModel()
        var visited: [UInt32] = []
        for _ in 0 ..< 4 {
            model.select(.previous)
            visited.append(model.selected ?? 0)
        }
        XCTAssertEqual(visited, [2, 4, 3, 1])
    }

    func testSelectionSkipsMirrorMembers() {
        var model = DisplayOverviewModel(displays: [
            display(1, 0, 0, main: true),
            display(2, 0, 0, mirrorOf: 1),
            display(3, 200, 0),
        ])
        model.select(.next)
        XCTAssertEqual(model.selected, 3)
        model.select(.next)
        XCTAssertEqual(model.selected, 1)
    }

    func testSelectByIDMapsMirrorMembersToTheirPrimary() {
        var model = DisplayOverviewModel(displays: [
            display(1, 0, 0, main: true),
            display(2, 0, 0, mirrorOf: 1),
            display(3, 200, 0),
        ])
        XCTAssertTrue(model.select(id: 3))
        XCTAssertEqual(model.selected, 3)
        XCTAssertTrue(model.select(id: 2))
        XCTAssertEqual(model.selected, 1)
        XCTAssertFalse(model.select(id: 99))
        XCTAssertEqual(model.selected, 1, "an unknown id changes nothing")
    }

    func testSelectingInAnEmptyModelIsANoOp() {
        var model = DisplayOverviewModel(displays: [])
        model.select(.next)
        model.select(.previous)
        XCTAssertNil(model.selected)
    }

    func testSingleDisplayStaysSelectedWhenCycling() {
        var model = DisplayOverviewModel(displays: [display(1, 0, 0, main: true)])
        model.select(.next)
        XCTAssertEqual(model.selected, 1)
        model.select(.previous)
        XCTAssertEqual(model.selected, 1)
    }
}

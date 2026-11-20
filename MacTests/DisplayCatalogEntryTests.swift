import CoreGraphics
import XCTest

final class DisplayCatalogEntryTests: XCTestCase {
    private func entry(id: UInt32 = 7, frame: CGRect = CGRect(x: 0, y: 0, width: 1512, height: 982), pixelWidth: Int = 3024,
                       hz: Double = 120, mirrorOf: UInt32? = nil,
                       meow: Set<UInt32> = [], own: Set<UInt32> = []) -> DisplayCatalogEntry {
        DisplayCatalogEntry.make(id: id, name: "Studio", frame: frame, isMain: true, isVirtual: false, pixelWidth: pixelWidth,
                                 refreshHz: hz, mirrorOf: mirrorOf, meowIDs: meow, ownIDs: own)
    }

    func testExistingKeysAreUnchanged() {
        let wire = entry().wire
        XCTAssertEqual(wire["id"] as? Int, 7)
        XCTAssertEqual(wire["name"] as? String, "Studio")
        XCTAssertEqual(wire["w"] as? Int, 1512)
        XCTAssertEqual(wire["h"] as? Int, 982)
        XCTAssertEqual(wire["main"] as? Bool, true)
        XCTAssertEqual(wire["virtual"] as? Bool, false)
        XCTAssertEqual(wire["scale"] as? Double, 2.0)
        XCTAssertEqual(wire["hz"] as? Int, 120)
    }

    func testNegativeOriginIsPreserved() {
        let wire = entry(frame: CGRect(x: -1920, y: -200, width: 1920, height: 1080)).wire
        XCTAssertEqual(wire["x"] as? Int, -1920)
        XCTAssertEqual(wire["y"] as? Int, -200)
    }

    func testScaleAndHzOmittedWhenUnknown() {
        let wire = entry(pixelWidth: 0, hz: 0).wire
        XCTAssertNil(wire["scale"])
        XCTAssertNil(wire["hz"])
    }

    func testOwnImpliesMeow() {
        let own = entry(own: [7])
        XCTAssertEqual(own.wire["own"] as? Bool, true)
        XCTAssertEqual(own.wire["meow"] as? Bool, true)
        let other = entry(meow: [7])
        XCTAssertEqual(other.wire["own"] as? Bool, false)
        XCTAssertEqual(other.wire["meow"] as? Bool, true)
        let plain = entry()
        XCTAssertEqual(plain.wire["own"] as? Bool, false)
        XCTAssertEqual(plain.wire["meow"] as? Bool, false)
    }

    func testMirrorOfOnlyWhenPresent() {
        XCTAssertNil(entry().wire["mirrorOf"])
        XCTAssertEqual(entry(mirrorOf: 3).wire["mirrorOf"] as? Int, 3)
    }
}

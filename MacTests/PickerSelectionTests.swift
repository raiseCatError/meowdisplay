import XCTest

final class PickerSelectionTests: XCTestCase {
    private let paired = ["08F232E6-947F-44B2-BA39-DC0D3DAAE1F7", "B1"]

    func testPresentSelectionIsKept() {
        XCTAssertEqual(PickerSelection.valid("B1", among: paired, fallback: ""), "B1")
    }

    func testMissingSelectionShowsTheFallbackTag() {
        XCTAssertEqual(PickerSelection.valid("forgotten", among: paired, fallback: ""), "")
        XCTAssertEqual(PickerSelection.valid("08F232E6-947F-44B2-BA39-DC0D3DAAE1F7", among: [], fallback: ""), "",
                       "options still loading")
    }

    func testFallbackItselfIsValid() {
        XCTAssertEqual(PickerSelection.valid("", among: paired, fallback: ""), "")
    }

    func testRememberedSelectionReappearsWithItsOption() {
        let stored = "08F232E6-947F-44B2-BA39-DC0D3DAAE1F7"
        XCTAssertEqual(PickerSelection.valid(stored, among: ["B1"], fallback: ""), "")
        XCTAssertEqual(PickerSelection.valid(stored, among: paired, fallback: ""), stored)
    }
}

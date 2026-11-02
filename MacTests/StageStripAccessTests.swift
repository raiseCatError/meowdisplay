import XCTest

final class StageStripAccessTests: XCTestCase {
    func testTargetsOnlyTheOneStripItemHoldingTheWindow() {
        XCTAssertEqual(try StageStripAccess.target(windowID: 17007, groups: [[21720, 21578], [17005, 17008, 17007]]).get(), 1)
        XCTAssertEqual(StageStripAccess.target(windowID: 5, groups: [[1], [2, 3]]), .failure(.init(result: .notInStrip)), "never a guess by position")
        XCTAssertEqual(StageStripAccess.target(windowID: 2, groups: [[2], [2]]), .failure(.init(result: .ambiguous)))
        XCTAssertEqual(StageStripAccess.target(windowID: 2, groups: []), .failure(.init(result: .notInStrip)))
    }
}

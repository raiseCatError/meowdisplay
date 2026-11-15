import XCTest

/// Hidden cursor reports that say where the Mac cursor is on another display.
final class OffDisplayCursorReportsTests: XCTestCase {

    func testLeavingTheDisplayIsAlwaysReported() {
        var r = OffDisplayCursorReports()
        XCTAssertTrue(r.shouldSend(CursorWirePosition(x: 1.2, y: 0.5), at: 0, leaving: true))
        // Even right away and at the same spot, if the receiver was shown the cursor again.
        XCTAssertTrue(r.shouldSend(CursorWirePosition(x: 1.2, y: 0.5), at: 0.001, leaving: true))
    }

    func testMovesElsewhereAreCappedAndOnlyWhenTheyChange() {
        var r = OffDisplayCursorReports()
        XCTAssertTrue(r.shouldSend(CursorWirePosition(x: 1.2, y: 0.5), at: 10, leaving: true))
        XCTAssertFalse(r.shouldSend(CursorWirePosition(x: 1.3, y: 0.5), at: 10.01, leaving: false), "too soon")
        XCTAssertTrue(r.shouldSend(CursorWirePosition(x: 1.3, y: 0.5), at: 10.04, leaving: false))
        XCTAssertFalse(r.shouldSend(CursorWirePosition(x: 1.3, y: 0.5), at: 11, leaving: false), "unchanged")
        // A move held back as too soon is reported by a later poll once the cursor stops there.
        XCTAssertTrue(r.shouldSend(CursorWirePosition(x: 1.4, y: 0.5), at: 12, leaving: false))
        XCTAssertFalse(r.shouldSend(CursorWirePosition(x: 1.41, y: 0.5), at: 12.01, leaving: false), "too soon")
        XCTAssertTrue(r.shouldSend(CursorWirePosition(x: 1.41, y: 0.5), at: 12.04, leaving: false))
    }

    func testResetStartsOver() {
        var r = OffDisplayCursorReports()
        _ = r.shouldSend(CursorWirePosition(x: -0.4, y: 0.2), at: 5, leaving: true)
        r.reset()
        XCTAssertTrue(r.shouldSend(CursorWirePosition(x: -0.4, y: 0.2), at: 5.001, leaving: false))
    }

    func testFieldsCarryThePositionAndReason() {
        XCTAssertEqual(OffDisplayCursorReports.fields(CursorWirePosition(x: -1.25, y: 2.5)),
                       "\"x\":-1.2500,\"y\":2.5000,\"why\":\"display\"")
    }

    // MARK: - Receiver side

    func testOnlyHiddenOffDisplayReportsGiveALocatorPosition() {
        XCTAssertEqual(CursorOffDisplayReport.position(visible: false, why: "display", x: 1.4, y: -0.2),
                       CGPoint(x: 1.4, y: -0.2))
        XCTAssertNil(CursorOffDisplayReport.position(visible: true, why: "display", x: 1.4, y: 0.2),
                     "a visible report is the cursor itself")
        XCTAssertNil(CursorOffDisplayReport.position(visible: false, why: nil, x: 0.5, y: 0.5),
                     "a plain hidden report (older sender, lock policy, Window mode) says nothing")
        XCTAssertNil(CursorOffDisplayReport.position(visible: false, why: "pane", x: 1.4, y: 0.2))
        XCTAssertNil(CursorOffDisplayReport.position(visible: false, why: "display", x: nil, y: 0.2))
        XCTAssertNil(CursorOffDisplayReport.position(visible: false, why: "display", x: .infinity, y: 0.2))
    }

    func testFarAwayPositionsAreBounded() {
        let p = CursorOffDisplayReport.position(visible: false, why: "display", x: -1e12, y: 1e12)
        XCTAssertEqual(p, CGPoint(x: -CursorOffDisplayReport.limit, y: CursorOffDisplayReport.limit))
    }

    func testTheLocatorIsOnForNewAndExistingInstalls() throws {
        XCTAssertTrue(ReceiverControlPreferences().showCursorLocator)
        var saved = ReceiverControlPreferences()
        saved.showCursorLocator = false
        let data = try JSONEncoder().encode(saved)
        XCTAssertFalse(try JSONDecoder().decode(ReceiverControlPreferences.self, from: data).showCursorLocator)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "showCursorLocator")
        let older = try JSONSerialization.data(withJSONObject: object)
        XCTAssertTrue(try JSONDecoder().decode(ReceiverControlPreferences.self, from: older).showCursorLocator)
    }
}

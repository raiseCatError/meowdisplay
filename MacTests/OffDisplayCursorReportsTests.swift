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
        XCTAssertNil(CursorOffDisplayReport.position(visible: false, why: "lock", x: 1.4, y: 0.2))
        XCTAssertNil(CursorOffDisplayReport.position(visible: false, why: "display", x: nil, y: 0.2))
        XCTAssertNil(CursorOffDisplayReport.position(visible: false, why: "display", x: .infinity, y: 0.2))
    }

    func testPaneFieldsCarryTheActivePane() {
        XCTAssertEqual(OffDisplayCursorReports.paneFields(CursorWirePosition(x: 1.0, y: 0.5),
                                                          pane: WorkspaceRect(x: 0.25, y: 0, width: 0.5, height: 1)),
                       "\"x\":1.0000,\"y\":0.5000,\"why\":\"pane\",\"px\":0.2500,\"py\":0.0000,\"pw\":0.5000,\"ph\":1.0000")
    }

    func testADisplayReportHasNoPane() {
        XCTAssertEqual(CursorOffDisplayReport.target(visible: false, why: "display", x: 1.4, y: 0.2),
                       CursorLocatorTarget(point: CGPoint(x: 1.4, y: 0.2), pane: nil))
    }

    func testADisplayReportCarriesTheReentryPointWhenGiven() {
        XCTAssertEqual(OffDisplayCursorReports.fields(CursorWirePosition(x: -1.25, y: 2.5),
                                                      resume: CursorWirePosition(x: 0.123456, y: 0.5)),
                       "\"x\":-1.2500,\"y\":2.5000,\"why\":\"display\",\"rx\":0.1235,\"ry\":0.5000")
        XCTAssertEqual(OffDisplayCursorReports.fields(CursorWirePosition(x: -1.25, y: 2.5), resume: nil),
                       OffDisplayCursorReports.fields(CursorWirePosition(x: -1.25, y: 2.5)),
                       "no injector: the report is the one older senders sent")
    }

    func testOnlyADisplayReportGivesAResumePoint() {
        XCTAssertEqual(CursorOffDisplayReport.target(visible: false, why: "display", x: 1.4, y: 0.2,
                                                     rx: 0.25, ry: 0.75),
                       CursorLocatorTarget(point: CGPoint(x: 1.4, y: 0.2), pane: nil,
                                           resume: CGPoint(x: 0.25, y: 0.75)))
        let pane = CursorOffDisplayReport.target(visible: false, why: "pane", x: 1, y: 0.5,
                                                 px: 0.25, py: 0, pw: 0.5, ph: 1, rx: 0.25, ry: 0.75)
        XCTAssertNotNil(pane)
        XCTAssertNil(pane?.resume, "a pane report never carries one")
        XCTAssertNil(CursorOffDisplayReport.target(visible: true, why: "display", x: 0.5, y: 0.5,
                                                   rx: 0.25, ry: 0.75), "a visible report is no locator at all")
    }

    func testAResumePointIsClampedIntoThePicture() {
        let target = CursorOffDisplayReport.target(visible: false, why: "display", x: 1.4, y: 0.2,
                                                   rx: -3, ry: 9)
        XCTAssertEqual(target?.resume, CGPoint(x: 0, y: 1))
    }

    func testAResumePointNeedsBothFiniteValues() {
        for (rx, ry) in [(Double.nan, 0.5), (0.5, Double.infinity), (0.5, -Double.infinity)] as [(Double, Double)] {
            let target = CursorOffDisplayReport.target(visible: false, why: "display", x: 1.4, y: 0.2,
                                                       rx: rx, ry: ry)
            XCTAssertNotNil(target, "the report still locates the cursor")
            XCTAssertNil(target?.resume)
        }
        let incomplete: [(Double?, Double?)] = [(nil, 0.5), (0.5, nil), (nil, nil)]
        for (rx, ry) in incomplete {
            let target = CursorOffDisplayReport.target(visible: false, why: "display", x: 1.4, y: 0.2,
                                                       rx: rx, ry: ry)
            XCTAssertEqual(target, CursorLocatorTarget(point: CGPoint(x: 1.4, y: 0.2), pane: nil, resume: nil))
        }
    }

    func testAPaneReportNeedsAUsablePane() {
        XCTAssertEqual(CursorOffDisplayReport.target(visible: false, why: "pane", x: 1, y: 0.5,
                                                     px: 0.25, py: 0, pw: 0.5, ph: 1),
                       CursorLocatorTarget(point: CGPoint(x: 1, y: 0.5), pane: CGRect(x: 0.25, y: 0, width: 0.5, height: 1)))
        XCTAssertNil(CursorOffDisplayReport.target(visible: false, why: "pane", x: 1, y: 0.5),
                     "no pane: nothing to point from")
        XCTAssertNil(CursorOffDisplayReport.target(visible: false, why: "pane", x: 1, y: 0.5,
                                                   px: 0.25, py: 0, pw: 0, ph: 1))
        XCTAssertNil(CursorOffDisplayReport.target(visible: false, why: "pane", x: 1, y: 0.5,
                                                   px: 2, py: 2, pw: 0.5, ph: 0.5), "entirely off the canvas")
        XCTAssertNil(CursorOffDisplayReport.target(visible: false, why: "pane", x: 1, y: 0.5,
                                                   px: .nan, py: 0, pw: 0.5, ph: 1))
        XCTAssertEqual(CursorOffDisplayReport.target(visible: false, why: "pane", x: 1, y: 0.5,
                                                     px: -0.5, py: 0, pw: 1, ph: 2)?.pane,
                       CGRect(x: 0, y: 0, width: 0.5, height: 1), "clipped to the canvas")
        XCTAssertNil(CursorOffDisplayReport.target(visible: true, why: "pane", x: 0.5, y: 0.5,
                                                   px: 0, py: 0, pw: 1, ph: 1))
    }

    func testFarAwayPositionsAreBounded() {
        let p = CursorOffDisplayReport.position(visible: false, why: "display", x: -1e12, y: 1e12)
        XCTAssertEqual(p, CGPoint(x: -CursorOffDisplayReport.limit, y: CursorOffDisplayReport.limit))
    }

    func testTheLocatorIsOffByDefaultAndAnOptInRoundTrips() throws {
        XCTAssertFalse(ReceiverControlPreferences().showCursorLocator)
        var saved = ReceiverControlPreferences()
        saved.showCursorLocator = true
        let data = try JSONEncoder().encode(saved)
        XCTAssertTrue(try JSONDecoder().decode(ReceiverControlPreferences.self, from: data).showCursorLocator)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "showCursorLocator")
        let older = try JSONSerialization.data(withJSONObject: object)
        XCTAssertFalse(try JSONDecoder().decode(ReceiverControlPreferences.self, from: older).showCursorLocator)
    }
}

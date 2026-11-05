import XCTest

/// `Mac/CursorWirePosition.swift`: the sender reports a cursor move whenever its four-decimal
/// wire value changes, instead of waiting for a 0.0004 movement threshold.
final class CursorWirePositionTests: XCTestCase {
    func testPositionsThatPrintTheSameAreEqual() {
        XCTAssertEqual(CursorWirePosition(x: 0.12341, y: 0.5), CursorWirePosition(x: 0.123449, y: 0.50004))
    }

    func testOneWireStepIsAChange() {
        // Under the old threshold a move this small was held back until moves added up.
        XCTAssertNotEqual(CursorWirePosition(x: 0.1234, y: 0.5), CursorWirePosition(x: 0.1235, y: 0.5))
        XCTAssertNotEqual(CursorWirePosition(x: 0.5, y: 0.1234), CursorWirePosition(x: 0.5, y: 0.1235))
    }

    func testFieldsCarryTheQuantizedPosition() {
        XCTAssertEqual(CursorWirePosition(x: 0.123456, y: 0.98765).fields, "\"x\":0.1235,\"y\":0.9877")
        XCTAssertEqual(CursorWirePosition(x: 0, y: 1).fields, "\"x\":0.0000,\"y\":1.0000")
    }

    func testFieldsDecodeToTheSamePositionTheSenderCompares() throws {
        let wire = CursorWirePosition(x: 0.73219, y: 0.04001)
        let json = try XCTUnwrap(("{" + wire.fields + "}").data(using: .utf8))
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Double])
        XCTAssertEqual(CursorWirePosition(x: try XCTUnwrap(decoded["x"]), y: try XCTUnwrap(decoded["y"])), wire)
    }

    func testQuantizingTwiceChangesNothing() {
        let wire = CursorWirePosition(x: 0.987654, y: 0.000049)
        XCTAssertEqual(CursorWirePosition(x: wire.x, y: wire.y), wire)
    }

    /// A slow, precise move (0.00003 per 8 ms poll, ~30 pt/s on a 1512 pt display), deduplicated
    /// the way `MacSender.pollCursorPosition` does it: every wire step is reported, and the last
    /// report is exactly where the cursor stopped.
    func testSlowMoveIsReportedAtEveryWireStepAndEndsWhereTheCursorStopped() {
        var lastSent: CursorWirePosition?
        var sent: [CursorWirePosition] = []
        var x = 0.3
        for _ in 0..<100 {
            let wire = CursorWirePosition(x: x, y: 0.5)
            if wire != lastSent {
                sent.append(wire)
                lastSent = wire
            }
            x += 0.00003
        }
        XCTAssertEqual(sent.last, CursorWirePosition(x: x - 0.00003, y: 0.5))
        for (a, b) in zip(sent, sent.dropFirst()) {
            XCTAssertEqual(b.x - a.x, 0.0001, accuracy: 1e-9)
        }
        XCTAssertGreaterThanOrEqual(sent.count, 30, "a 0.0004 threshold would have sent about 8")
    }
}

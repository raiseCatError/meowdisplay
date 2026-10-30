import CoreGraphics
import XCTest

/// `keyboardState` and `textCaret` (PROTOCOL.md 6.11): what the Mac encodes is
/// what a receiver decodes, malformed frames are ignored, and nothing but a
/// rectangle is ever on the wire.
final class TextCaretWireTests: XCTestCase {
    private func roundTrip(_ message: [String: Any]) throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: message)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testTypeNamesAreStable() {
        XCTAssertEqual(WireMessage.textCaret, "textCaret")
        XCTAssertEqual(WireMessage.keyboardState, "keyboardState")
        XCTAssertEqual(TextCaretWire.welcomeFeature, "textCaret")
    }

    func testCaretRoundTrips() throws {
        let rect = CGRect(x: 0.41234, y: 0.5, width: 0.002, height: 0.018)
        let message = try roundTrip(TextCaretWire.message(rect: rect, sequence: 12))
        XCTAssertEqual(message["type"] as? String, "textCaret")
        XCTAssertEqual(message["v"] as? Int, 1)
        XCTAssertEqual(message["s"] as? Int, 12)
        let update = try XCTUnwrap(TextCaretWire.parse(message))
        XCTAssertEqual(update.sequence, 12)
        let decoded = try XCTUnwrap(update.rect)
        XCTAssertEqual(decoded.minX, 0.41234, accuracy: 1e-9)
        XCTAssertEqual(decoded.minY, 0.5, accuracy: 1e-9)
        XCTAssertEqual(decoded.width, 0.002, accuracy: 1e-9)
        XCTAssertEqual(decoded.height, 0.018, accuracy: 1e-9)
    }

    func testNoCaretIsVisibleZeroAndCarriesNoGeometry() throws {
        let message = try roundTrip(TextCaretWire.message(rect: nil, sequence: 3))
        XCTAssertEqual(message["v"] as? Int, 0)
        XCTAssertNil(message["x"])
        XCTAssertNil(message["y"])
        XCTAssertNil(message["w"])
        XCTAssertNil(message["h"])
        let update = try XCTUnwrap(TextCaretWire.parse(message))
        XCTAssertNil(update.rect)
        XCTAssertEqual(update.sequence, 3)
    }

    func testOnlyAGeometryRectangleIsEverSent() {
        let keys = Set(TextCaretWire.message(rect: CGRect(x: 0.1, y: 0.2, width: 0.01, height: 0.02), sequence: 1).keys)
        XCTAssertEqual(keys, ["type", "s", "v", "x", "y", "w", "h"])
    }

    func testANonFiniteCaretIsSentAsNoCaret() {
        let message = TextCaretWire.message(rect: CGRect(x: CGFloat.nan, y: 0.2, width: 0.01, height: 0.02), sequence: 1)
        XCTAssertEqual(message["v"] as? Int, 0)
        XCTAssertEqual(TextCaretWire.message(rect: CGRect(x: 0.1, y: CGFloat.infinity, width: 0, height: 0), sequence: 1)["v"] as? Int, 0)
    }

    func testAnOriginEdgeCaretIsNotMistakenForABoolean() throws {
        // x = 0 and y = 1 are valid normalized positions and also look like JSON booleans to a bridged cast.
        let message = try roundTrip(TextCaretWire.message(rect: CGRect(x: 0, y: 1, width: 0, height: 0), sequence: 1))
        let rect = try XCTUnwrap(TextCaretWire.parse(message)?.rect)
        XCTAssertEqual(rect.minX, 0)
        XCTAssertEqual(rect.minY, 1)
    }

    func testMalformedCaretsAreIgnored() {
        XCTAssertNil(TextCaretWire.parse(["type": "cursor", "v": 1, "x": 0.1, "y": 0.1]))
        XCTAssertNil(TextCaretWire.parse(["type": "textCaret", "v": 1]))
        XCTAssertNil(TextCaretWire.parse(["type": "textCaret", "v": 1, "x": "0.1", "y": 0.2]))
        XCTAssertNil(TextCaretWire.parse(["type": "textCaret", "v": 1, "x": true, "y": 0.2]))
        XCTAssertNil(TextCaretWire.parse(["type": "textCaret", "v": 1, "x": Double.nan, "y": 0.2]))
    }

    func testSizeIsClampedAndOptional() throws {
        let update = try XCTUnwrap(TextCaretWire.parse(["type": "textCaret", "v": 1, "x": 0.5, "y": 0.5, "w": -4, "h": 9]))
        XCTAssertEqual(update.rect?.width, 0)
        XCTAssertEqual(update.rect?.height, 1)
        XCTAssertNil(update.sequence, "an unsequenced frame still decodes")
        let bare = try XCTUnwrap(TextCaretWire.parse(["type": "textCaret", "v": 1, "x": 0.5, "y": 0.25]))
        XCTAssertEqual(bare.rect, CGRect(x: 0.5, y: 0.25, width: 0, height: 0))
    }

    func testKeyboardStateRoundTrips() throws {
        for open in [true, false] {
            let message = try roundTrip(TextCaretWire.keyboardStateMessage(open: open))
            XCTAssertEqual(message["type"] as? String, "keyboardState")
            XCTAssertEqual(TextCaretWire.parseKeyboardState(message), open)
        }
        XCTAssertNil(TextCaretWire.parseKeyboardState(["type": "keyboardState"]))
        XCTAssertNil(TextCaretWire.parseKeyboardState(["type": "keyboardState", "open": "yes"]))
        XCTAssertNil(TextCaretWire.parseKeyboardState(["type": "keyboard", "open": true]))
    }
}

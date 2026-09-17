import XCTest

/// Wire-shape tests for the Mirror capture-source selection protocol
/// (`mirrorDisplayState` / `mirrorDisplayRequest` — see Shared/Protocol.swift).
/// `StreamReceiver`/`MacSender`/`SenderController` aren't in this hostless
/// test target (they pull in AVFoundation/ScreenCaptureKit/AppKit), so the
/// "Mac-originated selection reaches the receiver model" and "receiver-
/// originated selection updates canonical Mac state" round-trips are
/// exercised by the physical retest instead — these tests cover the wire
/// contract both sides actually share.
final class MirrorDisplayWireTests: XCTestCase {

    func testMirrorDisplayWireVersionIsFixedAt13() {
        // Mirror display selection bumped the wire to 13 at its own
        // milestone — superseded as "the current version" by
        // `extendShapeWireVersion` (14) at a later one; see
        // ExtendDisplayShapeTests/ProtocolVersionTests for that canary now.
        XCTAssertEqual(WireProtocol.mirrorDisplayWireVersion, 13)
    }

    // MARK: - Auto / Manual serialization

    func testAutoSerializesWithoutASelectedUUID() {
        let update = MirrorDisplayStateUpdate(selectedUUID: nil, displays: [])
        XCTAssertNil(update.selectedUUID)
    }

    func testManualSerializesWithTheStableUUID() {
        let update = MirrorDisplayStateUpdate(selectedUUID: "uuid-external", displays: [])
        XCTAssertEqual(update.selectedUUID, "uuid-external")
    }

    // MARK: - Decoding what a Mac would actually send

    func testDecodesAutoWithADisplayInventory() {
        let message: [String: Any] = [
            "type": "mirrorDisplayState",
            "displays": [
                ["uuid": "uuid-built-in", "name": "Built-in Retina Display", "isMain": true,
                 "logicalWidth": 1512, "logicalHeight": 982,
                 "pixelWidth": 3024, "pixelHeight": 1964, "likelyVirtual": false],
                ["uuid": "uuid-external", "name": "DELL U2723QE", "isMain": false,
                 "logicalWidth": 2560, "logicalHeight": 1440,
                 "pixelWidth": 2560, "pixelHeight": 1440, "likelyVirtual": false],
            ],
        ]
        guard let update = MirrorDisplayStateUpdate(message: message) else {
            return XCTFail("expected a decoded update")
        }
        XCTAssertNil(update.selectedUUID)
        XCTAssertEqual(update.displays.count, 2)
        XCTAssertEqual(update.displays[0].uuid, "uuid-built-in")
        XCTAssertTrue(update.displays[0].isMain)
        XCTAssertEqual(update.displays[1].name, "DELL U2723QE")
        XCTAssertFalse(update.displays[1].isMain)
    }

    func testDecodesManualSelection() {
        let message: [String: Any] = [
            "type": "mirrorDisplayState",
            "selectedUUID": "uuid-external",
            "displays": [
                ["uuid": "uuid-built-in", "name": "Built-in Retina Display"],
                ["uuid": "uuid-external", "name": "DELL U2723QE"],
            ],
        ]
        guard let update = MirrorDisplayStateUpdate(message: message) else {
            return XCTFail("expected a decoded update")
        }
        XCTAssertEqual(update.selectedUUID, "uuid-external")
    }

    func testSwitchingManualToAutoIsExpressedByDroppingSelectedUUID() {
        let manual = MirrorDisplayStateUpdate(message: [
            "type": "mirrorDisplayState", "selectedUUID": "uuid-external", "displays": [],
        ])
        XCTAssertEqual(manual?.selectedUUID, "uuid-external")

        let auto = MirrorDisplayStateUpdate(message: [
            "type": "mirrorDisplayState", "displays": [],
        ])
        XCTAssertNil(auto?.selectedUUID)
    }

    // MARK: - Selected-but-unavailable display

    func testSelectedUUIDNotInInventoryIsPreservedRatherThanSilentlyDropped() {
        // The receiver UI needs to distinguish "Manual, but the selected
        // display disappeared" from Auto — it must never guess a different
        // Manual display on its own. The wire layer's job is only to not
        // lose that information.
        let update = MirrorDisplayStateUpdate(message: [
            "type": "mirrorDisplayState", "selectedUUID": "uuid-unplugged", "displays": [],
        ])
        XCTAssertEqual(update?.selectedUUID, "uuid-unplugged")
        XCTAssertEqual(update?.displays.isEmpty, true)
    }

    // MARK: - Malformed / forward-compatible input

    func testRejectsWrongMessageType() {
        XCTAssertNil(MirrorDisplayStateUpdate(message: ["type": "displayModeState"]))
    }

    func testEntriesMissingRequiredFieldsAreSkippedNotCrashing() {
        let message: [String: Any] = [
            "type": "mirrorDisplayState",
            "displays": [
                ["uuid": "uuid-ok", "name": "Built-in Retina Display"],
                ["name": "missing uuid"],
                ["uuid": "missing-name"],
                "not-even-a-dictionary",
            ],
        ]
        let update = MirrorDisplayStateUpdate(message: message)
        XCTAssertEqual(update?.displays.count, 1)
        XCTAssertEqual(update?.displays.first?.uuid, "uuid-ok")
    }

    func testUnknownExtraFieldsFromANewerPeerAreTolerated() {
        let message: [String: Any] = [
            "type": "mirrorDisplayState",
            "selectedUUID": "uuid-external",
            "displays": [["uuid": "uuid-external", "name": "DELL U2723QE", "futureField": "??"]],
            "someFutureTopLevelField": 42,
        ]
        guard let update = MirrorDisplayStateUpdate(message: message) else {
            return XCTFail("expected a decoded update despite the unknown fields")
        }
        XCTAssertEqual(update.selectedUUID, "uuid-external")
        XCTAssertEqual(update.displays.first?.name, "DELL U2723QE")
    }

    func testMissingOptionalGeometryFieldsDefaultToZeroRatherThanFailingDecode() {
        let entry = MirrorDisplayEntry(entry: ["uuid": "uuid-x", "name": "Some Display"])
        XCTAssertEqual(entry?.logicalWidth, 0)
        XCTAssertEqual(entry?.pixelWidth, 0)
        XCTAssertEqual(entry?.isMain, false)
        XCTAssertEqual(entry?.likelyVirtual, false)
    }
}

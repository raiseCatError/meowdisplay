import XCTest

/// `ReceiverUIPreferenceUpdate` decodes the Mac -> receiver `receiverUI`
/// push (see `MacSender.setReceiverControlOverrides`) and applies it onto a
/// receiver's `ReceiverControlPreferences`. Every field is additive/
/// optional, matching the original `trayEnabled`/`keyboardButtonEnabled`
/// pair exactly — a message naming only one field must never disturb any
/// other stored preference, and defaults must survive when a field is
/// absent entirely.
final class ReceiverUIPreferenceUpdateTests: XCTestCase {
    func testDecodesOnlyTheFieldsPresentInTheMessage() {
        let update = ReceiverUIPreferenceUpdate(message: [
            "type": WireMessage.receiverUI,
            "hapticsEnabled": false,
        ])
        XCTAssertEqual(update?.hapticsEnabled, false)
        XCTAssertNil(update?.trayEnabled)
        XCTAssertNil(update?.inputMode)
        XCTAssertNil(update?.trackpadSensitivity)
    }

    func testWrongMessageTypeDecodesToNil() {
        XCTAssertNil(ReceiverUIPreferenceUpdate(message: ["type": "somethingElse", "hapticsEnabled": false]))
    }

    func testEmptyKnownFieldsDecodesToNil() {
        XCTAssertNil(ReceiverUIPreferenceUpdate(message: ["type": WireMessage.receiverUI]))
    }

    func testInputModeDecodesFromItsRawValue() {
        let update = ReceiverUIPreferenceUpdate(message: [
            "type": WireMessage.receiverUI,
            "inputMode": "trackpad",
        ])
        XCTAssertEqual(update?.inputMode, .trackpad)
    }

    func testUnknownInputModeRawValueIsIgnoredNotCrashing() {
        let update = ReceiverUIPreferenceUpdate(message: [
            "type": WireMessage.receiverUI,
            "inputMode": "not-a-real-mode",
        ])
        XCTAssertNil(update?.inputMode)
    }

    func testApplyOnlyTouchesFieldsThePayloadNamed() {
        var preferences = ReceiverControlPreferences()
        preferences.hapticsEnabled = true
        preferences.avoidNotch = true
        let update = ReceiverUIPreferenceUpdate(message: [
            "type": WireMessage.receiverUI,
            "hapticsEnabled": false,
        ])!

        update.apply(to: &preferences)

        XCTAssertEqual(preferences.hapticsEnabled, false)
        XCTAssertEqual(preferences.avoidNotch, true, "a field the message never named must be left untouched")
    }

    func testApplyClampsTrackpadSensitivityToItsSupportedRange() {
        var preferences = ReceiverControlPreferences()
        let update = ReceiverUIPreferenceUpdate(message: [
            "type": WireMessage.receiverUI,
            "trackpadSensitivity": 99.0,
        ])!

        update.apply(to: &preferences)

        XCTAssertEqual(preferences.trackpadSensitivity, PointerGestureConfig.trackpadSensitivityRange.upperBound)
    }

    func testDefaultsSurviveWhenAFieldIsNeverSent() {
        let fresh = ReceiverControlPreferences()
        var preferences = fresh
        let update = ReceiverUIPreferenceUpdate(message: [
            "type": WireMessage.receiverUI,
            "trayEnabled": false,
        ])!

        update.apply(to: &preferences)

        XCTAssertEqual(preferences.functionTrayEnabled, fresh.functionTrayEnabled)
        XCTAssertEqual(preferences.inputMode, fresh.inputMode)
        XCTAssertEqual(preferences.avSyncOffsetMs, fresh.avSyncOffsetMs)
    }
}

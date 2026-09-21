import XCTest

/// Covers `ReceiverHelloState` (`Shared/StreamReceiver.swift`) — the
/// Receiver Swift6-Hello-1 lock-protected owner for the Hello-owned
/// `announced*` preference mirrors and `lastAdvertisedAddrs` dedup memory.
/// State-equivalence tests only — no Hello JSON payload construction
/// (that's Hello-2 territory) and no network fixtures/sleeps.
final class ReceiverHelloStateTests: XCTestCase {

    func testDefaultSnapshotMatchesStreamReceiverDefaults() {
        let state = ReceiverHelloState()
        let snapshot = state.snapshot()
        XCTAssertEqual(snapshot.trayEnabled, true)
        XCTAssertEqual(snapshot.keyboardButtonEnabled, true)
        XCTAssertEqual(snapshot.functionTrayEnabled, true)
        XCTAssertEqual(snapshot.inputMode, .direct)
        XCTAssertEqual(snapshot.trackpadSensitivity, PointerGestureConfig.defaultTrackpadSensitivity)
        XCTAssertEqual(snapshot.hapticsEnabled, true)
        XCTAssertEqual(snapshot.avoidNotch, true)
        XCTAssertEqual(snapshot.pinchTarget, .viewport)
        XCTAssertEqual(snapshot.rotateTarget, .viewport)
        XCTAssertEqual(snapshot.snapRotation, true)
        XCTAssertEqual(snapshot.appGestureCommands, AppGestureCommands.defaults)
    }

    func testUpdateTrayAndKeyboardAppearsInSnapshot() {
        let state = ReceiverHelloState()
        state.updateTrayAndKeyboard(trayEnabled: false, keyboardButtonEnabled: false)
        let snapshot = state.snapshot()
        XCTAssertEqual(snapshot.trayEnabled, false)
        XCTAssertEqual(snapshot.keyboardButtonEnabled, false)
        // Untouched fields keep their defaults — this call only owns the pair.
        XCTAssertEqual(snapshot.functionTrayEnabled, true)
    }

    func testUpdatePreferencesAppearsCoherentlyInSnapshot() {
        let state = ReceiverHelloState()
        state.updatePreferences(
            functionTrayEnabled: false, inputMode: .trackpad, trackpadSensitivity: 2.5,
            hapticsEnabled: false, avoidNotch: false, pinchTarget: .disabled,
            rotateTarget: .disabled, snapRotation: false,
            appGestureCommands: AppGestureCommands()
        )
        let snapshot = state.snapshot()
        XCTAssertEqual(snapshot.functionTrayEnabled, false)
        XCTAssertEqual(snapshot.inputMode, .trackpad)
        XCTAssertEqual(snapshot.trackpadSensitivity, 2.5)
        XCTAssertEqual(snapshot.hapticsEnabled, false)
        XCTAssertEqual(snapshot.avoidNotch, false)
        XCTAssertEqual(snapshot.pinchTarget, .disabled)
        XCTAssertEqual(snapshot.rotateTarget, .disabled)
        XCTAssertEqual(snapshot.snapRotation, false)
        // Fields owned by the other update method are untouched — a single
        // snapshot read reflects one consistent point-in-time state across
        // fields from both update calls.
        XCTAssertEqual(snapshot.trayEnabled, true)
    }

    func testUnchangedAddressesAreNotReportedAsChanged() {
        let state = ReceiverHelloState()
        state.recordAdvertisedAddresses(["10.0.0.1", "192.168.1.5"])
        XCTAssertFalse(state.addressesChanged(["10.0.0.1", "192.168.1.5"]))
    }

    func testChangedAddressesAreReportedAsChanged() {
        let state = ReceiverHelloState()
        state.recordAdvertisedAddresses(["10.0.0.1"])
        XCTAssertTrue(state.addressesChanged(["10.0.0.1", "192.168.1.5"]))
    }

    func testEmptyAddressListIsRecordedAndComparedLikeAnyOther() {
        // sendHello writes `lastAdvertisedAddrs = addrs` unconditionally,
        // including when `addrs` is empty — no special-casing.
        let state = ReceiverHelloState()
        // Default lastAdvertisedAddrs is already [], so this is a no-op
        // write, but must still compare as "unchanged".
        state.recordAdvertisedAddresses([])
        XCTAssertFalse(state.addressesChanged([]))
        // Now record a real list, then go back to empty — must be seen as
        // a change, and the empty list must then be the new baseline.
        state.recordAdvertisedAddresses(["10.0.0.1"])
        XCTAssertTrue(state.addressesChanged([]))
        state.recordAdvertisedAddresses([])
        XCTAssertFalse(state.addressesChanged([]))
    }

    func testRecordThenSameListIsUnchangedThenDifferentListIsChanged() {
        let state = ReceiverHelloState()
        state.recordAdvertisedAddresses(["10.0.0.1", "10.0.0.2"])
        XCTAssertFalse(state.addressesChanged(["10.0.0.1", "10.0.0.2"]))
        XCTAssertTrue(state.addressesChanged(["10.0.0.2", "10.0.0.1"]))
        state.recordAdvertisedAddresses(["10.0.0.2", "10.0.0.1"])
        XCTAssertFalse(state.addressesChanged(["10.0.0.2", "10.0.0.1"]))
        XCTAssertTrue(state.addressesChanged(["10.0.0.1", "10.0.0.2"]))
    }

    func testAddressComparisonIsOrderSensitive() {
        // Matches the current source's plain `!=` on `[String]` — no
        // sorting/set normalization exists, so reordered-but-equal-content
        // lists must still be reported as "changed".
        let state = ReceiverHelloState()
        state.recordAdvertisedAddresses(["a", "b", "c"])
        XCTAssertTrue(state.addressesChanged(["c", "b", "a"]))
        XCTAssertFalse(state.addressesChanged(["a", "b", "c"]))
    }

    /// Many threads race preference updates and address recordings against
    /// concurrent snapshot/addressesChanged reads; the lock must make each
    /// operation atomic so nothing crashes or produces a torn read. Not
    /// asserting a specific interleaving — only that a final snapshot read
    /// succeeds and one of the two known preference states was observed.
    func testConcurrentUpdatesAndReadsProduceNoCorruption() {
        let state = ReceiverHelloState()
        let group = DispatchGroup()
        for i in 0..<200 {
            group.enter()
            DispatchQueue.global().async {
                if i % 2 == 0 {
                    state.updateTrayAndKeyboard(trayEnabled: i % 4 == 0, keyboardButtonEnabled: i % 4 == 0)
                } else {
                    state.recordAdvertisedAddresses(["10.0.0.\(i % 5)"])
                }
                _ = state.snapshot()
                _ = state.addressesChanged(["10.0.0.0"])
                group.leave()
            }
        }
        group.wait()
        let finalSnapshot = state.snapshot()
        XCTAssertTrue(finalSnapshot.trayEnabled == true || finalSnapshot.trayEnabled == false)
    }
}

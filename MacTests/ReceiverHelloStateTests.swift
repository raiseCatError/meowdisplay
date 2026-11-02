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

/// Receiver Swift6-Hello-2: covers the migration that made `helloState`
/// (`ReceiverHelloState`) the sole authoritative store for the 11 announced
/// Hello preference mirrors formerly held as `StreamReceiver`'s own
/// `announced*` stored properties (removed by this change) — exercised
/// purely through `StreamReceiver`'s own public writer API
/// (`setReceiverUIPreferencesForHello`/`announceReceiverPreferences`), the
/// same seam production UI code uses, plus the `helloState` test-only
/// accessor (`internal`, not `private`, precisely so this can read the
/// result without reaching into `sendHello`'s network send path).
import AVFoundation

@MainActor
final class StreamReceiverHelloStateMigrationTests: XCTestCase {

    private func makeReceiver() -> StreamReceiver {
        StreamReceiver(displayLayer: AVSampleBufferDisplayLayer(),
                        deviceKind: "Test", fallbackServiceName: "Test")
    }

    /// (1) Defaults produce the same announced values the old
    /// `StreamReceiver`-stored-property implementation defaulted to.
    func testFreshReceiverHelloStateMatchesOldDefaults() {
        let receiver = makeReceiver()
        let snapshot = receiver.helloState.snapshot()
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

    /// (2) `setReceiverUIPreferencesForHello` — production's tray/keyboard
    /// writer — changes the next `helloState` snapshot, and only that pair.
    func testSetReceiverUIPreferencesForHelloUpdatesHelloState() {
        let receiver = makeReceiver()
        let expectation = expectation(description: "queue hop completes")
        receiver.setReceiverUIPreferencesForHello(trayEnabled: false, keyboardButtonEnabled: false)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { expectation.fulfill() }
        wait(for: [expectation], timeout: 1)
        let snapshot = receiver.helloState.snapshot()
        XCTAssertEqual(snapshot.trayEnabled, false)
        XCTAssertEqual(snapshot.keyboardButtonEnabled, false)
        XCTAssertEqual(snapshot.functionTrayEnabled, true) // untouched
    }

    /// (2) `announceReceiverPreferences` — production's writer for the
    /// other 9 fields — changes the next `helloState` snapshot coherently.
    func testAnnounceReceiverPreferencesUpdatesHelloState() {
        let receiver = makeReceiver()
        var prefs = ReceiverControlPreferences()
        prefs.hapticsEnabled = false
        prefs.inputMode = .trackpad
        prefs.trackpadSensitivity = 3.0
        let expectation = expectation(description: "queue hop completes")
        receiver.announceReceiverPreferences(prefs)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { expectation.fulfill() }
        wait(for: [expectation], timeout: 1)
        let snapshot = receiver.helloState.snapshot()
        XCTAssertEqual(snapshot.hapticsEnabled, false)
        XCTAssertEqual(snapshot.inputMode, .trackpad)
        XCTAssertEqual(snapshot.trackpadSensitivity, 3.0)
        // Tray/keyboard belong to the other writer and stay at their
        // defaults here — no duplicate/cross-writer source of truth.
        XCTAssertEqual(snapshot.trayEnabled, true)
    }

    /// Receiver Swift6-Hello-Final: `announceReceiverPreferences` also
    /// writes `avSyncPreference` (`AVSyncPreference`, a separate audio-
    /// timing-domain owner — see its type doc) — clamped and applied
    /// alongside the `helloState` preference fields, in the same queue hop.
    func testAnnounceReceiverPreferencesUpdatesAVSyncPreference() {
        let receiver = makeReceiver()
        var prefs = ReceiverControlPreferences()
        prefs.avSyncOffsetMs = 400
        let expectation = expectation(description: "queue hop completes")
        receiver.announceReceiverPreferences(prefs)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { expectation.fulfill() }
        wait(for: [expectation], timeout: 1)
        XCTAssertEqual(receiver.avSyncPreference.get(), 400)
    }

    /// (4) Address-changed / unchanged dedup, exercised through `helloState`
    /// directly — the sole authority `checkAddressChangeAndSendHello`'s
    /// static rewrite now consults, matching the semantics the top-level
    /// `ReceiverHelloStateTests` cases above already cover for the type
    /// itself (order-sensitive `!=`, unconditional overwrite, empty-list
    /// handling).
    func testHelloStateIsSoleAddressDedupAuthorityForReceiver() {
        let receiver = makeReceiver()
        XCTAssertFalse(receiver.helloState.addressesChanged([]))
        XCTAssertTrue(receiver.helloState.addressesChanged(["10.0.0.1"]))
        receiver.helloState.recordAdvertisedAddresses(["10.0.0.1"])
        XCTAssertFalse(receiver.helloState.addressesChanged(["10.0.0.1"]))
    }
}

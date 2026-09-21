import Network
import XCTest

/// Covers the three narrow lock-protected owners introduced to eliminate the
/// StreamReceiver strict-Swift-6 diagnostics on `startTLSListener`'s
/// `newConnectionHandler`/`stateUpdateHandler(.failed)` and
/// `makePipelineHostEffects`'s `ensureTLSListening` (`Shared/StreamReceiver.swift`):
/// `TLSListenerState`, `PairingSuppressionState`, `ReceiverAdvertisementState`.
/// State-equivalence tests only — no real listening sockets, no sleeps.
final class ReceiverTLSListenerOwnershipTests: XCTestCase {

    /// A cheap, never-started `NWListener` — enough to exercise reference
    /// identity without opening a real socket.
    private func makeListener() -> NWListener {
        try! NWListener(using: .tcp)
    }

    // MARK: - TLSListenerState

    func testTLSListenerStateEmptyInitially() {
        let state = TLSListenerState()
        XCTAssertFalse(state.hasCurrent())
        XCTAssertNil(state.currentListener())
    }

    func testTLSListenerStateInstallMakesItCurrent() {
        let state = TLSListenerState()
        let listener = makeListener()
        state.install(listener)
        XCTAssertTrue(state.hasCurrent())
        XCTAssertTrue(state.isCurrent(listener))
        XCTAssertTrue(state.currentListener() === listener)
    }

    func testTLSListenerStateDifferentListenerIsStale() {
        let state = TLSListenerState()
        state.install(makeListener())
        let other = makeListener()
        XCTAssertFalse(state.isCurrent(other))
    }

    func testTLSListenerStateClearIfCurrentClearsCurrent() {
        let state = TLSListenerState()
        let listener = makeListener()
        state.install(listener)
        XCTAssertTrue(state.clearIfCurrent(listener))
        XCTAssertFalse(state.hasCurrent())
        XCTAssertNil(state.currentListener())
    }

    func testTLSListenerStateClearIfCurrentLeavesNewerListenerUntouched() {
        let state = TLSListenerState()
        let stale = makeListener()
        state.install(stale)
        let fresh = makeListener()
        state.install(fresh)
        // A late `.failed` callback for the superseded `stale` listener must
        // not clear the newer `fresh` one.
        XCTAssertFalse(state.clearIfCurrent(stale))
        XCTAssertTrue(state.hasCurrent())
        XCTAssertTrue(state.isCurrent(fresh))
    }

    func testTLSListenerStateCancelCurrentClearsReference() {
        let state = TLSListenerState()
        state.install(makeListener())
        state.cancelCurrent()
        XCTAssertFalse(state.hasCurrent())
    }

    // MARK: - PairingSuppressionState

    func testPairingSuppressionStateDefaultsFalse() {
        XCTAssertFalse(PairingSuppressionState().isSuppressed())
    }

    func testPairingSuppressionStateSetTrue() {
        let state = PairingSuppressionState()
        state.setSuppressed(true)
        XCTAssertTrue(state.isSuppressed())
    }

    func testPairingSuppressionStateSetFalseAfterTrue() {
        let state = PairingSuppressionState()
        state.setSuppressed(true)
        state.setSuppressed(false)
        XCTAssertFalse(state.isSuppressed())
    }

    // MARK: - ReceiverAdvertisementState

    func testAdvertisementStateDefaultServiceName() {
        let state = ReceiverAdvertisementState(serviceName: "MeowDisplay")
        XCTAssertEqual(state.currentServiceName(), "MeowDisplay")
    }

    func testAdvertisementStateRenameReflectedInSnapshotAndServices() {
        let state = ReceiverAdvertisementState(serviceName: "MeowDisplay")
        XCTAssertTrue(state.setServiceName("Jai's Mac"))
        XCTAssertEqual(state.currentServiceName(), "Jai's Mac")
        XCTAssertEqual(state.mediaService(installID: "id-1", protocolVersion: 3).name, "Jai's Mac")
        XCTAssertEqual(
            state.pairingService(installID: "id-1", protocolVersion: 3, pairingProtocolVersion: 1).name,
            "Jai's Mac")
    }

    func testAdvertisementStateSetServiceNameNoOpWhenUnchanged() {
        let state = ReceiverAdvertisementState(serviceName: "MeowDisplay")
        XCTAssertFalse(state.setServiceName("MeowDisplay"))
    }

    func testAdvertisementStateMediaServiceTXTFieldsExact() {
        let state = ReceiverAdvertisementState(serviceName: "MeowDisplay")
        let service = state.mediaService(installID: "install-abc", protocolVersion: 7)
        XCTAssertEqual(service.type, "_opensidecar._tcp")
        XCTAssertNil(service.domain)
        XCTAssertEqual(service.txtRecordObject?["id"], "install-abc")
        XCTAssertEqual(service.txtRecordObject?["pv"], "7")
        XCTAssertNil(service.txtRecordObject?["cr"])
        XCTAssertNil(service.txtRecordObject?["pp"])
    }

    func testAdvertisementStatePairingServiceTXTFieldsExactAndNeverIncludesCR() {
        let state = ReceiverAdvertisementState(serviceName: "MeowDisplay")
        _ = state.beginConnectRequest()
        let service = state.pairingService(installID: "install-abc", protocolVersion: 7, pairingProtocolVersion: 13)
        XCTAssertEqual(service.type, "_opendisplay-pair._tcp")
        XCTAssertNil(service.domain)
        XCTAssertEqual(service.txtRecordObject?["id"], "install-abc")
        XCTAssertEqual(service.txtRecordObject?["pv"], "7")
        XCTAssertEqual(service.txtRecordObject?["pp"], "13")
        // The pairing service must never advertise the receiver-Connect token.
        XCTAssertNil(service.txtRecordObject?["cr"])
    }

    func testAdvertisementStateMediaServiceIncludesCRWhenTokenSet() {
        let state = ReceiverAdvertisementState(serviceName: "MeowDisplay")
        let token = state.beginConnectRequest()
        let service = state.mediaService(installID: "install-abc", protocolVersion: 7)
        XCTAssertEqual(service.txtRecordObject?["cr"], token)
    }

    func testAdvertisementStateReplacingTokenInvalidatesOldTokenClear() {
        let state = ReceiverAdvertisementState(serviceName: "MeowDisplay")
        let first = state.beginConnectRequest()
        _ = state.beginConnectRequest()
        // A stale clear for the superseded first token must not clear the
        // newer one.
        XCTAssertFalse(state.clearConnectRequestIfCurrent(first))
        XCTAssertNotNil(state.mediaService(installID: "id", protocolVersion: 1).txtRecordObject?["cr"])
    }

    func testAdvertisementStateValidClearRemovesToken() {
        let state = ReceiverAdvertisementState(serviceName: "MeowDisplay")
        let token = state.beginConnectRequest()
        XCTAssertTrue(state.clearConnectRequestIfCurrent(token))
        XCTAssertNil(state.mediaService(installID: "id", protocolVersion: 1).txtRecordObject?["cr"])
    }

    func testAdvertisementStateLatestSnapshotReflectsLatestNameAndToken() {
        let state = ReceiverAdvertisementState(serviceName: "MeowDisplay")
        _ = state.setServiceName("Renamed")
        let token = state.beginConnectRequest()
        let service = state.mediaService(installID: "id", protocolVersion: 1)
        XCTAssertEqual(service.name, "Renamed")
        XCTAssertEqual(service.txtRecordObject?["cr"], token)
    }
}

import Network
import XCTest

/// Covers `PairingListenerState`, the narrow lock-protected owner introduced
/// to eliminate the StreamReceiver strict-Swift-6 diagnostic on
/// `startPairingListener`'s `newConnectionHandler`
/// (`Shared/StreamReceiver.swift`). State-equivalence tests only — no real
/// listening sockets, no sleeps. Mirrors `ReceiverTLSListenerOwnershipTests`'s
/// coverage of the identically-shaped `TLSListenerState`.
final class ReceiverPairingListenerOwnershipTests: XCTestCase {

    /// A cheap, never-started `NWListener` — enough to exercise reference
    /// identity without opening a real socket.
    private func makeListener() -> NWListener {
        try! NWListener(using: .tcp)
    }

    func testPairingListenerStateEmptyInitially() {
        let state = PairingListenerState()
        XCTAssertFalse(state.hasCurrent())
        XCTAssertNil(state.currentListener())
    }

    func testPairingListenerStateInstallMakesItCurrent() {
        let state = PairingListenerState()
        let listener = makeListener()
        state.install(listener)
        XCTAssertTrue(state.hasCurrent())
        XCTAssertTrue(state.isCurrent(listener))
        XCTAssertTrue(state.currentListener() === listener)
    }

    func testPairingListenerStateDifferentListenerIsStale() {
        let state = PairingListenerState()
        state.install(makeListener())
        let other = makeListener()
        XCTAssertFalse(state.isCurrent(other))
    }

    func testPairingListenerStateReplacementMakesOldListenerStale() {
        let state = PairingListenerState()
        let old = makeListener()
        state.install(old)
        let fresh = makeListener()
        state.install(fresh)
        XCTAssertFalse(state.isCurrent(old))
        XCTAssertTrue(state.isCurrent(fresh))
        XCTAssertTrue(state.currentListener() === fresh)
    }

    func testPairingListenerStateCancelCurrentClearsReference() {
        let state = PairingListenerState()
        state.install(makeListener())
        state.cancelCurrent()
        XCTAssertFalse(state.hasCurrent())
        XCTAssertNil(state.currentListener())
    }
}

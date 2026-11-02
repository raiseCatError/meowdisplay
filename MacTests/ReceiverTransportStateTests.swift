import XCTest

/// Covers `ReceiverTransportState` (`Shared/StreamReceiver.swift`) — the
/// B2.3 lock-protected owner for the display-only `transport` route label.
final class ReceiverTransportStateTests: XCTestCase {

    func testDefaultsToPlaceholder() {
        let state = ReceiverTransportState()
        XCTAssertEqual(state.get(), "—")
    }

    func testSetReplacesValue() {
        let state = ReceiverTransportState()
        state.set("USB")
        XCTAssertEqual(state.get(), "USB")
        state.set("LAN")
        XCTAssertEqual(state.get(), "LAN")
    }

    func testClearResetsToPlaceholder() {
        let state = ReceiverTransportState()
        state.set("AWDL")
        state.clear()
        XCTAssertEqual(state.get(), "—")
    }

    func testConcurrentSetsNeverProduceATornValue() {
        let state = ReceiverTransportState()
        let labels = ["USB", "AWDL", "LAN", "—"]
        DispatchQueue.concurrentPerform(iterations: 400) { i in
            state.set(labels[i % labels.count])
        }
        XCTAssertTrue(labels.contains(state.get()))
    }
}

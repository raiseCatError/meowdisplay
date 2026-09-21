import XCTest
import AVFoundation

@MainActor
final class ReceiverUISinkTests: XCTestCase {

    /// A headless `AVSampleBufferDisplayLayer` is enough to construct a real
    /// `StreamReceiver` off-screen — same pattern `ReceiverVideoPresenterTests`
    /// already uses for the presenter it owns.
    private func makeReceiver() -> StreamReceiver {
        StreamReceiver(displayLayer: AVSampleBufferDisplayLayer(),
                        deviceKind: "Test", fallbackServiceName: "Test")
    }

    func testPublishStatusWritesTargetStatus() {
        let receiver = makeReceiver()
        let sink = ReceiverUISink()
        sink.target = receiver
        sink.publishStatus("Connected · USB")
        XCTAssertEqual(receiver.status, "Connected · USB")
    }

    func testPublishStatusIsNoOpWithNoTargetAssigned() {
        let sink = ReceiverUISink()
        // Must not crash/trap when nobody has wired `target` yet.
        sink.publishStatus("ignored")
    }

    func testPublishSessionSnapshotWritesTargetSession() {
        let receiver = makeReceiver()
        let sink = ReceiverUISink()
        sink.target = receiver
        let snapshot = ReceiverSessionState()
        sink.publishSessionSnapshot(snapshot)
        XCTAssertEqual(receiver.session, snapshot)
    }

    func testPublishSessionSnapshotIsNoOpWithNoTargetAssigned() {
        let sink = ReceiverUISink()
        sink.publishSessionSnapshot(ReceiverSessionState())
    }

    func testReassigningTargetRedirectsSubsequentPublishes() {
        let firstReceiver = makeReceiver()
        let secondReceiver = makeReceiver()
        let sink = ReceiverUISink()
        sink.target = firstReceiver
        sink.publishStatus("first")
        XCTAssertEqual(firstReceiver.status, "first")
        sink.target = secondReceiver
        sink.publishStatus("second")
        XCTAssertEqual(secondReceiver.status, "second")
        XCTAssertEqual(firstReceiver.status, "first", "must not still be writing into the old target")
    }

    /// Lifetime review: `ReceiverUISink` must hold `target` weakly — it must
    /// never be the reason a `StreamReceiver` stays alive.
    func testTargetIsHeldWeakly() {
        let sink = ReceiverUISink()
        weak var weakReceiver: StreamReceiver?
        autoreleasepool {
            let receiver = makeReceiver()
            weakReceiver = receiver
            sink.target = receiver
            XCTAssertNotNil(weakReceiver)
        }
        XCTAssertNil(weakReceiver, "ReceiverUISink.target must not keep StreamReceiver alive")
    }
}

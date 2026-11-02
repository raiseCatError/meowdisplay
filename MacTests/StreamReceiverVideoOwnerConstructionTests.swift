import XCTest
import AVFoundation

/// Receiver Swift6-B2.2: covers the construction seam that replaced the
/// deferred `[weak self]`-through-`StreamReceiver` sibling lookup between
/// `videoDecoder` (`ReceiverVideoDecoder`) and `presenter`
/// (`ReceiverVideoPresenter`) with an explicit, forced construction order
/// plus an exactly-once binding (`StreamReceiver.VideoDecoderRef`) for the
/// one forward reference (`presenter -> videoDecoder`) that can't be
/// resolved by direct capture. `videoDecoder`/`presenter` are `private`, so
/// this exercises the seam the same way production code does: purely
/// through `StreamReceiver`'s own construction and deinitialization, never
/// by reaching into either owner directly (`ReceiverVideoDecoderTests`/
/// `ReceiverVideoPresenterTests` already cover each actor's own behavior in
/// isolation).
@MainActor
final class StreamReceiverVideoOwnerConstructionTests: XCTestCase {

    private func makeReceiver() -> StreamReceiver {
        StreamReceiver(displayLayer: AVSampleBufferDisplayLayer(),
                        deviceKind: "Test", fallbackServiceName: "Test")
    }

    /// `init` force-touches `presenter` then `videoDecoder` at its tail,
    /// which runs `VideoDecoderRef.bind` exactly once. A double-bind trips
    /// a `precondition` (fatal) — so a plain successful construction here
    /// already proves the exactly-once invariant on the happy path.
    /// Constructing twice, independently, proves there's no shared/static
    /// state between instances that a first receiver's bind could poison
    /// for a second.
    func testConstructionBindsExactlyOnceAndDoesNotCrash() {
        let first = makeReceiver()
        let second = makeReceiver()
        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
    }

    /// No retain cycle: `videoDecoder` captures `presenter` only weakly
    /// (see `StreamReceiver.makeVideoDecoder`'s doc comment for why), so
    /// releasing `StreamReceiver`'s own two strong references
    /// (`videoDecoder`/`presenter`) must let the whole graph deallocate —
    /// nothing in the decoder/presenter cross-wiring should keep either
    /// owner, or the receiver, alive on its own.
    func testReceiverAndOwnersDeallocateTogetherWithNoRetainCycle() {
        weak var weakReceiver: StreamReceiver?
        autoreleasepool {
            let receiver = makeReceiver()
            weakReceiver = receiver
            XCTAssertNotNil(weakReceiver)
        }
        XCTAssertNil(weakReceiver, "StreamReceiver (and its videoDecoder/presenter) leaked — check for a retain cycle in the B2.2 cross-wiring")
    }
}

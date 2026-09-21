import XCTest

/// Covers `ReceiverDisplayGeometryState` (`Shared/StreamReceiver.swift`) —
/// the Receiver Swift6-Geometry-1 lock-protected owner for the announced
/// panel geometry (`devicePixelsWide`/`devicePixelsHigh`/`deviceScale`,
/// removed as `StreamReceiver` stored properties by this change).
/// State-equivalence tests only — no Hello JSON payload construction and no
/// network fixtures/sleeps.
final class ReceiverDisplayGeometryStateTests: XCTestCase {

    func testDefaultSnapshotMatchesOldStreamReceiverDefaults() {
        let state = ReceiverDisplayGeometryState()
        let snapshot = state.snapshot()
        XCTAssertEqual(snapshot.pixelsWide, 0)
        XCTAssertEqual(snapshot.pixelsHigh, 0)
        XCTAssertEqual(snapshot.scale, 2)
    }

    func testUpdateAppliesFullChangeAndReportsDimensionsChanged() {
        let state = ReceiverDisplayGeometryState()
        let result = state.update(pixelsWide: 390, pixelsHigh: 844, scale: 3)
        XCTAssertTrue(result.dimensionsChanged)
        XCTAssertEqual(result.snapshot.pixelsWide, 390)
        XCTAssertEqual(result.snapshot.pixelsHigh, 844)
        XCTAssertEqual(result.snapshot.scale, 3)
        XCTAssertEqual(state.snapshot(), result.snapshot)
    }

    /// Matches `setPanel`'s contract: scale always updates even when the
    /// dimensions guard fails (`w`/`h` unchanged from current).
    func testUpdateWithUnchangedDimensionsStillUpdatesScaleButReportsNoChange() {
        let state = ReceiverDisplayGeometryState()
        _ = state.update(pixelsWide: 100, pixelsHigh: 200, scale: 1)
        let result = state.update(pixelsWide: 100, pixelsHigh: 200, scale: 2.5)
        XCTAssertFalse(result.dimensionsChanged)
        XCTAssertEqual(result.snapshot.pixelsWide, 100)
        XCTAssertEqual(result.snapshot.pixelsHigh, 200)
        XCTAssertEqual(result.snapshot.scale, 2.5)
    }

    /// Matches `setPanel`'s guard: non-positive width/height never applies,
    /// but scale still updates.
    func testUpdateWithNonPositiveDimensionsIsRejectedButScaleStillUpdates() {
        let state = ReceiverDisplayGeometryState()
        _ = state.update(pixelsWide: 100, pixelsHigh: 200, scale: 1)
        let result = state.update(pixelsWide: 0, pixelsHigh: 500, scale: 4)
        XCTAssertFalse(result.dimensionsChanged)
        XCTAssertEqual(result.snapshot.pixelsWide, 100)
        XCTAssertEqual(result.snapshot.pixelsHigh, 200)
        XCTAssertEqual(result.snapshot.scale, 4)
    }

    func testSeedNativePanelIfUnsetSetsDimensionsWhenUnset() {
        let state = ReceiverDisplayGeometryState()
        let snapshot = state.seedNativePanelIfUnset(pixelsWide: 1920, pixelsHigh: 1080, scale: 2)
        XCTAssertEqual(snapshot.pixelsWide, 1920)
        XCTAssertEqual(snapshot.pixelsHigh, 1080)
        XCTAssertEqual(snapshot.scale, 2)
    }

    /// Matches `setNativePanel`'s exact contract: a second native-panel
    /// report never replaces already-initialized dimensions.
    func testSecondSeedNativePanelDoesNotReplaceInitializedDimensions() {
        let state = ReceiverDisplayGeometryState()
        _ = state.seedNativePanelIfUnset(pixelsWide: 1920, pixelsHigh: 1080, scale: 2)
        let snapshot = state.seedNativePanelIfUnset(pixelsWide: 800, pixelsHigh: 600, scale: 2)
        XCTAssertEqual(snapshot.pixelsWide, 1920)
        XCTAssertEqual(snapshot.pixelsHigh, 1080)
    }

    /// ... but scale updates on every call, seeded or not.
    func testSecondSeedNativePanelStillUpdatesScale() {
        let state = ReceiverDisplayGeometryState()
        _ = state.seedNativePanelIfUnset(pixelsWide: 1920, pixelsHigh: 1080, scale: 2)
        let snapshot = state.seedNativePanelIfUnset(pixelsWide: 800, pixelsHigh: 600, scale: 3)
        XCTAssertEqual(snapshot.scale, 3)
    }

    /// Orientation swap goes through `update` with pre-swapped values —
    /// the state owner just needs to store the coherent result.
    func testOrientationDerivedSwappedDimensionsAreStoredCorrectly() {
        let state = ReceiverDisplayGeometryState()
        _ = state.update(pixelsWide: 1920, pixelsHigh: 1080, scale: 2)
        let result = state.update(pixelsWide: 1080, pixelsHigh: 1920, scale: 2)
        XCTAssertTrue(result.dimensionsChanged)
        XCTAssertEqual(state.snapshot().pixelsWide, 1080)
        XCTAssertEqual(state.snapshot().pixelsHigh, 1920)
    }

    func testSnapshotReturnsCoherentTriple() {
        let state = ReceiverDisplayGeometryState()
        _ = state.update(pixelsWide: 300, pixelsHigh: 400, scale: 2)
        let snapshot = state.snapshot()
        XCTAssertEqual(snapshot, ReceiverDisplayGeometryState.Snapshot(
            pixelsWide: 300, pixelsHigh: 400, scale: 2))
    }

    /// Many threads race `update`/`seedNativePanelIfUnset` against
    /// concurrent `snapshot` reads; the lock must make each operation
    /// atomic so every observed snapshot is one complete, known-valid
    /// triple — never a mix of fields from two different writes.
    func testConcurrentUpdateAndSnapshotNeverObservesTornTriple() {
        let state = ReceiverDisplayGeometryState()
        let knownTriples: Set<ReceiverDisplayGeometryState.Snapshot> = [
            ReceiverDisplayGeometryState.Snapshot(pixelsWide: 0, pixelsHigh: 0, scale: 2), // initial default
            ReceiverDisplayGeometryState.Snapshot(pixelsWide: 100, pixelsHigh: 200, scale: 1),
            ReceiverDisplayGeometryState.Snapshot(pixelsWide: 300, pixelsHigh: 400, scale: 2),
        ]
        let lock = NSLock()
        var observedInvalid = false
        let group = DispatchGroup()
        for i in 0..<300 {
            group.enter()
            DispatchQueue.global().async {
                if i % 2 == 0 {
                    _ = state.update(pixelsWide: 100, pixelsHigh: 200, scale: 1)
                } else {
                    _ = state.update(pixelsWide: 300, pixelsHigh: 400, scale: 2)
                }
                let snapshot = state.snapshot()
                if !knownTriples.contains(snapshot) {
                    lock.lock(); observedInvalid = true; lock.unlock()
                }
                group.leave()
            }
        }
        group.wait()
        XCTAssertFalse(observedInvalid)
        XCTAssertTrue(knownTriples.contains(state.snapshot()))
    }
}

/// Receiver Swift6-Geometry-1: covers the migration that made
/// `displayGeometryState` (`ReceiverDisplayGeometryState`) the sole
/// authoritative store for the announced panel geometry formerly held as
/// `StreamReceiver`'s own `devicePixelsWide`/`devicePixelsHigh`/
/// `deviceScale` stored properties (removed by this change) — exercised
/// through `StreamReceiver`'s own public writer API (`setNativePanel`/
/// `setPanel`/`setOrientation`), the same seam production UI code uses,
/// plus the `displayGeometryState` test-only accessor (`internal`, not
/// `private`, precisely so this can read the result without reaching into
/// `sendHello`'s network send path).
import AVFoundation

@MainActor
final class StreamReceiverDisplayGeometryMigrationTests: XCTestCase {

    private func makeReceiver() -> StreamReceiver {
        StreamReceiver(displayLayer: AVSampleBufferDisplayLayer(),
                        deviceKind: "Test", fallbackServiceName: "Test")
    }

    func testFreshReceiverGeometryMatchesOldDefaults() {
        let receiver = makeReceiver()
        let snapshot = receiver.displayGeometryState.snapshot()
        XCTAssertEqual(snapshot.pixelsWide, 0)
        XCTAssertEqual(snapshot.pixelsHigh, 0)
        XCTAssertEqual(snapshot.scale, 2)
    }

    /// `setNativePanel` seeds dimensions the first time and always updates
    /// scale, but never replaces already-initialized dimensions.
    func testSetNativePanelSeedsOnceAndAlwaysUpdatesScale() {
        let receiver = makeReceiver()
        receiver.setNativePanel(long: 1920, short: 1080, scale: 2)
        var snapshot = receiver.displayGeometryState.snapshot()
        XCTAssertEqual(snapshot.pixelsWide, 1920)
        XCTAssertEqual(snapshot.pixelsHigh, 1080)
        XCTAssertEqual(snapshot.scale, 2)

        receiver.setNativePanel(long: 800, short: 600, scale: 3)
        snapshot = receiver.displayGeometryState.snapshot()
        XCTAssertEqual(snapshot.pixelsWide, 1920) // unchanged
        XCTAssertEqual(snapshot.pixelsHigh, 1080) // unchanged
        XCTAssertEqual(snapshot.scale, 3) // updated
    }

    /// `setPanel` always updates scale; width/height update only when they
    /// actually differ from the current stored geometry.
    func testSetPanelUpdatesDimensionsOnlyWhenChanged() {
        let receiver = makeReceiver()
        receiver.setPanel(pixelsWide: 390, pixelsHigh: 844, scale: 3)
        var snapshot = receiver.displayGeometryState.snapshot()
        XCTAssertEqual(snapshot.pixelsWide, 390)
        XCTAssertEqual(snapshot.pixelsHigh, 844)
        XCTAssertEqual(snapshot.scale, 3)

        receiver.setPanel(pixelsWide: 390, pixelsHigh: 844, scale: 2)
        snapshot = receiver.displayGeometryState.snapshot()
        XCTAssertEqual(snapshot.pixelsWide, 390) // unchanged
        XCTAssertEqual(snapshot.pixelsHigh, 844) // unchanged
        XCTAssertEqual(snapshot.scale, 2) // still updates
    }

    /// `setOrientation` re-derives swapped dimensions from the native
    /// long/short values `setNativePanel` recorded and stores them
    /// coherently via `setPanel`.
    func testSetOrientationSwapsDimensionsFromNativePanel() {
        let receiver = makeReceiver()
        receiver.setNativePanel(long: 1920, short: 1080, scale: 2)
        receiver.setOrientation(portrait: true)
        var snapshot = receiver.displayGeometryState.snapshot()
        XCTAssertEqual(snapshot.pixelsWide, 1080)
        XCTAssertEqual(snapshot.pixelsHigh, 1920)

        receiver.setOrientation(portrait: false)
        snapshot = receiver.displayGeometryState.snapshot()
        XCTAssertEqual(snapshot.pixelsWide, 1920)
        XCTAssertEqual(snapshot.pixelsHigh, 1080)
    }

    /// `setOrientation` with no native panel ever reported is a no-op —
    /// matches the `guard nativeLong > 0 else { return }` early exit.
    func testSetOrientationWithoutNativePanelIsNoOp() {
        let receiver = makeReceiver()
        receiver.setOrientation(portrait: true)
        let snapshot = receiver.displayGeometryState.snapshot()
        XCTAssertEqual(snapshot.pixelsWide, 0)
        XCTAssertEqual(snapshot.pixelsHigh, 0)
    }

    /// Static verification of the `sendHello` geometry read path: `sendHello`
    /// is private, but its geometry fields come from exactly one call —
    /// `displayGeometryState.snapshot()` — so exercising the writer API and
    /// reading that same accessor proves what `sendHello` will send without
    /// standing up network fixtures.
    func testGeometryVisibleToHelloReadPathAfterWrites() {
        let receiver = makeReceiver()
        receiver.setPanel(pixelsWide: 1170, pixelsHigh: 2532, scale: 3)
        let snapshot = receiver.displayGeometryState.snapshot()
        XCTAssertEqual(snapshot.pixelsWide, 1170)
        XCTAssertEqual(snapshot.pixelsHigh, 2532)
        XCTAssertEqual(snapshot.scale, 3)
    }
}

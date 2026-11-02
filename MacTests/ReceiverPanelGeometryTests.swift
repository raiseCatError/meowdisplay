import CoreGraphics
import XCTest

final class ReceiverPanelGeometryTests: XCTestCase {
    func testFullScreenWindowAnnouncesTheNativePanelExactly() {
        // iPhone 15 Pro: 393×852 pt at 3× is the 1179×2556 native panel (odd width kept).
        let px = ReceiverPanelGeometry.pixels(windowPoints: CGSize(width: 393, height: 852), scale: 3)
        XCTAssertEqual(px?.wide, 1179)
        XCTAssertEqual(px?.high, 2556)
    }

    func testRotatedWindowSwapsDimensions() {
        let px = ReceiverPanelGeometry.pixels(windowPoints: CGSize(width: 852, height: 393), scale: 3)
        XCTAssertEqual(px?.wide, 2556)
        XCTAssertEqual(px?.high, 1179)
    }

    func testFractionalScaleRoundsToNearestPixel() {
        // A zoomed or non-integer native scale.
        let px = ReceiverPanelGeometry.pixels(windowPoints: CGSize(width: 414, height: 896), scale: 2.608)
        XCTAssertEqual(px?.wide, 1080)
        XCTAssertEqual(px?.high, 2337)
    }

    func testUnusableSizesAreIgnored() {
        XCTAssertNil(ReceiverPanelGeometry.pixels(windowPoints: .zero, scale: 3))
        XCTAssertNil(ReceiverPanelGeometry.pixels(windowPoints: CGSize(width: 100, height: 100), scale: 0))
        XCTAssertNil(ReceiverPanelGeometry.pixels(windowPoints: CGSize(width: CGFloat.nan, height: 100), scale: 2))
        XCTAssertNil(ReceiverPanelGeometry.pixels(windowPoints: CGSize(width: 100, height: CGFloat.infinity), scale: 2))
    }
}

@MainActor
final class ReceiverPanelSettlerTests: XCTestCase {
    private var applied: [ReceiverPanelSettler.Panel] = []
    private var connected = false

    private func makeSettler(delay: TimeInterval = 0.05) -> ReceiverPanelSettler {
        ReceiverPanelSettler(delay: delay, isConnected: { [unowned self] in self.connected },
                             apply: { [unowned self] in self.applied.append($0) })
    }

    private func settle(_ seconds: TimeInterval = 0.2) {
        let done = expectation(description: "settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { done.fulfill() }
        wait(for: [done], timeout: seconds + 2)
    }

    func testFirstSizeAppliesImmediatelyEvenWhenConnected() {
        connected = true
        let settler = makeSettler()
        settler.windowChanged(points: CGSize(width: 393, height: 852), scale: 3)
        XCTAssertEqual(applied.map(\.wide), [1179])
        XCTAssertEqual(applied.first?.scale, 3)
    }

    func testChangesWhileDisconnectedApplyImmediately() {
        let settler = makeSettler()
        settler.windowChanged(points: CGSize(width: 393, height: 852), scale: 3)
        settler.windowChanged(points: CGSize(width: 852, height: 393), scale: 3)
        XCTAssertEqual(applied.map(\.wide), [1179, 2556])
    }

    func testResizeWhileStreamingSendsOnlyTheSettledSize() {
        let settler = makeSettler()
        settler.windowChanged(points: CGSize(width: 393, height: 852), scale: 3)
        connected = true
        // An unfold in progress: several intermediate sizes, then the final one.
        for width in stride(from: 400, through: 700, by: 100) {
            settler.windowChanged(points: CGSize(width: CGFloat(width), height: 852), scale: 3)
        }
        XCTAssertEqual(applied.count, 1, "nothing is sent mid-resize")
        settle()
        XCTAssertEqual(applied.count, 2)
        XCTAssertEqual(applied.last?.wide, 2100)
        XCTAssertEqual(applied.last?.high, 2556)
    }

    func testReturningToTheAnnouncedSizeCancelsThePendingChange() {
        let settler = makeSettler()
        settler.windowChanged(points: CGSize(width: 393, height: 852), scale: 3)
        connected = true
        settler.windowChanged(points: CGSize(width: 600, height: 852), scale: 3)
        settler.windowChanged(points: CGSize(width: 393, height: 852), scale: 3)
        settle()
        XCTAssertEqual(applied.count, 1)
    }

    func testUnchangedSizeIsNotReannounced() {
        let settler = makeSettler()
        settler.windowChanged(points: CGSize(width: 393, height: 852), scale: 3)
        settler.windowChanged(points: CGSize(width: 393, height: 852), scale: 3)
        connected = true
        settler.windowChanged(points: CGSize(width: 393, height: 852), scale: 3)
        settle()
        XCTAssertEqual(applied.count, 1)
    }
}

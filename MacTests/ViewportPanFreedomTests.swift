import CoreGraphics
import XCTest

/// Viewport translation at 100% and beyond: any edge of the remote display
/// may reach the viewport's center but never pass it, and Move View's
/// navigation session reuses the same clamp.
final class ViewportPanFreedomTests: XCTestCase {
    /// A letterboxed 16:10 picture in a 1000x800 surface: 1000x625, centered.
    private let base = CGRect(x: 0, y: 87.5, width: 1000, height: 625)
    private var center: CGPoint { CGPoint(x: base.midX, y: base.midY) }

    private func displayed(_ state: ManualViewportState) -> RemoteViewportTransform {
        RemoteViewportCalculator.applyManualZoom(
            to: RemoteViewportTransform(remoteCrop: CGRect(x: 0, y: 0, width: 1, height: 1), displayedRect: base),
            state: state)
    }

    func testPanWorksAtExactlyOneHundredPercent() {
        let state = ManualViewportState(scale: 1, panX: 120, panY: -40).clamped(against: base)
        XCTAssertEqual(state.scale, 1)
        XCTAssertEqual(state.panX, 120)
        XCTAssertEqual(state.panY, -40)
        XCTAssertFalse(state.isIdentity)
        XCTAssertEqual(displayed(state).displayedRect, base.offsetBy(dx: 120, dy: -40))
    }

    func testLeftEdgeReachesTheCenterButNotPast() {
        let rect = displayed(ManualViewportState(scale: 1, panX: 10_000).clamped(against: base)).displayedRect
        XCTAssertEqual(rect.minX, center.x, accuracy: 0.001)
    }

    func testRightEdgeReachesTheCenterButNotPast() {
        let rect = displayed(ManualViewportState(scale: 1, panX: -10_000).clamped(against: base)).displayedRect
        XCTAssertEqual(rect.maxX, center.x, accuracy: 0.001)
    }

    func testTopEdgeReachesTheCenterButNotPast() {
        let rect = displayed(ManualViewportState(scale: 1, panY: 10_000).clamped(against: base)).displayedRect
        XCTAssertEqual(rect.minY, center.y, accuracy: 0.001)
    }

    func testBottomEdgeReachesTheCenterButNotPast() {
        let rect = displayed(ManualViewportState(scale: 1, panY: -10_000).clamped(against: base)).displayedRect
        XCTAssertEqual(rect.maxY, center.y, accuracy: 0.001)
    }

    func testTheDisplayCanNeverLeaveTheViewport() {
        for panX in stride(from: -5_000.0, through: 5_000, by: 1_250) {
            for panY in stride(from: -5_000.0, through: 5_000, by: 1_250) {
                for scale in [1.0, 1.7, 3.0] {
                    let rect = displayed(ManualViewportState(scale: CGFloat(scale), panX: CGFloat(panX),
                                                             panY: CGFloat(panY)).clamped(against: base)).displayedRect
                    // The picture always still touches the viewport's center.
                    XCTAssertLessThanOrEqual(rect.minX, center.x + 0.001)
                    XCTAssertGreaterThanOrEqual(rect.maxX, center.x - 0.001)
                    XCTAssertLessThanOrEqual(rect.minY, center.y + 0.001)
                    XCTAssertGreaterThanOrEqual(rect.maxY, center.y - 0.001)
                }
            }
        }
    }

    func testHigherZoomAllowsProportionallyMoreTravel() {
        let state = ManualViewportState(scale: 2, panX: 10_000, panY: -10_000).clamped(against: base)
        let rect = displayed(state).displayedRect
        XCTAssertEqual(rect.minX, center.x, accuracy: 0.001)
        XCTAssertEqual(rect.maxY, center.y, accuracy: 0.001)
    }

    func testRotatedExtentsLimitTravelToTheCenter() throws {
        let quarter = ManualViewportState(scale: 1, panX: 10_000, panY: 10_000, rotationRadians: .pi / 2)
            .clamped(against: base)
        let limits = try XCTUnwrap(quarter.panLimits(against: base))
        // A quarter turn swaps the extents.
        XCTAssertEqual(limits.x, base.height / 2, accuracy: 0.001)
        XCTAssertEqual(limits.y, base.width / 2, accuracy: 0.001)
        let transform = displayed(quarter)
        // The rotated picture's leftmost/topmost point sits on the center.
        let corners = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 0, y: 1), CGPoint(x: 1, y: 1)]
            .map(transform.viewPoint(forRemote:))
        XCTAssertEqual(corners.map(\.x).min() ?? 0, center.x, accuracy: 0.01)
        XCTAssertEqual(corners.map(\.y).min() ?? 0, center.y, accuracy: 0.01)

        let tilted = ManualViewportState(scale: 1.5, panX: -10_000, rotationRadians: .pi / 6).clamped(against: base)
        let tiltedCorners = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 0, y: 1), CGPoint(x: 1, y: 1)]
            .map(displayed(tilted).viewPoint(forRemote:))
        XCTAssertEqual(tiltedCorners.map(\.x).max() ?? 0, center.x, accuracy: 0.01)
    }

    func testInvalidGeometryResetsToIdentity() {
        let state = ManualViewportState(scale: 2, panX: 50, panY: 50, rotationRadians: 1)
        XCTAssertEqual(state.clamped(against: .zero), ManualViewportState(scale: 2))
        XCTAssertNil(state.panLimits(against: CGRect(x: 0, y: 0, width: 0, height: 100)))
        let nonFinite = ManualViewportState(scale: 1, panX: .nan, panY: .infinity).clamped(against: base)
        XCTAssertEqual(nonFinite.panX, 0)
        XCTAssertEqual(nonFinite.panY, 0)
    }

    func testResetAndRestoreIncludeAPanOnlyView() throws {
        let panned = ManualViewportState(scale: 1, panX: 200, panY: 0)
        let reset = try XCTUnwrap(ViewportResetRestorePolicy.toggled(current: panned, memory: nil, base: base))
        XCTAssertEqual(reset.current, .identity)
        XCTAssertEqual(reset.memory, panned)
        let restored = try XCTUnwrap(ViewportResetRestorePolicy.toggled(current: reset.current,
                                                                       memory: reset.memory, base: base))
        XCTAssertEqual(restored.current, panned)
        // Restoring into a smaller viewport re-clamps rather than overshoots.
        let small = CGRect(x: 0, y: 0, width: 200, height: 200)
        let reclamped = try XCTUnwrap(ViewportResetRestorePolicy.toggled(current: .identity,
                                                                        memory: panned, base: small))
        XCTAssertEqual(reclamped.current.panX, 100)
    }

    func testInputMappingStaysTheInverseOfRendering() {
        let states = [ManualViewportState(scale: 1, panX: 300, panY: -200),
                      ManualViewportState(scale: 2.4, panX: -900, panY: 400, rotationRadians: 0.7),
                      ManualViewportState(scale: 1, panX: 499, panY: 0, rotationRadians: .pi / 2)]
        for state in states {
            let transform = displayed(state.clamped(against: base))
            for remote in [CGPoint(x: 0.1, y: 0.2), CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.93, y: 0.71)] {
                let view = transform.viewPoint(forRemote: remote)
                XCTAssertTrue(transform.containsViewPoint(view))
                guard let back = transform.remotePoint(forView: view) else { return XCTFail("unmappable") }
                XCTAssertEqual(back.x, remote.x, accuracy: 0.0001)
                XCTAssertEqual(back.y, remote.y, accuracy: 0.0001)
            }
        }
    }

    func testPinchCommittedPanAtOneHundredPercentTranslates() {
        let result = ManualViewportState.pinching(from: .identity, initialBase: base,
                                                  initialMidpoint: center,
                                                  currentMidpoint: CGPoint(x: center.x + 80, y: center.y),
                                                  scaleRatio: 1)
        XCTAssertEqual(result.scale, 1)
        XCTAssertEqual(result.panX, 80, accuracy: 0.001)
    }

    // MARK: - Move View

    func testOneFingerMoveViewPans() {
        var session = ViewportNavigationSession()
        var state = ManualViewportState.identity
        state = session.update(points: [CGPoint(x: 100, y: 100)], current: state, base: base,
                               allowsZoom: true, allowsRotation: false)
        XCTAssertEqual(state, .identity, "the first sample only sets the baseline")
        state = session.update(points: [CGPoint(x: 160, y: 70)], current: state, base: base,
                               allowsZoom: true, allowsRotation: false)
        XCTAssertEqual(state.panX, 60, accuracy: 0.001)
        XCTAssertEqual(state.panY, -30, accuracy: 0.001)
        XCTAssertEqual(state.scale, 1)
    }

    func testAddingAFingerReBaselinesWithoutAJump() {
        var session = ViewportNavigationSession()
        var state = ManualViewportState.identity
        state = session.update(points: [CGPoint(x: 100, y: 100)], current: state, base: base,
                               allowsZoom: true, allowsRotation: false)
        state = session.update(points: [CGPoint(x: 150, y: 100)], current: state, base: base,
                               allowsZoom: true, allowsRotation: false)
        let beforeSecondFinger = state
        state = session.update(points: [CGPoint(x: 150, y: 100), CGPoint(x: 400, y: 400)], current: state,
                               base: base, allowsZoom: true, allowsRotation: false)
        XCTAssertEqual(state, beforeSecondFinger)
    }

    func testMoveViewPinchZoomsAndRotatesOnlyWhenAllowed() {
        func pinch(allowsZoom: Bool, allowsRotation: Bool) -> ManualViewportState {
            var session = ViewportNavigationSession()
            var state = ManualViewportState.identity
            state = session.update(points: [CGPoint(x: 400, y: 400), CGPoint(x: 600, y: 400)], current: state,
                                   base: base, allowsZoom: allowsZoom, allowsRotation: allowsRotation)
            // Twice as far apart, and turned a quarter.
            return session.update(points: [CGPoint(x: 500, y: 200), CGPoint(x: 500, y: 600)], current: state,
                                  base: base, allowsZoom: allowsZoom, allowsRotation: allowsRotation)
        }
        let both = pinch(allowsZoom: true, allowsRotation: true)
        XCTAssertEqual(both.scale, 2, accuracy: 0.001)
        XCTAssertEqual(both.rotationRadians, .pi / 2, accuracy: 0.001)
        let zoomOnly = pinch(allowsZoom: true, allowsRotation: false)
        XCTAssertEqual(zoomOnly.scale, 2, accuracy: 0.001)
        XCTAssertEqual(zoomOnly.rotationRadians, 0)
        let panOnly = pinch(allowsZoom: false, allowsRotation: false)
        XCTAssertEqual(panOnly.scale, 1)
    }

    func testMoveViewStillStopsAtTheCenter() {
        var session = ViewportNavigationSession()
        var state = session.update(points: [CGPoint(x: 0, y: 0)], current: .identity, base: base,
                                   allowsZoom: true, allowsRotation: false)
        state = session.update(points: [CGPoint(x: 5_000, y: 0)], current: state, base: base,
                               allowsZoom: true, allowsRotation: false)
        XCTAssertEqual(displayed(state).displayedRect.minX, center.x, accuracy: 0.001)
    }
}

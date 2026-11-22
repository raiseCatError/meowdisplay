import CoreGraphics
import XCTest

/// Receiver pointer input stays on the receiver's own display, and the cursor a receiver
/// draws is the Mac's real cursor unless that receiver is driving the workspace pointer.
final class CursorTargetingTests: XCTestCase {

    // MARK: - Coordinates stay on the display

    func testNormalizedCoordinatesNeverReachTheNextDisplay() {
        let bounds = CGRect(x: -1_920, y: -240, width: 1_920, height: 1_080)
        // 1.0 is the neighbour's first column: the last pixel of this display instead.
        XCTAssertEqual(InputCoordinateMapper.point(x: 1, y: 1, in: bounds, pixelScale: 2),
                       CGPoint(x: -0.5, y: 839.5))
        XCTAssertEqual(InputCoordinateMapper.point(x: 1.3, y: -0.2, in: bounds),
                       CGPoint(x: -1, y: -240))
        XCTAssertTrue(bounds.contains(InputCoordinateMapper.point(x: 1, y: 1, in: bounds)))
        XCTAssertEqual(InputCoordinateMapper.point(x: 0.5, y: 0.5, in: bounds), CGPoint(x: -960, y: 300))
    }

    func testClampKeepsPointsOnStaggeredDisplay() {
        let bounds = CGRect(x: 1_512, y: -300, width: 2_560, height: 1_440)
        let p = InputCoordinateMapper.clamp(CGPoint(x: 9_000, y: -9_000), into: bounds, pixelScale: 1)
        XCTAssertEqual(p, CGPoint(x: 4_071, y: -300))
        XCTAssertTrue(bounds.contains(p))
    }

    // MARK: - Re-entry point

    func testReentryUsesTheCursorWhileItIsOnTheDisplay() {
        var r = DisplayReentryPoint()
        let bounds = CGRect(x: 0, y: 0, width: 1_000, height: 500)
        let start = r.origin(cursor: CGPoint(x: 200, y: 100), in: bounds)
        XCTAssertEqual(start?.point, CGPoint(x: 200, y: 100))
        XCTAssertEqual(start?.cursorOnDisplay, true)
        XCTAssertEqual(r.normalized, CGPoint(x: 0.2, y: 0.2))
    }

    func testReentryFallsBackToTheDisplayCentreWithoutHistory() {
        var r = DisplayReentryPoint()
        let bounds = CGRect(x: -1_000, y: 0, width: 1_000, height: 500)
        let start = r.origin(cursor: CGPoint(x: 400, y: 100), in: bounds)
        XCTAssertEqual(start?.point, CGPoint(x: -500, y: 250))
        XCTAssertEqual(start?.cursorOnDisplay, false)
        XCTAssertNil(r.normalized, "a cursor elsewhere is never remembered")
    }

    func testReentryReturnsToTheLastSpotAndFollowsTheDisplayWhenItMoves() {
        var r = DisplayReentryPoint()
        r.note(CGPoint(x: 750, y: 125), in: CGRect(x: 0, y: 0, width: 1_000, height: 500))
        // The physical mouse left for another display, and the display was rearranged.
        let moved = CGRect(x: -1_000, y: 200, width: 1_000, height: 500)
        let start = r.origin(cursor: CGPoint(x: 3_000, y: 0), in: moved)
        XCTAssertEqual(start?.point, CGPoint(x: -250, y: 325))
        XCTAssertEqual(start?.cursorOnDisplay, false)
    }

    func testReentryIgnoresPointsOffTheDisplayAndGoneDisplays() {
        var r = DisplayReentryPoint()
        r.note(CGPoint(x: 1_000, y: 10), in: CGRect(x: 0, y: 0, width: 1_000, height: 500))
        XCTAssertNil(r.normalized, "maxX belongs to the next display")
        XCTAssertNil(r.origin(cursor: .zero, in: .zero), "no bounds: the input goes nowhere")
    }

    // MARK: - InputInjector (Mirror/Extend)

    private let grant = SessionInputGrantBox()
    private let events = LocatedEventSink()

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: InputPolicy.defaultsKey)
        LoginSessionConsole.shared.set(onConsole: true)
        grant.set(true)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: InputPolicy.defaultsKey)
        super.tearDown()
    }

    private var display: CGRect { CGDisplayBounds(CGMainDisplayID()) }

    private func makeInjector(cursor: CGPoint) -> InputInjector {
        let injector = InputInjector(displayID: CGMainDisplayID(), sessionInputGrant: grant, eventSink: events)
        injector.privacyGate = MacPrivacyGate(.unlocked)
        injector.cursorLocator = { cursor }
        return injector
    }

    /// A spot on no display at all, to the right of the main one (another display would be
    /// there in a real arrangement).
    private var elsewhere: CGPoint { CGPoint(x: display.maxX + 500, y: display.midY) }

    func testRelativeMoveWithTheCursorElsewhereStartsOnTheReceiversDisplay() throws {
        try XCTSkipIf(display.isEmpty, "needs a display")
        let injector = makeInjector(cursor: elsewhere)
        injector.handlePointerMoveRelative(dx: 0, dy: 0)
        let moved = try XCTUnwrap(events.posted.last)
        XCTAssertEqual(moved.type, .mouseMoved)
        XCTAssertTrue(display.contains(moved.location), "\(moved.location) is off \(display)")
        XCTAssertEqual(moved.location.x, display.midX, accuracy: 1)
    }

    func testRelativeMovePastTheEdgeStaysOnTheDisplay() throws {
        try XCTSkipIf(display.isEmpty, "needs a display")
        let injector = makeInjector(cursor: CGPoint(x: display.maxX - 2, y: display.midY))
        injector.handlePointerMoveRelative(dx: 100_000, dy: -100_000)
        let moved = try XCTUnwrap(events.posted.last)
        XCTAssertTrue(display.contains(moved.location), "\(moved.location) is off \(display)")
    }

    func testRelativeMoveWithTheCursorOnTheDisplayStartsFromIt() throws {
        try XCTSkipIf(display.isEmpty, "needs a display")
        let here = CGPoint(x: display.minX + 40, y: display.minY + 30)
        let injector = makeInjector(cursor: here)
        injector.handlePointerMoveRelative(dx: 0, dy: 0)
        XCTAssertEqual(try XCTUnwrap(events.posted.last).location, here)
    }

    func testDesktopTrackpadDragCrossesDisplaysAndRevocationReleasesIt() throws {
        let left = CGRect(x: 0, y: 0, width: 100, height: 80)
        let right = CGRect(x: 100, y: -20, width: 200, height: 120)
        let cursor = CGPoint(x: 95, y: 40)
        let injector = makeInjector(cursor: cursor)
        injector.desktopDisplayBounds = { point in
            [left, right].first { $0.contains(point) }
        }

        injector.handlePointerDown(button: .left, clickCount: 1, desktopTrackpad: true)
        injector.handlePointerMoveRelative(dx: 10, dy: 10, trackpadPoints: true, desktopTrackpad: true)
        XCTAssertEqual(events.posted.map(\.type), [.leftMouseDown, .leftMouseDragged])
        XCTAssertEqual(events.posted.last?.location, CGPoint(x: 105, y: 50))

        grant.set(false)
        injector.cancelActiveInput()
        injector.handlePointerMoveRelative(dx: 10, dy: 10, trackpadPoints: true, desktopTrackpad: true)
        XCTAssertEqual(events.posted.map(\.type), [.leftMouseDown, .leftMouseDragged, .leftMouseUp])
    }

    func testDesktopTrackpadDoesNotJumpIntoAGapInTheDisplayArrangement() {
        let display = CGRect(x: -100, y: 0, width: 100, height: 100)
        let cursor = CGPoint(x: -4, y: 20)
        let bounds: (CGPoint) -> CGRect? = { display.contains($0) ? display : nil }
        XCTAssertEqual(InputCoordinateMapper.desktopRelativePoint(from: cursor, dx: 20, dy: 10, displayAt: bounds),
                       CGPoint(x: -1, y: 30))
        XCTAssertNil(InputCoordinateMapper.desktopRelativePoint(from: cursor, dx: .infinity, dy: 0, displayAt: bounds))
    }

    func testAPressWithTheCursorElsewhereNeverClicksAnotherDisplay() throws {
        try XCTSkipIf(display.isEmpty, "needs a display")
        let injector = makeInjector(cursor: elsewhere)
        injector.handlePointerDown(button: .left, clickCount: 1)
        XCTAssertEqual(events.posted.map(\.type), [.mouseMoved, .leftMouseDown],
                       "the cursor comes onto the receiver's display first")
        XCTAssertTrue(events.posted.allSatisfy { display.contains($0.location) })
        injector.cancelActiveInput()
    }

    func testAPressWithTheCursorOnTheDisplayDoesNotMoveIt() throws {
        try XCTSkipIf(display.isEmpty, "needs a display")
        let here = CGPoint(x: display.midX + 7, y: display.midY - 3)
        let injector = makeInjector(cursor: here)
        injector.handlePointerDown(button: .left, clickCount: 1)
        XCTAssertEqual(events.posted.map(\.type), [.leftMouseDown])
        XCTAssertEqual(events.posted.first?.location, here)
        injector.cancelActiveInput()
    }

    func testAScrollWithTheCursorElsewhereScrollsTheReceiversDisplay() throws {
        try XCTSkipIf(display.isEmpty, "needs a display")
        let injector = makeInjector(cursor: elsewhere)
        injector.handleScroll(dx: 0, dy: 400)
        XCTAssertEqual(events.posted.map(\.type), [.mouseMoved, .scrollWheel])
        XCTAssertTrue(display.contains(events.posted[0].location))
    }

    func testTheLastSpotOnTheDisplayIsWhereInputComesBack() throws {
        try XCTSkipIf(display.isEmpty, "needs a display")
        let spot = CGPoint(x: display.minX + 25, y: display.minY + 25)
        let injector = makeInjector(cursor: elsewhere)
        injector.noteCursor(spot)              // seen there by the cursor echo
        injector.noteCursor(elsewhere)         // then the physical mouse left: not remembered
        injector.handlePointerDown(button: .left, clickCount: 1)
        XCTAssertEqual(events.posted.first?.location, spot)
        injector.cancelActiveInput()
    }

    func testReentryPointReadsAsTheCentreUntilTheCursorWasSeenOnTheDisplay() {
        let injector = makeInjector(cursor: elsewhere)
        XCTAssertEqual(injector.reentryNormalizedPoint(), CGPoint(x: 0.5, y: 0.5))
    }

    func testReentryPointReadsAsTheLastSpotSeenOnTheDisplay() throws {
        try XCTSkipIf(display.isEmpty, "needs a display")
        let injector = makeInjector(cursor: elsewhere)
        injector.noteCursor(CGPoint(x: display.minX + display.width / 4, y: display.minY + display.height * 3 / 4))
        injector.noteCursor(elsewhere)         // the physical mouse left: the spot stays
        let point = injector.reentryNormalizedPoint()
        XCTAssertEqual(point.x, CGFloat(0.25), accuracy: CGFloat(0.0001))
        XCTAssertEqual(point.y, CGFloat(0.75), accuracy: CGFloat(0.0001))
    }

    func testNothingMovesWithoutInputPermission() throws {
        try XCTSkipIf(display.isEmpty, "needs a display")
        grant.set(false)
        let injector = makeInjector(cursor: elsewhere)
        injector.handlePointerMoveRelative(dx: 10, dy: 10)
        injector.handlePointerDown(button: .left, clickCount: 1)
        injector.handleScroll(dx: 0, dy: 400)
        XCTAssertTrue(events.posted.isEmpty, "View Only: \(events.posted)")
    }

    // MARK: - Window mode binding

    func testCancellingInputEndsTheWorkspaceDragBinding() {
        let mapper = BindingMapper()
        let injector = makeInjector(cursor: .zero)
        injector.setTargetMapper(mapper)
        mapper.cancels = 0
        injector.cancelActiveInput()
        XCTAssertEqual(mapper.cancels, 1)
    }

    // MARK: - Which cursor a receiver sees in Window mode

    func testTheWorkspacePointerIsTheCursorOnlyWhileTheReceiverCanMoveIt() {
        XCTAssertTrue(WindowWorkspaceEngine.reportsWorkspacePointer(pointerDriven: true, receiverMayMovePointer: true))
        XCTAssertFalse(WindowWorkspaceEngine.reportsWorkspacePointer(pointerDriven: true, receiverMayMovePointer: false),
                       "View Only: the real Mac cursor, never a resume spot that nothing moves")
        XCTAssertFalse(WindowWorkspaceEngine.reportsWorkspacePointer(pointerDriven: false, receiverMayMovePointer: true))
        XCTAssertFalse(WindowWorkspaceEngine.reportsWorkspacePointer(pointerDriven: false, receiverMayMovePointer: false))
    }
}

/// Records each posted event's type and location.
private final class LocatedEventSink: SyntheticEventSink, @unchecked Sendable {
    struct Posted { let type: CGEventType; let location: CGPoint }
    private let lock = NSLock()
    private var entries: [Posted] = []
    var posted: [Posted] { lock.withLock { entries } }
    func post(_ event: CGEvent) {
        lock.withLock { entries.append(Posted(type: event.type, location: event.location)) }
    }
}

private final class BindingMapper: InputTargetMapper, @unchecked Sendable {
    var cancels = 0
    func mapPointer(phase: InputMapPhase, x: Double?, y: Double?, dx: Double, dy: Double) -> CGPoint? { nil }
    func scrollVector(dx: Double, dy: Double) -> CGVector { .zero }
    func keyboardTargetReady() -> Bool { true }
    func locate(x: Double, y: Double) -> CGPoint? { nil }
    func cancelBinding() { cancels += 1 }

}

/// Window mode: where the real Mac cursor is relative to the active pane while it is over none.
final class WindowOffPaneCursorTests: XCTestCase {

    private func onePane() -> WorkspaceInputTargeting {
        var t = WorkspaceInputTargeting()
        t.canvas = CGSize(width: 2000, height: 1000)
        t.windowFrames = [10: CGRect(x: 0, y: 0, width: 1000, height: 1000)]
        _ = t.update(assignments: [
            WorkspaceTileAssignment(tileID: "a", rect: .unit, windowID: 10, windowGeneration: 1, pid: 100, bundleID: "a",
                                    follow: .window, rotation: .none, fit: .fit, assignmentGeneration: 1),
        ])
        return t
    }

    func testOffPaneCursorExtendsTheActivePanesMapping() throws {
        let t = onePane()
        // Fit: the 1000x1000 window is drawn 500...1500 across the 2000x1000 canvas.
        let off = try XCTUnwrap(t.offPaneCursor(forGlobal: CGPoint(x: 1500, y: 500)))
        XCTAssertEqual(off.x, 1.0, accuracy: 1e-9)
        XCTAssertEqual(off.y, 0.5, accuracy: 1e-9)
        XCTAssertEqual(off.pane, WorkspaceRect(x: 0.25, y: 0, width: 0.5, height: 1))
        let left = try XCTUnwrap(t.offPaneCursor(forGlobal: CGPoint(x: -1000, y: -500)))
        XCTAssertLessThan(left.x, 0.25)
        XCTAssertLessThan(left.y, 0)
    }

    func testNoOffPaneCursorInsideThePaneOrWithoutAnActivePane() {
        XCTAssertNil(onePane().offPaneCursor(forGlobal: CGPoint(x: 750, y: 500)), "in the picture: the cursor itself")
        var t = WorkspaceInputTargeting()
        t.canvas = CGSize(width: 2000, height: 1000)
        t.windowFrames = [10: CGRect(x: 0, y: 0, width: 1000, height: 1000), 11: CGRect(x: 3000, y: 0, width: 1000, height: 1000)]
        _ = t.update(assignments: [
            WorkspaceTileAssignment(tileID: "a", rect: .init(x: 0, y: 0, width: 0.5, height: 1), windowID: 10, windowGeneration: 1,
                                    pid: 100, bundleID: "a", follow: .window, rotation: .none, fit: .fit, assignmentGeneration: 1),
            WorkspaceTileAssignment(tileID: "b", rect: .init(x: 0.5, y: 0, width: 0.5, height: 1), windowID: 11, windowGeneration: 1,
                                    pid: 200, bundleID: "b", follow: .window, rotation: .none, fit: .fit, assignmentGeneration: 2),
        ])
        XCTAssertNil(t.offPaneCursor(forGlobal: CGPoint(x: 2000, y: 500)), "two panes, none active: no locator")
        XCTAssertNil(onePane().offPaneCursor(forGlobal: CGPoint(x: CGFloat.nan, y: 0)))
    }
}

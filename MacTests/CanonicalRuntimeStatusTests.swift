import XCTest

/// Covers the canonical-state semantics the unified settings revamp depends
/// on: status text is gated on the *count of authenticated sessions*, never
/// on "any session exists" — the exact bug class that produced a false Idle
/// while a session was actually live and streaming (`SenderController` used
/// to read `sessions.isEmpty` for its status strip instead of
/// `activeDisplayEntries`, which is built from `applicationAuthenticated`
/// sessions only). `SenderController` itself needs the full app (ScreenCaptureKit/
/// Network/AppKit) and can't compile into this hostless test bundle — see
/// `ForgetDeviceCleanupTests` for the same constraint — so this exercises the
/// pure projection it's built from instead of duplicating its logic.
final class CanonicalRuntimeStatusTests: XCTestCase {
    func testNoAuthenticatedSessionsIsIdle() {
        XCTAssertEqual(CanonicalRuntimeStatus.statusText(activeDisplayCount: 0), "Idle")
    }

    func testOneAuthenticatedSessionIsSingularConnected() {
        XCTAssertEqual(CanonicalRuntimeStatus.statusText(activeDisplayCount: 1), "1 device connected")
    }

    func testMultipleAuthenticatedSessionsArePluralConnected() {
        XCTAssertEqual(CanonicalRuntimeStatus.statusText(activeDisplayCount: 2), "2 devices connected")
    }

    func testMirrorModeHeadlineSaysMirroring() {
        XCTAssertEqual(CanonicalRuntimeStatus.headline(mode: .mirror, route: nil), "Mirroring")
    }

    func testExtendModeHeadlineSaysExtending() {
        XCTAssertEqual(CanonicalRuntimeStatus.headline(mode: .extend, route: nil), "Extending")
    }

    func testLANRouteIsAppendedToTheHeadline() {
        XCTAssertEqual(CanonicalRuntimeStatus.headline(mode: .mirror, route: .lan), "Mirroring · LAN")
    }

    func testRemoteRouteIsAppendedToTheHeadline() {
        XCTAssertEqual(CanonicalRuntimeStatus.headline(mode: .extend, route: .remote), "Extending · Remote")
    }

    func testNoRouteYetOmitsTheSeparator() {
        // A session that authenticated but hasn't reported its
        // NWConnection.currentPath route yet (still dialing) must not show
        // a dangling "· " — the headline degrades to mode-only.
        XCTAssertEqual(CanonicalRuntimeStatus.headline(mode: .mirror, route: nil), "Mirroring")
    }

    // MARK: - Phase mapping (the toolbar "Reconnecting…" bug fix)

    func testRunningCapturePhaseIsConnected() {
        XCTAssertEqual(CanonicalRuntimeStatus.phase(capturePhase: .running, failed: false), .connected)
    }

    func testRecoveringCapturePhaseIsReconnecting() {
        // This is the exact bug: a session stays `applicationAuthenticated`
        // through a capture drop, so a count-only status text kept saying
        // "1 device connected" while the pipeline was actually recovering.
        XCTAssertEqual(CanonicalRuntimeStatus.phase(capturePhase: .recovering, failed: false), .reconnecting)
    }

    func testPausedCapturePhaseIsPaused() {
        XCTAssertEqual(CanonicalRuntimeStatus.phase(capturePhase: .paused, failed: false), .paused)
    }

    func testFailedSessionIsLostRegardlessOfCapturePhase() {
        XCTAssertEqual(CanonicalRuntimeStatus.phase(capturePhase: .running, failed: true), .lost)
    }

    func testStoppedCapturePhaseIsLost() {
        XCTAssertEqual(CanonicalRuntimeStatus.phase(capturePhase: .stopped, failed: false), .lost)
    }

    // MARK: - Aggregate phase (multiple active displays)

    func testEmptyAggregateIsIdle() {
        XCTAssertEqual(CanonicalRuntimeStatus.aggregatePhase(entryPhases: []), .idle)
    }

    func testOneUnhealthyEntryMakesTheWholeAggregateUnhealthy() {
        XCTAssertEqual(CanonicalRuntimeStatus.aggregatePhase(entryPhases: [.connected, .reconnecting]), .reconnecting)
    }

    func testLostOutranksReconnectingInTheAggregate() {
        XCTAssertEqual(CanonicalRuntimeStatus.aggregatePhase(entryPhases: [.reconnecting, .lost]), .lost)
    }

    func testAllPausedAggregatesToPaused() {
        XCTAssertEqual(CanonicalRuntimeStatus.aggregatePhase(entryPhases: [.paused, .paused]), .paused)
    }

    // MARK: - Entry/aggregate status text

    func testConnectedEntryTextIsTheHeadline() {
        XCTAssertEqual(
            CanonicalRuntimeStatus.entryStatusText(mode: .mirror, route: .lan, phase: .connected),
            "Mirroring · LAN")
    }

    func testPausedEntryTextUsesThePausedVerb() {
        XCTAssertEqual(
            CanonicalRuntimeStatus.entryStatusText(mode: .mirror, route: .lan, phase: .paused),
            "Paused · LAN")
    }

    func testReconnectingEntryTextNeverShowsAStaleConnectedString() {
        XCTAssertEqual(
            CanonicalRuntimeStatus.entryStatusText(mode: .mirror, route: .lan, phase: .reconnecting),
            "Reconnecting…")
    }

    func testLostEntryTextSaysConnectionLost() {
        XCTAssertEqual(
            CanonicalRuntimeStatus.entryStatusText(mode: .extend, route: nil, phase: .lost),
            "Connection Lost")
    }

    func testSingleEntryAggregateTextMatchesItsOwnEntryText() {
        let entries: [(mode: CaptureMode, route: ConnectionRoute?, phase: CanonicalConnectionPhase)] =
            [(mode: .mirror, route: .lan, phase: .reconnecting)]
        XCTAssertEqual(CanonicalRuntimeStatus.aggregateStatusText(entries: entries), "Reconnecting…")
    }

    func testMultiEntryHealthyAggregateFallsBackToTheCount() {
        let entries: [(mode: CaptureMode, route: ConnectionRoute?, phase: CanonicalConnectionPhase)] =
            [(mode: .mirror, route: .lan, phase: .connected), (mode: .extend, route: .lan, phase: .connected)]
        XCTAssertEqual(CanonicalRuntimeStatus.aggregateStatusText(entries: entries), "2 devices connected")
    }

    func testMultiEntryAggregateStillSurfacesAnUnhealthyOne() {
        let entries: [(mode: CaptureMode, route: ConnectionRoute?, phase: CanonicalConnectionPhase)] =
            [(mode: .mirror, route: .lan, phase: .connected), (mode: .extend, route: nil, phase: .lost)]
        XCTAssertEqual(CanonicalRuntimeStatus.aggregateStatusText(entries: entries), "Connection Lost")
    }
}

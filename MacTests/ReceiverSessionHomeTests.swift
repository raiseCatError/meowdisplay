import CoreGraphics
import XCTest

/// Back to Home — Keep Connected on the iOS/iPadOS receiver (#121): the session stays up behind
/// Home, nothing reaches the Mac from the hidden surface, local media pauses, and the session
/// comes back as it was (Shared/ReceiverSessionPresentation.swift).
final class ReceiverSessionHomeTests: XCTestCase {
    private let mac = "MAC-A"

    private func keptHome(_ peerID: String? = "MAC-A") -> ReceiverSessionPresentation {
        var presentation = ReceiverSessionPresentation.session
        XCTAssertTrue(presentation.showHome(surfaceRetained: true, macPeerID: peerID))
        return presentation
    }

    // MARK: Presentation

    func testHomeKeepsTheSessionAndResumeReturnsToIt() {
        var presentation = keptHome()
        XCTAssertEqual(presentation, .homeKeepingSession(macPeerID: mac))
        XCTAssertFalse(presentation.surfaceInteractive, "nothing on the hidden surface reaches the Mac")
        XCTAssertFalse(presentation.showHome(surfaceRetained: true, macPeerID: mac), "already on Home")
        XCTAssertTrue(presentation.resume())
        XCTAssertEqual(presentation, .session)
        XCTAssertTrue(presentation.surfaceInteractive)
        XCTAssertFalse(presentation.resume(), "already in the session")
    }

    func testOnlyARetainedSessionCanBeKept() {
        var presentation = ReceiverSessionPresentation.session
        XCTAssertFalse(presentation.showHome(surfaceRetained: false, macPeerID: nil))
        XCTAssertEqual(presentation, .session)
    }

    func testDisconnectEndsTheKeptSessionSoTheNextOneIsNotHidden() {
        var state = ReceiverSessionState()
        _ = state.connectionAdopted()
        _ = state.connectionEstablished()
        var presentation = keptHome()
        _ = state.connectionLost(reason: .explicitDisconnect)
        XCTAssertFalse(state.retainsReceiverSurface)
        XCTAssertTrue(presentation.sessionChanged(retainsSurface: state.retainsReceiverSurface, macPeerID: nil))
        XCTAssertEqual(presentation, .session)

        // A later session of any Mac starts on screen.
        _ = state.connectionAdopted()
        _ = state.connectionEstablished()
        XCTAssertFalse(presentation.sessionChanged(retainsSurface: state.retainsReceiverSurface, macPeerID: mac))
        XCTAssertEqual(presentation, .session)
        XCTAssertTrue(presentation.surfaceInteractive)
    }

    func testRecoveryAndAMigrationThroughConnectingStayKept() {
        var state = ReceiverSessionState()
        _ = state.connectionAdopted()
        _ = state.connectionEstablished()
        var presentation = keptHome()
        // USB ⇄ Wi-Fi migration: the session passes back through `connecting`.
        _ = state.connectionAdopted()
        XCTAssertTrue(state.retainsReceiverSurface)
        XCTAssertFalse(presentation.sessionChanged(retainsSurface: state.retainsReceiverSurface, macPeerID: nil))
        _ = state.connectionEstablished()
        XCTAssertFalse(presentation.sessionChanged(retainsSurface: state.retainsReceiverSurface, macPeerID: mac))
        // Transport loss: automatic recovery keeps the surface.
        _ = state.connectionLost(reason: .transportLost)
        XCTAssertEqual(state.phase, .reconnecting)
        XCTAssertFalse(presentation.sessionChanged(retainsSurface: state.retainsReceiverSurface, macPeerID: nil))
        XCTAssertEqual(presentation, .homeKeepingSession(macPeerID: mac))
    }

    func testTheMacEndingTheSessionKeepsHomeWithTheInterruption() {
        var state = ReceiverSessionState()
        _ = state.connectionAdopted()
        _ = state.connectionEstablished()
        var presentation = keptHome()
        _ = state.connectionLost(reason: .peerClosed)
        XCTAssertEqual(state.interruption, .peerDisconnected, "Home's card titles itself with this")
        XCTAssertFalse(presentation.sessionChanged(retainsSurface: state.retainsReceiverSurface, macPeerID: nil))
        XCTAssertTrue(presentation.keepsSessionOnHome, "Resume or Disconnect stays the person's choice")
    }

    func testAnotherMacTakingOverIsShownAndAnUnknownMacIsLearned() {
        var presentation = keptHome(nil)
        XCTAssertTrue(presentation.sessionChanged(retainsSurface: true, macPeerID: mac), "learned once known")
        XCTAssertEqual(presentation, .homeKeepingSession(macPeerID: mac))
        XCTAssertTrue(presentation.sessionChanged(retainsSurface: true, macPeerID: "MAC-B"),
                      "an accepted invitation from another Mac replaced the session")
        XCTAssertEqual(presentation, .session)
    }

    // MARK: Route, demo and Keep Screen Awake

    func testHomeOverAKeptSessionIsItsOwnRouteAndTheDemoCantStart() {
        let kept = keptHome()
        XCTAssertEqual(ReceiverPresentationRoute.resolve(demoActive: false, realSurfaceShown: true, presentation: kept), .sessionHome)
        XCTAssertEqual(ReceiverPresentationRoute.resolve(demoActive: true, realSurfaceShown: true, presentation: kept), .sessionHome)
        XCTAssertEqual(ReceiverPresentationRoute.resolve(demoActive: false, realSurfaceShown: false, presentation: kept), .idle,
                       "a session that is gone never leaves Home claiming it")
        XCTAssertEqual(ReceiverPresentationRoute.resolve(demoActive: false, realSurfaceShown: true), .receiver)
        XCTAssertFalse(ReceiverPresentationRoute.canEnterDemo(realSurfaceShown: true), "the kept surface is still shown underneath")
    }

    func testAKeptSessionKeepsTheScreenAwakeLikeTheSessionItself() {
        func awake(_ route: ReceiverPresentationRoute, settingsOpen: Bool = false) -> Bool {
            let inputs = ScreenAwakePolicy.Inputs(enabled: true, foreground: true,
                                                  watching: route.watchesMac && !settingsOpen, streaming: true)
            return ScreenAwakePolicy.decide(inputs, sinceStreaming: 0).awake
        }
        XCTAssertTrue(awake(.receiver))
        XCTAssertTrue(awake(.sessionHome), "Auto-Lock would lock the device and end the kept session")
        XCTAssertFalse(awake(.sessionHome, settingsOpen: true), "Settings lets Auto-Lock work, as in the session")
        XCTAssertFalse(awake(.idle))
        XCTAssertFalse(awake(.demo))
    }

    // MARK: Local media

    func testLocalMediaPolicyMatrix() {
        let home = keptHome()
        func policy(_ presence: ReceiverPictureInPictureLifecycle.Presence, _ presentation: ReceiverSessionPresentation,
                    pip: Bool = false) -> ReceiverLocalMediaPolicy {
            .resolve(presence: presence, presentation: presentation, pictureInPictureEngaged: pip)
        }
        XCTAssertEqual(policy(.foreground, .session), .live)
        XCTAssertEqual(policy(.foreground, home),
                       ReceiverLocalMediaPolicy(renderingPaused: true, audioSuspended: true, recoveryParked: false),
                       "Home in front: nothing shows or plays the Mac, but recovery keeps going")
        XCTAssertEqual(policy(.foreground, home, pip: true), .live, "a Picture in Picture window already up keeps showing it")
        let parked = ReceiverLocalMediaPolicy(renderingPaused: true, audioSuspended: true, recoveryParked: true)
        XCTAssertEqual(policy(.lingering, .session), parked, "the existing background linger is unchanged")
        XCTAssertEqual(policy(.lingering, home), parked)
        XCTAssertEqual(policy(.asleep, home), parked)
        XCTAssertEqual(policy(.live, .session, pip: true), .live)
        XCTAssertEqual(policy(.live, home, pip: true), .live)
    }

    // MARK: Picture in Picture

    func testHomeNeverStartsPictureInPictureButKeepsOneAlreadyUp() {
        var conditions = ReceiverPictureInPictureConditions(
            preferenceEnabled: true, systemSupported: true, rendersThroughDisplayLayer: true,
            receiverSurfaceShown: true, sessionPhase: .connected, videoEnabled: true)
        XCTAssertTrue(conditions.startsAutomaticallyFromInline)
        conditions.sessionOnHome = true
        XCTAssertFalse(conditions.startsAutomaticallyFromInline, "leaving the app from Home opens no window")
        XCTAssertTrue(conditions.hostsController, "the controller survives under Home")
        XCTAssertTrue(conditions.sustainsActiveWindow, "a window already up stays")
    }

    // MARK: Input

    func testNothingReachesTheMacFromTheSurfaceUnderHome() {
        let pv = WireProtocol.allowInputWireVersion
        XCTAssertTrue(BlockedInputAttemptPolicy.inputReachesMac(sessionLive: true, localAllow: true, macPV: pv, macState: .allowed,
                                                                surfaceInteractive: true))
        XCTAssertFalse(BlockedInputAttemptPolicy.inputReachesMac(sessionLive: true, localAllow: true, macPV: pv, macState: .allowed,
                                                                 surfaceInteractive: false))
        XCTAssertFalse(BlockedInputAttemptPolicy.inputReachesMac(sessionLive: true, localAllow: true, macPV: pv - 1, macState: .off,
                                                                 surfaceInteractive: false), "an older Mac too")
    }

    // MARK: Home rows

    func testOnlyTheSessionsMacIsConnectedAndOthersCantStartASecondSession() {
        XCTAssertEqual(HomeMacSessionRole.resolve(rowPeerID: mac, sessionMacPeerID: mac, sessionActive: true), .current)
        XCTAssertEqual(HomeMacSessionRole.resolve(rowPeerID: "MAC-B", sessionMacPeerID: mac, sessionActive: true), .otherMacInSession)
        XCTAssertEqual(HomeMacSessionRole.resolve(rowPeerID: nil, sessionMacPeerID: mac, sessionActive: true), .otherMacInSession,
                       "no pairing from Home behind a kept session")
        XCTAssertEqual(HomeMacSessionRole.resolve(rowPeerID: mac, sessionMacPeerID: nil, sessionActive: true), .otherMacInSession,
                       "recovering: the Mac isn't known, so nothing offers Connect")
        XCTAssertEqual(HomeMacSessionRole.resolve(rowPeerID: mac, sessionMacPeerID: nil, sessionActive: false), .available)
        XCTAssertEqual(HomeMacSessionRole.resolve(rowPeerID: nil, sessionMacPeerID: nil, sessionActive: false), .available)
    }
}

/// Rotating or resizing on Home doesn't reshape the Mac's display; Resume announces the latest size.
@MainActor
final class ReceiverPanelSettlerHoldTests: XCTestCase {
    private var applied: [ReceiverPanelSettler.Panel] = []
    private var connected = false

    private func makeSettler() -> ReceiverPanelSettler {
        ReceiverPanelSettler(delay: 0.05, isConnected: { [unowned self] in self.connected },
                             apply: { [unowned self] in self.applied.append($0) })
    }

    private func settle(_ seconds: TimeInterval = 0.2) {
        let done = expectation(description: "settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { done.fulfill() }
        wait(for: [done], timeout: seconds + 2)
    }

    func testHeldWhileConnectedSendsNothingThenTheLatestSizeOnRelease() {
        let settler = makeSettler()
        settler.windowChanged(points: CGSize(width: 393, height: 852), scale: 3)
        connected = true
        settler.setHeld(true)
        settler.windowChanged(points: CGSize(width: 852, height: 393), scale: 3)
        settler.windowChanged(points: CGSize(width: 600, height: 393), scale: 3)
        settle()
        XCTAssertEqual(applied.count, 1, "rotating on Home leaves the Mac's display alone")
        settler.setHeld(false)
        XCTAssertEqual(applied.count, 2, "Resume applies at once")
        XCTAssertEqual(applied.last?.wide, 1800)
        XCTAssertEqual(applied.last?.high, 1179)
    }

    func testHoldingParksASizeThatWasStillSettling() {
        let settler = makeSettler()
        settler.windowChanged(points: CGSize(width: 393, height: 852), scale: 3)
        connected = true
        settler.windowChanged(points: CGSize(width: 852, height: 393), scale: 3)
        settler.setHeld(true)
        settle()
        XCTAssertEqual(applied.count, 1)
        settler.setHeld(false)
        XCTAssertEqual(applied.map(\.wide), [1179, 2556])
    }

    func testReleaseWithNothingNewSendsNothing() {
        let settler = makeSettler()
        settler.windowChanged(points: CGSize(width: 393, height: 852), scale: 3)
        connected = true
        settler.setHeld(true)
        settler.windowChanged(points: CGSize(width: 852, height: 393), scale: 3)
        settler.windowChanged(points: CGSize(width: 393, height: 852), scale: 3)
        settler.setHeld(false)
        settle()
        XCTAssertEqual(applied.count, 1, "back at the announced size")
    }

    func testWhileDisconnectedTheHoldDoesNotDelayTheNextHello() {
        let settler = makeSettler()
        settler.setHeld(true)
        settler.windowChanged(points: CGSize(width: 393, height: 852), scale: 3)
        settler.windowChanged(points: CGSize(width: 852, height: 393), scale: 3)
        XCTAssertEqual(applied.map(\.wide), [1179, 2556])
    }
}

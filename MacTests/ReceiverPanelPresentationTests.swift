import XCTest

final class ReceiverPanelPresentationTests: XCTestCase {

    // MARK: - Display Mode picker (authoritative, never optimistic)

    private func picker(confirmed: ReceiverDisplayMode? = .mirror,
                        pending: ReceiverDisplayMode? = nil,
                        connected: Bool = true,
                        pv: Int = WireProtocol.version,
                        video: Bool = true) -> DisplayModePickerState? {
        DisplayModePickerState(confirmed: confirmed, pending: pending, connected: connected,
                               macProtocolVersion: pv, videoEnabled: video)
    }

    func testNoPickerUntilTheMacConfirmsAMode() {
        XCTAssertNil(picker(confirmed: nil))
    }

    func testPickerShowsConfirmedModeWhenNothingIsPending() throws {
        let state = try XCTUnwrap(picker(confirmed: .extend))
        XCTAssertEqual(state.selection, .extend)
        XCTAssertFalse(state.isSwitching)
        XCTAssertTrue(state.isEnabled)
    }

    func testPendingRequestShowsSwitchingAndLocksThePicker() throws {
        let state = try XCTUnwrap(picker(confirmed: .mirror, pending: .extend))
        XCTAssertEqual(state.selection, .extend)
        XCTAssertTrue(state.isSwitching)
        XCTAssertFalse(state.isEnabled)
    }

    func testPickerDisabledWhenDisconnectedOrMacTooOld() throws {
        XCTAssertFalse(try XCTUnwrap(picker(connected: false)).isEnabled)
        XCTAssertFalse(try XCTUnwrap(
            picker(pv: WireProtocol.displayModeWireVersion - 1)).isEnabled)
    }

    func testExtendDisabledWhileVideoIsOff() throws {
        XCTAssertTrue(try XCTUnwrap(picker(video: false)).extendDisabled)
        XCTAssertFalse(try XCTUnwrap(picker(video: true)).extendDisabled)
    }

    // MARK: - Connection controls

    private func connectedSession() -> ReceiverSessionState {
        var state = ReceiverSessionState()
        _ = state.connectionAdopted()
        _ = state.connectionEstablished()
        return state
    }

    func testConnectedOffersDisconnectOnly() {
        let controls = ReceiverConnectionControls(session: connectedSession(), connected: true)
        XCTAssertTrue(controls.canDisconnect)
        XCTAssertFalse(controls.canReconnect)
    }

    func testIdleOffersNeitherAction() {
        let controls = ReceiverConnectionControls(session: ReceiverSessionState(), connected: false)
        XCTAssertFalse(controls.canDisconnect)
        XCTAssertFalse(controls.canReconnect)
    }

    func testExplicitDisconnectDoesNotOfferReconnect() {
        var state = connectedSession()
        _ = state.connectionLost(reason: .explicitDisconnect)
        let controls = ReceiverConnectionControls(session: state, connected: false)
        XCTAssertFalse(controls.canReconnect, "a deliberate Disconnect is not a failed recovery")
        XCTAssertFalse(controls.canDisconnect)
    }

    func testActiveRecoveryOffersNoReconnectButFailedRecoveryDoes() {
        var state = connectedSession()
        _ = state.connectionLost(reason: .transportLost)
        XCTAssertFalse(ReceiverConnectionControls(session: state, connected: false).canReconnect)
        while state.beginReconnectAttempt() != nil { _ = state.endReconnectAttempt() }
        _ = state.exhaustRecovery()
        XCTAssertEqual(state.phase, .reconnectFailed)
        XCTAssertTrue(ReceiverConnectionControls(session: state, connected: false).canReconnect)
    }

    func testIncompatiblePeerNeverOffersReconnect() {
        var state = connectedSession()
        _ = state.connectionLost(reason: .protocolIncompatible)
        XCTAssertFalse(ReceiverConnectionControls(session: state, connected: false).canReconnect)
    }

    // MARK: - Streaming presentation

    func testCodecLabels() {
        XCTAssertEqual(ReceiverStreamingPresentation.codecLabel(.h264), "H.264")
        XCTAssertEqual(ReceiverStreamingPresentation.codecLabel(.hevc), "HEVC")
    }

    func testFPSLimitationOnlyWhenEncoderCeilingIsBelowTheRequest() {
        func state(safe: Int, requested: Int) -> MaxFPSStateUpdate {
            MaxFPSStateUpdate(preference: .standard, availableTiers: [30, 60],
                              encoderSafeFPS: safe, requestedFPS: requested,
                              effectiveFPS: min(safe, requested), reason: "")
        }
        XCTAssertNil(ReceiverStreamingPresentation.fpsLimitation(state: nil, profileLabel: "Performance"))
        XCTAssertNil(ReceiverStreamingPresentation.fpsLimitation(
            state: state(safe: 60, requested: 60), profileLabel: "Performance"))
        XCTAssertEqual(
            ReceiverStreamingPresentation.fpsLimitation(
                state: state(safe: 30, requested: 60), profileLabel: "Performance"),
            "Performance requests 60 FPS. Limited to 30 FPS at this display size.")
    }

    // MARK: - Mirror unavailable offer reaches a current-version receiver

    func testHeadlessSenderOffersUseExtendToACurrentVersionReceiver() {
        XCTAssertTrue(MirrorUnavailableOfferPolicy.shouldOffer(
            hasUsablePhysicalDisplay: false, receiverProtocolVersion: WireProtocol.version))
        XCTAssertFalse(MirrorUnavailableOfferPolicy.shouldOffer(
            hasUsablePhysicalDisplay: true, receiverProtocolVersion: WireProtocol.version),
            "usable physical display: Mirror proceeds, no offer")
    }

    func testExtendIsNeverGatedByPhysicalDisplayAvailability() {
        XCTAssertFalse(MirrorUnavailableOfferPolicy.canEnterMirror(hasUsablePhysicalDisplay: false))
        XCTAssertTrue(MirrorUnavailableOfferPolicy.canEnterMirror(hasUsablePhysicalDisplay: true))
    }
}

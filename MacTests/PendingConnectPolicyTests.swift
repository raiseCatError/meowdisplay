import XCTest

/// Issue #128: a Connect whose dial never reaches the application hello used
/// to leave no row, no status and no Cancel, while the device's Known Devices
/// row kept offering a Connect the pending session silently absorbed. It also
/// redialed forever.
final class PendingConnectPolicyTests: XCTestCase {
    private let peer = "phone-install"
    private let otherPeer = "tablet-install"

    private func session(_ id: String, deviceID: String? = nil, intended: String? = nil,
                         authenticated: Bool = false, admitted: Bool = false, failed: Bool = false,
                         status: String = "Starting…", automatic: Bool = false) -> PendingConnectPolicy.SessionSnapshot {
        .init(id: id, deviceID: deviceID, intendedPeerID: intended, authenticated: authenticated,
              admitted: admitted, failed: failed, status: status, automatic: automatic)
    }

    private func connection(_ sessions: [PendingConnectPolicy.SessionSnapshot]) -> KnownDeviceConnection {
        PendingConnectPolicy.connection(forPeerID: peer, sessions: sessions)
    }

    // MARK: - Row state

    func testNoSessionIsIdleAndOffersConnect() {
        XCTAssertEqual(connection([]), .idle)
        XCTAssertNil(connection([]).occupyingSessionID)
    }

    /// The reported case: a dial before hello now shows on the device's row,
    /// with its status, and holds the row so no absorbed Connect is offered.
    func testDialBeforeHelloShowsConnectingOnTheIntendedPeersRow() {
        let state = connection([session("wifi:Phone", intended: peer, status: "Waiting for receiver at Phone…")])
        XCTAssertEqual(state, .connecting(sessionID: "wifi:Phone", status: "Waiting for receiver at Phone…",
                                          automatic: false))
        XCTAssertEqual(state.occupyingSessionID, "wifi:Phone")
    }

    func testAutomaticAttemptIsMarkedAsSuch() {
        let state = connection([session("remote:phone", intended: peer, automatic: true)])
        XCTAssertEqual(state, .connecting(sessionID: "remote:phone", status: "Starting…", automatic: true))
    }

    func testAnotherDevicesDialDoesNotAppearOnThisRow() {
        XCTAssertEqual(connection([session("wifi:Tablet", intended: otherPeer)]), .idle)
        XCTAssertEqual(connection([session("usb:x", intended: nil)]), .idle, "an unidentified dial belongs to no row")
    }

    /// The hello proves who answered; that identity wins over the dial's aim.
    func testProvenIdentityWinsOverIntendedPeer() {
        XCTAssertEqual(connection([session("wifi:Phone", deviceID: otherPeer, intended: peer, authenticated: true)]),
                       .idle)
    }

    func testHelloWithoutAdmissionIsAwaitingApprovalNotConnected() {
        let state = connection([session("wifi:Phone", deviceID: peer, intended: peer, authenticated: true)])
        XCTAssertEqual(state, .awaitingApproval(sessionID: "wifi:Phone"))
        XCTAssertNotNil(state.occupyingSessionID)
    }

    func testAdmittedSessionIsConnected() {
        XCTAssertEqual(connection([session("wifi:Phone", deviceID: peer, authenticated: true, admitted: true)]),
                       .connected(sessionID: "wifi:Phone"))
    }

    /// Declined or blocked after the hello: the row used to say "Connected"
    /// (green, no Connect). It shows why instead, and offers Connect again.
    func testDeclinedSessionIsNotConnectedAndOffersConnect() {
        let declined = session("wifi:Phone", deviceID: peer, authenticated: true, failed: true,
                               status: "Phone declined the connection.")
        let state = connection([declined])
        XCTAssertEqual(state, .failed(sessionID: "wifi:Phone", status: "Phone declined the connection."))
        XCTAssertNil(state.occupyingSessionID)
    }

    func testLiveSessionWinsOverFailedCorpseAndPendingDial() {
        let corpse = session("usb:x", deviceID: peer, authenticated: true, failed: true, status: "Failed")
        let dialing = session("remote:phone", intended: peer)
        let live = session("wifi:Phone", deviceID: peer, authenticated: true, admitted: true)
        XCTAssertEqual(connection([corpse, dialing, live]), .connected(sessionID: "wifi:Phone"))
        XCTAssertEqual(connection([corpse, dialing]),
                       .connecting(sessionID: "remote:phone", status: "Starting…", automatic: false))
    }

    func testNewestFailureSpeaks() {
        let older = session("usb:x", intended: peer, failed: true, status: "old")
        let newer = session("wifi:Phone", intended: peer, failed: true, status: "new")
        XCTAssertEqual(connection([older, newer]), .failed(sessionID: "wifi:Phone", status: "new"))
    }

    // MARK: - Bounded first connect

    func testOnlyExplicitAttemptsAreBounded() {
        XCTAssertTrue(PendingConnectPolicy.boundsFirstConnect(userInitiated: true, awaitingWake: false))
        XCTAssertFalse(PendingConnectPolicy.boundsFirstConnect(userInitiated: false, awaitingWake: false))
        XCTAssertFalse(PendingConnectPolicy.boundsFirstConnect(userInitiated: true, awaitingWake: true),
                       "Wake & Connect keeps redialing while the Mac wakes")
    }

    func testDeadlineGivesUpOnlyBeforeHelloAndOnlyOnce() {
        XCTAssertTrue(PendingConnectPolicy.shouldGiveUp(authenticated: false, failed: false))
        XCTAssertFalse(PendingConnectPolicy.shouldGiveUp(authenticated: true, failed: false),
                       "a session waiting for approval has its own 60 s receiver timeout")
        XCTAssertFalse(PendingConnectPolicy.shouldGiveUp(authenticated: false, failed: true),
                       "an attempt that already failed keeps its own reason")
    }

    func testLimitIsSeveralDialsButBounded() {
        // Each dial has a 5 s deadline and redials back off to 10 s.
        XCTAssertGreaterThanOrEqual(PendingConnectPolicy.explicitFirstConnectLimit, 30)
        XCTAssertLessThanOrEqual(PendingConnectPolicy.explicitFirstConnectLimit, 60)
    }

    func testTimeoutStatusKeepsTheLastActionableReason() {
        let blocked = "macOS is blocking MeowDisplay from connecting to devices."
        let text = PendingConnectPolicy.timeoutStatus(name: "Phone", lastStatus: blocked)
        XCTAssertTrue(text.hasPrefix("Couldn't reach Phone."))
        XCTAssertTrue(text.contains(blocked))

        let plain = PendingConnectPolicy.timeoutStatus(name: "Phone", lastStatus: "Starting…")
        XCTAssertFalse(plain.contains("Last status"))
    }

    // MARK: - Row actions

    private func actions(_ connection: KnownDeviceConnection, hasTarget: Bool = true) -> KnownDeviceRowActions {
        KnownDeviceRowActions.actions(for: connection, hasTarget: hasTarget)
    }

    func testIdleRowOffersPlainConnectOnly() {
        XCTAssertEqual(actions(.idle), .init(offersConnect: true, connectReplacesAutomaticAttempt: false,
                                             offersCancel: false))
    }

    func testFailedRowOffersConnectAgain() {
        let state = KnownDeviceConnection.failed(sessionID: "wifi:Phone", status: "Declined")
        XCTAssertEqual(actions(state), .init(offersConnect: true, connectReplacesAutomaticAttempt: false,
                                             offersCancel: false))
    }

    func testIdleOrFailedRowWithoutARouteOffersNothing() {
        let none = KnownDeviceRowActions(offersConnect: false, connectReplacesAutomaticAttempt: false,
                                         offersCancel: false)
        XCTAssertEqual(actions(.idle, hasTarget: false), none)
        XCTAssertEqual(actions(.failed(sessionID: "x", status: "Declined"), hasTarget: false), none)
    }

    /// Issue #128: the explicit Connect must stay reachable while this Mac's
    /// own automatic attempt is still dialing.
    func testAutomaticAttemptOffersConnectNowAndCancel() {
        let state = KnownDeviceConnection.connecting(sessionID: "wifi:Phone", status: "Starting…", automatic: true)
        XCTAssertEqual(actions(state), .init(offersConnect: true, connectReplacesAutomaticAttempt: true,
                                             offersCancel: true))
    }

    func testAutomaticAttemptWithoutARouteStillOffersCancelOnly() {
        let state = KnownDeviceConnection.connecting(sessionID: "wifi:Phone", status: "Starting…", automatic: true)
        XCTAssertEqual(actions(state, hasTarget: false),
                       .init(offersConnect: false, connectReplacesAutomaticAttempt: false, offersCancel: true))
    }

    /// An explicit attempt in progress must not get a second Connect: it would
    /// be absorbed or duplicate the receiver's prompt.
    func testExplicitAttemptOffersCancelOnly() {
        let state = KnownDeviceConnection.connecting(sessionID: "wifi:Phone", status: "Starting…", automatic: false)
        XCTAssertEqual(actions(state), .init(offersConnect: false, connectReplacesAutomaticAttempt: false,
                                             offersCancel: true))
    }

    func testAwaitingApprovalAndConnectedRowsOfferNoConnectOrCancel() {
        let none = KnownDeviceRowActions(offersConnect: false, connectReplacesAutomaticAttempt: false,
                                         offersCancel: false)
        XCTAssertEqual(actions(.awaitingApproval(sessionID: "wifi:Phone")), none)
        XCTAssertEqual(actions(.connected(sessionID: "wifi:Phone")), none)
    }

    func testRowResolvesItsRouteOnlyWhereConnectCanBeOffered() {
        XCTAssertTrue(KnownDeviceRowActions.needsTarget(for: .idle))
        XCTAssertTrue(KnownDeviceRowActions.needsTarget(for: .failed(sessionID: "x", status: "Declined")))
        XCTAssertTrue(KnownDeviceRowActions.needsTarget(
            for: .connecting(sessionID: "x", status: "Starting…", automatic: true)))
        XCTAssertFalse(KnownDeviceRowActions.needsTarget(
            for: .connecting(sessionID: "x", status: "Starting…", automatic: false)))
        XCTAssertFalse(KnownDeviceRowActions.needsTarget(for: .awaitingApproval(sessionID: "x")))
        XCTAssertFalse(KnownDeviceRowActions.needsTarget(for: .connected(sessionID: "x")))
    }

    /// The row's automatic flag comes from the snapshot, so a Connect Now
    /// is offered exactly where `ExplicitConnectAdmission` would replace.
    func testRowStateFromAutomaticSnapshotOffersConnectNow() {
        let state = connection([session("remote:phone", intended: peer, automatic: true)])
        XCTAssertTrue(actions(state).connectReplacesAutomaticAttempt)
        let explicit = connection([session("remote:phone", intended: peer, automatic: false)])
        XCTAssertFalse(actions(explicit).offersConnect)
    }
}

import XCTest

/// The unified Mac app's sender and receiver roles keep separate approval
/// policy, per-Mac overrides and peer routing data. The original bug: both
/// roles read and wrote one "Automatically Allow Connections" key, so the
/// sender's (on by default) silently auto-approved any paired Mac that
/// connected to this Mac as a display.
///
/// `.sender` and a receiver-only app's receiver role share the original keys,
/// so the iPhone/iPad app and the standalone Mac Receiver are unchanged.
final class RolePreferencesIsolationTests: XCTestCase {
    private let sender = RolePreferences.sender
    private let displayRole = RolePreferences(isSeparateReceiverRole: true)
    private let receiverOnlyApp = RolePreferences(isSeparateReceiverRole: false)

    private var defaults: UserDefaults!
    private var suiteName: String!
    private var standardPeers: [String] = []

    override func setUp() {
        super.setUp()
        suiteName = "RolePreferencesIsolationTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        for peer in standardPeers {
            for role in [sender, displayRole] {
                RemoteEndpointStore.removeEndpoint(forPeerID: peer, role: role)
                WakeMetadataStore.removeMetadata(forPeerID: peer, role: role)
            }
        }
        super.tearDown()
    }

    private func standardPeer() -> String {
        let peer = "role-isolation-\(UUID().uuidString)"
        standardPeers.append(peer)
        return peer
    }

    // MARK: - Automatically Allow Connections

    func testSenderAutomaticApprovalNeverApprovesTheDisplayRole() {
        IncomingSessionPolicyStore.setAutomaticallyAllow(true, role: sender, defaults: defaults)

        XCTAssertFalse(IncomingSessionPolicyStore.automaticallyAllow(role: displayRole, defaults: defaults))
        XCTAssertEqual(IncomingSessionPolicyStore.decision(peerID: "paired-mac", intent: .automatic,
                                                           role: displayRole, defaults: defaults),
                       .decline, "a sending Mac's background attempt must not be admitted silently")
        XCTAssertEqual(IncomingSessionPolicyStore.decision(peerID: "paired-mac", intent: .manual,
                                                           role: displayRole, defaults: defaults),
                       .askUser, "an explicit request asks this Mac's user")
    }

    func testSenderDefaultOnDoesNotApproveTheDisplayRole() {
        // A 1.20.0 install never wrote the key: the sender's ON default.
        XCTAssertTrue(IncomingSessionPolicyStore.automaticallyAllow(role: sender, defaults: defaults))
        XCTAssertEqual(IncomingSessionPolicyStore.decision(peerID: "paired-mac", intent: .automatic,
                                                           role: displayRole, defaults: defaults), .decline)
    }

    func testDisplayRoleAutomaticApprovalNeverChangesTheSender() {
        IncomingSessionPolicyStore.setAutomaticallyAllow(false, role: sender, defaults: defaults)
        IncomingSessionPolicyStore.setAutomaticallyAllow(true, role: displayRole, defaults: defaults)

        XCTAssertFalse(IncomingSessionPolicyStore.automaticallyAllow(role: sender, defaults: defaults))
        XCTAssertEqual(IncomingSessionPolicyStore.decision(peerID: "iphone", intent: .automatic,
                                                           role: sender, defaults: defaults), .decline)
        XCTAssertEqual(IncomingSessionPolicyStore.decision(peerID: "mac", intent: .automatic,
                                                           role: displayRole, defaults: defaults), .accept)
    }

    func testDefaults() {
        XCTAssertTrue(IncomingSessionPolicyStore.automaticallyAllowDefault(sender), "sender unchanged")
        XCTAssertTrue(IncomingSessionPolicyStore.automaticallyAllowDefault(receiverOnlyApp),
                      "iPhone/iPad and standalone Mac Receiver unchanged")
        XCTAssertFalse(IncomingSessionPolicyStore.automaticallyAllowDefault(displayRole),
                       "the unified app's display role asks until the user opts in")
    }

    func testKeyNames() {
        XCTAssertEqual(IncomingSessionPolicyStore.automaticallyAllowKey(sender), "incomingSessionAutomaticallyAllow",
                       "existing sender preferences are read under their original name")
        XCTAssertEqual(IncomingSessionPolicyStore.automaticallyAllowKey(receiverOnlyApp),
                       "incomingSessionAutomaticallyAllow")
        XCTAssertEqual(IncomingSessionPolicyStore.automaticallyAllowKey(displayRole),
                       "receiver.incomingSessionAutomaticallyAllow")
    }

    func testExistingPreferencesStayWithTheSenderAndReceiverOnlyApps() {
        // What an existing install has on disk (written by 1.20.0, or by the
        // iPhone app / standalone receiver in their own domains).
        defaults.set(false, forKey: "incomingSessionAutomaticallyAllow")
        defaults.set(["peer": "blocked"], forKey: "incomingSessionPeerPolicy.v1")

        for role in [sender, receiverOnlyApp] {
            XCTAssertFalse(IncomingSessionPolicyStore.automaticallyAllow(role: role, defaults: defaults))
            XCTAssertEqual(IncomingSessionPolicyStore.policy(peerID: "peer", role: role, defaults: defaults), .blocked)
        }
        XCTAssertNil(IncomingSessionPolicyStore.policy(peerID: "peer", role: displayRole, defaults: defaults))
        XCTAssertFalse(IncomingSessionPolicyStore.automaticallyAllow(role: displayRole, defaults: defaults))
    }

    // MARK: - Per-Mac overrides

    /// A peer picks the install id it pairs with, so the same id can be
    /// pinned in both roles: its overrides must still not cross.
    func testPerPeerPolicyIsPerRoleEvenForTheSamePeerID() {
        IncomingSessionPolicyStore.setAutomaticallyAllow(false, role: displayRole, defaults: defaults)
        IncomingSessionPolicyStore.setPolicy(.alwaysAllow, peerID: "same-id", role: sender, defaults: defaults)

        XCTAssertNil(IncomingSessionPolicyStore.policy(peerID: "same-id", role: displayRole, defaults: defaults))
        XCTAssertEqual(IncomingSessionPolicyStore.decision(peerID: "same-id", intent: .automatic,
                                                           role: displayRole, defaults: defaults), .decline)

        IncomingSessionPolicyStore.setPolicy(.blocked, peerID: "same-id", role: displayRole, defaults: defaults)
        XCTAssertEqual(IncomingSessionPolicyStore.policy(peerID: "same-id", role: sender, defaults: defaults),
                       .alwaysAllow, "blocking a Mac as a display doesn't block it as a receiver")

        IncomingSessionPolicyStore.removePolicy(peerID: "same-id", role: sender, defaults: defaults)
        XCTAssertEqual(IncomingSessionPolicyStore.policy(peerID: "same-id", role: displayRole, defaults: defaults),
                       .blocked, "forgetting it in the sender doesn't lift the display role's block")
    }

    // MARK: - Role switching and relaunch

    func testSwitchingRolesAndRelaunchingNeverRestoreADisplayApproval() {
        IncomingSessionPolicyStore.setAutomaticallyAllow(true, role: sender, defaults: defaults)
        IncomingSessionPolicyStore.setPolicy(.alwaysAllow, peerID: "mac", role: sender, defaults: defaults)

        var state = MacAppRoleState(defaults: defaults)
        for enabled in [true, false, true, false, true] {
            _ = state.setReceiverEnabled(enabled, defaults: defaults)
            XCTAssertEqual(IncomingSessionPolicyStore.decision(peerID: "mac", intent: .automatic,
                                                               role: displayRole, defaults: defaults), .decline)
        }

        let relaunched = UserDefaults(suiteName: suiteName)!
        XCTAssertTrue(MacAppRoleState(defaults: relaunched).receiverEnabled)
        XCTAssertEqual(IncomingSessionPolicyStore.decision(peerID: "mac", intent: .automatic,
                                                           role: displayRole, defaults: relaunched), .decline)
        XCTAssertTrue(IncomingSessionPolicyStore.automaticallyAllow(role: sender, defaults: relaunched),
                      "the sender keeps its own choice")
    }

    // MARK: - Authorization entry points

    func testLegacySenderAdmissionUsesTheDisplayRolePolicy() {
        IncomingSessionPolicyStore.setAutomaticallyAllow(true, role: sender, defaults: defaults)
        XCTAssertFalse(ReceiverSessionAdmission.admitsLegacySender(peerID: "old-mac", role: displayRole,
                                                                   defaults: defaults),
                       "a pre-pv-21 Mac can't be asked, so it's refused rather than auto-admitted")

        IncomingSessionPolicyStore.setAutomaticallyAllow(true, role: displayRole, defaults: defaults)
        XCTAssertTrue(ReceiverSessionAdmission.admitsLegacySender(peerID: "old-mac", role: displayRole,
                                                                  defaults: defaults))
    }

    func testReceiverConnectRequestsUseTheSenderPolicy() {
        IncomingSessionPolicyStore.setAutomaticallyAllow(false, role: sender, defaults: defaults)
        IncomingSessionPolicyStore.setAutomaticallyAllow(true, role: displayRole, defaults: defaults)
        XCTAssertEqual(ReceiverRequestAdmission.decide(peerID: "ipad", intent: .automatic, existing: nil,
                                                       defaults: defaults), .drop)
        XCTAssertEqual(ReceiverRequestAdmission.decide(peerID: "ipad", intent: .manual, existing: nil,
                                                       defaults: defaults), .start(needsSenderApproval: true))
    }

    // MARK: - Routing hints

    func testRemoteEndpointsArePerRole() {
        let peer = standardPeer()
        RemoteEndpointStore.setEndpoint("100.64.0.1", port: 9001, forPeerID: peer, role: sender)

        XCTAssertNil(RemoteEndpointStore.endpoint(forPeerID: peer, role: displayRole))
        XCTAssertFalse(RemoteEndpointStore.allPeerIDs(role: displayRole).contains(peer))
        XCTAssertNil(RemoteEndpointStore.connectRequestEndpoint(forPeerID: peer, role: displayRole),
                     "the display role never knocks on an address the sender saved")

        RemoteEndpointStore.setEndpoint("100.64.0.2", port: 9001, forPeerID: peer, role: displayRole)
        XCTAssertEqual(RemoteEndpointStore.endpoint(forPeerID: peer, role: sender)?.host, "100.64.0.1",
                       "pairing the display role can't redirect the sender's dial")
        RemoteEndpointStore.removeEndpoint(forPeerID: peer, role: sender)
        XCTAssertEqual(RemoteEndpointStore.endpoint(forPeerID: peer, role: displayRole)?.host, "100.64.0.2")
        XCTAssertFalse(RemoteEndpointStore.allPeerIDs(role: sender).contains(peer),
                       "the sender never auto-connects to a Mac the display role saved")
    }

    func testWakeMetadataIsPerRole() {
        let peer = standardPeer()
        let metadata = WakeMetadata(macAddress: "aa:bb:cc:dd:ee:ff", interfaceName: "en0",
                                    ipv4: "192.168.1.5", subnetMask: "255.255.255.0",
                                    broadcastAddress: "192.168.1.255", updatedAt: Date())
        WakeMetadataStore.setMetadata(metadata, forPeerID: peer, role: displayRole)
        XCTAssertNil(WakeMetadataStore.metadata(forPeerID: peer, role: sender))
        WakeMetadataStore.removeMetadata(forPeerID: peer, role: sender)
        XCTAssertEqual(WakeMetadataStore.metadata(forPeerID: peer, role: displayRole), metadata)
    }

    func testPairingRecordsHintsInTheTrustNamespacesRole() {
        XCTAssertEqual(RolePreferences(trustNamespace: .standard), sender)
        XCTAssertEqual(RolePreferences(trustNamespace: .macReceiverRole), displayRole)
        XCTAssertEqual(RemoteEndpointStoreHints(role: displayRole).role, displayRole)
    }

    func testThisTestBundleIsAReceiverOnlyConfiguration() {
        // No `MeowDisplayReceiverRoleTrust` in a hostless test bundle: the
        // receiver role resolves to the original keys, as on iPhone.
        XCTAssertEqual(RolePreferences.receiverRole, receiverOnlyApp)
    }
}

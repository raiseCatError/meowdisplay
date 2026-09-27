import XCTest
import Network
import Security

/// The Mac's TCP/QUIC choice inside a network route
/// (`Mac/TransportProtocolSelection.swift`): selection, the no-downgrade
/// rule, anti-thrash stickiness, cooldown, and the capability/preference
/// stores. Pure — no network.
final class TransportProtocolSelectionTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "TransportProtocolSelectionTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func inputs(_ preference: NetworkTransportPreference,
                        support: PeerQUICSupport = .authenticated,
                        route: NetworkRouteKind = .local,
                        cooldown: Bool = false,
                        local: Bool = true) -> TransportProtocolSelector.Inputs {
        .init(preference: preference, localQUICAvailable: local, peerSupport: support,
              routeKind: route, cooldownActive: cooldown)
    }

    // MARK: - Selection

    func testAutoWithoutPeerCapabilityUsesTCP() {
        XCTAssertEqual(TransportProtocolSelector().decide(inputs(.auto, support: .unknown)), .tcp)
        XCTAssertEqual(TransportProtocolSelector().decide(inputs(.auto, support: .incompatible)), .tcp)
    }

    func testAutoWithCapabilityAttemptsQUIC() {
        XCTAssertEqual(TransportProtocolSelector().decide(inputs(.auto)), .quic)
    }

    func testAutoDuringCooldownUsesTCP() {
        XCTAssertEqual(TransportProtocolSelector().decide(inputs(.auto, cooldown: true)), .tcp)
    }

    func testAutoWithoutLocalRuntimeSupportUsesTCP() {
        XCTAssertEqual(TransportProtocolSelector().decide(inputs(.auto, local: false)), .tcp)
    }

    func testExplicitTCPAlwaysUsesTCP() {
        for support in [PeerQUICSupport.authenticated, .discoveryHint, .unknown, .incompatible] {
            XCTAssertEqual(TransportProtocolSelector().decide(inputs(.tcp, support: support)), .tcp)
        }
    }

    func testExplicitQUICWhenSupportedUsesQUICEvenInCooldown() {
        XCTAssertEqual(TransportProtocolSelector().decide(inputs(.quic)), .quic)
        XCTAssertEqual(TransportProtocolSelector().decide(inputs(.quic, cooldown: true)), .quic)
    }

    func testExplicitQUICWhenUnsupportedIsUnavailableNeverTCP() {
        for decision in [
            TransportProtocolSelector().decide(inputs(.quic, support: .unknown)),
            TransportProtocolSelector().decide(inputs(.quic, support: .incompatible)),
            TransportProtocolSelector().decide(inputs(.quic, local: false)),
            TransportProtocolSelector().decide(inputs(.quic, support: .discoveryHint, route: .remote)),
        ] {
            guard case .unavailable = decision else {
                return XCTFail("explicit QUIC must never resolve to \(decision)")
            }
        }
    }

    func testDiscoveryHintAllowsAQUICAttemptOnlyOnALocalRoute() {
        XCTAssertEqual(TransportProtocolSelector().decide(inputs(.auto, support: .discoveryHint, route: .local)), .quic)
        // Remote Access: TCP first until an authenticated session proves QUIC.
        XCTAssertEqual(TransportProtocolSelector().decide(inputs(.auto, support: .discoveryHint, route: .remote)), .tcp)
        XCTAssertEqual(TransportProtocolSelector().decide(inputs(.auto, support: .authenticated, route: .remote)), .quic)
    }

    func testRouteKindFromEndpoint() {
        XCTAssertEqual(NetworkRouteKind(endpoint: .service(name: "x", type: "_opensidecar._tcp", domain: "local.", interface: nil)), .local)
        XCTAssertEqual(NetworkRouteKind(endpoint: .hostPort(host: "100.64.0.1", port: 9001)), .remote)
    }

    // MARK: - Failure policy / no downgrade

    func testReachabilityFailureInAutoFallsBackToStickyTCP() {
        var selector = TransportProtocolSelector()
        XCTAssertEqual(selector.quicFailed(.reachability, preference: .auto), .fallbackToTCP)
        XCTAssertEqual(selector.sticky, .tcp)
        // Even with capability and no cooldown, the rest of the session is TCP.
        XCTAssertEqual(selector.decide(inputs(.auto)), .tcp)
    }

    func testSecurityFailureNeverFallsBack() {
        for preference in NetworkTransportPreference.allCases where preference != .tcp {
            var selector = TransportProtocolSelector()
            XCTAssertEqual(selector.quicFailed(.security, preference: preference), .stop(.security))
            XCTAssertEqual(selector.quicFailed(.security, preference: preference, established: true), .stop(.security))
            XCTAssertNil(selector.sticky)
        }
    }

    func testProtocolViolationNeverFallsBack() {
        var selector = TransportProtocolSelector()
        XCTAssertEqual(selector.quicFailed(.protocolViolation, preference: .auto), .stop(.protocolViolation))
        XCTAssertEqual(selector.quicFailed(.protocolViolation, preference: .auto, established: true),
                       .stop(.protocolViolation))
    }

    func testIndeterminateFailureRetriesQUICInsteadOfDowngrading() {
        var selector = TransportProtocolSelector()
        XCTAssertEqual(selector.quicFailed(.indeterminate, preference: .auto), .retryQUIC)
        XCTAssertNil(selector.sticky)
        XCTAssertEqual(selector.decide(inputs(.auto)), .quic)
    }

    func testExplicitQUICNeverFallsBackOnReachability() {
        var selector = TransportProtocolSelector()
        XCTAssertEqual(selector.quicFailed(.reachability, preference: .quic), .retryQUIC)
        XCTAssertEqual(selector.decide(inputs(.quic)), .quic)
    }

    func testFirstLiveFailureGetsOneRecoveryThenReachabilityFailureFallsBack() {
        var selector = TransportProtocolSelector()
        selector.established(.quic, preference: .auto)
        XCTAssertEqual(selector.sticky, .quic)
        // Live failure: one QUIC recovery attempt.
        XCTAssertEqual(selector.quicFailed(.reachability, preference: .auto, established: true), .retryQUIC)
        XCTAssertTrue(selector.inLiveRecovery)
        XCTAssertEqual(selector.decide(inputs(.auto)), .quic)
        // The recovery dial fails for reachability: cooldown + TCP, sticky.
        XCTAssertEqual(selector.quicFailed(.reachability, preference: .auto), .fallbackToTCP)
        XCTAssertFalse(selector.inLiveRecovery)
        XCTAssertEqual(selector.decide(inputs(.auto)), .tcp)
    }

    func testSuccessfulRecoveryStaysQUIC() {
        var selector = TransportProtocolSelector()
        selector.established(.quic, preference: .auto)
        selector.liveQUICLost()
        XCTAssertEqual(selector.decide(inputs(.auto)), .quic)
        selector.established(.quic, preference: .auto)
        XCTAssertFalse(selector.inLiveRecovery)
        XCTAssertEqual(selector.sticky, .quic)
    }

    /// No metric-driven switching exists: once committed, repeated decisions
    /// with any inputs never flip protocol inside the logical session.
    func testCommittedProtocolNeverThrashes() {
        var tcpSession = TransportProtocolSelector()
        tcpSession.established(.tcp, preference: .auto)
        for _ in 0..<50 {
            XCTAssertEqual(tcpSession.decide(inputs(.auto)), .tcp)
            XCTAssertEqual(tcpSession.decide(inputs(.auto, cooldown: true)), .tcp)
        }
        var quicSession = TransportProtocolSelector()
        quicSession.established(.quic, preference: .auto)
        for _ in 0..<50 {
            XCTAssertEqual(quicSession.decide(inputs(.auto, cooldown: true)), .quic)
        }
    }

    func testRouteChangeReRunsSelection() {
        var selector = TransportProtocolSelector()
        _ = selector.quicFailed(.reachability, preference: .auto)
        XCTAssertEqual(selector.decide(inputs(.auto)), .tcp)
        selector.routeChanged()
        XCTAssertNil(selector.sticky)
        XCTAssertEqual(selector.decide(inputs(.auto)), .quic)
    }

    // MARK: - Live preference changes

    func testSelectingAutoKeepsTheHealthyCurrentProtocol() {
        var selector = TransportProtocolSelector()
        XCTAssertNil(selector.preferenceChanged(to: .auto, current: .quic))
        XCTAssertEqual(selector.decide(inputs(.auto, cooldown: true)), .quic)
        var tcp = TransportProtocolSelector()
        XCTAssertNil(tcp.preferenceChanged(to: .auto, current: .tcp))
        XCTAssertEqual(tcp.decide(inputs(.auto)), .tcp)
    }

    func testExplicitChoiceMigratesOnlyWhenTheProtocolDiffers() {
        var selector = TransportProtocolSelector()
        XCTAssertEqual(selector.preferenceChanged(to: .tcp, current: .quic), .tcp)
        XCTAssertNil(selector.preferenceChanged(to: .tcp, current: .tcp))
        XCTAssertEqual(selector.preferenceChanged(to: .quic, current: .tcp), .quic)
        XCTAssertNil(selector.preferenceChanged(to: .quic, current: .quic))
        XCTAssertNil(selector.preferenceChanged(to: .quic, current: nil))
    }

    func testRapidPreferenceChangesLeaveOneConsistentDecision() {
        var selector = TransportProtocolSelector()
        var current: NetworkTransportProtocol = .quic
        for preference in [NetworkTransportPreference.tcp, .quic, .tcp, .auto, .quic, .tcp, .auto] {
            if let target = selector.preferenceChanged(to: preference, current: current) {
                current = target
            }
            let decision = selector.decide(inputs(preference))
            switch preference {
            case .tcp: XCTAssertEqual(decision, .tcp)
            case .quic: XCTAssertEqual(decision, .quic)
            case .auto: XCTAssertEqual(decision, current == .quic ? .quic : .tcp)
            }
        }
    }

    // MARK: - Failure classification

    func testTLSErrorsClassifyAsSecurity() {
        XCTAssertEqual(QUICFailureClassifier.classify(.tls(errSSLBadCert)), .security)
        XCTAssertEqual(QUICFailureClassifier.classify(.tls(errSSLPeerCertUnknown)), .security)
        XCTAssertEqual(QUICFailureClassifier.classify(.tls(errSSLHandshakeFail)), .security)
    }

    func testOrdinaryNetworkErrorsClassifyAsReachability() {
        for code in [POSIXErrorCode.ECONNREFUSED, .ENETUNREACH, .EHOSTUNREACH, .ETIMEDOUT, .ENETDOWN] {
            XCTAssertEqual(QUICFailureClassifier.classify(.posix(code)), .reachability, "\(code)")
        }
    }

    func testAmbiguousErrorsAreNeverReachability() {
        // ENOTCONN is how a server-side certificate rejection reaches the
        // dialing QUIC group — it must never read as "unreachable".
        for code in [POSIXErrorCode.ENOTCONN, .ECONNRESET, .ECONNABORTED, .EPROTO, .EBADMSG, .EPERM] {
            XCTAssertEqual(QUICFailureClassifier.classify(.posix(code)), .indeterminate, "\(code)")
        }
    }

    func testReachabilityIsNeverBelievedAfterThePeerWasVerified() {
        XCTAssertEqual(QUICFailureClassifier.refine(.reachability, peerVerified: false), .reachability)
        XCTAssertEqual(QUICFailureClassifier.refine(.reachability, peerVerified: true), .indeterminate)
        XCTAssertEqual(QUICFailureClassifier.refine(.security, peerVerified: true), .security)
        XCTAssertEqual(QUICFailureClassifier.refine(.protocolViolation, peerVerified: false), .protocolViolation)
        var selector = TransportProtocolSelector()
        let observed = QUICFailureClassifier.refine(QUICFailureClassifier.classify(.posix(.ENETDOWN)), peerVerified: true)
        XCTAssertEqual(selector.quicFailed(observed, preference: .auto), .retryQUIC, "no TCP fallback")
    }

    // MARK: - Stores

    func testAuthenticatedCapabilityIsRememberedAndTransientAbsenceIsNot() {
        let peer = "peer-\(UUID().uuidString)"
        XCTAssertEqual(PeerQUICCapabilityStore.support(peerID: peer, defaults: defaults), .unknown)
        PeerQUICCapabilityStore.recordAuthenticatedHello(
            QUICPeerCapability(transports: ["tcp", "quic"], quicVersion: 1), peerID: peer, defaults: defaults)
        XCTAssertEqual(PeerQUICCapabilityStore.support(peerID: peer, defaults: defaults), .authenticated)
        // A later hello without QUIC (listener down for a moment) does not
        // erase what was learned.
        PeerQUICCapabilityStore.recordAuthenticatedHello(
            QUICPeerCapability(transports: ["tcp"], quicVersion: nil), peerID: peer, defaults: defaults)
        XCTAssertEqual(PeerQUICCapabilityStore.support(peerID: peer, defaults: defaults), .authenticated)
    }

    func testIncompatibleQUICVersionDisablesSelection() {
        let peer = "peer-\(UUID().uuidString)"
        PeerQUICCapabilityStore.recordAuthenticatedHello(
            QUICPeerCapability(transports: ["tcp", "quic"], quicVersion: 2), peerID: peer, defaults: defaults)
        XCTAssertEqual(PeerQUICCapabilityStore.support(peerID: peer, defaults: defaults), .incompatible)
        XCTAssertEqual(TransportProtocolSelector().decide(inputs(.auto, support: .incompatible)), .tcp)
    }

    func testBonjourHintNeverPersistsCapabilityOrTrust() {
        let peer = "peer-\(UUID().uuidString)"
        let hints = QUICDiscoveryHintStore()
        let hint = QUICDiscoveryHint(txt: ["id": peer, "qv": "1"])!
        hints.replaceAll([.init(hint: hint, endpoint: .hostPort(host: "10.0.0.2", port: 9001))])
        XCTAssertEqual(TransportProtocolInputsResolver.peerSupport(
            peerID: peer, routeKind: .local, defaults: defaults, hints: hints), .discoveryHint)
        XCTAssertEqual(TransportProtocolInputsResolver.peerSupport(
            peerID: peer, routeKind: .remote, defaults: defaults, hints: hints), .unknown)
        XCTAssertEqual(PeerQUICCapabilityStore.support(peerID: peer, defaults: defaults), .unknown)
    }

    func testQUICEndpointMapping() {
        let hints = QUICDiscoveryHintStore()
        let remote = TransportProtocolInputsResolver.quicEndpoint(
            for: .hostPort(host: "100.64.0.9", port: 9001), peerID: "p", hints: hints)
        XCTAssertEqual(remote, .hostPort(host: "100.64.0.9", port: 9001))
        let service = TransportProtocolInputsResolver.quicEndpoint(
            for: .service(name: "iPad", type: "_opensidecar._tcp", domain: "local.", interface: nil),
            peerID: "p", hints: hints)
        XCTAssertEqual(service, .service(name: "iPad", type: QUICTransport.bonjourServiceType,
                                         domain: "local.", interface: nil))
        let browsed = NWEndpoint.service(name: "iPad (2)", type: QUICTransport.bonjourServiceType,
                                         domain: "local.", interface: nil)
        hints.replaceAll([.init(hint: QUICDiscoveryHint(txt: ["id": "p", "qv": "1"])!, endpoint: browsed)])
        XCTAssertEqual(TransportProtocolInputsResolver.quicEndpoint(
            for: .service(name: "iPad", type: "_opensidecar._tcp", domain: "local.", interface: nil),
            peerID: "p", hints: hints), browsed)
    }

    func testCooldownIsKeyedByPeerAndRouteAndExpires() {
        let store = QUICCooldownStore(duration: 600)
        let now = Date()
        store.start(peerID: "a", routeKind: .local, now: now)
        XCTAssertTrue(store.isActive(peerID: "a", routeKind: .local, now: now.addingTimeInterval(599)))
        XCTAssertFalse(store.isActive(peerID: "a", routeKind: .local, now: now.addingTimeInterval(601)))
        XCTAssertFalse(store.isActive(peerID: "a", routeKind: .remote, now: now))
        XCTAssertFalse(store.isActive(peerID: "b", routeKind: .local, now: now))
        store.clear(peerID: "a")
        XCTAssertFalse(store.isActive(peerID: "a", routeKind: .local, now: now))
        XCTAssertEqual(QUICCooldownStore.defaultDuration, 600)
    }

    func testPreferenceDefaultsToAutoAndPersists() {
        let peer = "peer-\(UUID().uuidString)"
        XCTAssertEqual(NetworkTransportPreferenceStore.load(peerID: peer, defaults: defaults), .auto)
        NetworkTransportPreferenceStore.save(.tcp, peerID: peer, defaults: defaults)
        XCTAssertEqual(NetworkTransportPreferenceStore.load(peerID: peer, defaults: defaults), .tcp)
        NetworkTransportPreferenceStore.save(.auto, peerID: peer, defaults: defaults)
        XCTAssertNil(defaults.object(forKey: NetworkTransportPreferenceStore.key(peerID: peer)))
    }

    func testForgetRemovesEveryNetworkTransportRecordForThatPeerOnly() {
        let forgotten = "peer-\(UUID().uuidString)"
        let kept = "peer-\(UUID().uuidString)"
        let cooldown = QUICCooldownStore()
        let hints = QUICDiscoveryHintStore()
        for peer in [forgotten, kept] {
            NetworkTransportPreferenceStore.save(.quic, peerID: peer, defaults: defaults)
            PeerQUICCapabilityStore.recordAuthenticatedHello(
                QUICPeerCapability(transports: ["quic"], quicVersion: 1), peerID: peer, defaults: defaults)
            cooldown.start(peerID: peer, routeKind: .local)
        }
        hints.replaceAll([forgotten, kept].map {
            .init(hint: QUICDiscoveryHint(txt: ["id": $0, "qv": "1"])!, endpoint: .hostPort(host: "10.0.0.1", port: 9001))
        })
        let defaults = self.defaults!
        ForgetDeviceAction.perform(
            peerID: forgotten, forgetTrust: { _ in }, removeRemoteEndpoint: { _ in },
            removeWakeMetadata: { _ in },
            removeNetworkTransportState: {
                NetworkTransportPreferenceStore.remove(peerID: $0, defaults: defaults)
                PeerQUICCapabilityStore.remove(peerID: $0, defaults: defaults)
                cooldown.clear(peerID: $0)
                hints.remove(peerID: $0)
            })
        XCTAssertEqual(NetworkTransportPreferenceStore.load(peerID: forgotten, defaults: defaults), .auto)
        XCTAssertEqual(PeerQUICCapabilityStore.support(peerID: forgotten, defaults: defaults), .unknown)
        XCTAssertFalse(cooldown.isActive(peerID: forgotten, routeKind: .local))
        XCTAssertNil(hints.entry(peerID: forgotten))
        XCTAssertEqual(NetworkTransportPreferenceStore.load(peerID: kept, defaults: defaults), .quic)
        XCTAssertEqual(PeerQUICCapabilityStore.support(peerID: kept, defaults: defaults), .authenticated)
        XCTAssertTrue(cooldown.isActive(peerID: kept, routeKind: .local))
        XCTAssertNotNil(hints.entry(peerID: kept))
    }

    func testRuntimeAvailabilityNeedsNoDeploymentFloorChange() {
        XCTAssertTrue(QUICRuntimeAvailability.isAvailable)
    }
}

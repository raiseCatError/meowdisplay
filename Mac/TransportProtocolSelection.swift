import Foundation
import Network

// TransportProtocolSelection — the Mac sender's TCP/QUIC choice INSIDE an
// already-chosen network route. Physical route (USB / LAN / AWDL / Remote,
// `ConnectionRoute` + `RouteArbitration`) and network protocol (TCP / QUIC)
// stay orthogonal: QUIC is never a route, USB never uses QUIC, and nothing
// here changes route priority.
//
// Everything in this file is pure or a small lock-protected store so the
// whole policy — including the no-downgrade and anti-thrash rules — is unit
// tested without a network (`TransportProtocolSelectionTests`).

/// The per-device "Network Transport" setting, owned by the Mac (the dialer).
enum NetworkTransportPreference: String, CaseIterable, Sendable, Identifiable {
    case auto
    case quic
    case tcp

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return "Auto"
        case .quic: return "QUIC"
        case .tcp: return "TCP"
        }
    }
}

/// The secure protocol a network-route session actually rides.
enum NetworkTransportProtocol: String, Sendable, Equatable {
    case tcp
    case quic

    var title: String { self == .tcp ? "TCP" : "QUIC" }
}

/// Why a QUIC attempt (dial or live connection) failed. Only
/// `.reachability` may ever lead to a TCP fallback, and only in Auto.
enum QUICFailureClass: String, Sendable, Equatable {
    /// UDP blocked / no listener / path unavailable / timeout before the
    /// secure handshake finished. The one fallback-eligible class.
    case reachability
    /// SPKI mismatch, certificate failure, missing client certificate,
    /// ALPN mismatch, authenticated peer-ID mismatch, policy rejection.
    case security
    /// An authenticated peer violated the MeowDisplay QUIC stream protocol.
    case protocolViolation
    /// Not provably a reachability failure (e.g. a reset mid-handshake).
    /// Treated as "QUIC failed, try QUIC again" — never as a reason to
    /// switch protocols, so an attacker cannot turn an ambiguous error into
    /// a downgrade and the policy cannot thrash on it.
    case indeterminate
}

enum QUICFailureClassifier {
    /// Conservative classification of a Network.framework error seen before
    /// or during a QUIC session. Anything TLS-related is security; only a
    /// short list of "the network could not reach it" POSIX/DNS errors is
    /// reachability; everything else is indeterminate.
    static func classify(_ error: NWError) -> QUICFailureClass {
        switch error {
        case .tls:
            return .security
        case .dns:
            return .reachability
        case .posix(let code):
            return reachabilityCodes.contains(code) ? .reachability : .indeterminate
        default:
            return .indeterminate
        }
    }

    /// A reachability verdict is only believable while the peer has NOT yet
    /// proven itself: after this side accepted the peer's pinned certificate
    /// the network evidently reached it, so any failure is at best
    /// indeterminate (the POSIX code a QUIC group reports after the peer
    /// rejects our certificate has been ENOTCONN or ENETDOWN).
    static func refine(_ failureClass: QUICFailureClass, peerVerified: Bool) -> QUICFailureClass {
        guard peerVerified, failureClass == .reachability else { return failureClass }
        return .indeterminate
    }

    static let reachabilityCodes: Set<POSIXErrorCode> = [
        .ECONNREFUSED, .ENETUNREACH, .EHOSTUNREACH, .ENETDOWN, .EHOSTDOWN,
        .ETIMEDOUT, .EADDRNOTAVAIL,
    ]
    // Deliberately NOT here: ENOTCONN / ECONNRESET / ECONNABORTED. A peer that
    // rejects this Mac's certificate during the QUIC handshake surfaces on
    // the dialing group as ENOTCONN (observed on macOS 26 loopback), so
    // treating it as reachability would turn an authentication failure into
    // a TCP downgrade.
}

/// What the dialing Mac does with each `NWConnectionGroup` state of its
/// QUIC tunnel. Pure so the transient-vs-fatal split is testable without a
/// network.
enum QUICGroupStatePolicy {
    enum Action: Equatable {
        /// First `.ready`: open Control, Video and Audio.
        case openStreams
        /// Nothing to do — including `.waiting`, which Network.framework
        /// retries on its own (a physical Mac -> iPhone dial reported
        /// `.waiting(ENETDOWN)` and then `.ready` moments later).
        case ignore
        case fail(QUICFailureClass, detail: String)
    }

    /// `.waiting` is never terminal, whatever error it carries: `.failed` is
    /// the group's fatal state. A group that never progresses is bounded by
    /// the application-handshake timer before the hello, and by the ping
    /// watchdog after it.
    static func action(for state: NWConnectionGroup.State, groupAlreadyReady: Bool) -> Action {
        switch state {
        case .ready:
            return groupAlreadyReady ? .ignore : .openStreams
        case .waiting:
            return .ignore
        case .failed(let error):
            return .fail(QUICFailureClassifier.classify(error), detail: "group failed")
        case .cancelled:
            return .fail(.indeterminate, detail: "group cancelled")
        default:
            return .ignore
        }
    }

    /// Class of the application-handshake timeout. Only a tunnel that never
    /// became ready AND never showed the receiver's pinned certificate is
    /// "unreachable"; a peer that completed the handshake but never said
    /// hello is not, so it never earns an Auto fallback.
    static func handshakeTimeoutClass(groupReady: Bool, peerVerified: Bool) -> QUICFailureClass {
        !groupReady && !peerVerified ? .reachability : .indeterminate
    }
}

/// What the Mac knows about this peer's QUIC support, strongest first.
enum PeerQUICSupport: Equatable, Sendable {
    /// Positive capability from a previous AUTHENTICATED hello.
    case authenticated
    /// Only an unauthenticated `_meowdisp-q._udp` hint — enough to ATTEMPT
    /// QUIC on a local route (pinning still authenticates), never Remote.
    case discoveryHint
    case unknown
    /// The peer announced a QUIC framing version this build cannot speak.
    case incompatible
}

/// Which kind of network route a dial targets, for hint eligibility and
/// cooldown keys. Derived from the dial endpoint before any path exists.
enum NetworkRouteKind: String, Sendable, Equatable {
    case local    // Bonjour service (LAN / AWDL)
    case remote   // host:port hint (Remote Access / callback)

    init(endpoint: NWEndpoint) {
        if case .service = endpoint { self = .local } else { self = .remote }
    }
}

/// Per-logical-session protocol selection state machine. One instance lives
/// on each `MacSender` (its `queue`); it resets only with a new logical
/// session, a route change, or an explicit preference change.
///
/// Invariants:
///   * USB is never decided here (callers only ask for network routes);
///   * explicit TCP never uses QUIC; explicit QUIC never uses TCP;
///   * Auto falls back to TCP ONLY after a `.reachability` QUIC failure, and
///     then stays TCP for the rest of the logical session (sticky) — no
///     periodic re-challenge, no metric-driven switching;
///   * security / protocol-violation failures never fall back — they stop.
struct TransportProtocolSelector: Equatable, Sendable {
    enum Decision: Equatable, Sendable {
        case tcp
        case quic
        /// Explicit QUIC with no usable QUIC for this peer/runtime — the
        /// session must NOT silently use TCP instead.
        case unavailable(reason: String)
    }

    enum FailureAction: Equatable, Sendable {
        /// Dial QUIC again (explicit QUIC, indeterminate failure, or the one
        /// live-recovery attempt).
        case retryQUIC
        /// Auto only: start the cooldown and use secure TCP for the rest of
        /// this logical session.
        case fallbackToTCP
        /// Security or protocol failure: report and stop, never downgrade.
        case stop(QUICFailureClass)
    }

    /// The protocol this logical session committed to, once one worked.
    private(set) var sticky: NetworkTransportProtocol?
    /// True between a live QUIC loss and the recovery dial's outcome.
    private(set) var inLiveRecovery = false

    struct Inputs: Equatable, Sendable {
        var preference: NetworkTransportPreference
        var localQUICAvailable: Bool
        var peerSupport: PeerQUICSupport
        var routeKind: NetworkRouteKind
        var cooldownActive: Bool
    }

    func decide(_ inputs: Inputs) -> Decision {
        switch inputs.preference {
        case .tcp:
            return .tcp
        case .quic:
            guard inputs.localQUICAvailable else { return .unavailable(reason: "QUIC is not available on this Mac") }
            guard Self.peerAllowsQUIC(inputs.peerSupport, routeKind: inputs.routeKind) else {
                return .unavailable(reason: inputs.peerSupport == .incompatible
                    ? "this device's QUIC version is not compatible"
                    : "this device has not reported QUIC support")
            }
            // Explicit QUIC ignores the Auto cooldown — the user asked.
            return .quic
        case .auto:
            if let sticky {
                // A session that already committed keeps its protocol. A
                // sticky QUIC whose support vanished (impossible mid-session
                // today) still degrades to TCP rather than dialing blind.
                if sticky == .quic,
                   !(inputs.localQUICAvailable && Self.peerAllowsQUIC(inputs.peerSupport, routeKind: inputs.routeKind)) {
                    return .tcp
                }
                return sticky == .quic ? .quic : .tcp
            }
            guard inputs.localQUICAvailable,
                  Self.peerAllowsQUIC(inputs.peerSupport, routeKind: inputs.routeKind),
                  !inputs.cooldownActive else { return .tcp }
            return .quic
        }
    }

    /// Only authenticated capability opens QUIC on Remote; a local route may
    /// also ATTEMPT it on the discovery hint (pinning authenticates).
    static func peerAllowsQUIC(_ support: PeerQUICSupport, routeKind: NetworkRouteKind) -> Bool {
        switch support {
        case .authenticated: return true
        case .discoveryHint: return routeKind == .local
        case .unknown, .incompatible: return false
        }
    }

    /// A secure session was established (authenticated handshake + ready).
    /// Auto commits to it for the rest of the logical session.
    mutating func established(_ protocolUsed: NetworkTransportProtocol, preference: NetworkTransportPreference) {
        inLiveRecovery = false
        if preference == .auto { sticky = protocolUsed }
    }

    /// An established QUIC session was lost. The next dial is the single
    /// QUIC recovery attempt; its own outcome decides what happens next.
    mutating func liveQUICLost() {
        inLiveRecovery = true
    }

    /// A QUIC attempt failed with `failureClass`. `established` means the
    /// session had passed its authenticated application handshake (a LIVE
    /// failure): it earns exactly one QUIC recovery dial, whose own failure
    /// is then judged like any dial failure.
    mutating func quicFailed(_ failureClass: QUICFailureClass,
                             preference: NetworkTransportPreference,
                             established: Bool = false) -> FailureAction {
        switch failureClass {
        case .security, .protocolViolation:
            inLiveRecovery = false
            return .stop(failureClass)
        case .indeterminate, .reachability:
            break
        }
        if established {
            inLiveRecovery = true
            return .retryQUIC
        }
        guard failureClass == .reachability, preference == .auto else { return .retryQUIC }
        inLiveRecovery = false
        sticky = .tcp
        return .fallbackToTCP
    }

    /// The route (LAN/AWDL <-> Remote) changed: protocol selection may run
    /// again for the new route.
    mutating func routeChanged() {
        sticky = nil
        inLiveRecovery = false
    }

    /// The user changed the preference. Returns the protocol the live session
    /// must migrate to (nil = keep the current connection untouched).
    /// Selecting Auto keeps a healthy current protocol until reconnect or
    /// route change; explicit TCP/QUIC migrate only when they differ.
    mutating func preferenceChanged(to preference: NetworkTransportPreference,
                                    current: NetworkTransportProtocol?) -> NetworkTransportProtocol? {
        inLiveRecovery = false
        switch preference {
        case .auto:
            sticky = current
            return nil
        case .tcp:
            sticky = nil
            return current == .quic ? .tcp : nil
        case .quic:
            sticky = nil
            return current == .tcp ? .quic : nil
        }
    }
}

// MARK: - Stores

/// In-memory QUIC cooldown after an ordinary reachability failure, keyed by
/// peer + route kind. Deliberately never persisted: a transient failure must
/// not become "unsupported". Cleared by an explicit QUIC choice, Forget, or
/// process restart.
final class QUICCooldownStore: @unchecked Sendable {
    // Invariant: `until` is only touched while holding `lock`; no method
    // calls out while holding it.
    static let shared = QUICCooldownStore()
    static let defaultDuration: TimeInterval = 10 * 60

    private let lock = NSLock()
    private var until: [String: Date] = [:]
    let duration: TimeInterval

    init(duration: TimeInterval = QUICCooldownStore.defaultDuration) {
        self.duration = duration
    }

    static func key(peerID: String, routeKind: NetworkRouteKind) -> String {
        "\(peerID)|\(routeKind.rawValue)"
    }

    func isActive(peerID: String, routeKind: NetworkRouteKind, now: Date = Date()) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let end = until[Self.key(peerID: peerID, routeKind: routeKind)] else { return false }
        return now < end
    }

    func start(peerID: String, routeKind: NetworkRouteKind, now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        until[Self.key(peerID: peerID, routeKind: routeKind)] = now.addingTimeInterval(duration)
    }

    func clear(peerID: String) {
        lock.lock(); defer { lock.unlock() }
        until = until.filter { !$0.key.hasPrefix("\(peerID)|") }
    }
}

/// Persisted POSITIVE authenticated QUIC capability per peer. Only an
/// authenticated hello writes it; a Bonjour hint never does; a transient
/// failure never erases it; an incompatible announced version does; a peer
/// now running a build older than QUIC (authenticated `pv` below
/// `quicTransportWireVersion`) does; Forget removes it.
enum PeerQUICCapabilityStore {
    static func key(peerID: String) -> String { "quicCapability.v1.\(peerID)" }

    /// - peerProtocolVersion: the `pv` of THIS authenticated hello (absent =
    ///   `WireProtocol.assumedWhenAbsent`) — never a Bonjour TXT value.
    static func recordAuthenticatedHello(_ capability: QUICPeerCapability, peerID: String,
                                         peerProtocolVersion: Int,
                                         defaults: UserDefaults = .standard) {
        guard peerProtocolVersion >= WireProtocol.quicTransportWireVersion else {
            // The authenticated peer build predates QUIC altogether (e.g. the
            // receiver was downgraded): whatever was learned from a newer
            // build no longer describes it.
            defaults.removeObject(forKey: key(peerID: peerID))
            return
        }
        if capability.supportsCompatibleQUIC {
            defaults.set(QUICTransport.applicationVersion, forKey: key(peerID: peerID))
        } else if capability.announcesIncompatibleQUIC {
            defaults.set(-1, forKey: key(peerID: peerID))
        }
        // A QUIC-era build (pv >= 22) announcing TCP only: leave whatever was
        // learned before — its QUIC listener may be down only transiently.
    }

    static func support(peerID: String, defaults: UserDefaults = .standard) -> PeerQUICSupport {
        guard let value = defaults.object(forKey: key(peerID: peerID)) as? Int else { return .unknown }
        if value == QUICTransport.applicationVersion { return .authenticated }
        return .incompatible
    }

    static func remove(peerID: String, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key(peerID: peerID))
    }
}

/// Persisted per-device Network Transport preference (default Auto).
enum NetworkTransportPreferenceStore {
    static func key(peerID: String) -> String { "networkTransportPreference.v1.\(peerID)" }

    static func load(peerID: String, defaults: UserDefaults = .standard) -> NetworkTransportPreference {
        defaults.string(forKey: key(peerID: peerID)).flatMap(NetworkTransportPreference.init(rawValue:)) ?? .auto
    }

    static func save(_ preference: NetworkTransportPreference, peerID: String, defaults: UserDefaults = .standard) {
        if preference == .auto {
            defaults.removeObject(forKey: key(peerID: peerID))
        } else {
            defaults.set(preference.rawValue, forKey: key(peerID: peerID))
        }
    }

    static func remove(peerID: String, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key(peerID: peerID))
    }
}

/// Latest `_meowdisp-q._udp` browse results by advertised install ID. A HINT
/// store: written from the Mac's browser (main thread), read on sender
/// queues; it never grants trust and is never persisted.
final class QUICDiscoveryHintStore: @unchecked Sendable {
    // Invariant: `hints` is only touched while holding `lock`.
    static let shared = QUICDiscoveryHintStore()

    struct Entry: Sendable {
        let hint: QUICDiscoveryHint
        let endpoint: NWEndpoint
    }

    private let lock = NSLock()
    private var hints: [String: Entry] = [:]

    func replaceAll(_ entries: [Entry]) {
        lock.lock(); defer { lock.unlock() }
        var next: [String: Entry] = [:]
        for entry in entries { next[entry.hint.peerID] = entry }
        hints = next
    }

    func entry(peerID: String) -> Entry? {
        lock.lock(); defer { lock.unlock() }
        return hints[peerID]
    }

    func remove(peerID: String) {
        lock.lock(); defer { lock.unlock() }
        hints[peerID] = nil
    }
}

/// Resolution of everything the selector needs for one dial, from the
/// shared stores. Kept separate from `MacSender` so it is testable with
/// injected stores.
enum TransportProtocolInputsResolver {
    static func peerSupport(peerID: String, routeKind: NetworkRouteKind,
                            defaults: UserDefaults = .standard,
                            hints: QUICDiscoveryHintStore = .shared) -> PeerQUICSupport {
        let authenticated = PeerQUICCapabilityStore.support(peerID: peerID, defaults: defaults)
        if authenticated != .unknown { return authenticated }
        if routeKind == .local, let entry = hints.entry(peerID: peerID) {
            return entry.hint.isCompatible ? .discoveryHint : .unknown
        }
        return .unknown
    }

    /// The QUIC endpoint for a secure TCP dial endpoint: the same host and
    /// port number over UDP, or — for a Bonjour service — the peer's
    /// `_meowdisp-q._udp` browse result when one is known (same instance
    /// name otherwise). Pure mapping; the endpoint is only a routing hint.
    static func quicEndpoint(for tcpEndpoint: NWEndpoint, peerID: String,
                             hints: QUICDiscoveryHintStore = .shared) -> NWEndpoint? {
        switch tcpEndpoint {
        case .hostPort(let host, let port):
            return .hostPort(host: host, port: port)
        case .service(let name, _, let domain, let interface):
            if let entry = hints.entry(peerID: peerID) { return entry.endpoint }
            return .service(name: name, type: QUICTransport.bonjourServiceType, domain: domain, interface: interface)
        default:
            return nil
        }
    }

    /// Whether the per-device UI may offer explicit QUIC.
    static func quicSelectable(peerID: String, defaults: UserDefaults = .standard,
                               hints: QUICDiscoveryHintStore = .shared) -> Bool {
        guard QUICRuntimeAvailability.isAvailable else { return false }
        switch peerSupport(peerID: peerID, routeKind: .local, defaults: defaults, hints: hints) {
        case .authenticated, .discoveryHint: return true
        case .unknown, .incompatible: return false
        }
    }
}

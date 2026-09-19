import Foundation
import Network

/// Remote (Tailscale / direct-host) pairing support. Everything here is a
/// routing or lifetime concern. Reachability never becomes trust: the
/// cryptographic flow in `PairingHandshake` (ECDH + transcript-bound SAS,
/// confirmed on both devices) and `TrustStore` SPKI pinning remain the only
/// trust boundary, exactly as for LAN pairing.

/// An untrusted endpoint hint typed by the user. Not an identity.
struct RemotePairingEndpoint: Equatable {
    let host: String
    let port: UInt16

    /// Trims, rejects empty/garbage hosts (syntax only, no DNS) and defaults
    /// to the dedicated remote pairing port when none is given. A bracketed
    /// IPv6 literal is unwrapped for `NWEndpoint.Host`.
    static func make(host rawHost: String, port rawPort: String = "")
        -> Result<RemotePairingEndpoint, RemoteEndpointValidation.Error> {
        let portText = rawPort.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectivePort = portText.isEmpty ? String(WireCrypto.remotePairingPort) : portText
        switch RemoteEndpointValidation.validate(host: rawHost, port: effectivePort) {
        case .failure(let error): return .failure(error)
        case .success(let value):
            var host = value.host
            if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
            return .success(RemotePairingEndpoint(host: host, port: value.port))
        }
    }

    var nwEndpoint: NWEndpoint {
        .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)
    }
}

/// Mac-side "Pair over Remote" availability. Pure value type with an injected
/// clock: the pairing listener is only reachable while the window is open,
/// admits one attempt at a time, and backs off briefly after repeated
/// failures. A window that expires stops admitting *new* attempts; an
/// attempt already admitted keeps its own bounded lifetime.
struct RemotePairingWindow: Equatable {
    static let openDuration: TimeInterval = 180
    static let attemptDeadline: TimeInterval = 90
    static let failuresBeforeCooldown = 3
    static let cooldownDuration: TimeInterval = 30

    enum Admission: Equatable { case admitted, notOpen, busy, coolingDown }

    private(set) var expiry: Date?
    private(set) var attemptInProgress = false
    private(set) var consecutiveFailures = 0
    private(set) var cooldownUntil: Date?

    func isOpen(now: Date) -> Bool { expiry.map { now < $0 } ?? false }

    mutating func open(now: Date, duration: TimeInterval = RemotePairingWindow.openDuration) {
        expiry = now.addingTimeInterval(duration)
        consecutiveFailures = 0
        cooldownUntil = nil
    }

    mutating func close() { expiry = nil }

    mutating func admit(now: Date) -> Admission {
        guard isOpen(now: now) else { return .notOpen }
        if let cooldownUntil, now < cooldownUntil { return .coolingDown }
        guard !attemptInProgress else { return .busy }
        attemptInProgress = true
        return .admitted
    }

    /// A successful pairing consumes the window (one pairing per open).
    mutating func finishAttempt(success: Bool, now: Date) {
        attemptInProgress = false
        if success { close(); consecutiveFailures = 0; return }
        consecutiveFailures += 1
        if consecutiveFailures >= Self.failuresBeforeCooldown {
            consecutiveFailures = 0
            cooldownUntil = now.addingTimeInterval(Self.cooldownDuration)
        }
    }
}

/// Generation guard for a single outstanding pairing attempt. A cancelled or
/// superseded attempt can never complete: its generation stops being current.
struct PairingAttemptTracker: Equatable {
    private(set) var generation: UInt64 = 0
    private(set) var active: UInt64?

    /// `nil` when an attempt is already running (duplicate is refused).
    mutating func begin() -> UInt64? {
        guard active == nil else { return nil }
        generation += 1
        active = generation
        return generation
    }

    func isCurrent(_ candidate: UInt64) -> Bool { active == candidate }

    /// Invalidates the in-flight attempt, if any.
    mutating func cancel() {
        guard active != nil else { return }
        active = nil
        generation += 1
    }

    /// `true` only if `candidate` was still the live attempt.
    @discardableResult
    mutating func finish(_ candidate: UInt64) -> Bool {
        guard active == candidate else { return false }
        active = nil
        return true
    }
}

/// Thread-safe liveness flag handed to the network layer so a cancelled or
/// superseded attempt cannot persist trust from a late callback.
final class PairingAttemptValidity: @unchecked Sendable {
    private let lock = NSLock()
    private var valid = true
    var isValid: Bool { lock.lock(); defer { lock.unlock() }; return valid }
    func invalidate() { lock.lock(); valid = false; lock.unlock() }
}

/// Product-level phase, derived from existing state rather than stored as a
/// second state machine.
enum RemotePairingPhase: Equatable {
    case off
    case available
    case inProgress
    case awaitingConfirmation

    static func derive(windowOpen: Bool, attemptInProgress: Bool, awaitingConfirmation: Bool) -> Self {
        if awaitingConfirmation { return .awaitingConfirmation }
        if attemptInProgress { return .inProgress }
        return windowOpen ? .available : .off
    }
}

/// Post-pairing routing hint. Written only after the peer is cryptographically
/// confirmed and pinned, keyed by the confirmed peer ID.
protocol RemoteEndpointHinting {
    func setEndpoint(_ host: String, port: UInt16, forPeerID peerID: String)
}

struct RemoteEndpointStoreHints: RemoteEndpointHinting {
    func setEndpoint(_ host: String, port: UInt16, forPeerID peerID: String) {
        RemoteEndpointStore.setEndpoint(host, port: port, forPeerID: peerID)
    }
}

/// Thread-safe one-way flag (e.g. "the handshake was reached").
final class PairingFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}

/// Why a remote pairing attempt ended, only where the code genuinely knows.
/// "Rejected" is used only when a handshake actually took place.
enum RemotePairingFailureKind: Equatable {
    case unreachable, timedOut, rejected, cancelledByPeer, ownerAuthFailed, keyChanged, codesDidNotMatch, updateRequired, failed

    var title: String {
        switch self {
        case .unreachable: "Couldn't reach the Mac"
        case .timedOut: "Pairing timed out"
        case .rejected: "Pairing was rejected"
        case .cancelledByPeer: "Pairing was cancelled on the other device"
        case .ownerAuthFailed: "Device owner authentication failed"
        case .keyChanged: "Trusted device key changed"
        case .codesDidNotMatch: "Codes did not match"
        case .updateRequired: "Update MeowDisplay on both devices to pair"
        case .failed: "Pairing failed"
        }
    }

    /// Non-retryable outcomes need a deliberate user action (Forget / update).
    var isRetryable: Bool { self != .keyChanged && self != .updateRequired }

    var detail: String? {
        switch self {
        case .unreachable: "Make sure the address is correct and Pair Over Remote is turned on on the Mac."
        case .keyChanged: "Forget the device to pair again."
        default: nil
        }
    }
}

/// What the iPhone UI shows for the single outstanding attempt. Stored on the
/// receiver next to `PairingAttemptTracker`; the SAS itself stays in
/// `PairingPromptModel`.
enum RemotePairingUIState: Equatable {
    case idle
    case connecting
    case failed(RemotePairingFailureKind)
    case succeeded

    /// The progress sheet is shown while an attempt is running, except while
    /// the SAS confirmation sheet owns the screen.
    func showsProgress(sasPending: Bool) -> Bool { self == .connecting && !sasPending }
}

/// Success feedback is a function of true completion only, for every
/// transport (LAN, USB, Remote): a failed or cancelled run never produces it.
enum PairingOutcomeFeedback: Equatable {
    case none, success

    static func forCompletion<T>(_ result: Result<T, Error>) -> Self {
        if case .success = result { return .success }
        return .none
    }
}

/// When the Mac starts the secure pairing ceremony for a device that just
/// appeared over USB. USB discovery and dialing are automatic; trust is not.
/// A pinned peer simply connects (the pinned TLS handshake governs, and a
/// changed key fails there); only an unpinned peer runs the SAS ceremony.
/// The ceremony never replaces an existing pin.
enum USBPairingPolicy {
    static let allowIdentityChange = false

    static func shouldBeginPairing(hasPin: Bool, alreadyAttemptedThisSession: Bool) -> Bool {
        !hasPin && !alreadyAttemptedThisSession
    }
}

/// Compact, truthful user-facing text. Raw errors stay in the logs.
enum RemotePairingFailure {
    /// `nil` means the user cancelled: return quietly to the form.
    static func classify(_ error: Error, cancelledByUser: Bool, deadlineFired: Bool,
                         handshakeReached: Bool) -> RemotePairingFailureKind? {
        if cancelledByUser { return nil }
        if let pairing = error as? PairingError {
            switch pairing {
            case .identityChanged: return .keyChanged
            case .cancelledByPeer: return .cancelledByPeer
            case .cancelledLocally: return nil
            case .trustStateChanged: return .failed
            case .ownerAuthenticationFailed: return .ownerAuthFailed
            case .invalidKey, .invalidConfirmation: return .codesDidNotMatch
            case .unsupportedVersion: return .updateRequired
            case .rejected: return handshakeReached ? (deadlineFired ? .timedOut : .rejected)
                                                   : (deadlineFired ? .unreachable : .failed)
            case .malformedMessage: return handshakeReached ? .failed : .unreachable
            }
        }
        return handshakeReached ? (deadlineFired ? .timedOut : .failed) : .unreachable
    }

    /// Mac side: a handshake always occurred by the time an error is reported.
    static func message(for error: Error, timedOut: Bool = false) -> String {
        guard let kind = classify(error, cancelledByUser: false, deadlineFired: timedOut, handshakeReached: true) else {
            return "Pairing was cancelled"
        }
        return kind.title
    }
}

/// Remembers the last attempted host so Try Again (and a re-created sheet)
/// never depends on view-local text. Cleared of nothing but the host: it is
/// only a routing hint.
struct RemotePairingRetryContext: Equatable {
    private(set) var lastEndpoint: RemotePairingEndpoint?

    mutating func remember(_ endpoint: RemotePairingEndpoint) { lastEndpoint = endpoint }

    /// The endpoint for a fresh attempt, only from a retryable failed state.
    func endpointForRetry(state: RemotePairingUIState) -> RemotePairingEndpoint? {
        guard case .failed(let kind) = state, kind.isRetryable else { return nil }
        return lastEndpoint
    }
}

/// Confirm-before-forget flow for the iPhone. Requesting or cancelling never
/// touches trust; only `confirm` runs the (existing) forget operation, once.
struct PeerForgetPrompt: Equatable {
    struct Candidate: Equatable { let peerID: String; let name: String }
    private(set) var candidate: Candidate?

    var isPresented: Bool { candidate != nil }

    mutating func request(peerID: String, name: String) { candidate = Candidate(peerID: peerID, name: name) }
    mutating func cancel() { candidate = nil }
    mutating func confirm(_ forget: (String) -> Void) {
        guard let candidate else { return }
        self.candidate = nil
        forget(candidate.peerID)
    }
}

/// Role-aware pairing copy shared by iPhone and Mac so terminology stays
/// aligned. Only iPhone → Mac exists today; `RemotePairingTarget` keeps the
/// wording ready for a future Mac → iPhone direction without implying it.
enum RemotePairingTarget {
    case mac, iPhone

    var noun: String { self == .mac ? "Mac" : "iPhone" }
}

enum PairingCopy {
    static let sasTitle = "Confirm on both devices"
    static let sasHelper = "If the codes match, confirm on both devices to finish pairing."
    static let connectingTitle = "Pairing…"
    static let waitingTitle = "Waiting for confirmation…"

    static func connectingHelper(target: RemotePairingTarget) -> String {
        "Make sure Pair Over Remote is turned on on the \(target.noun)."
    }

    /// Who must still confirm. On the iPhone the other device is "your Mac";
    /// on the Mac it is named by the peer's own display name, since the Mac
    /// can't know whether the peer is an iPhone or an iPad.
    static func waitingHelper(otherDevice: String) -> String {
        "Confirm the matching code on \(otherDevice) to finish pairing."
    }

    static func otherDevice(localIsMac: Bool, peerName: String) -> String {
        localIsMac ? "\u{201C}\(peerName)\u{201D}" : "your Mac"
    }
}

/// What the pairing UI shows for one attempt, derived from existing state.
enum PairingStage: Equatable {
    case connecting, sasReady, waitingForPeer, other

    static func derive(state: RemotePairingUIState?, sasPending: Bool, confirmedLocally: Bool) -> Self {
        if sasPending { return .sasReady }
        if confirmedLocally { return .waitingForPeer }
        if state == .connecting { return .connecting }
        return .other
    }
}

/// Local device-owner authentication before a NEW trust relationship is
/// approved. The decision is injectable so ceremony logic never touches
/// LocalAuthentication directly.
enum OwnerAuthResult: Equatable { case success, cancelled, failed }

protocol OwnerAuthenticating: AnyObject {
    func authenticate(reason: String) async -> OwnerAuthResult
    /// Dismiss any authentication UI still on screen (attempt ended).
    func invalidate()
}

/// What the trust store currently says about a peer, as seen at decision time.
enum PinSnapshot: Equatable {
    case unavailable        // no lookup installed: cannot verify, so never assume trust
    case absent
    case present(Data)
}

/// Whether persisting a Remote endpoint hint would change what is stored.
enum RemoteHintChange {
    static func wouldChange(existing: (host: String, port: UInt16)?, newHost: String) -> Bool {
        guard let existing else { return true }
        return existing.host.caseInsensitiveCompare(newHost) != .orderedSame
            || existing.port != WireCrypto.remoteRequestPort
    }
}

enum OwnerAuthPolicy {
    /// New trust (unknown or forgotten peer), an explicit identity replacement,
    /// or any change to the persisted Remote endpoint hint needs the device
    /// owner. A re-pair with the SAME pinned key that changes nothing creates no
    /// new trust, and ordinary connections to a pinned peer never reach the
    /// ceremony. The pin is re-checked NOW (not from the hello-time
    /// classification): if it is gone or unverifiable, this is new trust.
    /// Transport is irrelevant: LAN, Remote and USB are treated identically.
    static func isRequired(_ pending: PendingPairing, currentPin: PinSnapshot) -> Bool {
        if pending.changesRemoteEndpoint { return true }
        switch pending.classification {
        case .newPeer, .identityChanged:
            return true
        case .rePairSameKey:
            if case .present(let pin) = currentPin, pin == pending.peerSPKI { return false }
            return true
        }
    }

    /// Bidirectional / invisible formatting characters that can visually
    /// reorder or hide text in a system prompt. ZWJ/ZWNJ are deliberately kept:
    /// emoji sequences and several scripts need them.
    private static let dangerous: Set<UInt32> = {
        var set: Set<UInt32> = [0x061C, 0x200B, 0x200E, 0x200F, 0x2028, 0x2029, 0x2060, 0xFEFF]
        set.formUnion(0x202A...0x202E)
        set.formUnion(0x2066...0x2069)
        return set
    }()

    static func sanitizedName(_ name: String) -> String {
        let kept = name.unicodeScalars.filter {
            $0.properties.generalCategory != .control && !dangerous.contains($0.value)
        }
        var view = String.UnicodeScalarView(); view.append(contentsOf: kept)
        return String(String(view).trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
    }

    static func reason(peerName: String, updatingEndpointOnly: Bool = false) -> String {
        let name = sanitizedName(peerName)
        if updatingEndpointOnly {
            return name.isEmpty ? "Confirm that you want to update this device's remote address in MEOW."
                                : "Confirm that you want to update the remote address for \u{201C}\(name)\u{201D} in MEOW."
        }
        return name.isEmpty ? "Confirm that you want to trust this device in MEOW."
                            : "Confirm that you want to trust \u{201C}\(name)\u{201D} in MEOW."
    }
}

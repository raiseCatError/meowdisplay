import CryptoKit
import Foundation

enum PairingError: LocalizedError, Equatable {
    case malformedMessage
    case unsupportedVersion
    case invalidKey
    case invalidConfirmation
    case rejected
    case identityChanged
    case cancelledByPeer
    case cancelledLocally
    case ownerAuthenticationFailed
    case trustStateChanged
    case commitmentMismatch
    case tooManyAttempts

    var errorDescription: String? {
        switch self {
        case .malformedMessage: "Invalid pairing message"
        case .unsupportedVersion: "This device must be updated before pairing"
        case .invalidKey, .invalidConfirmation: "Pairing could not be verified"
        case .rejected: "Pairing was cancelled"
        case .identityChanged: "Device identity changed"
        case .cancelledByPeer: "Pairing was cancelled on the other device"
        case .cancelledLocally: "Pairing was cancelled"
        case .ownerAuthenticationFailed: "Device owner authentication failed"
        case .trustStateChanged: "Trust changed during pairing. Try again"
        case .commitmentMismatch: "Pairing could not be verified"
        case .tooManyAttempts: "Too many pairing attempts. Try again in 30 seconds."
        }
    }
}

/// First-pairing messages only. The media protocol never accepts these and
/// the pairing port never accepts media frames.
struct PairingHello: Codable, Equatable {
    let version: Int
    let deviceID: String
    let displayName: String
    let identitySPKI: Data
    let ephemeralPublicKey: Data
    let nonce: Data

    func validate() throws {
        guard version == WireProtocol.pairingVersion,
              UUID(uuidString: deviceID) != nil,
              !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              displayName.utf8.count <= 128,
              identitySPKI.count <= 512,
              ephemeralPublicKey.count == 65,
              nonce.count == 32,
              (try? P256.KeyAgreement.PublicKey(x963Representation: ephemeralPublicKey)) != nil
        else { throw version == WireProtocol.pairingVersion ? PairingError.malformedMessage : .unsupportedVersion }
    }
}

struct PairingConfirmation: Codable, Equatable {
    let accepted: Bool
    let authenticator: Data
}

/// Canonical, unambiguous byte encoding shared by the hello commitment and the
/// pairing transcript — never JSON, whose field order/whitespace/escaping
/// isn't a stable security boundary. Every variable-length field is prefixed
/// with its length (`lp`), so no ambiguous concatenation of two fields can
/// collide with a different split of the same bytes.
enum PairingCanonical {
    static func lp(_ data: Data) -> Data {
        var length = UInt32(data.count).bigEndian
        var out = Data()
        withUnsafeBytes(of: &length) { out.append(contentsOf: $0) }
        out.append(data)
        return out
    }

    /// Constant-time byte comparison — timing must not leak how much of a
    /// commitment matched.
    static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for (x, y) in zip(a, b) { diff |= x ^ y }
        return diff == 0
    }
}

/// The initiator's hello commitment: binds the initiator to its real hello
/// (identity, ephemeral key, nonce) before the responder has seen it, so the
/// responder cannot choose its own hello adaptively to grind the SAS. The
/// responder must send its own hello before the initiator ever reveals the
/// committed one.
enum PairingHelloCommitment {
    private static let domain = "MeowDisplay-Pairing-HelloCommit-v13"

    static func compute(initiatorHello hello: PairingHello) -> Data {
        var data = PairingCanonical.lp(Data(domain.utf8))
        data.append(PairingHandshake.Role.initiator.rawValue)
        var version = UInt32(hello.version).bigEndian
        withUnsafeBytes(of: &version) { data.append(contentsOf: $0) }
        data.append(PairingCanonical.lp(Data(hello.deviceID.utf8)))
        data.append(PairingCanonical.lp(Data(hello.displayName.utf8)))
        data.append(PairingCanonical.lp(hello.identitySPKI))
        data.append(PairingCanonical.lp(hello.ephemeralPublicKey))
        data.append(PairingCanonical.lp(hello.nonce))
        return Data(SHA256.hash(data: data))
    }

    static func verify(_ commitment: Data, revealedInitiatorHello hello: PairingHello) -> Bool {
        commitment.count == 32 && PairingCanonical.constantTimeEqual(commitment, compute(initiatorHello: hello))
    }
}

/// How an incoming/outgoing pairing request relates to existing trust for
/// this peer ID — computed once, before the user is prompted, so the UI can
/// tell a first-time pairing apart from an explicit re-pair or a changed
/// identity rather than silently treating "already trusted" as "nothing to
/// show". Existing trust must never suppress an explicit pairing request.
enum PairingClassification: Equatable {
    case newPeer
    case rePairSameKey
    case identityChanged
}

struct PendingPairing: Equatable, Identifiable {
    let peerID: String
    let peerName: String
    let peerSPKI: Data
    let sas: String
    var classification: PairingClassification = .newPeer
    /// This ceremony would create or change the persisted Remote endpoint hint
    /// for the peer (initiator over Remote). Decided before the user approves.
    var changesRemoteEndpoint = false
    var id: String { peerID }
}

/// Ephemeral P-256 ECDH with transcript-bound HKDF/HMAC confirmation.
/// The six-digit SAS authenticates both long-term identities, both ephemeral
/// keys, both nonces, roles, names and the protocol version. It is display
/// authentication only and is never used as an encryption key.
struct PairingHandshake {
    enum Role: UInt8 { case initiator = 1, responder = 2 }

    let role: Role
    let localHello: PairingHello
    private let ephemeralKey: P256.KeyAgreement.PrivateKey

    init(role: Role, deviceID: String, displayName: String, identitySPKI: Data,
         ephemeralKey: P256.KeyAgreement.PrivateKey = .init(), nonce: Data? = nil) {
        self.role = role
        self.ephemeralKey = ephemeralKey
        localHello = PairingHello(
            version: WireProtocol.pairingVersion,
            deviceID: deviceID,
            displayName: displayName,
            identitySPKI: identitySPKI,
            ephemeralPublicKey: ephemeralKey.publicKey.x963Representation,
            nonce: nonce ?? Data((0..<32).map { _ in UInt8.random(in: .min ... .max) }))
    }

    func result(peerHello: PairingHello) throws -> PairingResult {
        try localHello.validate()
        try peerHello.validate()
        guard peerHello.deviceID != localHello.deviceID,
              peerHello.identitySPKI != localHello.identitySPKI else { throw PairingError.malformedMessage }
        let peerKey: P256.KeyAgreement.PublicKey
        do { peerKey = try .init(x963Representation: peerHello.ephemeralPublicKey) }
        catch { throw PairingError.invalidKey }
        let shared = try ephemeralKey.sharedSecretFromKeyAgreement(with: peerKey)
        let transcript = Self.transcript(
            initiator: role == .initiator ? localHello : peerHello,
            responder: role == .responder ? localHello : peerHello)
        let transcriptHash = Data(SHA256.hash(data: transcript))
        let root = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: transcriptHash,
            sharedInfo: Data("OpenDisplay pairing v13".utf8),
            outputByteCount: 32)
        let sasKey = HKDF<SHA256>.deriveKey(inputKeyMaterial: root,
                                            salt: Data("sas".utf8),
                                            info: transcriptHash,
                                            outputByteCount: 4)
        let sasBytes = sasKey.withUnsafeBytes { Array($0) }
        let number = ((UInt32(sasBytes[0]) << 24) | (UInt32(sasBytes[1]) << 16)
            | (UInt32(sasBytes[2]) << 8) | UInt32(sasBytes[3])) % 1_000_000
        return PairingResult(
            pending: PendingPairing(peerID: peerHello.deviceID,
                                    peerName: peerHello.displayName,
                                    peerSPKI: peerHello.identitySPKI,
                                    sas: String(format: "%03d %03d", number / 1000, number % 1000)),
            localConfirmationKey: Self.confirmationKey(root: root, role: role),
            peerConfirmationKey: Self.confirmationKey(root: root,
                role: role == .initiator ? .responder : .initiator),
            transcriptHash: transcriptHash)
    }

    private static func confirmationKey(root: SymmetricKey, role: Role) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: root,
                               salt: Data("confirmation".utf8),
                               info: Data([role.rawValue]), outputByteCount: 32)
    }

    private static func transcript(initiator: PairingHello, responder: PairingHello) -> Data {
        var data = PairingCanonical.lp(Data("OpenDisplay-Pairing-Transcript-v13".utf8))
        for (role, hello) in [(Role.initiator, initiator), (Role.responder, responder)] {
            data.append(role.rawValue)
            var version = UInt32(hello.version).bigEndian
            withUnsafeBytes(of: &version) { data.append(contentsOf: $0) }
            data.append(PairingCanonical.lp(Data(hello.deviceID.utf8)))
            data.append(PairingCanonical.lp(Data(hello.displayName.utf8)))
            data.append(PairingCanonical.lp(hello.identitySPKI))
            data.append(PairingCanonical.lp(hello.ephemeralPublicKey))
            data.append(PairingCanonical.lp(hello.nonce))
        }
        return data
    }
}

struct PairingResult {
    let pending: PendingPairing
    fileprivate let localConfirmationKey: SymmetricKey
    fileprivate let peerConfirmationKey: SymmetricKey
    fileprivate let transcriptHash: Data

    func confirmation(accepted: Bool) -> PairingConfirmation {
        let body = transcriptHash + Data([accepted ? 1 : 0])
        return PairingConfirmation(accepted: accepted,
            authenticator: Data(HMAC<SHA256>.authenticationCode(for: body,
                                                                 using: localConfirmationKey)))
    }

    /// Live finalization steps after both SAS confirmations. A confirmation
    /// alone is provisional: trust is persisted only after the commit/ack
    /// exchange (see `PairingNetwork`), and an authenticated abort ends it.
    enum Step: UInt8 { case commit = 0x10, commitAck = 0x11, abort = 0x12 }

    func stepAuthenticator(_ step: Step) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: transcriptHash + Data([step.rawValue]),
                                             using: localConfirmationKey))
    }

    func verifyStep(_ step: Step, authenticator: Data) throws {
        guard HMAC<SHA256>.isValidAuthenticationCode(authenticator,
                                                     authenticating: transcriptHash + Data([step.rawValue]),
                                                     using: peerConfirmationKey)
        else { throw PairingError.invalidConfirmation }
    }

    func verify(_ confirmation: PairingConfirmation) throws {
        let body = transcriptHash + Data([confirmation.accepted ? 1 : 0])
        guard HMAC<SHA256>.isValidAuthenticationCode(confirmation.authenticator,
                                                      authenticating: body,
                                                      using: peerConfirmationKey)
        else { throw PairingError.invalidConfirmation }
        guard confirmation.accepted else { throw PairingError.rejected }
    }
}

/// Pure trust policy used by production Keychain storage and hostless tests.
enum TrustPinPolicy {
    enum Decision: Equatable { case new, match, identityChanged }

    static func decision(existing: Data?, presented: Data) -> Decision {
        guard let existing else { return .new }
        return existing == presented ? .match : .identityChanged
    }
}

protocol PeerTrustStoring {
    func pin(peerID: String) -> Data?
    // `allowIdentityChange` replaces a differing pin instead of refusing it.
    // Callers may only pass true after a *fresh* pairing handshake in which
    // both sides explicitly confirmed the same SAS for the changed identity
    // — never on the strength of a matching peer ID alone.
    @discardableResult
    func setPin(peerID: String, spki: Data, displayName: String,
                allowIdentityChange: Bool) -> Bool
    func forget(peerID: String)
}

extension PeerTrustStoring {
    @discardableResult
    func setPin(peerID: String, spki: Data, displayName: String) -> Bool {
        setPin(peerID: peerID, spki: spki, displayName: displayName, allowIdentityChange: false)
    }
}

/// Deterministic, Keychain-free test double for trust lifecycle tests.
final class InMemoryPeerTrustStore: PeerTrustStoring {
    private(set) var pins: [String: Data] = [:]
    func pin(peerID: String) -> Data? { pins[peerID] }
    func setPin(peerID: String, spki: Data, displayName: String,
                allowIdentityChange: Bool) -> Bool {
        switch TrustPinPolicy.decision(existing: pins[peerID], presented: spki) {
        case .new, .match: pins[peerID] = spki; return true
        case .identityChanged:
            guard allowIdentityChange else { return false }
            pins[peerID] = spki
            return true
        }
    }
    func forget(peerID: String) { pins[peerID] = nil }
}

struct PairingServiceRecord<Endpoint> {
    let stableID: String
    let displayName: String
    let endpoint: Endpoint
}

enum PairingServiceAssociation {
    static func endpoint<Endpoint>(forStableID stableID: String?,
                                   in records: [PairingServiceRecord<Endpoint>]) -> Endpoint? {
        guard let stableID, UUID(uuidString: stableID) != nil else { return nil }
        return records.first { $0.stableID == stableID }?.endpoint
    }
}

/// Pure classification of a presented key against the existing pin.
enum PairingClassifier {
    static func classify(_ pending: PendingPairing, existingPin: Data?) -> PendingPairing {
        var pending = pending
        switch TrustPinPolicy.decision(existing: existingPin, presented: pending.peerSPKI) {
        case .new: pending.classification = .newPeer
        case .match: pending.classification = .rePairSameKey
        case .identityChanged: pending.classification = .identityChanged
        }
        return pending
    }

    /// Remote pairing never replaces a pin: a changed key is a hard failure
    /// resolved through the normal Forget / re-pair flow.
    static func check(_ pending: PendingPairing, allowIdentityChange: Bool) throws {
        if pending.classification == .identityChanged, !allowIdentityChange {
            throw PairingError.identityChanged
        }
    }
}

/// The only place trust is written after a handshake. Runs strictly after the
/// peer's authenticated confirmation verified (so both sides accepted the same
/// SAS); a stale attempt never persists; the routing hint is saved only once
/// the pin succeeded and is keyed by the confirmed peer ID.
enum PairingFinalizer {
    static func complete(result: PairingResult, pending: PendingPairing,
                         peerConfirmation: PairingConfirmation, store: PeerTrustStoring,
                         isCurrent: () -> Bool = { true },
                         remoteHost: String? = nil, hints: RemoteEndpointHinting? = nil) throws {
        try result.verify(peerConfirmation)
        guard isCurrent() else { throw PairingError.rejected }
        // A same-key re-pair skipped owner auth because the pin existed when the
        // SAS was shown. If it vanished since, this would silently recreate
        // trust from a stale classification: refuse instead.
        if pending.classification == .rePairSameKey,
           store.pin(peerID: pending.peerID) != pending.peerSPKI {
            throw PairingError.trustStateChanged
        }
        guard store.setPin(peerID: pending.peerID, spki: pending.peerSPKI,
                           displayName: pending.peerName,
                           allowIdentityChange: pending.classification == .identityChanged)
        else { throw PairingError.identityChanged }
        if let remoteHost, let hints {
            hints.setEndpoint(remoteHost, port: WireCrypto.remoteRequestPort, forPeerID: pending.peerID)
        }
    }
}

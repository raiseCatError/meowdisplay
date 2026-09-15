import CryptoKit
import Foundation

enum PairingError: LocalizedError, Equatable {
    case malformedMessage
    case unsupportedVersion
    case invalidKey
    case invalidConfirmation
    case rejected
    case identityChanged

    var errorDescription: String? {
        switch self {
        case .malformedMessage: "Invalid pairing message"
        case .unsupportedVersion: "This device must be updated before pairing"
        case .invalidKey, .invalidConfirmation: "Pairing could not be verified"
        case .rejected: "Pairing was cancelled"
        case .identityChanged: "Device identity changed"
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
        guard version == WireProtocol.securePairingWireVersion,
              UUID(uuidString: deviceID) != nil,
              !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              displayName.utf8.count <= 128,
              identitySPKI.count <= 512,
              ephemeralPublicKey.count == 65,
              nonce.count == 32,
              (try? P256.KeyAgreement.PublicKey(x963Representation: ephemeralPublicKey)) != nil
        else { throw version == WireProtocol.securePairingWireVersion ? PairingError.malformedMessage : .unsupportedVersion }
    }
}

struct PairingConfirmation: Codable, Equatable {
    let accepted: Bool
    let authenticator: Data
}

struct PendingPairing: Equatable, Identifiable {
    let peerID: String
    let peerName: String
    let peerSPKI: Data
    let sas: String
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
            version: WireProtocol.securePairingWireVersion,
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
            sharedInfo: Data("OpenDisplay pairing v1".utf8),
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
        var data = Data("OpenDisplay-Pairing-Transcript-v1".utf8)
        for hello in [initiator, responder] {
            append(Data(String(hello.version).utf8), to: &data)
            append(Data(hello.deviceID.utf8), to: &data)
            append(Data(hello.displayName.utf8), to: &data)
            append(hello.identitySPKI, to: &data)
            append(hello.ephemeralPublicKey, to: &data)
            append(hello.nonce, to: &data)
        }
        return data
    }

    private static func append(_ field: Data, to data: inout Data) {
        var length = UInt32(field.count).bigEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(field)
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
    @discardableResult
    func setPin(peerID: String, spki: Data, displayName: String) -> Bool
    func forget(peerID: String)
}

/// Deterministic, Keychain-free test double for trust lifecycle tests.
final class InMemoryPeerTrustStore: PeerTrustStoring {
    private(set) var pins: [String: Data] = [:]
    func pin(peerID: String) -> Data? { pins[peerID] }
    func setPin(peerID: String, spki: Data, displayName: String) -> Bool {
        switch TrustPinPolicy.decision(existing: pins[peerID], presented: spki) {
        case .new: pins[peerID] = spki; return true
        case .match: return true
        case .identityChanged: return false
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

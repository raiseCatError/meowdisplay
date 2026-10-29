import XCTest
import Security
import CryptoKit
import X509
import SwiftASN1

/// A throwaway file keychain for tests that need real `SecIdentity` values,
/// so no test ever touches the developer's MeowDisplay Keychain rows.
/// Create one in `setUp`, call `delete()` in `tearDown`.
///
/// If the runner can't create a keychain or identity, the calls throw
/// `XCTSkip` with the Security status instead of falling back to real
/// identities.
final class TemporaryTestKeychain {
    struct Identity {
        let identity: SecIdentity
        let spki: Data
    }

    private var keychain: SecKeychain?
    private let path: String

    init(prefix: String) throws {
        path = NSTemporaryDirectory() + "\(prefix)-\(UUID().uuidString).keychain"
        let password = UUID().uuidString
        var created: SecKeychain?
        let status = SecKeychainCreate(path, UInt32(password.utf8.count), password, false, nil, &created)
        guard status == errSecSuccess, let created else {
            throw XCTSkip("temporary keychain unavailable on this runner (status \(status))")
        }
        keychain = created
    }

    func delete() {
        if let keychain { SecKeychainDelete(keychain) }
        keychain = nil
        try? FileManager.default.removeItem(atPath: path)
    }

    /// A fresh P-256 identity whose private key is generated INSIDE the
    /// temporary keychain (file keychains refuse raw EC key imports). The
    /// certificate carries that key's SPKI; its signature comes from a
    /// throwaway key, which is irrelevant here exactly as in production:
    /// MeowDisplay pins the leaf SPKI and never evaluates the chain, while
    /// the TLS handshake itself proves possession of the keychain key.
    func makeIdentity() throws -> Identity {
        guard let keychain else { throw XCTSkip("no temporary keychain") }
        var cfError: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey([
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits: 256,
            kSecUseKeychain: keychain,
            kSecPrivateKeyAttrs: [kSecAttrIsPermanent: true],
        ] as CFDictionary, &cfError),
              let publicKey = SecKeyCopyPublicKey(privateKey),
              let x963 = SecKeyCopyExternalRepresentation(publicKey, &cfError) as Data?,
              let p256 = try? P256.Signing.PublicKey(x963Representation: x963) else {
            throw XCTSkip("temporary keychain key unavailable: \(String(describing: cfError?.takeRetainedValue()))")
        }
        let signer = Certificate.PrivateKey(P256.Signing.PrivateKey())
        let name = try DistinguishedName { CommonName("meowdisplay-test-\(UUID().uuidString)") }
        let now = Date()
        let certificate = try Certificate(
            version: .v3, serialNumber: Certificate.SerialNumber(), publicKey: Certificate.PublicKey(p256),
            notValidBefore: now.addingTimeInterval(-3600), notValidAfter: now.addingTimeInterval(3600),
            issuer: name, subject: name, signatureAlgorithm: .ecdsaWithSHA256,
            extensions: try Certificate.Extensions { Critical(BasicConstraints.notCertificateAuthority) },
            issuerPrivateKey: signer)
        var serializer = DER.Serializer()
        try serializer.serialize(certificate)
        guard let secCert = SecCertificateCreateWithData(nil, Data(serializer.serializedBytes) as CFData) else {
            throw XCTSkip("could not build test certificate")
        }
        var status = SecItemAdd([kSecClass: kSecClassCertificate, kSecValueRef: secCert,
                                 kSecUseKeychain: keychain] as CFDictionary, nil)
        guard status == errSecSuccess else { throw XCTSkip("temporary certificate import failed (status \(status))") }
        var identity: SecIdentity?
        status = SecIdentityCreateWithCertificate(keychain, secCert, &identity)
        guard status == errSecSuccess, let identity else {
            throw XCTSkip("temporary identity unavailable (status \(status))")
        }
        return Identity(identity: identity, spki: p256.derRepresentation)
    }
}

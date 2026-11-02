import CryptoKit
import Foundation

/// A real, canonical P-256 SPKI per name, deterministic across runs: pairing
/// only accepts identities a TLS handshake could present (F1).
enum TestSPKI {
    static func of(_ name: String) -> Data {
        let seed = Data(SHA256.hash(data: Data(name.utf8)))
        // A valid scalar: SHA-256 of a name is below the P-256 order for these names.
        return (try? P256.Signing.PrivateKey(rawRepresentation: seed))?.publicKey.derRepresentation
            ?? P256.Signing.PrivateKey().publicKey.derRepresentation
    }
}

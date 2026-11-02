// Verifies an Ed25519 signature with CryptoKit.
// Usage: swift verify-ed25519.swift <base64 public key> <file> <base64 signature>
// Exits 0 if the signature over <file> verifies against the public key.
import CryptoKit
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 4,
      let publicKeyData = Data(base64Encoded: arguments[1]),
      let signature = Data(base64Encoded: arguments[3]),
      let message = FileManager.default.contents(atPath: arguments[2])
else {
    FileHandle.standardError.write(Data("usage: verify-ed25519.swift <base64 public key> <file> <base64 signature>\n".utf8))
    exit(2)
}
let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData)
exit(publicKey.isValidSignature(signature, for: message) ? 0 : 1)

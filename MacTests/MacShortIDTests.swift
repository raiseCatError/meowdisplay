import XCTest

/// Same-named Macs are told apart by a short ID from their identity key. Android computes the
/// same value (PinnedTlsShortIdTest uses the same vector).
final class MacShortIDTests: XCTestCase {
    func testKnownVectorMatchesAndroid() {
        XCTAssertEqual(TrustStore.shortID(spki: Data(0..<64)), "1764")
    }

    func testDifferentKeysGiveDifferentIDsAndShowNoFingerprintDigits() {
        let a = Data(0..<64), b = Data((0..<64).map { UInt8($0 ^ 0x5A) })
        XCTAssertNotEqual(TrustStore.shortID(spki: a), TrustStore.shortID(spki: b))
        XCTAssertEqual(TrustStore.shortID(spki: a).count, 4)
        let fingerprint = TrustStore.fingerprint(spki: a).replacingOccurrences(of: " ", with: "")
        XCTAssertFalse(fingerprint.hasPrefix(TrustStore.shortID(spki: a)), "its own derivation, not the fingerprint's first digits")
    }
}

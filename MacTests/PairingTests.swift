import CryptoKit
import XCTest

final class PairingTests: XCTestCase {
    private let initiatorKey = try! P256.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 1, count: 32))
    private let responderKey = try! P256.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 2, count: 32))

    private func pair(name: String = "Phone") throws -> (PairingResult, PairingResult) {
        let initiator = PairingHandshake(
            role: .initiator, deviceID: "11111111-1111-1111-1111-111111111111",
            displayName: "Mac", identitySPKI: Data("mac identity".utf8),
            ephemeralKey: initiatorKey, nonce: Data(repeating: 3, count: 32))
        let responder = PairingHandshake(
            role: .responder, deviceID: "22222222-2222-2222-2222-222222222222",
            displayName: name, identitySPKI: Data("phone identity".utf8),
            ephemeralKey: responderKey, nonce: Data(repeating: 4, count: 32))
        return (try initiator.result(peerHello: responder.localHello),
                try responder.result(peerHello: initiator.localHello))
    }

    func testBothSidesDeriveSameSASAndVerifyConfirmations() throws {
        let (mac, phone) = try pair()
        XCTAssertEqual(mac.pending.sas, phone.pending.sas)
        XCTAssertNoThrow(try mac.verify(phone.confirmation(accepted: true)))
        XCTAssertNoThrow(try phone.verify(mac.confirmation(accepted: true)))
    }

    func testRejectedConfirmationIsAuthenticatedAndRejected() throws {
        let (mac, phone) = try pair()
        XCTAssertThrowsError(try mac.verify(phone.confirmation(accepted: false))) {
            XCTAssertEqual($0 as? PairingError, .rejected)
        }
    }

    func testChangedTranscriptChangesSASAndInvalidatesConfirmation() throws {
        let (originalMac, originalPhone) = try pair()
        let (changedMac, _) = try pair(name: "Other Phone")
        XCTAssertNotEqual(originalMac.pending.sas, changedMac.pending.sas)
        XCTAssertThrowsError(try changedMac.verify(originalPhone.confirmation(accepted: true)))
    }

    func testMalformedAndOldHelloAreRejected() {
        let malformed = PairingHello(version: WireProtocol.securePairingWireVersion,
            deviceID: "not-a-uuid", displayName: "Phone", identitySPKI: Data(),
            ephemeralPublicKey: Data(), nonce: Data())
        XCTAssertThrowsError(try malformed.validate())
        let old = PairingHello(version: WireProtocol.securePairingWireVersion - 1,
            deviceID: UUID().uuidString, displayName: "Phone", identitySPKI: Data([1]),
            ephemeralPublicKey: responderKey.publicKey.x963Representation,
            nonce: Data(repeating: 1, count: 32))
        XCTAssertThrowsError(try old.validate()) {
            XCTAssertEqual($0 as? PairingError, .unsupportedVersion)
        }
    }

    func testPinCannotBeSilentlyOverwrittenAndForgetIsPeerOnly() {
        let store = InMemoryPeerTrustStore()
        XCTAssertTrue(store.setPin(peerID: "phone", spki: Data([1]), displayName: "Phone"))
        XCTAssertTrue(store.setPin(peerID: "mac", spki: Data([2]), displayName: "Mac"))
        XCTAssertFalse(store.setPin(peerID: "phone", spki: Data([9]), displayName: "Impostor"))
        XCTAssertEqual(store.pin(peerID: "phone"), Data([1]))
        store.forget(peerID: "phone")
        XCTAssertNil(store.pin(peerID: "phone"))
        XCTAssertEqual(store.pin(peerID: "mac"), Data([2]))
    }

    func testNormalDiscoveryAssociatesWithPairingServiceByStableID() {
        let wanted = "11111111-1111-1111-1111-111111111111"
        let records = [PairingServiceRecord(stableID: wanted,
                                             displayName: "Mac", endpoint: "pair-endpoint")]
        XCTAssertEqual(PairingServiceAssociation.endpoint(forStableID: wanted, in: records),
                       "pair-endpoint")
    }

    func testAssociationUpdatesWhenPairingServiceAppears() {
        let wanted = "11111111-1111-1111-1111-111111111111"
        XCTAssertNil(PairingServiceAssociation.endpoint(forStableID: wanted,
                                                         in: [PairingServiceRecord<String>]()))
        let appeared = [PairingServiceRecord(stableID: wanted,
                                              displayName: "Mac", endpoint: "later")]
        XCTAssertEqual(PairingServiceAssociation.endpoint(forStableID: wanted, in: appeared), "later")
    }

    func testWrongStableIDAndSameNameDoNotCrossPair() {
        let wanted = "11111111-1111-1111-1111-111111111111"
        let other = "22222222-2222-2222-2222-222222222222"
        let records = [PairingServiceRecord(stableID: other,
                                             displayName: "Same Mac Name", endpoint: "wrong")]
        XCTAssertNil(PairingServiceAssociation.endpoint(forStableID: wanted, in: records))
    }

    func testPairingServiceRemovalMakesEndpointUnavailable() {
        let wanted = "11111111-1111-1111-1111-111111111111"
        let removed: [PairingServiceRecord<String>] = []
        XCTAssertNil(PairingServiceAssociation.endpoint(forStableID: wanted, in: removed))
    }
}

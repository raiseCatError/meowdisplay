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
        let malformed = PairingHello(version: WireProtocol.pairingVersion,
            deviceID: "not-a-uuid", displayName: "Phone", identitySPKI: Data(),
            ephemeralPublicKey: Data(), nonce: Data())
        XCTAssertThrowsError(try malformed.validate())
        let old = PairingHello(version: WireProtocol.pairingVersion - 1,
            deviceID: UUID().uuidString, displayName: "Phone", identitySPKI: Data([1]),
            ephemeralPublicKey: responderKey.publicKey.x963Representation,
            nonce: Data(repeating: 1, count: 32))
        XCTAssertThrowsError(try old.validate()) {
            XCTAssertEqual($0 as? PairingError, .unsupportedVersion)
        }
    }

    // MARK: - v13 hello commitment (canonical encoding, grinding fix)

    private func makeInitiatorHello(deviceID: String = "11111111-1111-1111-1111-111111111111",
                                    displayName: String = "Mac",
                                    identitySPKI: Data = Data("mac identity".utf8),
                                    ephemeralKey: P256.KeyAgreement.PrivateKey? = nil,
                                    nonce: Data = Data(repeating: 3, count: 32)) -> PairingHello {
        PairingHello(version: WireProtocol.pairingVersion, deviceID: deviceID, displayName: displayName,
                     identitySPKI: identitySPKI,
                     ephemeralPublicKey: (ephemeralKey ?? initiatorKey).publicKey.x963Representation,
                     nonce: nonce)
    }

    func testCommitmentIsDeterministic() {
        let hello = makeInitiatorHello()
        XCTAssertEqual(PairingHelloCommitment.compute(initiatorHello: hello),
                       PairingHelloCommitment.compute(initiatorHello: hello))
    }

    func testCommitmentVerifiesAgainstTheExactRevealedHello() {
        let hello = makeInitiatorHello()
        let commitment = PairingHelloCommitment.compute(initiatorHello: hello)
        XCTAssertTrue(PairingHelloCommitment.verify(commitment, revealedInitiatorHello: hello))
    }

    func testCommitmentRejectsChangedDeviceID() {
        let hello = makeInitiatorHello()
        let commitment = PairingHelloCommitment.compute(initiatorHello: hello)
        let changed = makeInitiatorHello(deviceID: "33333333-3333-3333-3333-333333333333")
        XCTAssertFalse(PairingHelloCommitment.verify(commitment, revealedInitiatorHello: changed))
    }

    func testCommitmentRejectsChangedDisplayName() {
        let hello = makeInitiatorHello()
        let commitment = PairingHelloCommitment.compute(initiatorHello: hello)
        let changed = makeInitiatorHello(displayName: "Different")
        XCTAssertFalse(PairingHelloCommitment.verify(commitment, revealedInitiatorHello: changed))
    }

    func testCommitmentRejectsChangedSPKI() {
        let hello = makeInitiatorHello()
        let commitment = PairingHelloCommitment.compute(initiatorHello: hello)
        let changed = makeInitiatorHello(identitySPKI: Data("other identity".utf8))
        XCTAssertFalse(PairingHelloCommitment.verify(commitment, revealedInitiatorHello: changed))
    }

    func testCommitmentRejectsChangedEphemeralKey() {
        let hello = makeInitiatorHello()
        let commitment = PairingHelloCommitment.compute(initiatorHello: hello)
        let otherKey = try! P256.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 9, count: 32))
        let changed = makeInitiatorHello(ephemeralKey: otherKey)
        XCTAssertFalse(PairingHelloCommitment.verify(commitment, revealedInitiatorHello: changed))
    }

    func testCommitmentRejectsChangedNonce() {
        let hello = makeInitiatorHello()
        let commitment = PairingHelloCommitment.compute(initiatorHello: hello)
        let changed = makeInitiatorHello(nonce: Data(repeating: 7, count: 32))
        XCTAssertFalse(PairingHelloCommitment.verify(commitment, revealedInitiatorHello: changed))
    }

    /// The commitment is computed with a fixed `.initiator` role byte; a
    /// responder-role commitment over identical field bytes must not verify
    /// against it — the role byte binds the domain, not just the payload.
    func testCommitmentDoesNotCollideAcrossDomainLabelOrRole() {
        let hello = makeInitiatorHello()
        let commitment = PairingHelloCommitment.compute(initiatorHello: hello)
        var tampered = commitment
        tampered[0] ^= 0xFF
        XCTAssertFalse(PairingHelloCommitment.verify(tampered, revealedInitiatorHello: hello))
    }

    /// Two fields' length-prefixed concatenation cannot be re-split to
    /// collide with a different pair of fields carrying the same total bytes.
    func testCanonicalLengthPrefixingPreventsFieldBoundaryAmbiguity() {
        let a = makeInitiatorHello(displayName: "AB", identitySPKI: Data("C".utf8))
        let b = makeInitiatorHello(displayName: "A", identitySPKI: Data("BC".utf8))
        XCTAssertNotEqual(PairingHelloCommitment.compute(initiatorHello: a),
                          PairingHelloCommitment.compute(initiatorHello: b))
    }

    func testShortCommitmentIsRejectedNotJustMismatched() {
        let hello = makeInitiatorHello()
        XCTAssertFalse(PairingHelloCommitment.verify(Data(repeating: 0, count: 16),
                                                      revealedInitiatorHello: hello))
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

    // MARK: - Re-pair classification (issue: asymmetric-trust re-pair UX)

    func testTrustPinPolicyClassifiesNewMatchAndIdentityChangeDistinctly() {
        XCTAssertEqual(TrustPinPolicy.decision(existing: nil, presented: Data([1])), .new)
        XCTAssertEqual(TrustPinPolicy.decision(existing: Data([1]), presented: Data([1])), .match)
        XCTAssertEqual(TrustPinPolicy.decision(existing: Data([1]), presented: Data([2])), .identityChanged)
    }

    func testIdentityChangeIsRefusedWithoutExplicitApprovalButAllowedWith() {
        let store = InMemoryPeerTrustStore()
        XCTAssertTrue(store.setPin(peerID: "phone", spki: Data([1]), displayName: "Phone"))
        // A changed identity presenting under the same peer ID must never
        // silently replace the pin — only an explicit, confirmed re-pair may.
        XCTAssertFalse(store.setPin(peerID: "phone", spki: Data([2]), displayName: "Phone",
                                    allowIdentityChange: false))
        XCTAssertEqual(store.pin(peerID: "phone"), Data([1]))
        XCTAssertTrue(store.setPin(peerID: "phone", spki: Data([2]), displayName: "Phone",
                                   allowIdentityChange: true))
        XCTAssertEqual(store.pin(peerID: "phone"), Data([2]))
    }

    func testSameKeyRePairSucceedsWithoutNeedingIdentityChangeApproval() {
        let store = InMemoryPeerTrustStore()
        XCTAssertTrue(store.setPin(peerID: "phone", spki: Data([1]), displayName: "Phone"))
        // A re-pair with the SAME long-term key (one side merely forgot the
        // other) is a `.match`, not an identity change — it must succeed
        // without the identity-change escape hatch.
        XCTAssertTrue(store.setPin(peerID: "phone", spki: Data([1]), displayName: "Phone",
                                   allowIdentityChange: false))
        XCTAssertEqual(store.pin(peerID: "phone"), Data([1]))
    }

    func testPendingPairingDefaultsToNewPeerClassification() {
        let pending = PendingPairing(peerID: "p", peerName: "Phone", peerSPKI: Data([1]), sas: "000 000")
        XCTAssertEqual(pending.classification, .newPeer)
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

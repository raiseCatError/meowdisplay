import CryptoKit
import XCTest

/// Known-good vectors from the Swift implementation for other MeowDisplay
/// receivers (the Android port replays them in `AndroidReceiver/core`): the
/// v13 pairing ceremony, TLS pin fingerprints and the audio media frames.
/// Inputs are fixed, so every value is reproducible; the checked-in file is
/// the contract both implementations are held to.
///
/// To regenerate after a deliberate protocol change:
/// `TEST_RUNNER_MEOW_WRITE_FIXTURES=1 xcodebuild test … -only-testing:OpenSidecarMacTests/CrossPlatformFixtureTests`
final class CrossPlatformFixtureTests: XCTestCase {
    private static let fixtureURL = URL(fileURLWithPath: #filePath)
        .resolvingSymlinksInPath()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("fixtures/receiver-protocol/swift-vectors.json")

    // MARK: - Fixed inputs

    private struct Party {
        let deviceID: String
        let displayName: String
        let identityKey: P256.Signing.PrivateKey
        let ephemeralKey: P256.KeyAgreement.PrivateKey
        let nonce: Data

        init(deviceID: String, displayName: String, seed: String) {
            self.deviceID = deviceID
            self.displayName = displayName
            identityKey = try! P256.Signing.PrivateKey(rawRepresentation: Self.digest("\(seed)/identity"))
            ephemeralKey = try! P256.KeyAgreement.PrivateKey(rawRepresentation: Self.digest("\(seed)/ephemeral"))
            nonce = Self.digest("\(seed)/nonce")
        }

        static func digest(_ text: String) -> Data { Data(SHA256.hash(data: Data(text.utf8))) }

        var spki: Data { identityKey.publicKey.derRepresentation }

        func handshake(_ role: PairingHandshake.Role) -> PairingHandshake {
            PairingHandshake(role: role, deviceID: deviceID, displayName: displayName,
                             identitySPKI: spki, ephemeralKey: ephemeralKey, nonce: nonce)
        }

        var json: [String: Any] {
            [
                "deviceID": deviceID,
                "displayName": displayName,
                "identityPrivateKey": identityKey.rawRepresentation.hex,
                "identitySPKI": spki.base64EncodedString(),
                "ephemeralPrivateKey": ephemeralKey.rawRepresentation.hex,
                "ephemeralPublicKey": ephemeralKey.publicKey.x963Representation.base64EncodedString(),
                "nonce": nonce.base64EncodedString(),
            ]
        }
    }

    private static let cases: [(name: String, initiator: Party, responder: Party)] = [
        ("mac-initiates-android-responds",
         Party(deviceID: "0F1E2D3C-4B5A-6978-8796-A5B4C3D2E1F0", displayName: "MacBook Air", seed: "fixture-mac"),
         Party(deviceID: "1A2B3C4D-5E6F-4071-8293-A4B5C6D7E8F9", displayName: "Pixel 9 Pro Fold", seed: "fixture-android")),
        ("android-initiates-mac-responds-unicode-name",
         Party(deviceID: "2B3C4D5E-6F70-4182-93A4-B5C6D7E8F901", displayName: "Äidin tabletti 🐱", seed: "fixture-tablet"),
         Party(deviceID: "3C4D5E6F-7081-4293-A4B5-C6D7E8F90112", displayName: "Family MacBook", seed: "fixture-family-mac")),
    ]

    // MARK: - Vectors

    private static func pairingCase(name: String, initiator: Party, responder: Party) throws -> [String: Any] {
        let initiatorHandshake = initiator.handshake(.initiator)
        let responderHandshake = responder.handshake(.responder)
        let initiatorResult = try initiatorHandshake.result(peerHello: responderHandshake.localHello)
        let responderResult = try responderHandshake.result(peerHello: initiatorHandshake.localHello)
        XCTAssertEqual(initiatorResult.pending.sas, responderResult.pending.sas)

        func steps(_ result: PairingResult) -> [String: String] {
            [
                "commit": result.stepAuthenticator(.commit).base64EncodedString(),
                "commitAck": result.stepAuthenticator(.commitAck).base64EncodedString(),
                "abort": result.stepAuthenticator(.abort).base64EncodedString(),
            ]
        }
        func encoded(_ envelope: PairingEnvelope) throws -> String {
            String(decoding: try JSONEncoder().encode(envelope), as: UTF8.self)
        }
        let commitment = PairingHelloCommitment.compute(initiatorHello: initiatorHandshake.localHello)
        return [
            "name": name,
            "initiator": initiator.json,
            "responder": responder.json,
            "helloCommitment": commitment.base64EncodedString(),
            "sas": initiatorResult.pending.sas,
            "initiatorConfirmationAccepted": initiatorResult.confirmation(accepted: true).authenticator.base64EncodedString(),
            "initiatorConfirmationRejected": initiatorResult.confirmation(accepted: false).authenticator.base64EncodedString(),
            "responderConfirmationAccepted": responderResult.confirmation(accepted: true).authenticator.base64EncodedString(),
            "responderConfirmationRejected": responderResult.confirmation(accepted: false).authenticator.base64EncodedString(),
            "initiatorSteps": steps(initiatorResult),
            "responderSteps": steps(responderResult),
            // Exactly what the Swift side puts on the wire (JSONEncoder
            // defaults: escaped slashes, unordered keys), for decoders.
            "envelopes": [
                "helloCommit": try encoded(.helloCommit(commitment)),
                "hello": try encoded(.hello(responderHandshake.localHello)),
                "helloReveal": try encoded(.helloReveal(initiatorHandshake.localHello)),
                "confirmation": try encoded(.confirmation(responderResult.confirmation(accepted: true))),
                "commit": try encoded(.step(.commit, initiatorResult.stepAuthenticator(.commit))),
            ],
        ]
    }

    private static func audioFrames() -> [[String: Any]] {
        let cookie = AACLCFraming.audioSpecificConfig(sampleRate: 48_000, channelCount: 2) ?? Data()
        let frames: [(String, AudioMediaFrame, [String: Any])] = [
            ("config", .config(AudioConfigFrame(sampleRate: 48_000, channelCount: 2, cookie: cookie)),
             ["sampleRate": 48_000, "channelCount": 2, "cookie": cookie.base64EncodedString()]),
            ("packet", .packet(AudioPacketFrame(sequence: 7, capturedAtMs: 1_793_000_000_123, durationMs: 21,
                                                payload: Data([0x21, 0x1B, 0x94, 0x00, 0xFF]))),
             ["sequence": 7, "capturedAtMs": 1_793_000_000_123, "durationMs": 21, "payload": "IRuUAP8="]),
            ("pcmConfig", .pcmConfig(PCMConfigFrame(sampleRate: 48_000, channelCount: 2)),
             ["sampleRate": 48_000, "channelCount": 2]),
            ("pcmPacket", .pcmPacket(PCMPacketFrame(sequence: 1, capturedAtMs: -5, frameCount: 2,
                                                    payload: Data([0, 0, 0x80, 0x3F, 0, 0, 0x80, 0xBF]))),
             ["sequence": 1, "capturedAtMs": -5, "frameCount": 2, "payload": "AACAPwAAgL8="]),
        ]
        return frames.map { kind, frame, fields in
            var json = fields
            json["kind"] = kind
            json["bytes"] = frame.encode().base64EncodedString()
            return json
        }
    }

    private static func vectors() throws -> [String: Any] {
        var fingerprints: [[String: String]] = []
        for (_, initiator, responder) in cases {
            for party in [initiator, responder] {
                fingerprints.append(["spki": party.spki.base64EncodedString(),
                                     "fingerprint": TrustStore.fingerprint(spki: party.spki)])
            }
        }
        return [
            "_comment": "Generated from the Swift implementation by MacTests/CrossPlatformFixtureTests.swift. Do not edit by hand.",
            "pairingVersion": WireProtocol.pairingVersion,
            "pairing": try cases.map { try pairingCase(name: $0.name, initiator: $0.initiator, responder: $0.responder) },
            "fingerprints": fingerprints,
            "audioFrames": audioFrames(),
        ]
    }

    // MARK: - Tests

    func testTheCheckedInVectorsMatchTheSwiftImplementation() throws {
        let computed = try Self.vectors()
        if ProcessInfo.processInfo.environment["MEOW_WRITE_FIXTURES"] == "1" {
            try FileManager.default.createDirectory(at: Self.fixtureURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            var data = try JSONSerialization.data(withJSONObject: computed,
                                                  options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            data.append(UInt8(ascii: "\n"))
            try data.write(to: Self.fixtureURL)
        }
        let stored = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: Self.fixtureURL)) as? [String: Any])
        // Envelope strings are compared by meaning: JSONEncoder's key order
        // isn't part of the contract.
        XCTAssertEqual(NSDictionary(dictionary: Self.withoutEnvelopes(stored)),
                       NSDictionary(dictionary: Self.withoutEnvelopes(computed)))
        let storedCases = try XCTUnwrap(stored["pairing"] as? [[String: Any]])
        let computedCases = try XCTUnwrap(computed["pairing"] as? [[String: Any]])
        XCTAssertEqual(storedCases.count, computedCases.count)
        for (storedCase, computedCase) in zip(storedCases, computedCases) {
            let storedEnvelopes = try XCTUnwrap(storedCase["envelopes"] as? [String: String])
            let computedEnvelopes = try XCTUnwrap(computedCase["envelopes"] as? [String: String])
            XCTAssertEqual(Set(storedEnvelopes.keys), Set(computedEnvelopes.keys))
            for (kind, text) in computedEnvelopes {
                let mine = try JSONDecoder().decode(PairingEnvelope.self, from: Data(text.utf8))
                let theirs = try JSONDecoder().decode(PairingEnvelope.self,
                                                      from: Data(try XCTUnwrap(storedEnvelopes[kind]).utf8))
                XCTAssertEqual(Self.describe(mine), Self.describe(theirs), kind)
            }
        }
    }

    /// The stored vectors replay through the Swift implementation itself:
    /// each recorded reveal satisfies its recorded commitment and each
    /// recorded confirmation verifies on the other side.
    func testStoredVectorsVerifyAgainstTheirOwnCommitmentsAndConfirmations() throws {
        let stored = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: Self.fixtureURL)) as? [String: Any])
        for (index, pairing) in try XCTUnwrap(stored["pairing"] as? [[String: Any]]).enumerated() {
            let (_, initiator, responder) = Self.cases[index]
            let envelopes = try XCTUnwrap(pairing["envelopes"] as? [String: String])
            let reveal = try JSONDecoder().decode(PairingEnvelope.self,
                                                  from: Data(try XCTUnwrap(envelopes["helloReveal"]).utf8))
            let commitment = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(pairing["helloCommitment"] as? String)))
            XCTAssertTrue(PairingHelloCommitment.verify(commitment, revealedInitiatorHello: try XCTUnwrap(reveal.hello)))

            let initiatorResult = try initiator.handshake(.initiator).result(peerHello: responder.handshake(.responder).localHello)
            let responderAccepted = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(pairing["responderConfirmationAccepted"] as? String)))
            XCTAssertNoThrow(try initiatorResult.verify(PairingConfirmation(accepted: true, authenticator: responderAccepted)))
            let responderRejected = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(pairing["responderConfirmationRejected"] as? String)))
            XCTAssertThrowsError(try initiatorResult.verify(PairingConfirmation(accepted: false, authenticator: responderRejected))) {
                XCTAssertEqual($0 as? PairingError, .rejected)
            }
            let commitAck = try XCTUnwrap((pairing["responderSteps"] as? [String: String])?["commitAck"])
            XCTAssertNoThrow(try initiatorResult.verifyStep(.commitAck, authenticator: try XCTUnwrap(Data(base64Encoded: commitAck))))
        }
    }

    private static func withoutEnvelopes(_ vectors: [String: Any]) -> [String: Any] {
        var copy = vectors
        copy["pairing"] = (vectors["pairing"] as? [[String: Any]])?.map { pairing -> [String: Any] in
            var stripped = pairing
            stripped["envelopes"] = nil
            return stripped
        }
        return copy
    }

    private static func describe(_ envelope: PairingEnvelope) -> String {
        [envelope.kind.rawValue,
         envelope.hello.map { "\($0)" } ?? "-",
         envelope.confirmation.map { "\($0.accepted) \($0.authenticator.base64EncodedString())" } ?? "-",
         envelope.authenticator?.base64EncodedString() ?? "-",
         envelope.helloCommitment?.base64EncodedString() ?? "-"].joined(separator: "|")
    }
}

private extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

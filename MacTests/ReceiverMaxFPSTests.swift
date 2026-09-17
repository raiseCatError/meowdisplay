import XCTest

final class ReceiverMaxFPSTests: XCTestCase {

    // MARK: - Preference basics

    func testUserCeilingFPSNilWhenDisabled() {
        let preference = ReceiverMaxFPSPreference(enabled: false, maxFPS: 30)
        XCTAssertNil(preference.userCeilingFPS)
    }

    func testUserCeilingFPSIsMaxFPSWhenEnabled() {
        let preference = ReceiverMaxFPSPreference(enabled: true, maxFPS: 30)
        XCTAssertEqual(preference.userCeilingFPS, 30)
    }

    func testStandardIsDisabled() {
        XCTAssertFalse(ReceiverMaxFPSPreference.standard.enabled)
    }

    // MARK: - Wire decode safety

    func testDecodeFailsOnMissingFields() {
        XCTAssertNil(ReceiverMaxFPSPreference(message: [:]))
        XCTAssertNil(ReceiverMaxFPSPreference(message: ["enabled": true]))
        XCTAssertNil(ReceiverMaxFPSPreference(message: ["maxFPS": 30]))
    }

    func testDecodeFailsOnNonPositiveMaxFPS() {
        XCTAssertNil(ReceiverMaxFPSPreference(message: ["enabled": true, "maxFPS": 0]))
        XCTAssertNil(ReceiverMaxFPSPreference(message: ["enabled": true, "maxFPS": -30]))
    }

    func testWireRoundTrip() {
        let original = ReceiverMaxFPSPreference(enabled: true, maxFPS: 60)
        var dict = original.wireFields
        dict["type"] = "maxFPSRequest"
        let decoded = ReceiverMaxFPSPreference(message: dict)
        XCTAssertEqual(decoded, original)
    }

    // MARK: - Request/confirm bookkeeping (mirrors ExtendShapeRequestState)

    func testRequestThenConfirmSameValue() {
        var state = MaxFPSRequestState()
        let preference = ReceiverMaxFPSPreference(enabled: true, maxFPS: 30)
        XCTAssertTrue(state.request(preference))
        XCTAssertEqual(state.pending, preference)
        XCTAssertTrue(state.confirm(preference))
        XCTAssertEqual(state.confirmed, preference)
        XCTAssertNil(state.pending)
    }

    func testConfirmDifferentValueIsNotReceiverInitiated() {
        var state = MaxFPSRequestState()
        let requested = ReceiverMaxFPSPreference(enabled: true, maxFPS: 30)
        let confirmedByMacUI = ReceiverMaxFPSPreference(enabled: true, maxFPS: 60)
        XCTAssertTrue(state.request(requested))
        XCTAssertFalse(state.confirm(confirmedByMacUI))
        XCTAssertEqual(state.confirmed, confirmedByMacUI)
        XCTAssertNil(state.pending)
    }

    func testCannotRequestWhilePending() {
        var state = MaxFPSRequestState()
        XCTAssertTrue(state.request(ReceiverMaxFPSPreference(enabled: true, maxFPS: 30)))
        XCTAssertFalse(state.request(ReceiverMaxFPSPreference(enabled: true, maxFPS: 60)))
    }

    func testRequestingAlreadyConfirmedValueIsRejected() {
        var state = MaxFPSRequestState()
        let preference = ReceiverMaxFPSPreference(enabled: true, maxFPS: 30)
        XCTAssertTrue(state.request(preference))
        XCTAssertTrue(state.confirm(preference))
        XCTAssertFalse(state.request(preference))
    }

    func testExpireOnlyRetiresOwnGeneration() {
        var state = MaxFPSRequestState()
        XCTAssertTrue(state.request(ReceiverMaxFPSPreference(enabled: true, maxFPS: 30)))
        let staleGeneration = state.pendingGeneration
        XCTAssertTrue(state.confirm(ReceiverMaxFPSPreference(enabled: true, maxFPS: 30)))
        XCTAssertTrue(state.request(ReceiverMaxFPSPreference(enabled: true, maxFPS: 60)))
        XCTAssertFalse(state.expirePending(generation: staleGeneration))
        XCTAssertNotNil(state.pending)
    }

    func testResetClearsBoth() {
        var state = MaxFPSRequestState()
        XCTAssertTrue(state.request(ReceiverMaxFPSPreference(enabled: true, maxFPS: 30)))
        XCTAssertTrue(state.confirm(ReceiverMaxFPSPreference(enabled: true, maxFPS: 30)))
        XCTAssertTrue(state.request(ReceiverMaxFPSPreference(enabled: true, maxFPS: 60)))
        state.reset()
        XCTAssertNil(state.confirmed)
        XCTAssertNil(state.pending)
    }

    // MARK: - Per-peer persistence isolation

    func testPerPeerPersistenceIsolation() {
        let peerA = "peer-\(UUID().uuidString)"
        let peerB = "peer-\(UUID().uuidString)"
        defer {
            UserDefaults.standard.removeObject(forKey: "receiverMaxFPS.\(peerA)")
            UserDefaults.standard.removeObject(forKey: "receiverMaxFPS.\(peerB)")
        }
        ReceiverMaxFPSStore.save(ReceiverMaxFPSPreference(enabled: true, maxFPS: 30), peerID: peerA)
        ReceiverMaxFPSStore.save(ReceiverMaxFPSPreference(enabled: false, maxFPS: 60), peerID: peerB)

        XCTAssertEqual(ReceiverMaxFPSStore.load(peerID: peerA), ReceiverMaxFPSPreference(enabled: true, maxFPS: 30))
        XCTAssertEqual(ReceiverMaxFPSStore.load(peerID: peerB), ReceiverMaxFPSPreference(enabled: false, maxFPS: 60))
    }

    func testUnknownPeerLoadsNil() {
        XCTAssertNil(ReceiverMaxFPSStore.load(peerID: "never-seen-\(UUID().uuidString)"))
    }

    // MARK: - Older-peer wire-version compatibility

    func testMaxFPSWireVersionIsTheCurrentProtocolVersion() {
        XCTAssertEqual(WireProtocol.maxFPSWireVersion, WireProtocol.version)
    }

    // MARK: - maxFPSState wire round trip (PART 4/5/9)

    func testMaxFPSStateRoundTrip() {
        let original = MaxFPSStateUpdate(
            preference: ReceiverMaxFPSPreference(enabled: false, maxFPS: 60),
            availableTiers: [1, 5, 10, 24, 30, 60],
            encoderSafeFPS: 60, requestedFPS: 120, effectiveFPS: 60,
            reason: StreamingFPSPolicy.LimitReason.encoderThroughput.rawValue)
        var dict = original.wireFields
        dict["type"] = "maxFPSState"
        let decoded = MaxFPSStateUpdate(message: dict)
        XCTAssertEqual(decoded, original)
    }

    func testMaxFPSStateDecodeFailsOnWrongType() {
        XCTAssertNil(MaxFPSStateUpdate(message: ["type": "somethingElse", "enabled": false, "maxFPS": 60,
                                                 "encoderSafeFPS": 60, "requestedFPS": 60, "effectiveFPS": 60,
                                                 "reason": "requested"]))
    }
}

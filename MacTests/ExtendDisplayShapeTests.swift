import XCTest

final class ExtendDisplayShapeTests: XCTestCase {

    func testExtendShapeWireVersionIsFixedAtItsOwnMilestone() {
        // Extend shape bumped the wire at ITS milestone — see
        // MirrorDisplayWireTests/AudioMediaFrameTests for the same canary at
        // their own, now-superseded milestones, and ReceiverMaxFPSTests for
        // the CURRENT one.
        XCTAssertEqual(WireProtocol.extendShapeWireVersion, 14)
    }

    // MARK: - Automatic resolution

    func testAutomaticFullDisplayOnUsesReceiverAspect() {
        let preference = ExtendDisplayShapePreference(shape: .automatic, useFullDisplay: true)
        XCTAssertEqual(preference.resolvedAspect(receiverPhysicalAspect: 19.5 / 9.0), 19.5 / 9.0, accuracy: 0.0001)
    }

    func testAutomaticFullDisplayOffUses16x10() {
        let preference = ExtendDisplayShapePreference(shape: .automatic, useFullDisplay: false)
        XCTAssertEqual(preference.resolvedAspect(receiverPhysicalAspect: 19.5 / 9.0), 16.0 / 10.0, accuracy: 0.0001)
    }

    func testAutomaticFullDisplayOnWithoutReceiverAspectFallsBackTo16x10() {
        let preference = ExtendDisplayShapePreference(shape: .automatic, useFullDisplay: true)
        XCTAssertEqual(preference.resolvedAspect(receiverPhysicalAspect: nil), 16.0 / 10.0, accuracy: 0.0001)
    }

    func testStandardDefaultIsAutomaticFullDisplayOff() {
        XCTAssertEqual(ExtendDisplayShapePreference.standard,
                      ExtendDisplayShapePreference(shape: .automatic, useFullDisplay: false))
    }

    // MARK: - Explicit ratios override receiver aspect

    func testExplicitRatiosIgnoreReceiverAspectAndFullDisplay() {
        let cases: [(ExtendDisplayShape, Double)] = [
            (.r16x10, 16.0 / 10.0), (.r16x9, 16.0 / 9.0), (.r3x2, 3.0 / 2.0),
            (.r4x3, 4.0 / 3.0), (.r5x4, 5.0 / 4.0), (.r21x9, 21.0 / 9.0),
            (.r32x9, 32.0 / 9.0), (.r1x1, 1.0),
        ]
        for (shape, expected) in cases {
            for useFullDisplay in [true, false] {
                let preference = ExtendDisplayShapePreference(shape: shape, useFullDisplay: useFullDisplay)
                XCTAssertEqual(preference.resolvedAspect(receiverPhysicalAspect: 4.0 / 3.0), expected,
                               accuracy: 0.0001, "\(shape.rawValue) useFullDisplay=\(useFullDisplay)")
            }
        }
    }

    func testEveryShapeHasAUniqueTitle() {
        let titles = Set(ExtendDisplayShape.allCases.map(\.title))
        XCTAssertEqual(titles.count, ExtendDisplayShape.allCases.count)
        XCTAssertEqual(ExtendDisplayShape.automatic.title, "Automatic")
        XCTAssertEqual(ExtendDisplayShape.r16x10.title, "16:10")
    }

    // MARK: - Wire decode safety

    func testWireDecodeRejectsUnknownShape() {
        XCTAssertNil(ExtendDisplayShapePreference(message: ["type": "extendShapeState", "shape": "9:99"]))
    }

    func testWireDecodeRejectsMissingShape() {
        XCTAssertNil(ExtendDisplayShapePreference(message: ["type": "extendShapeState"]))
    }

    func testWireDecodeDefaultsUseFullDisplayWhenAbsent() {
        let decoded = ExtendDisplayShapePreference(message: ["shape": "automatic"])
        XCTAssertEqual(decoded, ExtendDisplayShapePreference(shape: .automatic, useFullDisplay: false))
    }

    func testWireRoundTrip() {
        let original = ExtendDisplayShapePreference(shape: .r21x9, useFullDisplay: true)
        var message = original.wireFields
        message["type"] = "extendShapeRequest"
        XCTAssertEqual(ExtendDisplayShapePreference(message: message), original)
    }

    // MARK: - Sizing

    func testSizingMatchesLegacyBehaviorWhenAspectEqualsPhysical() {
        // Automatic + Full Display ON reduces to exactly the pre-pv-14
        // halving of the receiver's own pixels — no shape-driven change.
        let size = ExtendDisplaySizing.pointSize(receiverPixelsWide: 2556, receiverPixelsHigh: 1179,
                                                 aspect: 2556.0 / 1179.0)
        XCTAssertEqual(size.wide, (2556 / 2) & ~1)
        XCTAssertEqual(size.high, (1179 / 2) & ~1)
    }

    func testSizingProduces16x10ForDefaultAutomatic() {
        let size = ExtendDisplaySizing.pointSize(receiverPixelsWide: 2556, receiverPixelsHigh: 1179,
                                                 aspect: ExtendDisplayShape.defaultAutomaticAspect)
        XCTAssertEqual(Double(size.wide) / Double(size.high), 16.0 / 10.0, accuracy: 0.01)
    }

    func testSizingIsEvenAndPositiveForEveryExplicitRatio() {
        for shape in ExtendDisplayShape.allCases {
            guard let aspect = shape.explicitAspect else { continue }
            let size = ExtendDisplaySizing.pointSize(receiverPixelsWide: 2556, receiverPixelsHigh: 1179, aspect: aspect)
            XCTAssertGreaterThan(size.wide, 0, shape.rawValue)
            XCTAssertGreaterThan(size.high, 0, shape.rawValue)
            XCTAssertEqual(size.wide % 2, 0, shape.rawValue)
            XCTAssertEqual(size.high % 2, 0, shape.rawValue)
            XCTAssertEqual(Double(size.wide) / Double(size.high), aspect, accuracy: 0.02, shape.rawValue)
        }
    }

    func testSizingNeverGrowsPastTheReceiverPanelsOwnLongEdgeScale() {
        // Picking a taller ratio (e.g. 4:3) on a wide phone must not blow up
        // the desktop far beyond the panel's own implied scale.
        let wide = ExtendDisplaySizing.pointSize(receiverPixelsWide: 2796, receiverPixelsHigh: 1290, aspect: 4.0 / 3.0)
        XCTAssertLessThanOrEqual(wide.wide, (2796 / 2) & ~1)
    }

    func testSizingHandlesDegenerateInputSafely() {
        let size = ExtendDisplaySizing.pointSize(receiverPixelsWide: 0, receiverPixelsHigh: 0, aspect: 1.0)
        XCTAssertGreaterThan(size.wide, 0)
        XCTAssertGreaterThan(size.high, 0)
    }

    // MARK: - Request/confirm bookkeeping

    func testRequestThenConfirmSameValueReportsReceiverInitiated() {
        var state = ExtendShapeRequestState()
        let preference = ExtendDisplayShapePreference(shape: .r16x9, useFullDisplay: false)
        XCTAssertTrue(state.request(preference))
        XCTAssertTrue(state.confirm(preference))
        XCTAssertEqual(state.confirmed, preference)
        XCTAssertNil(state.pending)
    }

    func testConfirmDifferentValueThanRequestedIsNotReceiverInitiated() {
        var state = ExtendShapeRequestState()
        let requested = ExtendDisplayShapePreference(shape: .r16x9, useFullDisplay: false)
        let macChose = ExtendDisplayShapePreference(shape: .r4x3, useFullDisplay: false)
        XCTAssertTrue(state.request(requested))
        XCTAssertFalse(state.confirm(macChose))
        XCTAssertEqual(state.confirmed, macChose)
    }

    func testCannotRequestWhileAlreadyPending() {
        var state = ExtendShapeRequestState()
        XCTAssertTrue(state.request(ExtendDisplayShapePreference(shape: .r16x9, useFullDisplay: false)))
        XCTAssertFalse(state.request(ExtendDisplayShapePreference(shape: .r4x3, useFullDisplay: false)))
    }

    func testRequestingTheAlreadyConfirmedValueIsRejected() {
        var state = ExtendShapeRequestState()
        let preference = ExtendDisplayShapePreference(shape: .r16x9, useFullDisplay: false)
        _ = state.request(preference)
        _ = state.confirm(preference)
        XCTAssertFalse(state.request(preference))
    }

    func testExpirePendingOnlyRetiresItsOwnGeneration() {
        var state = ExtendShapeRequestState()
        _ = state.request(ExtendDisplayShapePreference(shape: .r16x9, useFullDisplay: false))
        let staleGeneration = state.pendingGeneration - 1
        XCTAssertFalse(state.expirePending(generation: staleGeneration))
        XCTAssertNotNil(state.pending)
        XCTAssertTrue(state.expirePending(generation: state.pendingGeneration))
        XCTAssertNil(state.pending)
    }

    func testResetClearsBothConfirmedAndPending() {
        var state = ExtendShapeRequestState()
        let preference = ExtendDisplayShapePreference(shape: .r16x9, useFullDisplay: false)
        _ = state.request(preference)
        _ = state.confirm(preference)
        state.reset()
        XCTAssertNil(state.confirmed)
        XCTAssertNil(state.pending)
    }

    // MARK: - Per-peer persistence

    func testPerPeerPersistenceDoesNotBleedBetweenPeers() {
        let peerA = "test.extendshape.peerA.\(UUID().uuidString)"
        let peerB = "test.extendshape.peerB.\(UUID().uuidString)"
        defer {
            UserDefaults.standard.removeObject(forKey: "extendShape.\(peerA)")
            UserDefaults.standard.removeObject(forKey: "extendShape.\(peerB)")
        }
        XCTAssertNil(ExtendDisplayShapeStore.load(peerID: peerA))
        XCTAssertNil(ExtendDisplayShapeStore.load(peerID: peerB))

        ExtendDisplayShapeStore.save(ExtendDisplayShapePreference(shape: .r16x10, useFullDisplay: false), peerID: peerA)
        ExtendDisplayShapeStore.save(ExtendDisplayShapePreference(shape: .automatic, useFullDisplay: true), peerID: peerB)

        XCTAssertEqual(ExtendDisplayShapeStore.load(peerID: peerA),
                      ExtendDisplayShapePreference(shape: .r16x10, useFullDisplay: false))
        XCTAssertEqual(ExtendDisplayShapeStore.load(peerID: peerB),
                      ExtendDisplayShapePreference(shape: .automatic, useFullDisplay: true))
    }
}

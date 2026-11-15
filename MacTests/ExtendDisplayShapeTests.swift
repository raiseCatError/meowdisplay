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

    // MARK: - Desktop Size

    private let desktopSizeHellos: [(wide: Int, high: Int)] = [
        (2796, 1290), (1290, 2796), (2556, 1179), (2732, 2048), (2360, 1640), (1920, 1080),
    ]

    func testDesktopSizeFactorsAndTitles() {
        XCTAssertEqual(ExtendDesktopSize.allCases, [.standard, .larger, .largest])
        XCTAssertEqual(ExtendDesktopSize.standard.factor, 1.0, accuracy: 0.0001)
        XCTAssertEqual(ExtendDesktopSize.larger.factor, 0.8, accuracy: 0.0001)
        XCTAssertEqual(ExtendDesktopSize.largest.factor, 0.65, accuracy: 0.0001)
        XCTAssertEqual(ExtendDesktopSize.standard.title, "Default")
        XCTAssertEqual(ExtendDesktopSize.larger.title, "Larger Text")
        XCTAssertEqual(ExtendDesktopSize.largest.title, "Largest Text")
    }

    func testFactorOneReproducesTheExistingPointSizeForEveryShape() {
        for hello in desktopSizeHellos {
            let physicalAspect = Double(hello.wide) / Double(hello.high)
            for shape in ExtendDisplayShape.allCases {
                for useFullDisplay in [false, true] {
                    let preference = ExtendDisplayShapePreference(shape: shape, useFullDisplay: useFullDisplay)
                    let aspect = preference.resolvedAspect(receiverPhysicalAspect: physicalAspect)
                    let plain = ExtendDisplaySizing.pointSize(
                        receiverPixelsWide: hello.wide, receiverPixelsHigh: hello.high, aspect: aspect)
                    let scaledByOne = ExtendDisplaySizing.pointSize(
                        receiverPixelsWide: hello.wide, receiverPixelsHigh: hello.high, aspect: aspect,
                        desktopScale: 1)
                    let plan = ExtendDisplayPlan.resolve(
                        receiverPixelsWide: hello.wide, receiverPixelsHigh: hello.high, aspect: aspect,
                        desktopSize: .standard)
                    XCTAssertEqual(scaledByOne.wide, plain.wide, "\(hello) \(shape.rawValue)")
                    XCTAssertEqual(scaledByOne.high, plain.high, "\(hello) \(shape.rawValue)")
                    XCTAssertEqual(plan.wide, plain.wide, "\(hello) \(shape.rawValue)")
                    XCTAssertEqual(plan.high, plain.high, "\(hello) \(shape.rawValue)")
                }
            }
        }
    }

    func testStandardPointSizesKeepTheirExactLegacyValues() {
        // Automatic + Use Full Display: halving each axis independently.
        let full = ExtendDisplaySizing.pointSize(receiverPixelsWide: 2556, receiverPixelsHigh: 1179,
                                                 aspect: 2556.0 / 1179.0)
        XCTAssertEqual(full.wide, 1278)
        XCTAssertEqual(full.high, 588)
        // Default Automatic 16:10: long edge halved, short edge from the ratio.
        let sixteenTen = ExtendDisplaySizing.pointSize(receiverPixelsWide: 2796, receiverPixelsHigh: 1290,
                                                       aspect: ExtendDisplayShape.defaultAutomaticAspect)
        XCTAssertEqual(sixteenTen.wide, 1398)
        XCTAssertEqual(sixteenTen.high, 874)
    }

    func testScaledSizesAreEvenAtLeastTwoCloseInRatioAndNeverLargerThanStandard() {
        for hello in desktopSizeHellos {
            let physicalAspect = Double(hello.wide) / Double(hello.high)
            for shape in ExtendDisplayShape.allCases {
                let preference = ExtendDisplayShapePreference(shape: shape, useFullDisplay: false)
                let aspect = preference.resolvedAspect(receiverPhysicalAspect: physicalAspect)
                let standard = ExtendDisplaySizing.pointSize(
                    receiverPixelsWide: hello.wide, receiverPixelsHigh: hello.high, aspect: aspect)
                for size in ExtendDesktopSize.allCases {
                    let scaled = ExtendDisplaySizing.pointSize(
                        receiverPixelsWide: hello.wide, receiverPixelsHigh: hello.high, aspect: aspect,
                        desktopScale: size.factor)
                    let label = "\(hello) \(shape.rawValue) \(size.rawValue)"
                    XCTAssertEqual(scaled.wide % 2, 0, label)
                    XCTAssertEqual(scaled.high % 2, 0, label)
                    XCTAssertGreaterThanOrEqual(scaled.wide, 2, label)
                    XCTAssertGreaterThanOrEqual(scaled.high, 2, label)
                    XCTAssertLessThanOrEqual(scaled.wide, standard.wide, label)
                    XCTAssertLessThanOrEqual(scaled.high, standard.high, label)
                    let standardRatio = Double(standard.wide) / Double(standard.high)
                    let scaledRatio = Double(scaled.wide) / Double(scaled.high)
                    XCTAssertEqual(scaledRatio / standardRatio, 1.0, accuracy: 0.01, label)
                }
            }
        }
    }

    func testScalingNeverDropsBelowTwoPoints() {
        let tiny = ExtendDisplaySizing.pointSize(receiverPixelsWide: 6, receiverPixelsHigh: 4, aspect: 1.5,
                                                 desktopScale: 0.1)
        XCTAssertGreaterThanOrEqual(tiny.wide, 2)
        XCTAssertGreaterThanOrEqual(tiny.high, 2)
    }

    func testLargerSizesShrinkTheDesktopMonotonically() {
        let standard = ExtendDisplayPlan.resolve(receiverPixelsWide: 2796, receiverPixelsHigh: 1290,
                                                 aspect: 16.0 / 10.0, desktopSize: .standard)
        let larger = ExtendDisplayPlan.resolve(receiverPixelsWide: 2796, receiverPixelsHigh: 1290,
                                               aspect: 16.0 / 10.0, desktopSize: .larger)
        let largest = ExtendDisplayPlan.resolve(receiverPixelsWide: 2796, receiverPixelsHigh: 1290,
                                                aspect: 16.0 / 10.0, desktopSize: .largest)
        XCTAssertLessThan(larger.wide, standard.wide)
        XCTAssertLessThan(largest.wide, larger.wide)
        XCTAssertLessThan(larger.high, standard.high)
        XCTAssertLessThan(largest.high, larger.high)
    }

    func testDesktopSizeWireRoundTrip() {
        for size in ExtendDesktopSize.allCases {
            let original = ExtendDisplayShapePreference(shape: .r4x3, useFullDisplay: false, desktopSize: size)
            var message = original.wireFields
            message["type"] = "extendShapeRequest"
            XCTAssertEqual(message["desktopSize"] as? String, size.rawValue)
            XCTAssertEqual(ExtendDisplayShapePreference(message: message), original)
            XCTAssertEqual(ExtendDisplayShapePreference.desktopSize(inMessage: message), size)
        }
    }

    func testMessageWithoutDesktopSizeDecodesAsStandard() {
        let decoded = ExtendDisplayShapePreference(message: ["shape": "16:9", "useFullDisplay": false])
        XCTAssertEqual(decoded?.desktopSize, .standard)
        XCTAssertNil(ExtendDisplayShapePreference.desktopSize(inMessage: ["shape": "16:9"]))
    }

    func testMessageWithUnknownDesktopSizeDecodesAsStandard() {
        let message: [String: Any] = ["shape": "16:9", "useFullDisplay": false, "desktopSize": "enormous"]
        XCTAssertEqual(ExtendDisplayShapePreference(message: message)?.desktopSize, .standard)
        XCTAssertNil(ExtendDisplayShapePreference.desktopSize(inMessage: message))
    }

    func testCodableRecordWithoutDesktopSizeDecodesAsStandard() throws {
        let json = Data(#"{"shape":"21:9","useFullDisplay":true}"#.utf8)
        let decoded = try JSONDecoder().decode(ExtendDisplayShapePreference.self, from: json)
        XCTAssertEqual(decoded, ExtendDisplayShapePreference(shape: .r21x9, useFullDisplay: true))
        XCTAssertEqual(decoded.desktopSize, .standard)
    }

    func testCodableRoundTripKeepsDesktopSize() throws {
        let original = ExtendDisplayShapePreference(shape: .r3x2, useFullDisplay: false, desktopSize: .largest)
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(ExtendDisplayShapePreference.self, from: data), original)
    }

    func testStoredRecordWithoutDesktopSizeLoadsAsStandard() {
        let peer = "test.extendshape.legacy.\(UUID().uuidString)"
        let key = "extendShape.\(peer)"
        defer { UserDefaults.standard.removeObject(forKey: key) }
        UserDefaults.standard.set(["shape": "16:9", "useFullDisplay": false], forKey: key)
        let loaded = ExtendDisplayShapeStore.load(peerID: peer)
        XCTAssertEqual(loaded, ExtendDisplayShapePreference(shape: .r16x9, useFullDisplay: false))
        XCTAssertEqual(loaded?.desktopSize, .standard)
    }

    func testStoredDesktopSizeRoundTrips() {
        let peer = "test.extendshape.size.\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: "extendShape.\(peer)") }
        let preference = ExtendDisplayShapePreference(shape: .automatic, useFullDisplay: false, desktopSize: .larger)
        ExtendDisplayShapeStore.save(preference, peerID: peer)
        XCTAssertEqual(ExtendDisplayShapeStore.load(peerID: peer), preference)
    }

    // MARK: - Reservation and reconfigure decision

    func testReservationIsTheUnscaledLongEdgeForEveryDesktopSize() {
        for hello in desktopSizeHellos {
            let aspect = ExtendDisplayShape.defaultAutomaticAspect
            let standard = ExtendDisplayPlan.resolve(
                receiverPixelsWide: hello.wide, receiverPixelsHigh: hello.high, aspect: aspect,
                desktopSize: .standard)
            for size in ExtendDesktopSize.allCases {
                let plan = ExtendDisplayPlan.resolve(
                    receiverPixelsWide: hello.wide, receiverPixelsHigh: hello.high, aspect: aspect,
                    desktopSize: size)
                XCTAssertEqual(plan.reservedPointsPerAxis, max(standard.wide, standard.high), "\(hello) \(size)")
                XCTAssertEqual(plan.unscaledWide, standard.wide, "\(hello) \(size)")
                XCTAssertEqual(plan.unscaledHigh, standard.high, "\(hello) \(size)")
                XCTAssertGreaterThanOrEqual(plan.reservedPointsPerAxis, max(plan.wide, plan.high), "\(hello) \(size)")
            }
        }
    }

    func testReconfigureReRunsOnlyWhenTheCurrentPreferenceResolvesToDifferentPoints() {
        func plan(_ preference: ExtendDisplayShapePreference) -> ExtendDisplayPlan {
            ExtendDisplayPlan.resolve(
                receiverPixelsWide: 2796, receiverPixelsHigh: 1290,
                aspect: preference.resolvedAspect(receiverPhysicalAspect: 2796.0 / 1290.0),
                desktopSize: preference.desktopSize)
        }
        let applied = plan(.standard)
        XCTAssertFalse(ExtendDisplayPlan.needsAnotherPass(applied: applied, current: plan(.standard)))
        var larger = ExtendDisplayShapePreference.standard
        larger.desktopSize = .larger
        XCTAssertTrue(ExtendDisplayPlan.needsAnotherPass(applied: applied, current: plan(larger)))
        let widerShape = ExtendDisplayShapePreference(shape: .r21x9, useFullDisplay: false)
        XCTAssertTrue(ExtendDisplayPlan.needsAnotherPass(applied: applied, current: plan(widerShape)))
        // A preference change that resolves to the same points is not a reason to rebuild.
        let sameShapeFullOff = ExtendDisplayShapePreference(shape: .r16x10, useFullDisplay: true)
        XCTAssertFalse(ExtendDisplayPlan.needsAnotherPass(applied: applied, current: plan(sameShapeFullOff)))
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

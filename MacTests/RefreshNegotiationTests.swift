import XCTest

final class RefreshNegotiationTests: XCTestCase {

    private func input(mode: RefreshNegotiation.DisplayMode = .extend, profile: StreamingProfile = .performance,
                       customFPS: Int? = nil, source: Int?, receiverMax: Int?, effective: Int?,
                       user: Int? = nil, width: Int = 2388, height: Int = 1668,
                       codec: StreamCodec = .hevc, decode: Int? = nil) -> RefreshNegotiation.Input {
        RefreshNegotiation.Input(mode: mode, profile: profile, customFPS: customFPS, sourceRefreshHz: source,
                                 receiverMaxFPS: receiverMax, receiverEffectiveRefreshHz: effective,
                                 userMaxFPS: user, encodeWidth: width, encodeHeight: height, codec: codec,
                                 receiverDecodePixelsPerSecond: decode)
    }

    // MARK: - Old peers: exactly today's behaviour

    func testLegacyPeerGetsExactlyTodaysFrameRateAcrossTheMatrix() {
        let sizes = [(2388, 1668), (2796, 1572), (2796, 1196), (5120, 2880), (1704, 786)]
        let profiles: [(StreamingProfile, Int?)] = [(.efficiency, nil), (.performance, nil), (.custom, nil),
                                                    (.custom, 30), (.custom, 90), (.custom, 120)]
        for receiverMax in [nil, 30, 60, 90, 120, 144] as [Int?] {
            for user in [nil, 24, 60, 90] as [Int?] {
                for codec in StreamCodec.allCases {
                    for (width, height) in sizes {
                        for (profile, custom) in profiles {
                            for source in [nil, 60, 120] as [Int?] {
                                for mode in RefreshNegotiation.DisplayMode.allCases {
                                    let negotiationInput = input(mode: mode, profile: profile, customFPS: custom,
                                                                 source: source, receiverMax: receiverMax,
                                                                 effective: nil, user: user, width: width,
                                                                 height: height, codec: codec)
                                    let result = RefreshNegotiation.negotiate(negotiationInput)
                                    // Today's MacSender.effectiveFPS for an already chosen codec.
                                    let common = StreamingFPSPolicy.commonTargetFPS(
                                        profile: profile, requestedFPS: custom, receiverMaxFPS: receiverMax,
                                        userMaxFPS: user)
                                    let today = StreamingFPSPolicy.codecEffectiveFPS(
                                        commonTarget: common, codec: codec,
                                        encoderSafeFPS: EncoderCapability.codecSafeFPS(width: width, height: height))
                                    XCTAssertTrue(result.isLegacy)
                                    XCTAssertEqual(result.capabilityCeilingFPS, today.fps)
                                    XCTAssertEqual(result.initialTargetFPS, today.fps)
                                    XCTAssertEqual(result.legacyFPS, today.fps)
                                    XCTAssertEqual(result.allowedTargets, [today.fps])
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    func testLegacyLimitingStageMapsTodaysReason() {
        XCTAssertEqual(RefreshNegotiation.negotiate(input(source: 60, receiverMax: 60, effective: nil)).limitingStage,
                       .receiverMaximum)
        XCTAssertEqual(RefreshNegotiation.negotiate(input(source: 60, receiverMax: 120, effective: nil, user: 30)).limitingStage,
                       .userLimit)
        XCTAssertEqual(RefreshNegotiation.negotiate(input(source: 60, receiverMax: 120, effective: nil, width: 5120,
                                                          height: 2880, codec: .h264)).limitingStage,
                       .senderEncoder)
    }

    // MARK: - Source cadence

    func testNeverTargetsAboveTheSourceCadence() {
        let result = RefreshNegotiation.negotiate(input(mode: .mirror, source: 60, receiverMax: 120, effective: 120))
        XCTAssertFalse(result.isLegacy)
        XCTAssertEqual(result.capabilityCeilingFPS, 60)
        XCTAssertEqual(result.initialTargetFPS, 60)
        XCTAssertEqual(result.allowedTargets, [20, 30, 60])
        XCTAssertEqual(result.limitingStage, .source)
        XCTAssertEqual(result.legacyFPS, 120, "today's policy would have targeted 120 from a 60 Hz source")
    }

    func testUnknownSourceIsTreatedAsSixtyAndNeverOffersHighRefresh() {
        let result = RefreshNegotiation.negotiate(input(source: nil, receiverMax: 120, effective: 120))
        XCTAssertEqual(result.capabilityCeilingFPS, 60)
        XCTAssertFalse(result.allowedTargets.contains { $0 > 60 })
    }

    // MARK: - 60 first, 90/120 only when every stage agrees

    func testProMotionWithHighRefreshSourceStartsAtSixtyAndAllows120() {
        let result = RefreshNegotiation.negotiate(input(source: 120, receiverMax: 120, effective: 120))
        XCTAssertEqual(result.capabilityCeilingFPS, 120)
        XCTAssertEqual(result.initialTargetFPS, 60)
        XCTAssertEqual(result.allowedTargets, [20, 30, 60, 120], "90 does not divide a 120 Hz source evenly")
    }

    func testNinetyHzSourceAllowsNinety() {
        let result = RefreshNegotiation.negotiate(input(source: 90, receiverMax: 120, effective: 120))
        XCTAssertEqual(result.capabilityCeilingFPS, 90)
        XCTAssertEqual(result.allowedTargets, [20, 30, 60, 90])
        XCTAssertEqual(result.initialTargetFPS, 60)
    }

    func testEffectiveRefreshBelowMaximumWins() {
        // ProMotion held at 60 (for example by Low Power Mode).
        let result = RefreshNegotiation.negotiate(input(source: 120, receiverMax: 120, effective: 60))
        XCTAssertEqual(result.capabilityCeilingFPS, 60)
        XCTAssertEqual(result.limitingStage, .receiverEffective)
        XCTAssertEqual(result.allowedTargets, [20, 30, 60])
    }

    func testH264EncoderLimitAtTheActualRaster() {
        let result = RefreshNegotiation.negotiate(input(source: 120, receiverMax: 120, effective: 120,
                                                        width: 5120, height: 2880, codec: .h264))
        XCTAssertEqual(result.capabilityCeilingFPS, EncoderCapability.codecSafeFPS(width: 5120, height: 2880))
        XCTAssertEqual(result.limitingStage, .senderEncoder)
        XCTAssertEqual(result.allowedTargets, [20, 30, result.capabilityCeilingFPS])
        XCTAssertEqual(result.initialTargetFPS, result.capabilityCeilingFPS)
    }

    func testHEVCHasNoInventedEncoderCeiling() {
        let result = RefreshNegotiation.negotiate(input(source: 120, receiverMax: 120, effective: 120,
                                                        width: 5120, height: 2880, codec: .hevc))
        XCTAssertEqual(result.capabilityCeilingFPS, 120)
        XCTAssertFalse(result.stageLimits.contains { $0.stage == .senderEncoder })
    }

    func testReceiverDecoderThroughputLimit() {
        let pixels = 2388 * 1668
        let result = RefreshNegotiation.negotiate(input(source: 120, receiverMax: 120, effective: 120,
                                                        decode: pixels * 75))
        XCTAssertEqual(result.capabilityCeilingFPS, 75)
        XCTAssertEqual(result.limitingStage, .receiverDecoder)
        XCTAssertEqual(result.allowedTargets, [20, 30, 60])
    }

    func testUserLimitAndProfile() {
        let user = RefreshNegotiation.negotiate(input(source: 120, receiverMax: 120, effective: 120, user: 30))
        XCTAssertEqual(user.capabilityCeilingFPS, 30)
        XCTAssertEqual(user.limitingStage, .userLimit)
        XCTAssertEqual(user.allowedTargets, [20, 30])
        XCTAssertEqual(user.initialTargetFPS, 30)

        let efficiency = RefreshNegotiation.negotiate(input(profile: .efficiency, source: 120, receiverMax: 120,
                                                            effective: 120))
        XCTAssertEqual(efficiency.capabilityCeilingFPS, 60)
        XCTAssertEqual(efficiency.limitingStage, .profile)
    }

    func testProductCeilingIs120() {
        let result = RefreshNegotiation.negotiate(input(source: 240, receiverMax: 240, effective: 240))
        XCTAssertEqual(result.capabilityCeilingFPS, 120)
        // Performance requests exactly the product ceiling; the profile is
        // reported first on a tie.
        XCTAssertEqual(result.limitingStage, .profile)
        XCTAssertEqual(result.stageLimits.first { $0.stage == .productCeiling }?.fps, 120)
        XCTAssertEqual(result.allowedTargets.last, 120)
        XCTAssertFalse(result.allowedTargets.contains(90))
    }

    func testEachModeUsesItsOwnSource() {
        // Mirror: the physical display's active mode.
        XCTAssertEqual(RefreshNegotiation.negotiate(input(mode: .mirror, source: 60, receiverMax: 120,
                                                          effective: 120)).capabilityCeilingFPS, 60)
        // Extend: the virtual display's supported refresh.
        XCTAssertEqual(RefreshNegotiation.negotiate(input(mode: .extend, source: 120, receiverMax: 120,
                                                          effective: 120)).capabilityCeilingFPS, 120)
        // Window view: the compositor's frame budget.
        let window = RefreshNegotiation.negotiate(input(mode: .window, source: 30, receiverMax: 120, effective: 120))
        XCTAssertEqual(window.capabilityCeilingFPS, 30)
        XCTAssertEqual(window.allowedTargets, [20, 30])
    }

    func testCeilingAndTargetAreIndependentOfObservedPerformance() {
        // Same inputs, same answer: the negotiation has no performance input.
        let a = RefreshNegotiation.negotiate(input(source: 120, receiverMax: 120, effective: 120))
        let b = RefreshNegotiation.negotiate(input(source: 120, receiverMax: 120, effective: 120))
        XCTAssertEqual(a, b)
        XCTAssertLessThanOrEqual(a.initialTargetFPS, a.capabilityCeilingFPS)
    }
}

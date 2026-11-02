import XCTest

final class StreamingProfileTests: XCTestCase {

    /// No encoder/user ceiling in play — isolates the profile/receiver-
    /// capability behavior the original (pre-encoder-safety) test matrix
    /// covered, now through the 5-arg `effectiveFPS`.
    private func fps(profile: StreamingProfile, requestedFPS: Int? = nil, receiverMaxFPS: Int?,
                     userMaxFPS: Int? = nil, encoderSafeFPS: Int = StreamingFPSPolicy.hardCapFPS) -> Int {
        StreamingFPSPolicy.effectiveFPS(profile: profile, requestedFPS: requestedFPS, receiverMaxFPS: receiverMaxFPS,
                                        userMaxFPS: userMaxFPS, encoderSafeFPS: encoderSafeFPS).fps
    }

    // MARK: - Effective FPS policy (spec test matrix)

    func test60HzReceiverPerformanceIs60() {
        XCTAssertEqual(fps(profile: .performance, receiverMaxFPS: 60), 60)
    }

    func test120HzReceiverPerformanceIs120() {
        XCTAssertEqual(fps(profile: .performance, receiverMaxFPS: 120), 120)
    }

    func testOverReportedCapabilityClampsTo120() {
        XCTAssertEqual(fps(profile: .performance, receiverMaxFPS: 240), 120)
        XCTAssertEqual(fps(profile: .performance, receiverMaxFPS: 165), 120)
    }

    func testCustom120On60HzReceiverClampsSafely() {
        XCTAssertEqual(fps(profile: .custom, requestedFPS: 120, receiverMaxFPS: 60), 60)
    }

    func testEfficiencyNeverExceeds60() {
        for receiverMax in [nil, 30, 60, 90, 120, 240] as [Int?] {
            let value = fps(profile: .efficiency, receiverMaxFPS: receiverMax)
            XCTAssertLessThanOrEqual(value, 60, "Efficiency exceeded 60fps for receiverMaxFPS=\(String(describing: receiverMax))")
        }
    }

    func testOlderPeerWithNoCapabilityGetsSafeDefault() {
        // No `maxFPS` in hello at all (pre-milestone peer) — must not be
        // treated as "unlimited"; falls back to the documented safe default.
        XCTAssertEqual(fps(profile: .performance, receiverMaxFPS: nil), StreamingFPSPolicy.defaultReceiverMaxFPS)
        XCTAssertEqual(fps(profile: .custom, requestedFPS: 120, receiverMaxFPS: nil), StreamingFPSPolicy.defaultReceiverMaxFPS)
    }

    func testCustomAutoMatchesPerformanceCeiling() {
        for receiverMax in [30, 60, 90, 120] {
            XCTAssertEqual(fps(profile: .custom, receiverMaxFPS: receiverMax),
                           fps(profile: .performance, receiverMaxFPS: receiverMax))
        }
    }

    func testCustomRequestBelowReceiverCapabilityIsHonoredExactly() {
        XCTAssertEqual(fps(profile: .custom, requestedFPS: 30, receiverMaxFPS: 120), 30)
        XCTAssertEqual(fps(profile: .custom, requestedFPS: 90, receiverMaxFPS: 120), 90)
    }

    func testNeverExceedsHardCapRegardlessOfInputs() {
        let receiverCandidates: [Int?] = [nil, 1, 60, 120, 144, 165, 240, 1000]
        let requestCandidates: [Int?] = [nil, 1, 30, 60, 90, 120, 144, 240, 1000]
        for profile in StreamingProfile.allCases {
            for receiverMax in receiverCandidates {
                for requested in requestCandidates {
                    let value = fps(profile: profile, requestedFPS: requested, receiverMaxFPS: receiverMax)
                    XCTAssertLessThanOrEqual(value, StreamingFPSPolicy.hardCapFPS)
                    XCTAssertGreaterThanOrEqual(value, 1)
                }
            }
        }
    }

    // MARK: - Encoder-safe ceiling (PART 1/7)

    func testEncoderSafeCeilingWinsOverEverythingElse() {
        let result = StreamingFPSPolicy.effectiveFPS(profile: .performance, requestedFPS: nil,
                                                       receiverMaxFPS: 120, userMaxFPS: nil, encoderSafeFPS: 60)
        XCTAssertEqual(result.fps, 60)
        XCTAssertEqual(result.reason, .encoderThroughput)
    }

    func testEncoderSafeCeilingNeverRaisesRequestedFPS() {
        // A generous encoder ceiling must not push a lower profile/custom
        // request UP — encoderSafeFPS only ever narrows, never widens.
        let result = StreamingFPSPolicy.effectiveFPS(profile: .custom, requestedFPS: 30,
                                                       receiverMaxFPS: 120, userMaxFPS: nil, encoderSafeFPS: 120)
        XCTAssertEqual(result.fps, 30)
        XCTAssertEqual(result.reason, .requested)
    }

    func testRequested60NeverRaisedTo120ByAGenerousEncoderCeiling() {
        let result = StreamingFPSPolicy.effectiveFPS(profile: .custom, requestedFPS: 60,
                                                       receiverMaxFPS: 120, userMaxFPS: nil, encoderSafeFPS: 120)
        XCTAssertEqual(result.fps, 60)
    }

    // MARK: - Receiver-enforced user ceiling (PART 2)

    func testUserCeilingWinsWhenEnabled() {
        let result = StreamingFPSPolicy.effectiveFPS(profile: .performance, requestedFPS: nil,
                                                       receiverMaxFPS: 120, userMaxFPS: 30, encoderSafeFPS: 120)
        XCTAssertEqual(result.fps, 30)
        XCTAssertEqual(result.reason, .userCeiling)
    }

    func testUserCeilingIgnoredWhenNil() {
        // nil == enforcement OFF (ReceiverMaxFPSPreference.userCeilingFPS).
        let result = StreamingFPSPolicy.effectiveFPS(profile: .performance, requestedFPS: nil,
                                                       receiverMaxFPS: 120, userMaxFPS: nil, encoderSafeFPS: 120)
        XCTAssertEqual(result.fps, 120)
    }

    func testUserCeilingAboveEverythingElseDoesNotWin() {
        // A user ceiling higher than every other constraint never becomes
        // the reason — the tightest constraint always wins regardless of
        // which one it is.
        let result = StreamingFPSPolicy.effectiveFPS(profile: .performance, requestedFPS: nil,
                                                       receiverMaxFPS: 60, userMaxFPS: 120, encoderSafeFPS: 120)
        XCTAssertEqual(result.fps, 60)
        XCTAssertEqual(result.reason, .receiverCapability)
    }

    // MARK: - Available user-ceiling tiers (PART 2 picker filtering)

    func testAvailableTiersNeverExceedReceiverCapability() {
        let tiers = StreamingFPSPolicy.availableUserCeilingTiers(receiverMaxFPS: 60, encoderSafeFPS: 120)
        XCTAssertEqual(tiers, [1, 5, 10, 24, 30, 60])
    }

    func testAvailableTiersNeverExceedEncoderSafeCeiling() {
        // Exactly PART 2's own example: 120Hz receiver, 60fps-safe encode.
        let tiers = StreamingFPSPolicy.availableUserCeilingTiers(receiverMaxFPS: 120, encoderSafeFPS: 60)
        XCTAssertEqual(tiers, [1, 5, 10, 24, 30, 60])
        XCTAssertFalse(tiers.contains(120))
    }

    func testAvailableTiersReturnTo120WhenEncoderCeilingRecovers() {
        let limited = StreamingFPSPolicy.availableUserCeilingTiers(receiverMaxFPS: 120, encoderSafeFPS: 60)
        let recovered = StreamingFPSPolicy.availableUserCeilingTiers(receiverMaxFPS: 120, encoderSafeFPS: 120)
        XCTAssertFalse(limited.contains(120))
        XCTAssertTrue(recovered.contains(120))
    }

    // MARK: - Persisted profile survives reload

    func testPersistedProfileSurvivesReload() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        defer { defaults.removePersistentDomain(forName: #function) }

        defaults.set(StreamingProfile.performance.rawValue, forKey: "streamingProfile")
        let reloaded = StreamingProfile(rawValue: defaults.string(forKey: "streamingProfile") ?? "") ?? .performance
        XCTAssertEqual(reloaded, .performance)

        defaults.set(StreamingProfile.custom.rawValue, forKey: "streamingProfile")
        defaults.set(CustomFrameRateSelection.fps90.rawValue, forKey: "customFrameRate")
        let reloadedProfile = StreamingProfile(rawValue: defaults.string(forKey: "streamingProfile") ?? "") ?? .performance
        let reloadedFPS = CustomFrameRateSelection(rawValue: defaults.string(forKey: "customFrameRate") ?? "") ?? .auto
        XCTAssertEqual(reloadedProfile, .custom)
        XCTAssertEqual(reloadedFPS, .fps90)
        XCTAssertEqual(reloadedFPS.requestedFPS, 90)
    }

    func testUnknownPersistedRawValueFallsBackSafely() {
        // Simulates a downgrade/corrupted-defaults scenario: an unrecognized
        // rawValue must never crash the reload path.
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        defer { defaults.removePersistentDomain(forName: #function) }

        defaults.set("some-future-profile", forKey: "streamingProfile")
        let reloaded = StreamingProfile(rawValue: defaults.string(forKey: "streamingProfile") ?? "") ?? .performance
        XCTAssertEqual(reloaded, .performance)
    }

    // MARK: - Switching profiles updates effective settings

    func testSwitchingProfilesUpdatesEffectiveFPS() {
        let receiverMaxFPS = 120
        let efficiencyFPS = fps(profile: .efficiency, receiverMaxFPS: receiverMaxFPS)
        let performanceFPS = fps(profile: .performance, receiverMaxFPS: receiverMaxFPS)
        let customFPS = fps(profile: .custom, requestedFPS: 30, receiverMaxFPS: receiverMaxFPS)

        XCTAssertEqual(efficiencyFPS, 60)
        XCTAssertEqual(performanceFPS, 120)
        XCTAssertEqual(customFPS, 30)
        // Each switch produces a genuinely different effective rate — proves
        // the profile actually drives the computation, not a constant.
        XCTAssertNotEqual(efficiencyFPS, performanceFPS)
        XCTAssertNotEqual(performanceFPS, customFPS)
    }
}

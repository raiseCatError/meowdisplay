import XCTest

final class StreamingProfileTests: XCTestCase {

    // MARK: - Effective FPS policy (spec test matrix)

    func test60HzReceiverPerformanceIs60() {
        XCTAssertEqual(
            StreamingFPSPolicy.effectiveFPS(profile: .performance, requestedFPS: nil, receiverMaxFPS: 60),
            60)
    }

    func test120HzReceiverPerformanceIs120() {
        XCTAssertEqual(
            StreamingFPSPolicy.effectiveFPS(profile: .performance, requestedFPS: nil, receiverMaxFPS: 120),
            120)
    }

    func testOverReportedCapabilityClampsTo120() {
        XCTAssertEqual(
            StreamingFPSPolicy.effectiveFPS(profile: .performance, requestedFPS: nil, receiverMaxFPS: 240),
            120)
        XCTAssertEqual(
            StreamingFPSPolicy.effectiveFPS(profile: .performance, requestedFPS: nil, receiverMaxFPS: 165),
            120)
    }

    func testCustom120On60HzReceiverClampsSafely() {
        XCTAssertEqual(
            StreamingFPSPolicy.effectiveFPS(profile: .custom, requestedFPS: 120, receiverMaxFPS: 60),
            60)
    }

    func testEfficiencyNeverExceeds60() {
        for receiverMax in [nil, 30, 60, 90, 120, 240] as [Int?] {
            let fps = StreamingFPSPolicy.effectiveFPS(profile: .efficiency, requestedFPS: nil, receiverMaxFPS: receiverMax)
            XCTAssertLessThanOrEqual(fps, 60, "Efficiency exceeded 60fps for receiverMaxFPS=\(String(describing: receiverMax))")
        }
    }

    func testOlderPeerWithNoCapabilityGetsSafeDefault() {
        // No `maxFPS` in hello at all (pre-milestone peer) — must not be
        // treated as "unlimited"; falls back to the documented safe default.
        XCTAssertEqual(
            StreamingFPSPolicy.effectiveFPS(profile: .performance, requestedFPS: nil, receiverMaxFPS: nil),
            StreamingFPSPolicy.defaultReceiverMaxFPS)
        XCTAssertEqual(
            StreamingFPSPolicy.effectiveFPS(profile: .custom, requestedFPS: 120, receiverMaxFPS: nil),
            StreamingFPSPolicy.defaultReceiverMaxFPS)
    }

    func testCustomAutoMatchesPerformanceCeiling() {
        for receiverMax in [30, 60, 90, 120] {
            XCTAssertEqual(
                StreamingFPSPolicy.effectiveFPS(profile: .custom, requestedFPS: nil, receiverMaxFPS: receiverMax),
                StreamingFPSPolicy.effectiveFPS(profile: .performance, requestedFPS: nil, receiverMaxFPS: receiverMax))
        }
    }

    func testCustomRequestBelowReceiverCapabilityIsHonoredExactly() {
        XCTAssertEqual(
            StreamingFPSPolicy.effectiveFPS(profile: .custom, requestedFPS: 30, receiverMaxFPS: 120),
            30)
        XCTAssertEqual(
            StreamingFPSPolicy.effectiveFPS(profile: .custom, requestedFPS: 90, receiverMaxFPS: 120),
            90)
    }

    func testNeverExceedsHardCapRegardlessOfInputs() {
        let receiverCandidates: [Int?] = [nil, 1, 60, 120, 144, 165, 240, 1000]
        let requestCandidates: [Int?] = [nil, 1, 30, 60, 90, 120, 144, 240, 1000]
        for profile in StreamingProfile.allCases {
            for receiverMax in receiverCandidates {
                for requested in requestCandidates {
                    let fps = StreamingFPSPolicy.effectiveFPS(profile: profile, requestedFPS: requested, receiverMaxFPS: receiverMax)
                    XCTAssertLessThanOrEqual(fps, StreamingFPSPolicy.hardCapFPS)
                    XCTAssertGreaterThanOrEqual(fps, 1)
                }
            }
        }
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
        let efficiencyFPS = StreamingFPSPolicy.effectiveFPS(profile: .efficiency, requestedFPS: nil, receiverMaxFPS: receiverMaxFPS)
        let performanceFPS = StreamingFPSPolicy.effectiveFPS(profile: .performance, requestedFPS: nil, receiverMaxFPS: receiverMaxFPS)
        let customFPS = StreamingFPSPolicy.effectiveFPS(profile: .custom, requestedFPS: 30, receiverMaxFPS: receiverMaxFPS)

        XCTAssertEqual(efficiencyFPS, 60)
        XCTAssertEqual(performanceFPS, 120)
        XCTAssertEqual(customFPS, 30)
        // Each switch produces a genuinely different effective rate — proves
        // the profile actually drives the computation, not a constant.
        XCTAssertNotEqual(efficiencyFPS, performanceFPS)
        XCTAssertNotEqual(performanceFPS, customFPS)
    }
}

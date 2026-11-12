import XCTest

final class StreamingModeTests: XCTestCase {

    // MARK: - Enum/default parsing

    func testAllCasesHaveNonEmptyLabelAndExplanation() {
        for mode in StreamingMode.allCases {
            XCTAssertFalse(mode.label.isEmpty)
            XCTAssertFalse(mode.explanation.isEmpty)
        }
    }

    func testUnknownPersistedRawValueFallsBackToAutomatic() {
        let reloaded = StreamingMode(rawValue: "some-future-mode") ?? .automatic
        XCTAssertEqual(reloaded, .automatic)
    }

    func testAbsentPersistedValueResolvesToAutomatic() {
        // Existing users with no stored value must land on Automatic — the
        // new default this milestone introduces.
        let reloaded = StreamingMode(rawValue: "") ?? .automatic
        XCTAssertEqual(reloaded, .automatic)
    }

    // MARK: - Persistence survives reload

    func testPersistedModeSurvivesReload() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        defer { defaults.removePersistentDomain(forName: #function) }

        defaults.set(StreamingMode.custom.rawValue, forKey: "streamingMode")
        let reloaded = StreamingMode(rawValue: defaults.string(forKey: "streamingMode") ?? "") ?? .automatic
        XCTAssertEqual(reloaded, .custom)

        defaults.set(StreamingMode.automatic.rawValue, forKey: "streamingMode")
        let reloadedAgain = StreamingMode(rawValue: defaults.string(forKey: "streamingMode") ?? "") ?? .automatic
        XCTAssertEqual(reloadedAgain, .automatic)
    }

    // MARK: - Automatic mode forces the fixed default policy

    func testAutomaticForcesPerformanceProfileRegardlessOfStoredValue() {
        for stored: StreamingProfile in [.efficiency, .performance, .custom] {
            XCTAssertEqual(StreamingModePolicy.effectiveProfile(mode: .automatic, stored: stored), .performance)
        }
    }

    func testAutomaticForcesAutoPriorityRegardlessOfStoredValue() {
        for stored: StreamingPriority in [.auto, .preferFPS, .preferLatency] {
            XCTAssertEqual(StreamingModePolicy.effectivePriority(mode: .automatic, stored: stored), .auto)
        }
    }

    func testAutomaticForcesAutoCodecRegardlessOfStoredValue() {
        for stored: CodecPreference in CodecPreference.allCases {
            XCTAssertEqual(StreamingModePolicy.effectiveCodec(mode: .automatic, stored: stored), .auto)
        }
    }

    func testAutomaticNeverAppliesACustomFrameRate() {
        XCTAssertNil(StreamingModePolicy.effectiveCustomFPS(mode: .automatic, storedProfile: .custom, storedCustomFPS: 90))
        XCTAssertNil(StreamingModePolicy.effectiveCustomFPS(mode: .automatic, storedProfile: .performance, storedCustomFPS: nil))
    }

    // `StreamQuality`'s own `.effective(mode:stored:)` (Mac/MacSender.swift)
    // mirrors this exact automatic/custom split, but `StreamQuality` is
    // Mac-app-only and outside this test target's compiled sources (like
    // every other quality-related behavior — there's no pre-existing
    // `StreamQualityTests.swift` either), so it isn't exercised here.

    // MARK: - Custom mode passes stored values through unchanged

    func testCustomPassesThroughStoredProfile() {
        for stored: StreamingProfile in [.efficiency, .performance, .custom] {
            XCTAssertEqual(StreamingModePolicy.effectiveProfile(mode: .custom, stored: stored), stored)
        }
    }

    func testCustomPassesThroughStoredPriority() {
        for stored: StreamingPriority in [.auto, .preferFPS, .preferLatency] {
            XCTAssertEqual(StreamingModePolicy.effectivePriority(mode: .custom, stored: stored), stored)
        }
    }

    func testCustomPassesThroughStoredCodec() {
        for stored: CodecPreference in CodecPreference.allCases {
            XCTAssertEqual(StreamingModePolicy.effectiveCodec(mode: .custom, stored: stored), stored)
        }
    }

    func testCustomWithCustomProfileAppliesTheStoredFrameRate() {
        XCTAssertEqual(StreamingModePolicy.effectiveCustomFPS(mode: .custom, storedProfile: .custom, storedCustomFPS: 90), 90)
        XCTAssertNil(StreamingModePolicy.effectiveCustomFPS(mode: .custom, storedProfile: .custom, storedCustomFPS: nil))
    }

    func testCustomWithNonCustomProfileNeverAppliesAFrameRate() {
        // `customFrameRate` is irrelevant outside `StreamingProfile.custom` —
        // same rule the existing construction call site already applied
        // before this milestone (`streamingProfile == .custom ? … : nil`).
        XCTAssertNil(StreamingModePolicy.effectiveCustomFPS(mode: .custom, storedProfile: .performance, storedCustomFPS: 90))
        XCTAssertNil(StreamingModePolicy.effectiveCustomFPS(mode: .custom, storedProfile: .efficiency, storedCustomFPS: 90))
    }

    // MARK: - Mode switching preserves the underlying stored values

    func testSwitchingAutomaticToCustomAndBackPreservesStoredCustomValues() {
        // The policy functions never mutate their `stored` inputs — this is
        // exactly what lets `SenderController` leave `streamingProfile`/
        // `streamingPriority`/`codecPreference`/`quality` untouched across a
        // mode switch and still see the user's prior Custom choices the
        // moment they switch back.
        let storedProfile = StreamingProfile.custom
        let storedPriority = StreamingPriority.preferLatency
        let storedCodec = CodecPreference.hevc
        let storedFPS = 90

        // Automatic hides/overrides them...
        XCTAssertEqual(StreamingModePolicy.effectiveProfile(mode: .automatic, stored: storedProfile), .performance)
        XCTAssertEqual(StreamingModePolicy.effectivePriority(mode: .automatic, stored: storedPriority), .auto)
        XCTAssertEqual(StreamingModePolicy.effectiveCodec(mode: .automatic, stored: storedCodec), .auto)

        // ...but switching back to Custom sees the exact same stored values,
        // unchanged by the trip through Automatic.
        XCTAssertEqual(StreamingModePolicy.effectiveProfile(mode: .custom, stored: storedProfile), storedProfile)
        XCTAssertEqual(StreamingModePolicy.effectivePriority(mode: .custom, stored: storedPriority), storedPriority)
        XCTAssertEqual(StreamingModePolicy.effectiveCodec(mode: .custom, stored: storedCodec), storedCodec)
        XCTAssertEqual(StreamingModePolicy.effectiveCustomFPS(mode: .custom, storedProfile: storedProfile,
                                                               storedCustomFPS: storedFPS), storedFPS)
    }

    // MARK: - Receiver requests (issue #142)

    private let stored = StreamingProfileSetting(profile: .efficiency, customFrameRate: .fps90)

    func testReceiverProfileRequestIsRejectedWhileAutomatic() {
        for requested in StreamingProfile.allCases {
            XCTAssertEqual(StreamingModePolicy.remoteProfileRequest(
                mode: .automatic, stored: stored, requestedProfile: requested, requestedCustomFrameRate: .fps60),
                .rejectedAutomatic, "\(requested): Automatic would report Performance anyway; store and restart nothing")
        }
    }

    func testReceiverPriorityRequestIsRejectedWhileAutomatic() {
        for requested in StreamingPriority.allCases {
            XCTAssertEqual(StreamingModePolicy.remotePriorityRequest(mode: .automatic, stored: .auto, requested: requested),
                           .rejectedAutomatic)
        }
    }

    func testReceiverRequestForTheSettingInUseNeedsNoRestart() {
        XCTAssertEqual(StreamingModePolicy.remoteProfileRequest(
            mode: .custom, stored: stored, requestedProfile: .efficiency, requestedCustomFrameRate: .auto), .unchanged,
            "a non-Custom profile ignores the request's frame rate, so this is the stored setting")
        let custom = StreamingProfileSetting(profile: .custom, customFrameRate: .fps60)
        XCTAssertEqual(StreamingModePolicy.remoteProfileRequest(
            mode: .custom, stored: custom, requestedProfile: .custom, requestedCustomFrameRate: .fps60), .unchanged)
        XCTAssertEqual(StreamingModePolicy.remotePriorityRequest(mode: .custom, stored: .preferFPS, requested: .preferFPS),
                       .unchanged)
    }

    func testReceiverRequestInCustomAppliesAndKeepsTheStoredFrameRateForOtherProfiles() {
        // A 2.0.0 Apple receiver always sends customFrameRate "auto"; picking
        // Performance must not reset the Mac's custom 90 FPS.
        XCTAssertEqual(StreamingModePolicy.remoteProfileRequest(
            mode: .custom, stored: stored, requestedProfile: .performance, requestedCustomFrameRate: .auto),
            .apply(StreamingProfileSetting(profile: .performance, customFrameRate: .fps90)))
        XCTAssertEqual(StreamingModePolicy.remoteProfileRequest(
            mode: .custom, stored: stored, requestedProfile: .custom, requestedCustomFrameRate: .fps120),
            .apply(StreamingProfileSetting(profile: .custom, customFrameRate: .fps120)))
        XCTAssertEqual(StreamingModePolicy.remoteProfileRequest(
            mode: .custom, stored: stored, requestedProfile: .custom, requestedCustomFrameRate: nil),
            .apply(StreamingProfileSetting(profile: .custom, customFrameRate: .fps90)),
            "no frame rate in the request keeps the stored one")
        XCTAssertEqual(StreamingModePolicy.remotePriorityRequest(mode: .custom, stored: .auto, requested: .preferLatency),
                       .apply(.preferLatency))
    }

    func testProfileStateCarriesModeAndFrameRateAndOlderMessagesStillParse() throws {
        let update = StreamingProfileStateUpdate(profile: .custom, mode: .custom, customFrameRate: .fps90)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(update.wireJSON.utf8)) as? [String: Any])
        XCTAssertEqual(object["type"] as? String, WireMessage.streamingProfileState)
        XCTAssertEqual(StreamingProfileStateUpdate(message: object), update)

        let automatic = StreamingProfileStateUpdate(profile: .performance, mode: .automatic, customFrameRate: nil)
        let automaticObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(automatic.wireJSON.utf8)) as? [String: Any])
        XCTAssertNil(automaticObject["customFrameRate"])
        XCTAssertEqual(StreamingProfileStateUpdate(message: automaticObject), automatic)

        // A pre-#142 Mac: profile only. The mode stays unknown, so the
        // receiver keeps its controls enabled as before.
        let old = StreamingProfileStateUpdate(message: ["type": WireMessage.streamingProfileState, "profile": "efficiency"])
        XCTAssertEqual(old, StreamingProfileStateUpdate(profile: .efficiency, mode: nil, customFrameRate: nil))
        XCTAssertNil(ReceiverStreamingModeNote.text(for: old?.mode))
        XCTAssertNil(StreamingProfileStateUpdate(message: ["profile": "turbo"]))
        XCTAssertNotNil(ReceiverStreamingModeNote.text(for: .automatic))
    }
}

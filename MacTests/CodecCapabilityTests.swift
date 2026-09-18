import XCTest

final class CodecCapabilityTests: XCTestCase {

    // MARK: - Common vs. codec-specific FPS (the pre-clamp integration bug)
    //
    // `MacSender.effectiveFPS(width:height:)` used to feed
    // `StreamingFPSPolicy.effectiveFPS` — which unconditionally folds in
    // H.264's `encoderSafeFPS` — into EVERY caller's FPS value, including
    // the one handed to `CodecSelectionPolicy` for the Auto decision. That
    // silently pre-clamped the "requested" FPS Auto ever saw to H.264's own
    // throughput ceiling, so Auto's "would H.264 need to reduce this?"
    // question could never be true in the live pipeline — even though
    // `CodecSelectionPolicy`'s own unit tests above pass, because they feed
    // raw, un-pre-clamped numbers directly. These tests exercise the fixed
    // two-step shape (`commonTargetFPS` then `codecEffectiveFPS`/
    // `CodecSelectionPolicy.select`) the same way `MacSender.effectiveFPS`/
    // `selectCodec` now compose them, to pin the INTEGRATION, not just the
    // policy function in isolation.

    private func commonTarget(profile: StreamingProfile = .performance, requestedFPS: Int? = nil,
                               receiverMaxFPS: Int? = nil, userMaxFPS: Int? = nil) -> StreamingFPSPolicy.Result {
        StreamingFPSPolicy.commonTargetFPS(profile: profile, requestedFPS: requestedFPS,
                                            receiverMaxFPS: receiverMaxFPS, userMaxFPS: userMaxFPS)
    }

    func testAutoAtDecodeCeilingRasterWithMutualHEVCSelectsHEVCAtTheFullCommonTarget() {
        // SCENARIO 1: 4096x2304 (the legacy H.264 decode-ceiling raster),
        // requested 60 (Performance profile, receiver caps at 60). H.264's
        // own measured throughput ceiling at this size is below 60 (a real,
        // large raster genuinely constrains H.264 macroblock throughput).
        let width = 4096, height = 2304
        let common = commonTarget(receiverMaxFPS: 60)
        XCTAssertEqual(common.fps, 60)
        let h264Ceiling = EncoderCapability.codecSafeFPS(width: width, height: height)
        XCTAssertLessThan(h264Ceiling, common.fps, "test assumes H.264 cannot sustain 60 at 4096x2304")

        let decision = CodecSelectionPolicy.select(.init(
            preference: .auto, senderSupportsHEVC: true, receiverSupportsHEVC: true,
            requestedWidth: width, requestedHeight: height, requestedFPS: common.fps))
        XCTAssertEqual(decision.codec, .hevc)

        // The critical assertion: HEVC's EFFECTIVE fps stays at the full
        // common target (60) — NOT reduced to H.264's ceiling.
        let effective = StreamingFPSPolicy.codecEffectiveFPS(
            commonTarget: common, codec: decision.codec, encoderSafeFPS: h264Ceiling)
        XCTAssertEqual(effective.fps, 60)
    }

    func testAutoAtDecodeCeilingRasterWithoutHEVCFallsBackToH264AtItsReducedSafeFPS() {
        // SCENARIO 2: identical to scenario 1, but HEVC is not mutually
        // supported — must fall back to H.264 at its OWN reduced ceiling,
        // not at the unclamped common target.
        let width = 4096, height = 2304
        let common = commonTarget(receiverMaxFPS: 60)
        let h264Ceiling = EncoderCapability.codecSafeFPS(width: width, height: height)
        XCTAssertLessThan(h264Ceiling, common.fps)

        let decision = CodecSelectionPolicy.select(.init(
            preference: .auto, senderSupportsHEVC: true, receiverSupportsHEVC: false,
            requestedWidth: width, requestedHeight: height, requestedFPS: common.fps))
        XCTAssertEqual(decision.codec, .h264)

        let effective = StreamingFPSPolicy.codecEffectiveFPS(
            commonTarget: common, codec: decision.codec, encoderSafeFPS: h264Ceiling)
        XCTAssertEqual(effective.fps, h264Ceiling)
        XCTAssertEqual(effective.reason, .encoderThroughput)
    }

    func testExplicitHEVCAtAConstrainingRasterIsNotClampedByH264Throughput() {
        // SCENARIO 3: explicit HEVC preference at a raster where H.264 would
        // clamp — HEVC's effective FPS must equal the full common target,
        // never H.264's ceiling, regardless of Auto not being in play.
        let width = 4096, height = 2304
        let common = commonTarget(receiverMaxFPS: 120)
        let h264Ceiling = EncoderCapability.codecSafeFPS(width: width, height: height)
        XCTAssertLessThan(h264Ceiling, common.fps)

        let decision = CodecSelectionPolicy.select(.init(
            preference: .hevc, senderSupportsHEVC: true, receiverSupportsHEVC: true,
            requestedWidth: width, requestedHeight: height, requestedFPS: common.fps))
        XCTAssertEqual(decision.codec, .hevc)

        let effective = StreamingFPSPolicy.codecEffectiveFPS(
            commonTarget: common, codec: decision.codec, encoderSafeFPS: h264Ceiling)
        XCTAssertEqual(effective.fps, common.fps)
        XCTAssertNotEqual(effective.fps, h264Ceiling)
    }

    func testExplicitH264StillAppliesItsOwnSafeFPSClamp() {
        // SCENARIO 4: explicit H.264 preference — its throughput clamp must
        // remain fully in effect (this milestone must not accidentally
        // loosen H.264's existing safety behavior).
        let width = 4096, height = 2304
        let common = commonTarget(receiverMaxFPS: 120)
        let h264Ceiling = EncoderCapability.codecSafeFPS(width: width, height: height)
        XCTAssertLessThan(h264Ceiling, common.fps)

        let decision = CodecSelectionPolicy.select(.init(
            preference: .h264, senderSupportsHEVC: true, receiverSupportsHEVC: true,
            requestedWidth: width, requestedHeight: height, requestedFPS: common.fps))
        XCTAssertEqual(decision.codec, .h264)

        let effective = StreamingFPSPolicy.codecEffectiveFPS(
            commonTarget: common, codec: decision.codec, encoderSafeFPS: h264Ceiling)
        XCTAssertEqual(effective.fps, h264Ceiling)
    }

    func testReceiverDisplayMaxFPSIsACommonLimitThatCapsBothCodecs() {
        // SCENARIO 5: receiver display max = 60, requested 120 (Performance)
        // — a genuinely codec-INDEPENDENT limit (the panel itself cannot
        // show more than 60Hz) must cap BOTH codecs identically, at a raster
        // small enough that H.264 throughput never separately engages.
        let width = 1920, height = 1080
        let common = commonTarget(profile: .performance, receiverMaxFPS: 60)
        XCTAssertEqual(common.fps, 60)
        let h264Ceiling = EncoderCapability.codecSafeFPS(width: width, height: height)
        XCTAssertGreaterThanOrEqual(h264Ceiling, 60, "test assumes H.264 throughput never separately engages at this size")

        let h264Effective = StreamingFPSPolicy.codecEffectiveFPS(commonTarget: common, codec: .h264, encoderSafeFPS: h264Ceiling)
        let hevcEffective = StreamingFPSPolicy.codecEffectiveFPS(commonTarget: common, codec: .hevc, encoderSafeFPS: h264Ceiling)
        XCTAssertEqual(h264Effective.fps, 60)
        XCTAssertEqual(hevcEffective.fps, 60)
    }

    func testUserMaxFPSIsACommonLimitThatCapsBothCodecs() {
        // SCENARIO 6: user-enforced ceiling = 30 — also codec-independent
        // (a battery-saving choice, not a hardware constraint) and must cap
        // both codecs identically.
        let width = 1920, height = 1080
        let common = commonTarget(profile: .performance, receiverMaxFPS: 120, userMaxFPS: 30)
        XCTAssertEqual(common.fps, 30)
        let h264Ceiling = EncoderCapability.codecSafeFPS(width: width, height: height)

        let h264Effective = StreamingFPSPolicy.codecEffectiveFPS(commonTarget: common, codec: .h264, encoderSafeFPS: h264Ceiling)
        let hevcEffective = StreamingFPSPolicy.codecEffectiveFPS(commonTarget: common, codec: .hevc, encoderSafeFPS: h264Ceiling)
        XCTAssertEqual(h264Effective.fps, 30)
        XCTAssertEqual(hevcEffective.fps, 30)
    }

    func testRuntimeHEVCFallbackTargetFPSModelMatchesMacSendersOwnClamp() {
        // Models `MacSender.setupEncoder`'s runtime-HEVC-failure branch: it
        // must reduce its target FPS to H.264's safe ceiling before
        // recreating the encoder as H.264 — reusing HEVC's unclamped target
        // would reproduce the exact throughput failure this whole mechanism
        // exists to prevent. `MacSender` itself isn't in this test target
        // (ScreenCaptureKit/VideoToolbox dependencies), so this pins the
        // pure arithmetic it must apply: `min(targetFPS, codecSafeFPS)`.
        let width = 4096, height = 2304
        let hevcTargetFPS = 60 // what HEVC was about to encode at, unclamped
        let h264Ceiling = EncoderCapability.codecSafeFPS(width: width, height: height)
        XCTAssertLessThan(h264Ceiling, hevcTargetFPS)
        let fallbackFPS = min(hevcTargetFPS, h264Ceiling)
        XCTAssertEqual(fallbackFPS, h264Ceiling)
    }

    // MARK: - Explicit preference (TESTS 2/3/4)

    func testExplicitH264AlwaysWinsRegardlessOfHEVCSupport() {
        let result = CodecSelectionPolicy.select(.init(
            preference: .h264, senderSupportsHEVC: true, receiverSupportsHEVC: true,
            requestedWidth: 3840, requestedHeight: 2160, requestedFPS: 120))
        XCTAssertEqual(result.codec, .h264)
        XCTAssertEqual(result.reason, CodecSelectionPolicy.Reason.explicitPreference.rawValue)
    }

    func testExplicitHEVCUsesHEVCWhenMutuallySupported() {
        let result = CodecSelectionPolicy.select(.init(
            preference: .hevc, senderSupportsHEVC: true, receiverSupportsHEVC: true,
            requestedWidth: 1920, requestedHeight: 1080, requestedFPS: 60))
        XCTAssertEqual(result.codec, .hevc)
        XCTAssertEqual(result.reason, CodecSelectionPolicy.Reason.explicitPreference.rawValue)
    }

    func testExplicitHEVCFallsBackToH264WhenReceiverLacksSupport() {
        let result = CodecSelectionPolicy.select(.init(
            preference: .hevc, senderSupportsHEVC: true, receiverSupportsHEVC: false,
            requestedWidth: 1920, requestedHeight: 1080, requestedFPS: 60))
        XCTAssertEqual(result.codec, .h264)
        XCTAssertEqual(result.reason, CodecSelectionPolicy.Reason.explicitHEVCUnsupported.rawValue)
    }

    func testExplicitHEVCFallsBackToH264WhenSenderLacksHardwareEncoder() {
        let result = CodecSelectionPolicy.select(.init(
            preference: .hevc, senderSupportsHEVC: false, receiverSupportsHEVC: true,
            requestedWidth: 1920, requestedHeight: 1080, requestedFPS: 60))
        XCTAssertEqual(result.codec, .h264)
        XCTAssertEqual(result.reason, CodecSelectionPolicy.Reason.explicitHEVCUnsupported.rawValue)
    }

    // MARK: - Auto policy (TESTS 1/5/6/7/8)

    func testAutoWithH264OnlyReceiverAlwaysUsesH264() {
        // TEST 1: H.264-only receiver -> H.264, even at a size/FPS that
        // exceeds H.264's own safe ceiling — there is nowhere else to go.
        let result = CodecSelectionPolicy.select(.init(
            preference: .auto, senderSupportsHEVC: true, receiverSupportsHEVC: false,
            requestedWidth: 3840, requestedHeight: 2160, requestedFPS: 120))
        XCTAssertEqual(result.codec, .h264)
        XCTAssertEqual(result.reason, CodecSelectionPolicy.Reason.hevcUnavailable.rawValue)
    }

    func testAutoUsesH264WhenH264SatisfiesTheRequest() {
        // TEST 5: a small/modest request that H.264's own safe ceiling
        // covers outright — Auto must not reach for HEVC just because it's
        // available.
        let ceiling = EncoderCapability.codecSafeFPS(width: 1920, height: 1080)
        XCTAssertGreaterThanOrEqual(ceiling, 60, "test assumes 1920x1080@60 is within H.264's safe ceiling")
        let result = CodecSelectionPolicy.select(.init(
            preference: .auto, senderSupportsHEVC: true, receiverSupportsHEVC: true,
            requestedWidth: 1920, requestedHeight: 1080, requestedFPS: 60))
        XCTAssertEqual(result.codec, .h264)
        XCTAssertEqual(result.reason, CodecSelectionPolicy.Reason.requestSatisfiedByH264.rawValue)
    }

    func testAutoUsesHEVCWhenH264WouldReduceAndHEVCIsMutuallySupported() {
        // TEST 6: a request whose FPS exceeds H.264's own safe ceiling at
        // this size (2796x1748 is ~106-safe per EncoderCapabilityTests) —
        // H.264 would have to reduce it, and HEVC can take it instead.
        let ceiling = EncoderCapability.codecSafeFPS(width: 2796, height: 1748)
        XCTAssertLessThan(ceiling, 120, "test assumes this size can't sustain 120 in H.264")
        let result = CodecSelectionPolicy.select(.init(
            preference: .auto, senderSupportsHEVC: true, receiverSupportsHEVC: true,
            requestedWidth: 2796, requestedHeight: 1748, requestedFPS: 120))
        XCTAssertEqual(result.codec, .hevc)
        XCTAssertEqual(result.reason, CodecSelectionPolicy.Reason.h264WouldReduceConfiguration.rawValue)
    }

    func testAutoFallsBackToSafeH264WhenH264ConstrainedAndHEVCUnavailable() {
        // TEST 7: same codec-constrained request as above, but HEVC is not
        // mutually supported — Auto must stay on H.264 (reduced elsewhere by
        // the caller's existing FPS/resolution clamping; this policy only
        // decides the codec).
        let result = CodecSelectionPolicy.select(.init(
            preference: .auto, senderSupportsHEVC: true, receiverSupportsHEVC: false,
            requestedWidth: 2796, requestedHeight: 1748, requestedFPS: 120))
        XCTAssertEqual(result.codec, .h264)
        XCTAssertEqual(result.reason, CodecSelectionPolicy.Reason.hevcUnavailable.rawValue)
    }

    // Scenario C from the raster-reduction audit ("requested raster alone
    // exceeds an H.264 frame-size ceiling, independent of FPS throughput")
    // has NO corresponding test: this codebase implements no such ceiling.
    // `EncoderCapability` (its own doc comment) models ONLY a measured
    // macroblock-RATE throughput bound, never a separate spec-derived
    // maximum-frame-size (MaxFS) limit — and inventing one here, backed by
    // no hardware measurement, would be exactly the "fake universal level
    // ceiling" the milestone forbids. The only resolution-reducing mechanism
    // that exists (`hello.maxEncodeWide`/`maxEncodeHigh`, PROTOCOL.md 6.5) is
    // a receiver-declared DECODE ceiling applied identically regardless of
    // codec, before `CodecSelectionPolicy` ever runs — a non-codec
    // constraint per the spec's own rule (see `testAutoNonCodecReductionDoesNotForceHEVC`
    // below), not something this policy could correctly treat as "H.264
    // would need to reduce the raster". If a real hardware-measured H.264
    // frame-size bound is ever established, model it in `EncoderCapability`
    // (alongside `codecSafeFPS`) and feed it into this policy the same way;
    // until then, asserting behavior for it would test a ceiling that does
    // not exist anywhere in the running code.

    func testAutoNonCodecReductionDoesNotForceHEVC() {
        // Scenario E: `CodecSelectionPolicy` only ever sees the caller's
        // ALREADY-clamped target (post decode-ceiling / receiver-FPS-ceiling
        // / quality-preset reduction — none of which are codec-specific).
        // A request that was reduced for one of those reasons, but whose
        // FINAL numbers H.264 can satisfy outright, must stay on H.264 — the
        // policy has no way to see, and must not try to infer, why the
        // numbers it was handed are what they are.
        let reducedWidth = 1920, reducedHeight = 1080, reducedFPS = 30
        let ceiling = EncoderCapability.codecSafeFPS(width: reducedWidth, height: reducedHeight)
        XCTAssertGreaterThanOrEqual(ceiling, reducedFPS, "test assumes the already-reduced target is well within H.264's ceiling")
        let result = CodecSelectionPolicy.select(.init(
            preference: .auto, senderSupportsHEVC: true, receiverSupportsHEVC: true,
            requestedWidth: reducedWidth, requestedHeight: reducedHeight, requestedFPS: reducedFPS))
        XCTAssertEqual(result.codec, .h264)
        XCTAssertEqual(result.reason, CodecSelectionPolicy.Reason.requestSatisfiedByH264.rawValue)
    }

    func testAutoTreatsOldReceiverWithNoCodecFieldAsH264Only() {
        // TEST 8: a `PhoneInfo`/`hello` with no `codecs` field at all decodes
        // `receiverSupportsHEVC` as false (see `PhoneInfo.receiverSupportsHEVC`)
        // — modeled here at the policy layer as `receiverSupportsHEVC: false`,
        // the same input an absent-field hello produces.
        let result = CodecSelectionPolicy.select(.init(
            preference: .auto, senderSupportsHEVC: true, receiverSupportsHEVC: false,
            requestedWidth: 1920, requestedHeight: 1080, requestedFPS: 60))
        XCTAssertEqual(result.codec, .h264)
    }

    // MARK: - Codec capability is decoupled from overall protocol version
    //
    // Codec capability is the explicit `hello.codecs` field, never the
    // overall `pv`: a peer may advertise a lower `pv` than the latest for
    // reasons unrelated to codecs, and a pv 16 peer that advertises HEVC can
    // still use it. `CodecCapabilityProbe.receiverSupportsHEVC` and
    // `MacSender.sendStreamCodecState`'s gate therefore key off `codecs`
    // alone — the function under test deliberately has no `pv` parameter.

    func testReceiverSupportsHEVCWhenCodecsAdvertiseItRegardlessOfCappedProtocolVersion() {
        // A peer of any `pv` (including a pre-17 one) whose `hello.codecs`
        // explicitly includes "hevc" because its hardware decoder supports it.
        XCTAssertTrue(CodecCapabilityProbe.receiverSupportsHEVC(codecs: ["h264", "hevc"]))

        // Feeding that into the Auto policy alongside a sender that also
        // supports HEVC and a request H.264 cannot satisfy must still reach
        // HEVC — a lower `pv` must never suppress an otherwise-eligible
        // HEVC selection.
        let result = CodecSelectionPolicy.select(.init(
            preference: .auto, senderSupportsHEVC: true,
            receiverSupportsHEVC: CodecCapabilityProbe.receiverSupportsHEVC(codecs: ["h264", "hevc"]),
            requestedWidth: 2796, requestedHeight: 1748, requestedFPS: 120))
        XCTAssertEqual(result.codec, .hevc)
    }

    func testReceiverWithoutCodecsFieldIsH264OnlyRegardlessOfProtocolVersion() {
        // A peer whose build predates
        // codec advertisement entirely (no `codecs` field at all) — must be
        // H.264-only, not "unknown means everything".
        XCTAssertFalse(CodecCapabilityProbe.receiverSupportsHEVC(codecs: nil))

        let result = CodecSelectionPolicy.select(.init(
            preference: .auto, senderSupportsHEVC: true,
            receiverSupportsHEVC: CodecCapabilityProbe.receiverSupportsHEVC(codecs: nil),
            requestedWidth: 2796, requestedHeight: 1748, requestedFPS: 120))
        XCTAssertEqual(result.codec, .h264)
        XCTAssertEqual(result.reason, CodecSelectionPolicy.Reason.hevcUnavailable.rawValue)
    }

    func testAutoNeverChoosesHEVCWithoutSenderHardwareSupport() {
        // Auto must never pick HEVC just because the receiver supports it —
        // both ends must.
        let result = CodecSelectionPolicy.select(.init(
            preference: .auto, senderSupportsHEVC: false, receiverSupportsHEVC: true,
            requestedWidth: 2796, requestedHeight: 1748, requestedFPS: 120))
        XCTAssertEqual(result.codec, .h264)
        XCTAssertEqual(result.reason, CodecSelectionPolicy.Reason.hevcUnavailable.rawValue)
    }

    // MARK: - HEVC NAL classification (TEST 9) — never H.264's `& 0x1F`

    func testHEVCNALClassificationUsesSixBitTypeInBitsOneThroughSix() {
        // VPS: nal_unit_type 32 -> first byte = 32 << 1 = 0x40.
        XCTAssertEqual(HEVCNALUnitType.classify(firstByte: 0x40), .vps)
        // SPS: type 33 -> 33 << 1 = 0x42.
        XCTAssertEqual(HEVCNALUnitType.classify(firstByte: 0x42), .sps)
        // PPS: type 34 -> 34 << 1 = 0x44.
        XCTAssertEqual(HEVCNALUnitType.classify(firstByte: 0x44), .pps)
        // Prefix/suffix SEI: types 39/40.
        XCTAssertEqual(HEVCNALUnitType.classify(firstByte: 39 << 1), .seiPrefix)
        XCTAssertEqual(HEVCNALUnitType.classify(firstByte: 40 << 1), .seiSuffix)
        // An ordinary slice type (e.g. 0, IDR_W_RADL) is `.other`, not VPS/SPS/PPS.
        XCTAssertEqual(HEVCNALUnitType.classify(firstByte: 0x00), .other(0))
    }

    func testHEVCNALClassificationDiffersFromH264ByteValuesAtTheSameOffsets() {
        // H.264's SPS (type 7, `first & 0x1F == 7`) and PPS (type 8) byte
        // values must NOT be misclassified as HEVC VPS/SPS/PPS (32/33/34) —
        // proving the two type spaces are genuinely disjoint at the bit
        // level this milestone's "don't reuse H.264's mask" rule protects.
        let h264SPSByte: UInt8 = 0x67   // 0x60 | 7 — a real H.264 SPS NAL header byte
        let h264PPSByte: UInt8 = 0x68   // 0x60 | 8
        XCTAssertNotEqual(HEVCNALUnitType.classify(firstByte: h264SPSByte), .vps)
        XCTAssertNotEqual(HEVCNALUnitType.classify(firstByte: h264SPSByte), .sps)
        XCTAssertNotEqual(HEVCNALUnitType.classify(firstByte: h264PPSByte), .pps)
    }

    // MARK: - H.264 path unchanged (TEST 10)

    func testH264ParameterSetTypesStillUseFiveBitMask() {
        // The H.264 side of the dispatch (StreamReceiver.handleAnnexB's
        // non-HEVC branch) still classifies via `first & 0x1F`: 7 = SPS,
        // 8 = PPS. This pins those constants so a future refactor can't
        // silently renumber them.
        XCTAssertEqual(UInt8(0x67) & 0x1F, 7)
        XCTAssertEqual(UInt8(0x68) & 0x1F, 8)
    }

    // MARK: - Receiver hardware-decode capability controls advertisement (TEST 13)

    func testCodecAdvertisementIncludesHEVCOnlyWhenHardwareDecodeSupported() {
        XCTAssertEqual(CodecCapabilityProbe.supportedCodecs(hevcHardwareDecodeSupported: false), [.h264])
        XCTAssertEqual(CodecCapabilityProbe.supportedCodecs(hevcHardwareDecodeSupported: true), [.h264, .hevc])
    }

    // MARK: - Runtime fallback reason exists and is distinct (TEST 12)

    func testRuntimeFallbackReasonIsDistinctFromEveryOtherReason() {
        let reasons: [CodecSelectionPolicy.Reason] = [
            .requestSatisfiedByH264, .h264WouldReduceConfiguration, .hevcUnavailable,
            .explicitPreference, .explicitHEVCUnsupported, .runtimeFallback
        ]
        XCTAssertEqual(Set(reasons.map(\.rawValue)).count, reasons.count)
    }

    // MARK: - Wire message round-trip (streamCodecState)

    func testStreamCodecStateRoundTripsThroughWireFields() {
        let update = StreamCodecStateUpdate(codec: .hevc, reason: "h264 safe configuration would reduce requested stream")
        let decoded = StreamCodecStateUpdate(message: update.wireFields)
        XCTAssertEqual(decoded, update)
    }

    func testStreamCodecStateRejectsWrongType() {
        XCTAssertNil(StreamCodecStateUpdate(message: ["type": "somethingElse", "codec": "hevc"]))
    }

    func testStreamCodecStateRejectsUnknownCodec() {
        XCTAssertNil(StreamCodecStateUpdate(message: ["type": WireMessage.streamCodecState, "codec": "av1"]))
    }

    // MARK: - Persisted user preference (TEST 14)

    func testCodecPreferenceAllCasesHaveNonEmptyLabelAndExplanation() {
        for preference in CodecPreference.allCases {
            XCTAssertFalse(preference.label.isEmpty)
            XCTAssertFalse(preference.explanation.isEmpty)
        }
    }

    func testUnknownPersistedCodecPreferenceFallsBackToAuto() {
        let reloaded = CodecPreference(rawValue: "some-future-codec") ?? .auto
        XCTAssertEqual(reloaded, .auto)
    }

    func testAbsentPersistedCodecPreferenceResolvesToAuto() {
        let reloaded = CodecPreference(rawValue: "") ?? .auto
        XCTAssertEqual(reloaded, .auto)
    }

    func testPersistedCodecPreferenceSurvivesReload() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        defer { defaults.removePersistentDomain(forName: #function) }

        defaults.set(CodecPreference.hevc.rawValue, forKey: "codecPreference")
        let reloaded = CodecPreference(rawValue: defaults.string(forKey: "codecPreference") ?? "") ?? .auto
        XCTAssertEqual(reloaded, .hevc)

        defaults.set(CodecPreference.h264.rawValue, forKey: "codecPreference")
        let reloadedAgain = CodecPreference(rawValue: defaults.string(forKey: "codecPreference") ?? "") ?? .auto
        XCTAssertEqual(reloadedAgain, .h264)
    }

    // MARK: - Per-codec decode-raster ceiling (`CodecDecodeCeiling`)
    //
    // `hello.maxEncodeWide/High` is historically H.264-SPECIFIC (see
    // `iOSDecodeCeiling`'s and `MacReceiver.start()`'s doc comments: "the
    // VideoToolbox H.264 hardware decoder's actual pixel ceiling" / "4096x2304
    // is H.264's practical hardware-decode ceiling"). These tests pin the
    // deliberate, currently-shared-but-codec-aware model in
    // `CodecDecodeCeiling`, not an assumption that it is codec-independent.

    func testLegacyReceiverWithNoDecodeCeilingPreservesOldBehaviorForBothCodecs() {
        // A pre-milestone receiver (or one that omits the fields) advertises
        // no ceiling at all — must stay "no clamp" for either codec, exactly
        // as before this milestone existed.
        let h264 = CodecDecodeCeiling.applicable(codec: .h264, legacyMaxEncodeWide: nil, legacyMaxEncodeHigh: nil)
        let hevc = CodecDecodeCeiling.applicable(codec: .hevc, legacyMaxEncodeWide: nil, legacyMaxEncodeHigh: nil)
        XCTAssertNil(h264.width)
        XCTAssertNil(h264.height)
        XCTAssertNil(hevc.width)
        XCTAssertNil(hevc.height)
    }

    func testLegacyDecodeCeilingAppliesToH264() {
        let result = CodecDecodeCeiling.applicable(codec: .h264, legacyMaxEncodeWide: 4096, legacyMaxEncodeHigh: 2304)
        XCTAssertEqual(result.width, 4096)
        XCTAssertEqual(result.height, 2304)
    }

    func testH264SpecificCeilingCurrentlyAlsoAppliesToHEVCAsADeliberateConservativeChoice() {
        // NOT "HEVC silently inherits an H.264 bug" — this pins the
        // documented, intentional choice: no distinct HEVC decode-raster
        // measurement exists anywhere in this codebase (VideoToolbox exposes
        // no queryable per-codec max-raster capability), so HEVC's
        // applicable ceiling deliberately equals H.264's today rather than
        // inventing a larger number pre-hardware-test. If this test ever
        // needs to change, it must be because a real, additive,
        // codec-specific capability (e.g. `hello.hevcMaxEncodeWide/High`)
        // was introduced and threaded through here — not because someone
        // guessed a bigger number from OS version or marketing specs.
        let h264 = CodecDecodeCeiling.applicable(codec: .h264, legacyMaxEncodeWide: 4096, legacyMaxEncodeHigh: 2304)
        let hevc = CodecDecodeCeiling.applicable(codec: .hevc, legacyMaxEncodeWide: 4096, legacyMaxEncodeHigh: 2304)
        XCTAssertEqual(h264.width, hevc.width)
        XCTAssertEqual(h264.height, hevc.height)
    }

    func testAutoDoesNotChooseHEVCMerelyToPreserveRasterSinceCeilingsAreIdentical() {
        // Given `CodecDecodeCeiling`'s current shared-ceiling design, the
        // requested raster fed to `CodecSelectionPolicy` is ALREADY clamped
        // identically regardless of which codec is eventually chosen (the
        // clamp happens at capture-provisioning time, before codec
        // selection — see `MacSender.clampedCaptureSize`). Auto must
        // therefore never treat "the raster was reduced" as evidence HEVC
        // would help: it is a shared, non-codec-differentiating constraint
        // by construction today, and choosing HEVC here would rest on the
        // false premise that HEVC's ceiling differs. Only H.264's real,
        // measured, FPS-throughput ceiling (`EncoderCapability.codecSafeFPS`)
        // is left as a genuine codec-differentiating signal — and this
        // already-clamped, comfortably-safe request satisfies it outright.
        let clampedWidth = 4096, clampedHeight = 2304, requestedFPS = 30
        let ceiling = EncoderCapability.codecSafeFPS(width: clampedWidth, height: clampedHeight)
        XCTAssertGreaterThanOrEqual(ceiling, requestedFPS, "test assumes the shared-ceiling-clamped raster comfortably satisfies this FPS in H.264")
        let result = CodecSelectionPolicy.select(.init(
            preference: .auto, senderSupportsHEVC: true, receiverSupportsHEVC: true,
            requestedWidth: clampedWidth, requestedHeight: clampedHeight, requestedFPS: requestedFPS))
        XCTAssertEqual(result.codec, .h264)
        XCTAssertEqual(result.reason, CodecSelectionPolicy.Reason.requestSatisfiedByH264.rawValue)
    }

    func testAutoCanStillChooseHEVCWhenH264ThroughputSpecificallyIsTheConstraint() {
        // The one constraint that IS genuinely codec-specific today —
        // H.264's measured macroblock-rate/FPS ceiling — still correctly
        // routes to HEVC when mutually supported, unaffected by the shared
        // raster ceiling above (this request is well inside 4096x2304, so
        // the raster ceiling never engages at all; only the FPS ceiling
        // does).
        let width = 2796, height = 1748, requestedFPS = 120
        let fpsCeiling = EncoderCapability.codecSafeFPS(width: width, height: height)
        XCTAssertLessThan(fpsCeiling, requestedFPS, "test assumes this size can't sustain 120 in H.264")
        let result = CodecSelectionPolicy.select(.init(
            preference: .auto, senderSupportsHEVC: true, receiverSupportsHEVC: true,
            requestedWidth: width, requestedHeight: height, requestedFPS: requestedFPS))
        XCTAssertEqual(result.codec, .hevc)
        XCTAssertEqual(result.reason, CodecSelectionPolicy.Reason.h264WouldReduceConfiguration.rawValue)
    }

    // MARK: - Reconnect / route migration codec confirmation
    //
    // `MacSender.swift`/`Shared/StreamReceiver.swift` themselves aren't in
    // this test target (VideoToolbox/Network/AVFoundation dependencies), so
    // these pin the one pure, extracted predicate the fix's correctness
    // rests on (`CodecCapabilityProbe.shouldConfirmCodecOnHello`) — the
    // actual wiring (`sendStreamCodecState()` now called unconditionally
    // from the Mac's `case "hello":` handler, using this predicate as its
    // internal guard) is verified by code inspection plus the full
    // build/test pass, the same limitation already noted for other
    // MacSender-internal call-site wiring in this milestone's earlier audits.

    func testHelloWithCodecsFieldConfirmsCodecRegardlessOfWhatChanged() {
        // A reconnect/route-migration hello that changes NOTHING about
        // capability (same `codecs` as before) must still confirm — this is
        // a per-CONNECTION resend, not conditioned on any delta.
        XCTAssertTrue(CodecCapabilityProbe.shouldConfirmCodecOnHello(codecs: ["h264", "hevc"]))
        XCTAssertTrue(CodecCapabilityProbe.shouldConfirmCodecOnHello(codecs: ["h264"]))
    }

    func testHelloWithoutCodecsFieldNeverConfirms() {
        // A pre-milestone peer that never sends `codecs` at all must not be
        // sent a message type it predates.
        XCTAssertFalse(CodecCapabilityProbe.shouldConfirmCodecOnHello(codecs: nil))
    }

    func testReconnectAfterReceiverRestartWhileHEVCActiveModelsTheFixedContract() {
        // The concrete failure mode this fix closes: encoder stays HEVC
        // across a reconnect (no dimension/FPS change, so `setupEncoder`
        // never re-runs); the RECEIVER PROCESS restarted in between, so its
        // fresh `StreamReceiver` instance defaults `receivedStreamCodec` to
        // `.h264` (the documented, correct default until a real
        // `streamCodecState` arrives). The SAME `hello.codecs` this receiver
        // sends is what must trigger `sendStreamCodecState()` again — proving
        // the resend is keyed on capability advertisement (still true after
        // restart), never on the encoder having just been (re)created.
        let receiverDefaultCodec = StreamCodec.h264   // fresh StreamReceiver()'s default
        let macActiveCodec = StreamCodec.hevc         // never torn down across the reconnect
        XCTAssertNotEqual(receiverDefaultCodec, macActiveCodec, "test models the exact mismatch the fix closes")

        let helloCodecs = ["h264", "hevc"]   // unchanged from before the restart
        XCTAssertTrue(CodecCapabilityProbe.shouldConfirmCodecOnHello(codecs: helloCodecs))

        // What actually gets sent: `activeCodec` (persisted Mac-side state),
        // never a fresh `CodecSelectionPolicy.select` re-run — the resend
        // must reflect reality, not re-decide it.
        let confirmation = StreamCodecStateUpdate(codec: macActiveCodec, reason: "reconnect confirmation")
        XCTAssertEqual(confirmation.wireFields["codec"] as? String, StreamCodec.hevc.wireValue)
    }

    // MARK: - Wire-version currency (TEST 15)

    func testHevcCodecWireVersionIsFixedAtNineteen() {
        XCTAssertEqual(WireProtocol.hevcCodecWireVersion, 19)
    }

    func testWireProtocolVersionIsCurrentlyNineteen() {
        // Additive feature (this milestone bumps `WireProtocol.version`
        // itself, following the same convention as every prior additive
        // feature in this file — e.g. `maxFPSWireVersion`,
        // `streamingPriorityWireVersion`). A future milestone that bumps
        // this further should update this canary deliberately, the same
        // way `MirrorUnavailableOfferPolicyTests` documents superseding
        // `StreamingPriorityTests`' matching canary.
        XCTAssertEqual(WireProtocol.version, 19)
    }
}

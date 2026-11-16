import XCTest

final class AdaptiveStreamingControllerTests: XCTestCase {
    private typealias Controller = AdaptiveStreamingController
    private typealias Sample = AdaptiveStreamingSample

    private static let iPad = AdaptiveReceiverDisplay(pointsWide: 1194, pointsHigh: 834, scale: 2, sizeClass: .tablet)
    private static let iPhone = AdaptiveReceiverDisplay(pointsWide: 852, pointsHigh: 393, scale: 3, sizeClass: .phone)

    private func makeController(receiver: AdaptiveReceiverDisplay? = iPad, native: (Int, Int) = (2388, 1668),
                                source: Int = 60, receiverMax: Int = 60, effective: Int? = 60,
                                mode: RefreshNegotiation.DisplayMode = .extend,
                                streamingMode: StreamingMode = .automatic, telemetry: Bool = true,
                                override: AdaptiveOperatingPoint? = nil,
                                dataPolicy: NetworkCost.DataPolicy = .normal) -> Controller {
        let negotiation = RefreshNegotiation.negotiate(RefreshNegotiation.Input(
            mode: mode, sourceRefreshHz: source, receiverMaxFPS: receiverMax, receiverEffectiveRefreshHz: effective,
            encodeWidth: native.0, encodeHeight: native.1, codec: .hevc))
        return Controller(configuration: .init(streamingMode: streamingMode, mode: mode, negotiation: negotiation,
                                               nativeEncodeWidth: native.0, nativeEncodeHeight: native.1,
                                               receiver: receiver, receiverTelemetryAvailable: telemetry,
                                               explicitOverride: override),
                          generation: 1, routeEpoch: 1, dataPolicy: dataPolicy)
    }

    /// A healthy 2 s window at `index`.
    private func sample(_ index: Int, source: Double = 60, mode: RefreshNegotiation.DisplayMode = .extend,
                        _ modify: (inout Sample) -> Void = { _ in }) -> Sample {
        var s = Sample(generation: 1, routeEpoch: 1, mode: mode,
                       windowStart: Double(index) * 2, windowEnd: Double(index) * 2 + 2)
        s.sourceUniqueFPS = source
        s.captureFPS = source
        s.encodedFPS = source
        s.deliveredFPS = source
        s.decodedFPS = source
        s.enqueuedFPS = source
        s.encodeQueueDepth = 1
        s.encodeQueueAgeMs = 3
        s.rttMs = 5
        s.jitterMs = 1
        s.sendBackpressure = 0
        s.decodeTimeP95Ms = 4
        s.presentationQueueAgeMs = 6
        s.stallCount = 0
        s.payloadBytesPerSecond = 1_000_000
        modify(&s)
        return s
    }

    private func congested(_ s: inout Sample) {
        s.sendBackpressure = 0.3
        s.deliveredFPS = 45
        s.decodedFPS = 45
        s.enqueuedFPS = 45
        s.rttMs = 80
    }

    // Well above two frame intervals even at 20 fps.
    private func encoderOverloaded(_ s: inout Sample) { s.encodeQueueAgeMs = 200 }
    private func decoderOverloaded(_ s: inout Sample) { s.decodeTimeP95Ms = 30 }

    // MARK: - Start, bypass and fallback

    func testStartsAtTodaysQualityAndSixtyFirst() {
        let controller = makeController(source: 120, receiverMax: 120, effective: 120)
        let decision = controller.initialDecision()
        XCTAssertEqual(decision.action, .initial)
        XCTAssertEqual(decision.point, AdaptiveOperatingPoint(rasterScale: 1, bitrate: 18_000_000, fps: 60))
        XCTAssertEqual(Controller.fixedAutomaticPoint(controller.configuration.negotiation).fps, 120,
                       "today's fixed policy targets 120 on the same receiver")
    }

    func testCustomModeBypassesTheController() {
        var controller = makeController(streamingMode: .custom)
        XCTAssertEqual(controller.initialDecision().action, .bypass)
        XCTAssertNil(controller.effectivePoint)
        for index in 0..<20 {
            let decision = controller.ingest(sample(index, congested))
            XCTAssertEqual(decision.action, .bypass)
            XCTAssertEqual(decision.reason, .customModeBypass)
            XCTAssertNil(decision.point)
        }
        XCTAssertEqual(controller.routeDidChange(epoch: 9, now: 50).action, .bypass)
        XCTAssertEqual(controller.tick(now: 100).action, .bypass)
    }

    func testExplicitUserOverrideWins() {
        let override = AdaptiveOperatingPoint(rasterScale: 0.5, bitrate: 3_000_000, fps: 30)
        var controller = makeController(override: override, dataPolicy: .saver)
        for index in 0..<10 {
            let decision = controller.ingest(sample(index, encoderOverloaded))
            XCTAssertEqual(decision.action, .bypass)
            XCTAssertEqual(decision.reason, .userOverride)
            XCTAssertEqual(decision.point, override)
        }
    }

    func testPeerWithoutTelemetryGetsExactlyTheFixedPolicy() {
        var controller = makeController(source: 60, receiverMax: 120, effective: nil, telemetry: false)
        let fixed = AdaptiveOperatingPoint(rasterScale: 1, bitrate: 18_000_000, fps: 120)
        XCTAssertEqual(controller.initialDecision().point, fixed)
        for index in 0..<30 {
            let decision = controller.ingest(sample(index, index.isMultiple(of: 2) ? congested : { _ in }))
            XCTAssertEqual(decision.action, .fixedPolicy)
            XCTAssertEqual(decision.reason, .legacyPeerFixedPolicy)
            XCTAssertEqual(decision.point, fixed)
        }
    }

    // MARK: - Cause-specific responses

    func testNetworkBackpressureLowersBitrateThenRasterKeepingSixty() {
        var controller = makeController()
        XCTAssertEqual(controller.ingest(sample(0, congested)).reason, .confirmingDownshift)
        let first = controller.ingest(sample(1, congested))
        XCTAssertEqual(first.action, .downshift)
        XCTAssertEqual(first.reason, .networkBitrateDown)
        XCTAssertEqual(first.cause, .network)
        XCTAssertEqual(first.changed, [.bitrate])
        XCTAssertEqual(first.cost, .encoderReconfigure)
        XCTAssertEqual(first.point, AdaptiveOperatingPoint(rasterScale: 1, bitrate: 15_000_000, fps: 60))

        var sawRaster = false
        for index in 2..<200 {
            let decision = controller.ingest(sample(index, congested))
            guard decision.isChange, let point = decision.point else { continue }
            let lastResort = decision.reason == .lastResortRasterBelowFloor
            if decision.changed == [.raster], !lastResort {
                sawRaster = true
                XCTAssertGreaterThanOrEqual(point.rasterScale, controller.rasterFloor - 1e-9,
                                            "raster stays at the floor while FPS/bitrate options remain")
            }
            if point.fps < 60, !lastResort {
                XCTAssertTrue(sawRaster)
                XCTAssertEqual(point.rasterScale, controller.rasterFloor, accuracy: 1e-9,
                               "FPS drops below 60 only once the raster is at the readability floor")
            }
            if decision.reason == .lastResortRasterBelowFloor {
                XCTAssertEqual(point.fps, 20)
                XCTAssertEqual(point.bitrate, 2_000_000)
            }
        }
        XCTAssertTrue(sawRaster)
    }

    func testFirstRasterStepWaitsForTheBitsPerPixelFloor() {
        var controller = makeController()
        var lastBitrateBeforeRaster: Int?
        for index in 0..<60 {
            let decision = controller.ingest(sample(index, congested))
            if decision.changed == [.raster] {
                lastBitrateBeforeRaster = decision.previous?.bitrate
                break
            }
        }
        // 2388x1668 at 60 fps: 6 Mbps is the lowest step at or above 0.02 bpp.
        XCTAssertEqual(lastBitrateBeforeRaster, 6_000_000)
    }

    func testEncoderOverloadLowersPixelThroughputNotBitrate() {
        var controller = makeController()
        var rasterChangeTimes: [Double] = []
        var reasons: [AdaptiveStreamingDecision.Reason] = []
        for index in 0..<150 {
            let s = sample(index, encoderOverloaded)
            let decision = controller.ingest(s)
            guard decision.isChange, let point = decision.point else { continue }
            reasons.append(decision.reason)
            XCTAssertEqual(decision.cause, .encoder)
            XCTAssertEqual(point.bitrate, 18_000_000, "overload never cuts the bitrate")
            if decision.changed.contains(.raster) { rasterChangeTimes.append(s.windowEnd) }
            if point.fps < 60, decision.reason != .lastResortRasterBelowFloor {
                XCTAssertEqual(point.rasterScale, controller.rasterFloor, accuracy: 1e-9)
            }
        }
        XCTAssertEqual(reasons.first, .overloadRasterDown)
        XCTAssertTrue(reasons.contains(.overloadFPSDown))
        XCTAssertEqual(reasons.last, .lastResortRasterBelowFloor)
        for (a, b) in zip(rasterChangeTimes, rasterChangeTimes.dropFirst()) {
            XCTAssertGreaterThanOrEqual(b - a, AdaptiveStreamingThresholds.standard.minRestartIntervalSeconds,
                                        "restart-class changes are rate-limited")
        }
    }

    func testDecoderOverloadLowersRasterNotBitrate() {
        var controller = makeController()
        _ = controller.ingest(sample(0, decoderOverloaded))
        let decision = controller.ingest(sample(1, decoderOverloaded))
        XCTAssertEqual(decision.cause, .decoder)
        XCTAssertEqual(decision.reason, .overloadRasterDown)
        XCTAssertEqual(decision.cost, .captureRestart)
        XCTAssertEqual(decision.point, AdaptiveOperatingPoint(rasterScale: 0.875, bitrate: 18_000_000, fps: 60))
    }

    func testOverloadAtHighRefreshDropsFPSFirst() {
        var controller = makeController(source: 120, receiverMax: 120, effective: 120)
        var index = 0
        while controller.point.fps < 120 && index < 100 {
            _ = controller.ingest(sample(index, source: 120))
            index += 1
        }
        XCTAssertEqual(controller.point.fps, 120, "healthy headroom reaches 120")
        // Let the 120 probe confirm.
        for _ in 0..<3 {
            _ = controller.ingest(sample(index, source: 120))
            index += 1
        }
        _ = controller.ingest(sample(index, source: 120, encoderOverloaded))
        let decision = controller.ingest(sample(index + 1, source: 120, encoderOverloaded))
        XCTAssertEqual(decision.reason, .overloadFPSDown)
        XCTAssertEqual(decision.point?.fps, 60)
        XCTAssertEqual(decision.point?.rasterScale, 1)
    }

    func testIdleSourceIsNotCongestionAndEarnsNoCredit() {
        var controller = makeController()
        // Lower the bitrate once so an upshift is possible.
        _ = controller.ingest(sample(0, congested))
        XCTAssertEqual(controller.ingest(sample(1, congested)).action, .downshift)
        let lowered = controller.point
        var index = 2
        for _ in 0..<3 {
            XCTAssertEqual(controller.ingest(sample(index)).action, .hold)
            index += 1
        }
        // Idle: one distinct frame per second, with a stale-looking delivery
        // ratio and RTT that would otherwise look bad.
        for _ in 0..<20 {
            let decision = controller.ingest(sample(index, source: 1) { $0.enqueuedFPS = 0.5 })
            XCTAssertEqual(decision.action, .hold)
            XCTAssertEqual(decision.reason, .sourceLimited)
            index += 1
        }
        // 3 + 1 healthy windows: still one short of the upshift streak.
        let decision = controller.ingest(sample(index))
        XCTAssertEqual(decision.action, .hold)
        XCTAssertEqual(controller.point, lowered)
        XCTAssertEqual(controller.ingest(sample(index + 1)).action, .upshift)
    }

    func testThermalSeriousTakesAProtectiveStepAndCriticalClampsImmediately() {
        var controller = makeController()
        _ = controller.ingest(sample(0) { $0.senderThermal = .serious })
        let serious = controller.ingest(sample(1) { $0.senderThermal = .serious })
        XCTAssertEqual(serious.cause, .thermal)
        XCTAssertEqual(serious.reason, .thermalRasterDown)

        var critical = makeController(source: 120, receiverMax: 120, effective: 120)
        let clamp = critical.ingest(sample(0, source: 120) { $0.receiverThermal = .critical })
        XCTAssertEqual(clamp.action, .policyClamp)
        XCTAssertEqual(clamp.reason, .thermalClamp)
        XCTAssertEqual(clamp.point?.fps, 30)
        XCTAssertEqual(clamp.point?.rasterScale, 0.75)
        // No upshift while critical.
        for index in 1..<40 {
            let decision = critical.ingest(sample(index, source: 120) { $0.receiverThermal = .critical })
            XCTAssertNotEqual(decision.action, .upshift)
            XCTAssertLessThanOrEqual(decision.point?.fps ?? 0, 30)
        }
    }

    func testLowPowerAndWindowPanesClampHighRefresh() {
        var power = makeController(source: 120, receiverMax: 120, effective: 120)
        var index = 0
        while power.point.fps < 120 && index < 100 {
            _ = power.ingest(sample(index, source: 120))
            index += 1
        }
        let clamp = power.ingest(sample(index, source: 120) { $0.power = .lowPower })
        XCTAssertEqual(clamp.reason, .powerClamp)
        XCTAssertEqual(clamp.point?.fps, 60)

        var window = makeController(source: 120, receiverMax: 120, effective: 120, mode: .window)
        for index in 0..<100 {
            let decision = window.ingest(sample(index, source: 120, mode: .window) { $0.activePaneCount = 3 })
            XCTAssertLessThanOrEqual(decision.point?.fps ?? 0, 60)
        }
    }

    // MARK: - Readability floor

    func testReadabilityFloorFromReceiverSizeAndDensity() {
        XCTAssertEqual(makeController(receiver: Self.iPad).rasterFloor, 0.625)
        XCTAssertEqual(makeController(receiver: Self.iPhone, native: (1704, 786)).rasterFloor, 0.75)
        XCTAssertEqual(makeController(receiver: nil).rasterFloor, 0.75)
        // A large Mac display mirrored to an iPad: 3024 px for 1194 displayed points.
        XCTAssertEqual(makeController(receiver: Self.iPad, native: (3024, 1964)).rasterFloor, 0.5)
    }

    func testPhoneNeverDropsBelowFloorWhileLowerFPSRemains() {
        var controller = makeController(receiver: Self.iPhone, native: (1704, 786))
        var lastResort: AdaptiveOperatingPoint?
        for index in 0..<200 {
            let decision = controller.ingest(sample(index, encoderOverloaded))
            guard let point = decision.point else { continue }
            if point.rasterScale < 0.75 - 1e-9 {
                XCTAssertEqual(point.fps, 20, "below the floor only once FPS is exhausted")
                if decision.reason == .lastResortRasterBelowFloor, lastResort == nil { lastResort = point }
            }
        }
        XCTAssertEqual(lastResort?.rasterScale, 0.625)
    }

    // MARK: - Stability

    func testSingleBadWindowsNeverChangeAnything() {
        var controller = makeController()
        for index in 0..<100 {
            let decision = controller.ingest(sample(index, index.isMultiple(of: 2) ? congested : { _ in }))
            XCTAssertFalse(decision.isChange, "alternating non-severe windows must not move the point")
        }
    }

    func testSevereBackpressureDownshiftsInOneWindow() {
        var controller = makeController()
        let decision = controller.ingest(sample(0) {
            $0.sendBackpressure = 0.7
            $0.enqueuedFPS = 20
        })
        XCTAssertEqual(decision.action, .downshift)
        XCTAssertEqual(decision.changed, [.bitrate])
    }

    func testUpshiftIsAProbeConfirmedOrRevertedWithBackoff() {
        var controller = makeController()
        _ = controller.ingest(sample(0, congested))
        _ = controller.ingest(sample(1, congested))       // 15 Mbps at t=4
        var index = 2
        var upshift: AdaptiveStreamingDecision?
        while upshift == nil && index < 20 {
            let decision = controller.ingest(sample(index))
            if decision.action == .upshift { upshift = decision }
            index += 1
        }
        XCTAssertEqual(upshift?.reason, .upshiftBitrate)
        XCTAssertEqual(upshift?.point?.bitrate, 18_000_000)
        XCTAssertGreaterThanOrEqual(Double(index) * 2 - 4, AdaptiveStreamingThresholds.standard.minDwellSeconds)

        // One bad window during the probe reverts it at once.
        let revert = controller.ingest(sample(index, congested))
        XCTAssertEqual(revert.action, .probeRevert)
        XCTAssertEqual(revert.reason, .probeFailedRevert)
        XCTAssertEqual(revert.point?.bitrate, 15_000_000)
        let revertedAt = Double(index) * 2 + 2
        index += 1

        // The bitrate dimension is backed off; nothing else can go up on a
        // 60 Hz iPad at full raster.
        var nextUpshiftAt: Double?
        while nextUpshiftAt == nil && index < 100 {
            let s = sample(index)
            if controller.ingest(s).action == .upshift { nextUpshiftAt = s.windowEnd }
            index += 1
        }
        XCTAssertNotNil(nextUpshiftAt)
        XCTAssertGreaterThanOrEqual((nextUpshiftAt ?? 0) - revertedAt,
                                    AdaptiveStreamingThresholds.standard.probeBackoffBaseSeconds)
    }

    func testProbeConfirmsAfterHealthyWindows() {
        var controller = makeController()
        _ = controller.ingest(sample(0, congested))
        _ = controller.ingest(sample(1, congested))
        var index = 2
        while controller.ingest(sample(index)).action != .upshift { index += 1 }
        index += 1
        XCTAssertEqual(controller.ingest(sample(index)).reason, .probeConfirming)
        XCTAssertEqual(controller.ingest(sample(index + 1)).reason, .probeConfirming)
        XCTAssertEqual(controller.ingest(sample(index + 2)).reason, .probeConfirmed)
        // A later bad window is an ordinary downshift, not a revert.
        _ = controller.ingest(sample(index + 3, congested))
        XCTAssertEqual(controller.ingest(sample(index + 4, congested)).action, .downshift)
    }

    func testRepeatedFlipsTriggerTheOscillationGuard() {
        var controller = makeController()
        _ = controller.ingest(sample(0, congested))
        _ = controller.ingest(sample(1, congested))
        var index = 2
        var sawGuard = false
        var upshifts = 0
        while index < 300 && !sawGuard {
            let decision = controller.ingest(sample(index))
            if decision.reason == .oscillationBackoff { sawGuard = true }
            if decision.action == .upshift {
                upshifts += 1
                index += 1
                _ = controller.ingest(sample(index, congested))   // fail the probe
            }
            index += 1
        }
        XCTAssertTrue(sawGuard)
        XCTAssertLessThanOrEqual(upshifts, 3)
    }

    // MARK: - Policy clamps

    func testDataSaverClampsTheLadderTop() {
        var controller = makeController()
        let clamp = controller.ingest(sample(0) { $0.dataPolicy = .saver })
        XCTAssertEqual(clamp.action, .policyClamp)
        XCTAssertEqual(clamp.reason, .dataSaverClamp)
        XCTAssertEqual(clamp.point, AdaptiveOperatingPoint(rasterScale: 0.75, bitrate: 6_000_000, fps: 60))
        for index in 1..<100 {
            let point = controller.ingest(sample(index) { $0.dataPolicy = .saver }).point
            XCTAssertLessThanOrEqual(point?.rasterScale ?? 0, 0.75)
            XCTAssertLessThanOrEqual(point?.bitrate ?? 0, 6_000_000)
            XCTAssertLessThanOrEqual(point?.fps ?? 0, 60)
        }
        // Reversible: back to normal, the controller climbs again (slowly).
        var raised = false
        for index in 100..<140 {
            if controller.ingest(sample(index)).action == .upshift { raised = true }
        }
        XCTAssertTrue(raised)
    }

    func testSaverStartsClampedAndNeverGoesBelowReadabilityFloor() {
        let controller = makeController(receiver: Self.iPhone, native: (1704, 786), dataPolicy: .saver)
        XCTAssertEqual(controller.point.rasterScale, 0.75)
        XCTAssertEqual(controller.point.bitrate, 6_000_000)
        var tablet = makeController(receiver: AdaptiveReceiverDisplay(pointsWide: 1194, pointsHigh: 834, scale: 2,
                                                                      sizeClass: .phone),
                                    dataPolicy: .saver)
        // A phone-class floor above the saver top keeps the floor.
        XCTAssertEqual(tablet.rasterFloor, 0.75)
        XCTAssertEqual(tablet.ingest(sample(0) { $0.dataPolicy = .saver }).point?.rasterScale, 0.75)
    }

    // MARK: - Safety: stale data, routes, generations

    func testInsufficientOrStaleDataHolds() {
        var controller = makeController()
        XCTAssertEqual(controller.ingest(sample(0) {
            $0.enqueuedFPS = nil
            $0.decodedFPS = nil
            $0.deliveredFPS = nil
        }).reason, .insufficientData)
        XCTAssertEqual(controller.ingest(sample(1) { $0.windowEnd = $0.windowStart + 0.2 }).reason, .insufficientData)
        XCTAssertEqual(controller.ingest(sample(2, mode: .mirror)).reason, .insufficientData)
        _ = controller.ingest(sample(3))
        XCTAssertEqual(controller.ingest(sample(3)).reason, .insufficientData, "an out-of-order window is ignored")
        XCTAssertEqual(controller.tick(now: 8 + 7).reason, .staleTelemetry)
        XCTAssertFalse(controller.tick(now: 60).isChange)
    }

    func testStaleRouteCallbacksAreIgnoredAndNewRoutesHold() {
        var controller = makeController()
        let stale = controller.routeDidChange(epoch: 1, now: 1)
        XCTAssertEqual(stale.reason, .staleRouteEpoch)
        XCTAssertFalse(stale.isChange)
        XCTAssertEqual(controller.routeDidChange(epoch: 0, now: 2).reason, .staleRouteEpoch)

        XCTAssertEqual(controller.routeDidChange(epoch: 2, now: 10).reason, .routeChangeSettling)
        // An older route's sample is stale too.
        XCTAssertEqual(controller.ingest(sample(5, congested)).reason, .staleRouteEpoch)
        // Inside the hold, even bad windows don't move anything.
        let held = controller.ingest(sample(5) {
            $0.routeEpoch = 2
            self.congested(&$0)
        })
        XCTAssertEqual(held.reason, .routeChangeSettling)
        XCTAssertEqual(controller.routeEpoch, 2)
    }

    func testRouteChangeRevertsAnUnconfirmedProbe() {
        var controller = makeController()
        _ = controller.ingest(sample(0, congested))
        _ = controller.ingest(sample(1, congested))
        var index = 2
        while controller.ingest(sample(index)).action != .upshift { index += 1 }
        let decision = controller.routeDidChange(epoch: 2, now: Double(index) * 2 + 3)
        XCTAssertEqual(decision.action, .probeRevert)
        XCTAssertEqual(decision.point?.bitrate, 15_000_000)
    }

    func testGenerationChangeResetsAndOldGenerationsAreIgnored() {
        var controller = makeController()
        _ = controller.ingest(sample(0, congested))
        _ = controller.ingest(sample(1, congested))
        XCTAssertEqual(controller.point.bitrate, 15_000_000)
        let reset = controller.ingest(sample(2) { $0.generation = 2 })
        XCTAssertEqual(reset.action, .reset)
        XCTAssertEqual(reset.reason, .generationReset)
        XCTAssertEqual(reset.point, AdaptiveOperatingPoint(rasterScale: 1, bitrate: 18_000_000, fps: 60))
        XCTAssertEqual(controller.generation, 2)
        XCTAssertEqual(controller.ingest(sample(3)).reason, .staleGeneration)
    }

    func testSwitchingFromCustomToAutomaticStartsFresh() {
        var controller = makeController(streamingMode: .custom)
        var configuration = controller.configuration
        configuration.streamingMode = .automatic
        let decision = controller.reconfigure(configuration, now: 10)
        XCTAssertEqual(decision.action, .reset)
        XCTAssertEqual(decision.point, AdaptiveOperatingPoint(rasterScale: 1, bitrate: 18_000_000, fps: 60))
    }

    // MARK: - Isolation and determinism

    func testControllersDoNotShareState() {
        var solo = makeController()
        var a = makeController()
        var b = makeController(receiver: Self.iPhone, native: (1704, 786))
        for index in 0..<120 {
            let healthy = sample(index)
            let expected = solo.ingest(healthy)
            _ = b.ingest(sample(index, encoderOverloaded))
            _ = b.routeDidChange(epoch: UInt64(index + 2), now: Double(index) * 2 + 1)
            XCTAssertEqual(a.ingest(healthy), expected)
        }
        XCTAssertEqual(a.point, solo.point)
    }

    func testSameInputsGiveTheSameDecisions() {
        func run() -> [AdaptiveStreamingDecision] {
            var controller = makeController(source: 120, receiverMax: 120, effective: 120)
            var decisions: [AdaptiveStreamingDecision] = []
            for index in 0..<200 {
                let s: Sample
                switch index % 37 {
                case 0..<5: s = sample(index, source: 120, congested)
                case 5..<8: s = sample(index, source: 1)
                case 30..<33: s = sample(index, source: 120, encoderOverloaded)
                default: s = sample(index, source: 120)
                }
                decisions.append(controller.ingest(s))
                if index == 150 { decisions.append(controller.routeDidChange(epoch: 2, now: s.windowEnd)) }
            }
            return decisions
        }
        XCTAssertEqual(run(), run())
    }

    func testEveryDecisionCarriesAReasonAndEvidence() {
        var controller = makeController()
        for index in 0..<40 {
            let decision = controller.ingest(sample(index, index < 10 ? congested : { _ in }))
            XCTAssertNotNil(decision.evidence.rasterFloor)
            XCTAssertNotNil(decision.evidence.ceilingFPS)
            if decision.cause == .network {
                XCTAssertEqual(decision.evidence.sendBackpressure, 0.3)
                XCTAssertNotNil(decision.evidence.rttMs)
            }
        }
    }
}

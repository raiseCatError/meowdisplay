import CoreVideo
import XCTest

/// Performance Lab frame-ID strip (#123): encoding, decoding under scaling,
/// noise, blur and clutter, unique/duplicate/skipped accounting, and the
/// receiver probe writing into the real diagnostics recorder.
final class PerformanceLabFrameIDTests: XCTestCase {

    // MARK: Codec

    func testGrayCodeRoundTripsAndChangesOneBitPerStep() {
        for n: UInt32 in [0, 1, 2, 3, 255, 256, 65_535, 1_048_574, 1_048_575] {
            XCTAssertEqual(PerformanceLabFrameIDCodec.fromGray(PerformanceLabFrameIDCodec.gray(n)), n)
        }
        for n: UInt32 in 0..<5_000 {
            let a = PerformanceLabFrameIDCodec.gray(n), b = PerformanceLabFrameIDCodec.gray(n + 1)
            XCTAssertEqual((a ^ b).nonzeroBitCount, 1)
        }
    }

    func testCRCMatchesTheCCITTFalseCheckValue() {
        XCTAssertEqual(PerformanceLabFrameIDCodec.crc16(Array("123456789".utf8)), 0x29B1)
    }

    func testModulesRoundTripForEveryCounterBitAndSegment() {
        var counters: [UInt32] = [0, 1, PerformanceLabFrameIDCodec.counterModulus - 1]
        for bit in 0..<20 { counters.append(1 << UInt32(bit)) }
        for counter in counters {
            for segment: UInt8 in [0, 7, 15] {
                let modules = PerformanceLabFrameIDCodec.modules(counter: counter, segment: segment)
                XCTAssertEqual(modules.count, PerformanceLabFrameIDCodec.codeModules)
                XCTAssertEqual(PerformanceLabFrameIDCodec.parse(modules: modules),
                               PerformanceLabFrameIDReading(counter: counter, segment: segment))
            }
        }
    }

    func testCounterWrapsAtTheModulus() {
        let modules = PerformanceLabFrameIDCodec.modules(counter: PerformanceLabFrameIDCodec.counterModulus + 5, segment: 1)
        XCTAssertEqual(PerformanceLabFrameIDCodec.parse(modules: modules)?.counter, 5)
    }

    func testAnySingleFlippedModuleIsRejected() {
        let modules = PerformanceLabFrameIDCodec.modules(counter: 123_456, segment: 3)
        for i in modules.indices {
            var bad = modules
            bad[i].toggle()
            XCTAssertNil(PerformanceLabFrameIDCodec.parse(modules: bad), "flip at \(i) accepted")
        }
    }

    // MARK: Row and image decoding

    private func stripImage(counter: UInt32, segment: UInt8 = 2, width: Int = 1620, height: Int = 200,
                            stripWidth: Int = 1620, x: Int = 0, y: Int = 40) -> PerformanceLabLumaImage {
        var image = PerformanceLabLumaImage(width: width, height: height, fill: 200)
        image.drawStrip(counter: counter, segment: segment, x: x, y: y, width: stripWidth,
                        height: stripWidth / PerformanceLabFrameIDCodec.stripModules * PerformanceLabFrameIDCodec.stripHeightModules)
        return image
    }

    /// Box-filter resample (area average), the way a scaler blurs edges.
    private func resample(_ src: PerformanceLabLumaImage, width: Int, height: Int) -> PerformanceLabLumaImage {
        var out = PerformanceLabLumaImage(width: width, height: height)
        let sx = Double(src.width) / Double(width), sy = Double(src.height) / Double(height)
        for y in 0..<height {
            for x in 0..<width {
                let x0 = Int(Double(x) * sx), x1 = max(x0 + 1, Int(Double(x + 1) * sx))
                let y0 = Int(Double(y) * sy), y1 = max(y0 + 1, Int(Double(y + 1) * sy))
                var sum = 0, n = 0
                for yy in y0..<min(y1, src.height) {
                    for xx in x0..<min(x1, src.width) { sum += Int(src.pixels[yy * src.width + xx]); n += 1 }
                }
                out.pixels[y * width + x] = UInt8(sum / max(n, 1))
            }
        }
        return out
    }

    private func locate(_ image: PerformanceLabLumaImage) -> PerformanceLabFrameIDReading? {
        var buffer: [UInt8] = []
        return PerformanceLabFrameIDLocator.locate(in: image, rowHint: nil, buffer: &buffer)?.reading
    }

    func testDecodesAtNativeSize() {
        XCTAssertEqual(locate(stripImage(counter: 777)), PerformanceLabFrameIDReading(counter: 777, segment: 2))
    }

    func testDecodesWhenScaledDownOrUp() {
        let source = stripImage(counter: 98_765)
        // 30 px modules at native size → 3 px (÷10) up to 51 px (×1.7).
        for scale in [0.1, 0.17, 0.25, 0.333, 0.5, 0.71, 1.7] {
            let w = Int(Double(source.width) * scale), h = Int(Double(source.height) * scale)
            let image = scale < 1 ? resample(source, width: w, height: h) : upscale(source, width: w, height: h)
            XCTAssertEqual(locate(image)?.counter, 98_765, "scale \(scale)")
        }
    }

    private func upscale(_ src: PerformanceLabLumaImage, width: Int, height: Int) -> PerformanceLabLumaImage {
        var out = PerformanceLabLumaImage(width: width, height: height)
        for y in 0..<height {
            for x in 0..<width {
                // Linear interpolation horizontally (soft edges), nearest vertically.
                let fx = (Double(x) + 0.5) * Double(src.width) / Double(width) - 0.5
                let x0 = max(0, min(src.width - 1, Int(fx.rounded(.down)))), x1 = min(src.width - 1, x0 + 1)
                let t = max(0, min(1, fx - Double(x0)))
                let sy = min(src.height - 1, y * src.height / height)
                let a = Double(src.pixels[sy * src.width + x0]), b = Double(src.pixels[sy * src.width + x1])
                out.pixels[y * width + x] = UInt8((a + (b - a) * t).rounded())
            }
        }
        return out
    }

    func testDecodesWithNoiseBlurAndVideoRangeLevels() {
        var image = stripImage(counter: 4242)
        var rng = PerformanceLabRandom(seed: 7)
        // Video range (16-235), ±25 noise, then a 5-tap horizontal blur.
        for i in image.pixels.indices {
            let v = 16 + Int(image.pixels[i]) * 219 / 255
            image.pixels[i] = UInt8(max(0, min(255, v + Int(rng.next() % 51) - 25)))
        }
        var blurred = image
        for y in 0..<image.height {
            for x in 2..<(image.width - 2) {
                var sum = 0
                for dx in -2...2 { sum += Int(image.pixels[y * image.width + x + dx]) }
                blurred.pixels[y * image.width + x] = UInt8(sum / 5)
            }
        }
        XCTAssertEqual(locate(blurred)?.counter, 4242)
    }

    func testFindsASmallStripInsideClutteredContent() {
        // A Window view composite: busy content everywhere, the fixture tile at an offset.
        var image = PerformanceLabLumaImage(width: 1920, height: 1080)
        var rng = PerformanceLabRandom(seed: 99)
        for i in image.pixels.indices { image.pixels[i] = rng.next() % 3 == 0 ? 30 : 220 }
        image.drawStrip(counter: 31_337, segment: 9, x: 700, y: 400, width: 594, height: 44)
        XCTAssertEqual(locate(image), PerformanceLabFrameIDReading(counter: 31_337, segment: 9))
    }

    func testNoFalsePositivesInRandomOrTextLikeImages() {
        var rng = PerformanceLabRandom(seed: 2026)
        for trial in 0..<20 {
            var image = PerformanceLabLumaImage(width: 960, height: 540)
            if trial % 2 == 0 {
                for i in image.pixels.indices { image.pixels[i] = UInt8(truncatingIfNeeded: rng.next()) }
            } else {
                // Bars of random widths: closest to a barcode without being one.
                for y in 0..<image.height {
                    var x = 0
                    while x < image.width {
                        let w = 1 + Int(rng.next() % 40), dark = rng.next() % 2 == 0
                        for xx in x..<min(image.width, x + w) { image.pixels[y * image.width + xx] = dark ? 0 : 255 }
                        x += w
                    }
                }
            }
            XCTAssertNil(locate(image), "false positive in image \(trial)")
        }
    }

    // MARK: Tracker

    func testTrackerCountsUniqueDuplicateSkippedAndIntervals() {
        var t = PerformanceLabFrameIDTracker()
        func r(_ c: UInt32) -> PerformanceLabFrameIDReading { .init(counter: c, segment: 0) }
        XCTAssertEqual(t.observe(r(10), atMs: 0), .baseline)
        XCTAssertEqual(t.observe(r(11), atMs: 16), .unique(skipped: 0, intervalMs: 16))
        XCTAssertEqual(t.observe(r(11), atMs: 33), .duplicate)
        XCTAssertEqual(t.observe(r(14), atMs: 50), .unique(skipped: 2, intervalMs: 34))
        XCTAssertEqual(t.observe(nil, atMs: 66), .unreadable)
        XCTAssertEqual(t.tally, PerformanceLabFrameIDTally(read: 4, unique: 3, duplicate: 1, skipped: 2, unreadable: 1, discontinuities: 0))
    }

    /// B6: a frame that arrived but could not be read may have carried one
    /// of the missing IDs, so it is never also counted as skipped.
    func testUnreadableFramesBetweenReadsAreNotCountedAsSkipped() {
        var t = PerformanceLabFrameIDTracker()
        func r(_ c: UInt32) -> PerformanceLabFrameIDReading { .init(counter: c, segment: 0) }
        XCTAssertEqual(t.observe(r(10), atMs: 0), .baseline)
        XCTAssertEqual(t.observe(nil, atMs: 16), .unreadable)
        XCTAssertEqual(t.observe(nil, atMs: 33), .unreadable)
        XCTAssertEqual(t.observe(r(13), atMs: 50), .unique(skipped: 0, intervalMs: 50), "IDs 11 and 12 may be the two unread frames")
        XCTAssertEqual(t.observe(nil, atMs: 66), .unreadable)
        XCTAssertEqual(t.observe(r(17), atMs: 83), .unique(skipped: 2, intervalMs: 33), "3 missing IDs, 1 unread frame: 2 provably missing")
        XCTAssertEqual(t.tally, PerformanceLabFrameIDTally(read: 3, unique: 3, duplicate: 0, skipped: 2, unreadable: 3, discontinuities: 0))
        // A lost strip re-baselines: the frames in between say nothing.
        t.rebaseline()
        XCTAssertEqual(t.observe(r(400), atMs: 500), .baseline)
        XCTAssertEqual(t.tally.skipped, 2)
    }

    func testTrackerHandlesWrapAndRestart() {
        var t = PerformanceLabFrameIDTracker()
        let max = PerformanceLabFrameIDCodec.counterModulus - 1
        _ = t.observe(.init(counter: max - 1, segment: 0), atMs: 0)
        XCTAssertEqual(t.observe(.init(counter: 1, segment: 0), atMs: 10), .unique(skipped: 2, intervalMs: 10), "wraps forward")
        XCTAssertEqual(t.observe(.init(counter: 0, segment: 0), atMs: 20), .discontinuity, "backwards = fixture restarted")
        XCTAssertEqual(t.observe(.init(counter: 1, segment: 0), atMs: 30), .unique(skipped: 0, intervalMs: 10))
    }

    // MARK: Probe → recorder → wire

    private func makeRecorder() -> StreamDiagnosticsRecorder {
        StreamDiagnosticsRecorder(side: .receiver, windowSeconds: 5, diagnosticsSwitch: StreamDiagnosticsSwitch(enabled: true),
                                  resourceSampler: nil, nowMs: 0)
    }

    func testProbeRecordsExactCountsIntoTheRecorderAndTheWireSummary() throws {
        let probe = PerformanceLabFrameIDProbe()
        let recorder = makeRecorder()
        var ms = 0.0
        for counter: UInt32 in [10, 11, 11, 14] {
            ms += 16
            probe.observe(stripImage(counter: counter, width: 800, height: 120, stripWidth: 756, x: 20, y: 10), recorder: recorder, nowMs: ms)
        }
        XCTAssertTrue(probe.isLocked)
        let snapshot = recorder.snapshot(at: ms)
        XCTAssertEqual(snapshot.count(.frameIDRead), 4)
        XCTAssertEqual(snapshot.count(.frameIDUnique), 3)
        XCTAssertEqual(snapshot.count(.frameIDDuplicate), 1)
        XCTAssertEqual(snapshot.count(.frameIDSkipped), 2)
        XCTAssertEqual(snapshot.stage(.frameIDUniqueInterval)?.count, 2, "intervals between the three unique frames")

        let summary = StreamDiagnosticsPeerSummary.from(snapshot)
        XCTAssertEqual(summary.frameIDMissing, 2)
        XCTAssertEqual(summary.frameIDUnreadable, 0)
        XCTAssertEqual(summary.frameIDUnexamined, 0)
        let wire = summary.wireFields
        XCTAssertEqual(wire["fidSkip"] as? Double, 2)
        XCTAssertNil(wire["fidN"], "removed: nothing read it")
        let back = try XCTUnwrap(StreamDiagnosticsPeerSummary.fromWire(wire, side: .receiver))
        XCTAssertEqual(back.frameIDDuplicates, 1)
        XCTAssertEqual(back.frameIDMissing, 2)
    }

    func testWireSummaryHasNoFrameIDKeysWithoutTheFixture() {
        let recorder = makeRecorder()
        recorder.recordArrival(bytes: 100, wireSubmitToSendMs: nil, mappedSubmitToReceiveMs: nil, at: 1)
        let wire = StreamDiagnosticsPeerSummary.from(recorder.snapshot(at: 2)).wireFields
        XCTAssertFalse(wire.keys.contains { $0.hasPrefix("fid") })
    }

    func testProbeProbesOneFrameInThirtyUntilFoundAndUnlocksAfterMisses() {
        let probe = PerformanceLabFrameIDProbe()
        let recorder = makeRecorder()
        let blank = PerformanceLabLumaImage(width: 400, height: 80, fill: 128)
        let strip = stripImage(counter: 5, width: 400, height: 80, stripWidth: 378, x: 10, y: 10)
        var ms = 0.0
        // Not a lab frame: nothing is counted while probing.
        for _ in 0..<60 { ms += 16; probe.observe(blank, recorder: recorder, nowMs: ms) }
        XCTAssertEqual(recorder.snapshot(at: ms).count(.frameIDUnreadable), 0)
        // The strip appears: found at the next probe, then read on every frame.
        var reads = 0
        for _ in 0..<30 {
            ms += 16
            probe.observe(strip, recorder: recorder, nowMs: ms)
            if probe.isLocked { reads += 1 }
        }
        XCTAssertTrue(probe.isLocked)
        XCTAssertEqual(recorder.snapshot(at: ms).count(.frameIDRead), Int64(reads))
        // The fixture leaves: unreadable while locked, then back to probing.
        for _ in 0..<PerformanceLabFrameIDProbe.missesBeforeUnlock { ms += 16; probe.observe(blank, recorder: recorder, nowMs: ms) }
        XCTAssertFalse(probe.isLocked)
        XCTAssertEqual(recorder.snapshot(at: ms).count(.frameIDUnreadable), Int64(PerformanceLabFrameIDProbe.missesBeforeUnlock))
        // It comes back with a much later ID while the reader is searching:
        // the frames it did not examine are unexamined, never skipped IDs.
        let later = stripImage(counter: 500, width: 400, height: 80, stripWidth: 378, x: 10, y: 10)
        for _ in 0..<(PerformanceLabFrameIDProbe.probeEveryNthFrame - 1) {
            ms += 16
            probe.observe(later, recorder: recorder, nowMs: ms)
            XCTAssertFalse(probe.isLocked, "not probed yet")
        }
        ms += 16
        probe.observe(later, recorder: recorder, nowMs: ms)
        XCTAssertTrue(probe.isLocked)
        let after = recorder.snapshot(at: ms)
        XCTAssertEqual(after.count(.frameIDUnexamined), Int64(PerformanceLabFrameIDProbe.probeEveryNthFrame - 1))
        XCTAssertEqual(after.count(.frameIDSkipped), 0, "re-baselined when found again: 495 IDs are not 'skipped'")
        XCTAssertEqual(probe.tally.skipped, 0)
    }

    func testProbeReadsBiPlanarAndBGRAPixelBuffers() throws {
        let image = stripImage(counter: 2024, width: 640, height: 96, stripWidth: 594, x: 23, y: 20)
        for format in [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_32BGRA] {
            var pb: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferCreate(nil, image.width, image.height, format, nil, &pb), kCVReturnSuccess)
            let buffer = try XCTUnwrap(pb)
            CVPixelBufferLockBaseAddress(buffer, [])
            let biPlanar = format != kCVPixelFormatType_32BGRA
            let base = try XCTUnwrap(biPlanar ? CVPixelBufferGetBaseAddressOfPlane(buffer, 0) : CVPixelBufferGetBaseAddress(buffer))
            let stride = biPlanar ? CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) : CVPixelBufferGetBytesPerRow(buffer)
            let p = base.assumingMemoryBound(to: UInt8.self)
            for y in 0..<image.height {
                for x in 0..<image.width {
                    let v = image.pixels[y * image.width + x]
                    if biPlanar {
                        p[y * stride + x] = v
                    } else {
                        // Coloured light and dark (chroma differs, luma still contrasts).
                        let o = y * stride + 4 * x
                        p[o] = v > 128 ? 180 : 20; p[o + 1] = v > 128 ? 255 : 0; p[o + 2] = v > 128 ? 255 : 60; p[o + 3] = 255
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])

            let probe = PerformanceLabFrameIDProbe()
            let recorder = makeRecorder()
            probe.observe(buffer, recorder: recorder, nowMs: 1)
            XCTAssertTrue(probe.isLocked, "format \(format)")
            XCTAssertEqual(probe.tally.read, 1)
        }
    }

    func testDisabledRecorderMeansTheProbeIsNeverCalledByThePresenterGuard() {
        // The presenter calls the probe only inside `diagnostics.isEnabled`;
        // a disabled recorder also ignores anything recorded.
        let recorder = StreamDiagnosticsRecorder(side: .receiver, diagnosticsSwitch: StreamDiagnosticsSwitch(enabled: false),
                                                 resourceSampler: nil, nowMs: 0)
        let probe = PerformanceLabFrameIDProbe()
        probe.observe(stripImage(counter: 1), recorder: recorder, nowMs: 1)
        XCTAssertEqual(recorder.snapshot(at: 2).count(.frameIDRead), 0)
    }
}

import CoreGraphics
import XCTest

/// `DecodeCeilingTests`/`ExtendDisplayShapeTests`/`ExtendViewportTests` each
/// prove their own function is correct in isolation, given inputs a test
/// author picked. That was exactly the gap behind the real-device Extend
/// regression this suite guards: every pure function was individually
/// correct, but nothing proved the actual PIPELINE — shape preference ->
/// virtual-display point size -> native pixel size -> decode-ceiling clamp
/// -> viewport fit — composes them into the right end-to-end numbers. These
/// tests wire the real production functions together the same way
/// `MacSender` does (see `setupExtend`/`resizeExistingDisplay`/
/// `clampedCaptureSize`), so a change to any one piece that breaks the
/// composition — not just the piece itself — fails here.
final class ExtendIntegrationBoundaryTests: XCTestCase {

    /// Mirrors `MacSender.clampedCaptureSize`: native pixels are 2x the
    /// virtual display's points (HiDPI), scaled by the quality preset, then
    /// clamped to the receiver's advertised decode ceiling.
    private func encodedSize(pointsWide: Int, pointsHigh: Int,
                             qualityScale: Double = 1.0,
                             maxWide: Int? = nil, maxHigh: Int? = nil) -> (width: Int, height: Int) {
        let nativeW = (Int(Double(pointsWide * 2) * qualityScale)) & ~1
        let nativeH = (Int(Double(pointsHigh * 2) * qualityScale)) & ~1
        return DecodeCeiling.clamp(width: nativeW, height: nativeH, maxWide: maxWide, maxHigh: maxHigh)
    }

    // MARK: - Explicit shape -> virtual display dimensions

    func testExplicit16x9ProducesA16x9VirtualDisplayOnALandscapeReceiver() {
        let preference = ExtendDisplayShapePreference(shape: .r16x9, useFullDisplay: false)
        // iPhone-shaped landscape hello: pixelsWide is the long edge.
        let physicalAspect = 2796.0 / 1290.0
        let aspect = preference.resolvedAspect(receiverPhysicalAspect: physicalAspect)
        let size = ExtendDisplaySizing.pointSize(receiverPixelsWide: 2796, receiverPixelsHigh: 1290, aspect: aspect)
        XCTAssertEqual(Double(size.wide) / Double(size.high), 16.0 / 9.0, accuracy: 0.01)
    }

    func testExplicit16x9ProducesA16x9VirtualDisplayOnAPortraitReceiver() {
        let preference = ExtendDisplayShapePreference(shape: .r16x9, useFullDisplay: false)
        let physicalAspect = 1290.0 / 2796.0
        let aspect = preference.resolvedAspect(receiverPhysicalAspect: physicalAspect)
        let size = ExtendDisplaySizing.pointSize(receiverPixelsWide: 1290, receiverPixelsHigh: 2796, aspect: aspect)
        XCTAssertEqual(Double(size.wide) / Double(size.high), 16.0 / 9.0, accuracy: 0.01)
    }

    // MARK: - Decode ceiling preserves the requested shape end-to-end

    func testDecodeCeilingPreserves16x9ThroughTheFullPipeline() {
        let preference = ExtendDisplayShapePreference(shape: .r16x9, useFullDisplay: false)
        let aspect = preference.resolvedAspect(receiverPhysicalAspect: 2796.0 / 1290.0)
        let points = ExtendDisplaySizing.pointSize(receiverPixelsWide: 2796, receiverPixelsHigh: 1290, aspect: aspect)
        // A receiver decode ceiling with a DIFFERENT aspect than the request
        // (a real-world case: the ceiling reflects decoder throughput, not
        // the chosen shape) must not leak its own aspect into the result.
        let encoded = encodedSize(pointsWide: points.wide, pointsHigh: points.high, maxWide: 1920, maxHigh: 1200)
        XCTAssertLessThanOrEqual(encoded.width, 1920)
        XCTAssertLessThanOrEqual(encoded.height, 1200)
        XCTAssertEqual(Double(encoded.width) / Double(encoded.height), 16.0 / 9.0, accuracy: 0.02)
    }

    func testDecodeCeilingPreserves16x10ThroughTheFullPipeline() {
        let preference = ExtendDisplayShapePreference(shape: .r16x10, useFullDisplay: false)
        let aspect = preference.resolvedAspect(receiverPhysicalAspect: 2796.0 / 1290.0)
        let points = ExtendDisplaySizing.pointSize(receiverPixelsWide: 2796, receiverPixelsHigh: 1290, aspect: aspect)
        let encoded = encodedSize(pointsWide: points.wide, pointsHigh: points.high, maxWide: 1920, maxHigh: 1080)
        XCTAssertLessThanOrEqual(encoded.width, 1920)
        XCTAssertLessThanOrEqual(encoded.height, 1080)
        XCTAssertEqual(Double(encoded.width) / Double(encoded.height), 16.0 / 10.0, accuracy: 0.02)
    }

    func testDecodeCeilingNeverUpscalesTheComposedExtendStream() {
        let preference = ExtendDisplayShapePreference(shape: .r21x9, useFullDisplay: false)
        let aspect = preference.resolvedAspect(receiverPhysicalAspect: 2796.0 / 1290.0)
        let points = ExtendDisplaySizing.pointSize(receiverPixelsWide: 2796, receiverPixelsHigh: 1290, aspect: aspect)
        let unclamped = encodedSize(pointsWide: points.wide, pointsHigh: points.high, qualityScale: 0.5)
        // A ceiling far larger than the (already quality-scaled-down) stream
        // must pass it through unchanged, never scale it up toward the cap.
        let encoded = encodedSize(pointsWide: points.wide, pointsHigh: points.high, qualityScale: 0.5,
                                  maxWide: 8000, maxHigh: 8000)
        XCTAssertEqual(encoded.width, unclamped.width)
        XCTAssertEqual(encoded.height, unclamped.height)
    }

    // MARK: - Viewport: content aspect matching receiver aspect fills it

    func test16x9ContentIntoA16x9ViewportFillsItWithNoLetterboxing() {
        let bounds = CGRect(x: 0, y: 0, width: 1600, height: 900)   // exactly 16:9
        let content = CGSize(width: 1920, height: 1080)             // also 16:9
        let t = RemoteViewportCalculator.normal(viewBounds: bounds, remoteAspectSize: content)
        XCTAssertEqual(t.displayedRect.width, bounds.width, accuracy: 0.5)
        XCTAssertEqual(t.displayedRect.height, bounds.height, accuracy: 0.5)
        XCTAssertEqual(t.displayedRect.minX, 0, accuracy: 0.5)
        XCTAssertEqual(t.displayedRect.minY, 0, accuracy: 0.5)
    }

    // MARK: - Real pipeline dimensions never crop extreme ratios

    func testUltrawideShapeThroughTheRealSizingPipelineNeverCropsInLandscape() {
        let preference = ExtendDisplayShapePreference(shape: .r32x9, useFullDisplay: false)
        let aspect = preference.resolvedAspect(receiverPhysicalAspect: 2796.0 / 1290.0)
        let points = ExtendDisplaySizing.pointSize(receiverPixelsWide: 2796, receiverPixelsHigh: 1290, aspect: aspect)
        let contentSize = CGSize(width: Double(points.wide), height: Double(points.high))
        let bounds = CGRect(x: 0, y: 0, width: 852, height: 393)
        let t = RemoteViewportCalculator.normal(viewBounds: bounds, remoteAspectSize: contentSize)
        XCTAssertLessThanOrEqual(t.displayedRect.width, bounds.width + 0.5)
        XCTAssertLessThanOrEqual(t.displayedRect.height, bounds.height + 0.5)
    }
}

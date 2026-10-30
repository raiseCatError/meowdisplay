import CoreVideo
import ScreenCaptureKit
import XCTest

/// P1: pane capture health (never an endless "Waiting"), capture sizing without capture crops,
/// and ScreenCaptureKit's padded frames mapped by their content rect.
final class WindowCaptureHealthTests: XCTestCase {
    func testAPaneIsWaitingThenLiveAndStaticContentStaysLive() {
        XCTAssertEqual(TileCaptureWatch.verdict(now: 1, startedAt: 0, firstCompleteAt: nil, suspendedSince: nil, sourceLooksAvailable: true), .waiting)
        XCTAssertEqual(TileCaptureWatch.verdict(now: 60, startedAt: 0, firstCompleteAt: 0.2, suspendedSince: nil, sourceLooksAvailable: true), .live,
                       "no new frames for a minute after the first one is a static window, not a stall")
    }

    func testNoFrameInTimeIsAStallAndRestartsBackOffThenGiveUp() {
        XCTAssertEqual(TileCaptureWatch.verdict(now: 4.1, startedAt: 0, firstCompleteAt: nil, suspendedSince: nil, sourceLooksAvailable: true), .stalled)
        XCTAssertEqual((1...5).compactMap(TileCaptureWatch.retryDelay(attempt:)), [1, 2, 4, 8, 16])
        XCTAssertNil(TileCaptureWatch.retryDelay(attempt: 6), "then the pane says it failed and offers Retry")
    }

    func testAWindowInStageManagersStripIsPausedNotWaiting() {
        // Measured: a strip window delivers one .suspended frame and nothing more.
        XCTAssertEqual(TileCaptureWatch.verdict(now: 30, startedAt: 0, firstCompleteAt: nil, suspendedSince: 0.1, sourceLooksAvailable: false), .paused)
        XCTAssertEqual(TileCaptureWatch.verdict(now: 30, startedAt: 0, firstCompleteAt: 1, suspendedSince: 20, sourceLooksAvailable: false), .paused,
                       "left the stage while streaming: paused, last picture kept")
        XCTAssertEqual(TileCaptureWatch.verdict(now: 7, startedAt: 0, firstCompleteAt: nil, suspendedSince: 0.5, sourceLooksAvailable: true), .stalled,
                       "paused although the window is on the stage: restarted")
        XCTAssertEqual(TileCaptureWatch.verdict(now: 2.4, startedAt: 0, firstCompleteAt: 0.2, suspendedSince: 0.3, sourceLooksAvailable: true), .stalled,
                       "back on the stage: a fresh stream after 2 s (lab: a rebuilt stream is live within a second)")
        XCTAssertEqual(TileCaptureWatch.verdict(now: 1.5, startedAt: 0, firstCompleteAt: 0.2, suspendedSince: 0.3, sourceLooksAvailable: true), .paused,
                       "not before: the catalog may see the stage a moment before the stream does")
        XCTAssertTrue(StageManagerWindows.looksLikeThumbnail(CGRect(x: -238, y: 180, width: 176, height: 166)))
        XCTAssertFalse(StageManagerWindows.looksLikeThumbnail(CGRect(x: 214, y: 30, width: 1554, height: 993)))
    }

    func testTheRealWindowBehindAStageManagerThumbnailIsFoundByTitle() {
        let chrome = CGRect(x: 0, y: 30, width: 1920, height: 1050), other = CGRect(x: 50, y: 50, width: 800, height: 600)
        // Measured: Chrome's Accessibility title has " - High memory usage…" after the window's own.
        XCTAssertEqual(StageManagerWindows.matchingFrame(title: "Android C3 Status",
                                                         in: [("Android C3 Status - High memory usage - 1.1 GB", chrome), ("Inbox", other)]), chrome)
        XCTAssertEqual(StageManagerWindows.matchingFrame(title: "Doc", in: [("Doc", other), ("Doc 2", chrome)]), other, "exact wins")
        XCTAssertNil(StageManagerWindows.matchingFrame(title: "Doc", in: [("Doc A", other), ("Doc B", chrome)]), "ambiguous: unknown")
        XCTAssertEqual(StageManagerWindows.matchingFrame(title: "", in: [("Only", chrome)]), chrome, "the app's only window")
    }

    func testCaptureSizeFollowsTheDrawnSizeInStepsUpToTheSourcesOwnPixels() {
        let window = CGSize(width: 1600, height: 1000)
        let fit = WorkspaceCaptureSizing.size(source: window, drawScale: 0.5, backingScale: 2)
        XCTAssertEqual(fit, CGSize(width: 800, height: 500), "a quarter of the 2x pixels covers a 0.5 draw scale")
        let slightlyMore = WorkspaceCaptureSizing.size(source: window, drawScale: 0.52, backingScale: 2)
        XCTAssertEqual(slightlyMore, CGSize(width: 1066, height: 666), "the next step up, not every small change")
        XCTAssertEqual(WorkspaceCaptureSizing.size(source: window, drawScale: 16, backingScale: 2), CGSize(width: 3200, height: 2000),
                       "8x zoom never asks for more than the window's own pixels")
        let huge = WorkspaceCaptureSizing.size(source: CGSize(width: 6000, height: 3000), drawScale: 10, backingScale: 2)
        XCTAssertLessThanOrEqual(huge.width, 4096); XCTAssertLessThanOrEqual(huge.width * huge.height, 12_000_000)
        XCTAssertEqual(Int(huge.width) % 2, 0)
    }

    func testTheContentRectComesFromTheFrameInfoAndPaddingIsLeftOut() throws {
        let buffer = try solid(1200, 800)
        // Measured: a 1920x1050 window in a 1200x800 buffer: content (0,0,1200,656.25), scale 0.625.
        let info: [SCStreamFrameInfo: Any] = [.contentRect: CGRect(x: 0, y: 0, width: 1200, height: 656.25).dictionaryRepresentation,
                                              .scaleFactor: 1.0, .contentScale: 0.625]
        XCTAssertEqual(WindowTileCapture.contentRect(info, pixels: buffer), CGRect(x: 0, y: 0, width: 1200, height: 656.25))
        let points = try XCTUnwrap(WindowTileCapture.sourcePoints(info))
        XCTAssertEqual(points.width, 1920, accuracy: 1e-6); XCTAssertEqual(points.height, 1050, accuracy: 1e-6)
        let retina: [SCStreamFrameInfo: Any] = [.contentRect: CGRect(x: 0, y: 0, width: 600, height: 300).dictionaryRepresentation, .scaleFactor: 2.0]
        XCTAssertEqual(WindowTileCapture.contentRect(retina, pixels: buffer), CGRect(x: 0, y: 0, width: 1200, height: 600), "points x scale factor")
        XCTAssertEqual(WindowTileCapture.contentRect([:], pixels: buffer), CGRect(x: 0, y: 0, width: 1200, height: 800), "unknown: the whole buffer")
    }

    func testThePaneShowsOnlyTheContentNeverThePadding() throws {
        let compositor = try XCTUnwrap(WorkspaceCompositor())
        compositor.resize(to: CGSize(width: 400, height: 400))
        // Content red on top, green padding below (as ScreenCaptureKit pads a wide window).
        let buffer = try solid(400, 400) { _, y in y < 200 ? (0, 0, 255) : (0, 255, 0) }
        let t = TileContentTransform(tile: WorkspaceRect(x: 0, y: 0, width: 400, height: 400), source: WorkspaceSize(width: 800, height: 400),
                                     rotation: .none, fit: .fit)
        let item = WorkspaceCompositor.Item(rect: WorkspaceRect(x: 0, y: 0, width: 1, height: 1), transform: t, frame: buffer,
                                            sourceSize: .zero, dimmed: false, content: CGRect(x: 0, y: 0, width: 400, height: 200))
        let out = try XCTUnwrap(compositor.compose([item]))
        // Fit: the 2:1 window fills the width, 200 tall, centred (y 100...300).
        for y in [105, 200, 295] { XCTAssertEqual(pixel(out, 200, y).r, 255, accuracy: 3, "content at y=\(y)") }
        for y in [50, 350] { XCTAssertLessThan(pixel(out, 200, y).g, 40, "no padding in the letterbox (y=\(y))") }
    }

    private func solid(_ w: Int, _ h: Int, _ color: (Int, Int) -> (UInt8, UInt8, UInt8) = { _, _ in (0, 0, 255) }) throws -> CVPixelBuffer {
        var out: CVPixelBuffer?
        let attrs = [kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]] as CFDictionary
        XCTAssertEqual(CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, attrs, &out), kCVReturnSuccess)
        let buffer = try XCTUnwrap(out)
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
        let row = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<h { for x in 0..<w { let c = color(x, y); let p = base + y * row + x * 4; p[0] = c.0; p[1] = c.1; p[2] = c.2; p[3] = 255 } }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    private func pixel(_ buffer: CVPixelBuffer, _ x: Int, _ y: Int) -> (b: Double, g: Double, r: Double) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let p = base + y * CVPixelBufferGetBytesPerRow(buffer) + x * 4
        return (Double(p[0]), Double(p[1]), Double(p[2]))
    }

    /// A Full Desktop pane asks macOS for its content before its stream exists; it used to read
    /// as started at uptime 0 and was restarted as "stalled" at once (log 2026-10-30 17:14:45).
    func testAPaneWaitingToStartIsNotStalled() {
        let capture = WindowTileCapture(tileID: "w7", windowID: 0, assignmentGeneration: 1)
        let h = capture.healthNow
        let now = ProcessInfo.processInfo.systemUptime
        XCTAssertGreaterThan(h.startedAt, now - 1)
        XCTAssertEqual(TileCaptureWatch.verdict(now: now + 0.5, startedAt: h.startedAt, firstCompleteAt: nil,
                                                suspendedSince: nil, sourceLooksAvailable: true), .waiting)
        XCTAssertEqual(TileCaptureWatch.verdict(now: h.startedAt + 4.1, startedAt: h.startedAt, firstCompleteAt: nil,
                                                suspendedSince: nil, sourceLooksAvailable: true), .stalled, "a stream that never delivers still restarts")
    }

    /// Regression (2026-10-30 21:3x): a Stage Manager strip window after Home and back looped
    /// paused → one frame ("live again") → paused → restart every 2–3 s. Now: one fresh stream per
    /// change in the window, otherwise it stays Paused.
    func testAPauseMacOSKeepsGetsOneFreshStreamPerChangeNotALoop() {
        let frame = CGRect(x: 100, y: 80, width: 900, height: 600)
        let sig = TileCaptureWatch.windowSignature(frame: frame, availability: "visible", inStageStrip: false, isActive: false)
        XCTAssertEqual(TileCaptureWatch.unexplainedPause(signature: sig, restartedFor: nil), .restart)
        XCTAssertEqual(TileCaptureWatch.unexplainedPause(signature: sig, restartedFor: sig), .stayPaused,
                       "nothing changed since the last fresh stream: stay Paused")
        let activated = TileCaptureWatch.windowSignature(frame: frame, availability: "visible", inStageStrip: false, isActive: true)
        XCTAssertEqual(TileCaptureWatch.unexplainedPause(signature: activated, restartedFor: sig), .restart,
                       "brought forward on the Mac: try again")
        let moved = TileCaptureWatch.windowSignature(frame: frame.offsetBy(dx: 40, dy: 0), availability: "visible", inStageStrip: false, isActive: false)
        XCTAssertNotEqual(moved, sig)
        let leftStrip = TileCaptureWatch.windowSignature(frame: frame, availability: "visible", inStageStrip: true, isActive: false)
        XCTAssertNotEqual(leftStrip, sig)
    }
}

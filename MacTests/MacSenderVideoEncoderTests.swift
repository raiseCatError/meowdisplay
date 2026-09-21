import CoreMedia
import VideoToolbox
import XCTest

/// Covers `MacSenderVideoEncoder`'s real decision logic: session identity and
/// the stale-output verdict that decides whether a completed frame may be
/// published. These are unit tests of the OWNERSHIP rules, not proof of
/// VideoToolbox's own runtime behaviour — the sessions created here are real,
/// but nothing in this file establishes what VideoToolbox guarantees.
@available(macOS 14.0, *)
final class MacSenderVideoEncoderTests: XCTestCase {

    private static let width = 640
    private static let height = 360

    private func configuration(codec: StreamCodec = .h264,
                               fps: Int = 30,
                               lowLatency: Bool = false) -> MacSenderVideoEncoder.Configuration {
        MacSenderVideoEncoder.Configuration(
            width: Self.width, height: Self.height, fps: fps,
            bitrate: 8_000_000, codec: codec, lowLatency: lowLatency)
    }

    /// Creates a session or skips: a machine without a usable encoder for
    /// `codec` must not fail the suite.
    private func makeActiveEncoder(codec: StreamCodec = .h264) throws -> MacSenderVideoEncoder {
        let encoder = MacSenderVideoEncoder()
        let status = encoder.create(configuration(codec: codec))
        try XCTSkipUnless(encoder.isActive,
                          "no usable \(codec.wireValue) encoder on this machine (status \(status))")
        return encoder
    }

    private func makePixelBuffer() throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, Self.width, Self.height,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary,
            &buffer)
        return try XCTUnwrap(buffer, "CVPixelBufferCreate failed (status \(status))")
    }

    // MARK: - Session lifecycle

    func testStartsWithNoSession() {
        let encoder = MacSenderVideoEncoder()
        XCTAssertFalse(encoder.isActive)
        XCTAssertNil(encoder.currentTokenForTesting)
    }

    func testCreateInstallsSessionCarryingItsConfiguredCodec() throws {
        let encoder = try makeActiveEncoder(codec: .h264)
        let token = try XCTUnwrap(encoder.currentTokenForTesting)
        XCTAssertEqual(encoder.codecIfCurrentForTesting(token), .h264)
    }

    func testInvalidateClearsSessionAndSpendsItsToken() throws {
        let encoder = try makeActiveEncoder()
        let token = try XCTUnwrap(encoder.currentTokenForTesting)
        encoder.invalidate()
        XCTAssertFalse(encoder.isActive)
        XCTAssertNil(encoder.currentTokenForTesting)
        // The verdict the output handler asks for: output from the retired
        // session is stale and must not be published.
        XCTAssertNil(encoder.codecIfCurrentForTesting(token))
    }

    func testInvalidateIsIdempotent() throws {
        let encoder = try makeActiveEncoder()
        encoder.invalidate()
        encoder.invalidate()
        XCTAssertFalse(encoder.isActive)
    }

    // MARK: - Stale output across an in-place recreation

    /// The interleaving the session token exists for: session A is replaced by
    /// session B WITHOUT `captureGeneration` moving (the live-FPS-change,
    /// Video-On and encoder-failure-streak recovery paths all do exactly
    /// this), and A's output arrives afterwards.
    func testRecreatingInPlaceMakesTheRetiredSessionsOutputStale() throws {
        let encoder = try makeActiveEncoder()
        let tokenA = try XCTUnwrap(encoder.currentTokenForTesting)

        XCTAssertEqual(encoder.create(configuration(fps: 60)), noErr)
        let tokenB = try XCTUnwrap(encoder.currentTokenForTesting)

        XCTAssertNotEqual(tokenA, tokenB, "a replacement session must get a new identity")
        XCTAssertNil(encoder.codecIfCurrentForTesting(tokenA),
                     "session A's output must be rejected once B is current")
        XCTAssertEqual(encoder.codecIfCurrentForTesting(tokenB), .h264)
    }

    func testTokensAreNeverReusedAcrossManyRecreations() throws {
        let encoder = try makeActiveEncoder()
        var seen: Set<UInt64> = []
        for _ in 0..<5 {
            XCTAssertEqual(encoder.create(configuration()), noErr)
            let token = try XCTUnwrap(encoder.currentTokenForTesting)
            XCTAssertTrue(seen.insert(token).inserted, "session identity was reused")
        }
        // Every retired token stays stale forever.
        for token in seen where token != encoder.currentTokenForTesting {
            XCTAssertNil(encoder.codecIfCurrentForTesting(token))
        }
    }

    /// HEVC ↔ H.264 is the case that makes staleness a correctness issue and
    /// not just tidiness: parameter-set extraction is codec-specific, so a
    /// frame from an HEVC session must never be read with the H.264 APIs.
    func testRetiredSessionsCodecIsNotReplacedByTheNewSessionsCodec() throws {
        let encoder = MacSenderVideoEncoder()
        _ = encoder.create(configuration(codec: .hevc))
        try XCTSkipUnless(encoder.isActive, "no usable HEVC encoder on this machine")
        let hevcToken = try XCTUnwrap(encoder.currentTokenForTesting)
        XCTAssertEqual(encoder.codecIfCurrentForTesting(hevcToken), .hevc)

        XCTAssertEqual(encoder.create(configuration(codec: .h264)), noErr)
        XCTAssertEqual(encoder.codecIfCurrentForTesting(
            try XCTUnwrap(encoder.currentTokenForTesting)), .h264)
        XCTAssertNil(encoder.codecIfCurrentForTesting(hevcToken),
                     "the HEVC session's output must not be packaged as H.264")
    }

    // MARK: - Submission

    func testSubmitWithoutASessionReportsInvalidSessionAndNeverCallsBack() throws {
        let encoder = MacSenderVideoEncoder()
        let pixelBuffer = try makePixelBuffer()
        var callbacks = 0
        let status = encoder.submit(pixelBuffer, pts: CMTime(value: 0, timescale: 600),
                                    forceKeyframe: false) { _, _, _ in callbacks += 1 }
        XCTAssertEqual(status, kVTInvalidSessionErr)
        XCTAssertEqual(callbacks, 0,
                       "a frame that was never submitted must not produce an output callback")
    }

    func testSubmitAfterInvalidateReportsInvalidSession() throws {
        let encoder = try makeActiveEncoder()
        encoder.invalidate()
        let pixelBuffer = try makePixelBuffer()
        XCTAssertEqual(
            encoder.submit(pixelBuffer, pts: CMTime(value: 0, timescale: 600),
                           forceKeyframe: false) { _, _, _ in },
            kVTInvalidSessionErr)
    }

    /// A frame submitted to, and completed by, the CURRENT session carries a
    /// non-nil codec — i.e. the stale check does not reject live output.
    func testCurrentSessionsOutputCarriesItsCodec() throws {
        let encoder = try makeActiveEncoder()
        let pixelBuffer = try makePixelBuffer()
        let completed = expectation(description: "encode output")
        let received = OutputBox()
        let status = encoder.submit(pixelBuffer, pts: CMTime(value: 0, timescale: 600),
                                    forceKeyframe: true) { status, buffer, codec in
            received.record(status: status, hasBuffer: buffer != nil, codec: codec)
            completed.fulfill()
        }
        XCTAssertEqual(status, noErr)
        wait(for: [completed], timeout: 10)
        XCTAssertEqual(received.status, noErr)
        XCTAssertTrue(received.hasBuffer)
        XCTAssertEqual(received.codec, .h264, "live output must not be treated as stale")
    }

    /// Minimal thread-safe box: the output handler runs on VideoToolbox's own
    /// thread, so the test must not read plain locals across it.
    private final class OutputBox: @unchecked Sendable {
        private let lock = NSLock()
        private var statusValue: OSStatus = -1
        private var hasBufferValue = false
        private var codecValue: StreamCodec?

        func record(status: OSStatus, hasBuffer: Bool, codec: StreamCodec?) {
            lock.lock(); defer { lock.unlock() }
            statusValue = status
            hasBufferValue = hasBuffer
            codecValue = codec
        }

        var status: OSStatus { lock.lock(); defer { lock.unlock() }; return statusValue }
        var hasBuffer: Bool { lock.lock(); defer { lock.unlock() }; return hasBufferValue }
        var codec: StreamCodec? { lock.lock(); defer { lock.unlock() }; return codecValue }
    }
}

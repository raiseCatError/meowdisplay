import XCTest

/// Covers `ReceiverDecodedFrameSink` (`Shared/StreamReceiver.swift`) — the
/// lock-protected sole storage authority behind `StreamReceiver.onDecodedFrame`,
/// letting `makePresenter()`'s `decodedFrameReady` effect read the live
/// callback per frame without capturing `self`. Behavior tests (closure
/// equality is unavailable), asserting on which callback actually runs.
final class ReceiverDecodedFrameSinkTests: XCTestCase {

    func testInitiallyNil() {
        let sink = ReceiverDecodedFrameSink()
        XCTAssertNil(sink.get())
    }

    func testSetThenGetReturnsCurrentCallback() {
        let sink = ReceiverDecodedFrameSink()
        var observed: Double?
        sink.set { _, captureMs in observed = captureMs }
        sink.get()?(makePixelBuffer(), 42)
        XCTAssertEqual(observed, 42)
    }

    func testReplaceCallbackObservesNewOneOnly() {
        let sink = ReceiverDecodedFrameSink()
        var firstCalled = false
        var secondCaptureMs: Double?
        sink.set { _, _ in firstCalled = true }
        sink.set { _, captureMs in secondCaptureMs = captureMs }
        sink.get()?(makePixelBuffer(), 7)
        XCTAssertFalse(firstCalled)
        XCTAssertEqual(secondCaptureMs, 7)
    }

    func testSetNilClearsCallback() {
        let sink = ReceiverDecodedFrameSink()
        sink.set { _, _ in }
        sink.set(nil)
        XCTAssertNil(sink.get())
    }

    private func makePixelBuffer() -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 1, 1, kCVPixelFormatType_32BGRA, nil, &buffer)
        return buffer!
    }
}

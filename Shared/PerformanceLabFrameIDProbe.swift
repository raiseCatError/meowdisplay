// Performance Lab (#123): the receiver-side frame-ID reader.
//
// Reads the lab fixture's frame-ID strip from decoded frames and records
// exact source-unique / duplicate / skipped counts and the interval between
// unique frames into the session's diagnostics recorder.
//
// Where it runs: `ReceiverVideoPresenter.presentDecoded`, the only place a
// decoded pixel buffer already exists (the experimental Metal path). The
// default AVSampleBufferDisplayLayer path decodes inside the system layer,
// so there is nothing to read there without changing rendering, which this
// never does. Only while diagnostics are on.
//
// Cost: while no strip has been found it probes one frame in
// `probeEveryNthFrame` (a grid of rows, read-only lock); once found it reads
// two or three rows per frame; after `missesBeforeUnlock` failed frames in a
// row it goes back to probing. Nothing here touches the pixels or the
// presentation path.

import CoreVideo
import Foundation

final class PerformanceLabFrameIDProbe: @unchecked Sendable {
    static let shared = PerformanceLabFrameIDProbe()

    static let probeEveryNthFrame = 30
    static let missesBeforeUnlock = 30

    private let lock = NSLock()
    private var tracker = PerformanceLabFrameIDTracker()
    private var rowHint: Int?
    private var framesUntilProbe = 0
    private var misses = 0
    private var buffer: [UInt8] = []

    init() {}

    /// Whether a strip is currently being followed (tests and the lab view).
    var isLocked: Bool {
        lock.lock(); defer { lock.unlock() }
        return rowHint != nil
    }

    var tally: PerformanceLabFrameIDTally {
        lock.lock(); defer { lock.unlock() }
        return tracker.tally
    }

    /// Starts counting from scratch (a new receiver session).
    func reset() {
        lock.lock(); defer { lock.unlock() }
        tracker = PerformanceLabFrameIDTracker()
        rowHint = nil
        framesUntilProbe = 0
        misses = 0
    }

    /// A decoded frame. Call only when `recorder.isEnabled`.
    func observe(_ pixelBuffer: CVPixelBuffer, recorder: StreamDiagnosticsRecorder,
                 nowMs: Double = StreamDiagnosticsClock.nowMs()) {
        guard shouldRead() else { return }
        guard let plane = PerformanceLabPixelBufferLuma(pixelBuffer) else { return }
        plane.withLockedRows { source in
            self.read(source, recorder: recorder, nowMs: nowMs)
        }
    }

    /// Pure entry point over any luma source (tests).
    func observe(_ source: PerformanceLabLumaSource, recorder: StreamDiagnosticsRecorder, nowMs: Double) {
        guard shouldRead() else { return }
        read(source, recorder: recorder, nowMs: nowMs)
    }

    /// Locked: every frame. Unlocked: one frame in `probeEveryNthFrame`.
    private func shouldRead() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if rowHint != nil { return true }
        if framesUntilProbe > 0 {
            framesUntilProbe -= 1
            return false
        }
        framesUntilProbe = Self.probeEveryNthFrame - 1
        return true
    }

    private func read(_ source: PerformanceLabLumaSource, recorder: StreamDiagnosticsRecorder, nowMs: Double) {
        lock.lock()
        let hint = rowHint
        var scratch = buffer
        lock.unlock()

        // Locked: only the known row (and its confirmation), so a frame
        // costs a few rows. Unlocked: the full row grid, one frame in N.
        let hit: (reading: PerformanceLabFrameIDReading, row: Int)?
        if let hint {
            hit = PerformanceLabFrameIDLocator.readConfirmed(source, row: hint, buffer: &scratch).map { ($0, hint) }
        } else {
            hit = PerformanceLabFrameIDLocator.locate(in: source, rowHint: nil, buffer: &scratch)
        }

        lock.lock()
        buffer = scratch
        let event: PerformanceLabFrameIDTracker.Event?
        if let hit {
            rowHint = hit.row
            misses = 0
            event = tracker.observe(hit.reading, atMs: nowMs)
        } else if rowHint != nil {
            misses += 1
            if misses >= Self.missesBeforeUnlock {
                rowHint = nil
                misses = 0
                framesUntilProbe = Self.probeEveryNthFrame - 1
            }
            event = tracker.observe(nil, atMs: nowMs)
        } else {
            // Probing and nothing on screen: not a lab frame, nothing to count.
            event = nil
        }
        lock.unlock()

        guard let event else { return }
        switch event {
        case .baseline:
            recorder.increment(.frameIDRead, at: nowMs)
            recorder.increment(.frameIDUnique, at: nowMs)
            recorder.markInterval(.frameIDUniqueInterval, at: nowMs)
        case .unique(let skipped, _):
            recorder.increment(.frameIDRead, at: nowMs)
            recorder.increment(.frameIDUnique, at: nowMs)
            if skipped > 0 { recorder.increment(.frameIDSkipped, by: Int64(skipped), at: nowMs) }
            recorder.markInterval(.frameIDUniqueInterval, at: nowMs)
        case .duplicate:
            recorder.increment(.frameIDRead, at: nowMs)
            recorder.increment(.frameIDDuplicate, at: nowMs)
        case .discontinuity:
            recorder.increment(.frameIDRead, at: nowMs)
            recorder.increment(.frameIDDiscontinuity, at: nowMs)
        case .unreadable:
            recorder.increment(.frameIDUnreadable, at: nowMs)
        }
    }
}

/// Luma rows of a decoded pixel buffer: the Y plane of 4:2:0 bi-planar
/// buffers, or Rec. 601 luma computed from 32BGRA. Read-only lock.
struct PerformanceLabPixelBufferLuma {
    private let pixelBuffer: CVPixelBuffer
    private let biPlanar: Bool

    init?(_ pixelBuffer: CVPixelBuffer) {
        switch CVPixelBufferGetPixelFormatType(pixelBuffer) {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            biPlanar = true
        case kCVPixelFormatType_32BGRA:
            biPlanar = false
        default:
            return nil
        }
        self.pixelBuffer = pixelBuffer
    }

    func withLockedRows(_ body: (PerformanceLabLumaSource) -> Void) {
        guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else { return }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        let base = biPlanar ? CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) : CVPixelBufferGetBaseAddress(pixelBuffer)
        guard let base else { return }
        let rows = Rows(
            base: UnsafeRawPointer(base),
            width: biPlanar ? CVPixelBufferGetWidthOfPlane(pixelBuffer, 0) : CVPixelBufferGetWidth(pixelBuffer),
            height: biPlanar ? CVPixelBufferGetHeightOfPlane(pixelBuffer, 0) : CVPixelBufferGetHeight(pixelBuffer),
            bytesPerRow: biPlanar ? CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0) : CVPixelBufferGetBytesPerRow(pixelBuffer),
            bgra: !biPlanar)
        body(rows)
    }

    private struct Rows: PerformanceLabLumaSource {
        let base: UnsafeRawPointer
        let width: Int
        let height: Int
        let bytesPerRow: Int
        let bgra: Bool

        func readRow(_ y: Int, into buffer: inout [UInt8]) {
            if buffer.count != width { buffer = [UInt8](repeating: 0, count: width) }
            let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            if bgra {
                for x in 0..<width {
                    let b = Int(row[4 * x]), g = Int(row[4 * x + 1]), r = Int(row[4 * x + 2])
                    buffer[x] = UInt8((77 * r + 150 * g + 29 * b) >> 8)
                }
            } else {
                buffer.withUnsafeMutableBufferPointer { dst in
                    if let d = dst.baseAddress { memcpy(d, row, width) }
                }
            }
        }
    }
}

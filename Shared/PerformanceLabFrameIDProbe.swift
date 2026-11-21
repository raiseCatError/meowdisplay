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
//
// Counting: a lost strip re-baselines the tracker, so frames that went by
// unread while it searched again are counted as `frame_id.unexamined`,
// never as skipped IDs.

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
    /// The strip was followed and then lost: frames until it is found
    /// again are counted as unexamined.
    private var searchingAgain = false
    private var buffer: [UInt8] = []
    /// The receiver session (its recorder) and stream generation the last
    /// frame belonged to. A new one re-baselines the counter, so a
    /// reconnect or new session mid-trial is never counted as skipped IDs.
    private var stream: StreamKey?

    struct StreamKey: Equatable, Sendable {
        let recorder: ObjectIdentifier
        let generation: UInt64?
    }

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
        searchingAgain = false
        stream = nil
    }

    /// A decoded frame. Call only when `recorder.isEnabled`. `generation`:
    /// the presentation generation the frame belongs to.
    func observe(_ pixelBuffer: CVPixelBuffer, recorder: StreamDiagnosticsRecorder, generation: UInt64? = nil,
                 nowMs: Double = StreamDiagnosticsClock.nowMs()) {
        noteStream(recorder: recorder, generation: generation)
        guard shouldRead() else { return noteUnexamined(recorder: recorder, nowMs: nowMs) }
        guard let plane = PerformanceLabPixelBufferLuma(pixelBuffer) else { return }
        plane.withLockedRows { source in
            self.read(source, recorder: recorder, nowMs: nowMs)
        }
    }

    /// Pure entry point over any luma source (tests).
    func observe(_ source: PerformanceLabLumaSource, recorder: StreamDiagnosticsRecorder, generation: UInt64? = nil,
                 nowMs: Double) {
        noteStream(recorder: recorder, generation: generation)
        guard shouldRead() else { return noteUnexamined(recorder: recorder, nowMs: nowMs) }
        read(source, recorder: recorder, nowMs: nowMs)
    }

    /// A frame the reader skipped while probing: counted only while it
    /// searches for a strip it had found before (otherwise there is no
    /// fixture to speak of).
    private func noteUnexamined(recorder: StreamDiagnosticsRecorder, nowMs: Double) {
        lock.lock()
        let searching = searchingAgain
        lock.unlock()
        if searching { recorder.increment(.frameIDUnexamined, at: nowMs) }
    }

    /// A different receiver session (recorder) or stream generation than
    /// the last frame: the next read is a new baseline, not a skip. The
    /// tally (tests, lab view) keeps counting.
    private func noteStream(recorder: StreamDiagnosticsRecorder, generation: UInt64?) {
        let key = StreamKey(recorder: ObjectIdentifier(recorder), generation: generation)
        lock.lock(); defer { lock.unlock() }
        guard key != stream else { return }
        if stream != nil { tracker.rebaseline() }
        searchingAgain = false
        stream = key
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
        var unexamined = false
        if let hit {
            rowHint = hit.row
            misses = 0
            searchingAgain = false
            event = tracker.observe(hit.reading, atMs: nowMs)
        } else if rowHint != nil {
            misses += 1
            event = tracker.observe(nil, atMs: nowMs)
            if misses >= Self.missesBeforeUnlock {
                // Lost: the next read is a new baseline, so the frames that
                // go by unread meanwhile are never counted as skipped IDs.
                rowHint = nil
                misses = 0
                framesUntilProbe = Self.probeEveryNthFrame - 1
                tracker.rebaseline()
                searchingAgain = true
            }
        } else {
            // Probing: a lost strip not found again yet is an unexamined
            // frame; never having had one, nothing to count.
            unexamined = searchingAgain
            event = nil
        }
        lock.unlock()

        if unexamined { recorder.increment(.frameIDUnexamined, at: nowMs) }
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

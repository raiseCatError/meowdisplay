// Performance Lab (#123): the machine-readable frame ID the lab fixture draws
// into every frame it changes, and the pure reader for it.
//
// The ID is a one-row barcode of large black/white modules (luma only, so it
// survives chroma subsampling, scaling and moderate compression):
//
//   quiet(2) | guard 1 0 1 | 44 data modules | guard 1 0 1 | quiet(2)
//
// Data = magic (4 bits) | segment (4 bits) | frame counter (20 bits, Gray
// coded) | CRC-16/CCITT-FALSE over the first 28 bits (16 bits). Dark = 1.
// The strip is drawn several modules tall, so a reader confirms a hit on a
// second row one module away.
//
// Pure Foundation: compiled into every app target and into MacTests.

import Foundation

/// One decoded frame ID.
struct PerformanceLabFrameIDReading: Equatable, Sendable {
    /// Source frame counter (modulo `PerformanceLabFrameIDCodec.counterModulus`).
    var counter: UInt32
    /// Index of the workload segment the frame was drawn in (modulo 16).
    var segment: UInt8
}

enum PerformanceLabFrameIDCodec {
    /// Bump when the strip layout or payload changes.
    static let version = 1
    static let counterBits = 20
    static let counterModulus: UInt32 = 1 << 20
    static let magic: UInt32 = 0xA
    static let guardModules: [Bool] = [true, false, true]
    static let dataModules = 44
    /// Guard + data + guard.
    static let codeModules = 50
    /// Light modules on each side of the code.
    static let quietModules = 2
    /// Total strip width in modules, quiet zones included.
    static var stripModules: Int { codeModules + 2 * quietModules }
    /// Strip height in modules (the reader confirms on a row one module away).
    static let stripHeightModules = 4

    // MARK: Encoding

    static func gray(_ n: UInt32) -> UInt32 { n ^ (n >> 1) }

    static func fromGray(_ g: UInt32) -> UInt32 {
        var n = g
        var shift: UInt32 = 1
        while shift < 32 {
            n ^= n >> shift
            shift <<= 1
        }
        return n
    }

    /// CRC-16/CCITT-FALSE (poly 0x1021, init 0xFFFF) over `bytes`.
    static func crc16(_ bytes: [UInt8]) -> UInt16 {
        var crc: UInt16 = 0xFFFF
        for byte in bytes {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 {
                crc = (crc & 0x8000) != 0 ? (crc << 1) ^ 0x1021 : crc << 1
            }
        }
        return crc
    }

    /// The 28 payload bits (magic, segment, Gray counter), MSB first in a UInt32.
    static func payload(counter: UInt32, segment: UInt8) -> UInt32 {
        let c = counter % counterModulus
        return (magic << 24) | (UInt32(segment & 0xF) << 20) | gray(c)
    }

    private static func checksum(of payload: UInt32) -> UInt16 {
        // 28 bits, left-aligned in four bytes.
        let v = payload << 4
        return crc16([UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)])
    }

    /// The 50 code modules (guards included, quiet zones excluded); true = dark.
    static func modules(counter: UInt32, segment: UInt8) -> [Bool] {
        let p = payload(counter: counter, segment: segment)
        let crc = checksum(of: p)
        var bits: [Bool] = []
        bits.reserveCapacity(codeModules)
        bits += guardModules
        for i in stride(from: 27, through: 0, by: -1) { bits.append((p >> UInt32(i)) & 1 == 1) }
        for i in stride(from: 15, through: 0, by: -1) { bits.append((crc >> UInt16(i)) & 1 == 1) }
        bits += guardModules
        return bits
    }

    /// Parses 50 sampled code modules. nil when a guard, the magic or the checksum fails.
    static func parse(modules bits: [Bool]) -> PerformanceLabFrameIDReading? {
        guard bits.count == codeModules,
              Array(bits[0..<3]) == guardModules,
              Array(bits[(codeModules - 3)...]) == guardModules else { return nil }
        var payload: UInt32 = 0
        for b in bits[3..<31] { payload = (payload << 1) | (b ? 1 : 0) }
        var crc: UInt16 = 0
        for b in bits[31..<47] { crc = (crc << 1) | (b ? 1 : 0) }
        guard payload >> 24 == magic, checksum(of: payload) == crc else { return nil }
        let segment = UInt8((payload >> 20) & 0xF)
        let counter = fromGray(payload & (counterModulus - 1))
        return PerformanceLabFrameIDReading(counter: counter, segment: segment)
    }

    // MARK: Reading a row of luma

    /// Minimum luma contrast (max − min) in a row before it is tried.
    static let minimumContrast = 60
    /// Smallest module, in pixels, the reader accepts.
    static let minimumModulePixels = 2.0

    /// Finds and decodes a strip in one row of 8-bit luma. Tolerates scaling
    /// (any module width ≥ 2 px), blur of under half a module, noise and
    /// video-range levels.
    static func decodeRow(_ row: UnsafeBufferPointer<UInt8>) -> PerformanceLabFrameIDReading? {
        let n = row.count
        guard n >= codeModules * 2 else { return nil }
        var lo = 255, hi = 0
        for v in row {
            let i = Int(v)
            if i < lo { lo = i }
            if i > hi { hi = i }
        }
        guard hi - lo >= minimumContrast else { return nil }
        let threshold = (lo + hi) / 2

        // Run-length encode the binarized row.
        var runDark: [Bool] = []
        var runStart: [Int] = []
        var runLength: [Int] = []
        var x = 0
        while x < n {
            let dark = Int(row[x]) < threshold
            let start = x
            while x < n, (Int(row[x]) < threshold) == dark { x += 1 }
            runDark.append(dark)
            runStart.append(start)
            runLength.append(x - start)
        }

        let count = runDark.count
        guard count >= 5 else { return nil }
        for i in 1..<(count - 2) where runDark[i] {
            // Guard 1 0 1: the first dark and light runs are one module each;
            // the third (dark) run may merge with dark data modules after it.
            let a = Double(runLength[i]), b = Double(runLength[i + 1]), c = Double(runLength[i + 2])
            let m = (a + b) / 2
            guard m >= minimumModulePixels,
                  a >= 0.6 * m, a <= 1.4 * m, b >= 0.6 * m, b <= 1.4 * m, c >= 0.5 * m,
                  Double(runLength[i - 1]) >= 0.8 * m else { continue }
            let x0 = Double(runStart[i])
            let expectedEnd = x0 + Double(codeModules) * m
            let tolerance = max(3, 0.08 * Double(codeModules) * m)
            var j = i + 2
            while j < count {
                if runDark[j] {
                    let end = Double(runStart[j] + runLength[j])
                    if end > expectedEnd + tolerance { break }
                    if end >= expectedEnd - tolerance {
                        let module = (end - x0) / Double(codeModules)
                        if let reading = sample(row, x0: x0, module: module, threshold: threshold) {
                            return reading
                        }
                    }
                }
                j += 1
            }
        }
        return nil
    }

    private static func sample(_ row: UnsafeBufferPointer<UInt8>, x0: Double, module: Double,
                               threshold: Int) -> PerformanceLabFrameIDReading? {
        let n = row.count
        var bits = [Bool](repeating: false, count: codeModules)
        let half = max(0, Int(module * 0.25))
        for k in 0..<codeModules {
            let cx = Int(x0 + (Double(k) + 0.5) * module)
            let from = max(0, cx - half), to = min(n - 1, cx + half)
            guard from <= to else { return nil }
            var sum = 0
            for px in from...to { sum += Int(row[px]) }
            bits[k] = sum < threshold * (to - from + 1)
        }
        return parse(modules: bits)
    }

    static func decodeRow(_ row: [UInt8]) -> PerformanceLabFrameIDReading? {
        row.withUnsafeBufferPointer { decodeRow($0) }
    }
}

/// Rows of 8-bit luma from any image (a pixel buffer plane, a test array).
protocol PerformanceLabLumaSource {
    var width: Int { get }
    var height: Int { get }
    /// Fills `buffer` (resized to `width`) with row `y`'s luma.
    func readRow(_ y: Int, into buffer: inout [UInt8])
}

/// A luma image held in memory (tests, synthetic frames).
struct PerformanceLabLumaImage: PerformanceLabLumaSource, Equatable, Sendable {
    let width: Int
    let height: Int
    var pixels: [UInt8]

    init(width: Int, height: Int, fill: UInt8 = 255) {
        self.width = width
        self.height = height
        pixels = [UInt8](repeating: fill, count: width * height)
    }

    func readRow(_ y: Int, into buffer: inout [UInt8]) {
        let start = y * width
        buffer = Array(pixels[start..<(start + width)])
    }

    /// Draws a strip (quiet zones included) into `rect` (pixels).
    mutating func drawStrip(counter: UInt32, segment: UInt8, x: Int, y: Int, width stripWidth: Int, height stripHeight: Int,
                            dark: UInt8 = 0, light: UInt8 = 255) {
        let modules = PerformanceLabFrameIDCodec.modules(counter: counter, segment: segment)
        let total = Double(PerformanceLabFrameIDCodec.stripModules)
        for py in max(0, y)..<min(height, y + stripHeight) {
            for px in max(0, x)..<min(width, x + stripWidth) {
                let u = (Double(px - x) + 0.5) / Double(stripWidth) * total
                let k = Int(u) - PerformanceLabFrameIDCodec.quietModules
                let isDark = k >= 0 && k < modules.count && modules[k]
                pixels[py * width + px] = isDark ? dark : light
            }
        }
    }
}

enum PerformanceLabFrameIDLocator {
    /// Searches the image for a strip: tries `rowHint` first, then a grid of
    /// rows. A hit must be confirmed by the same reading one module above or
    /// below. Returns the reading and the row it was found on.
    static func locate(in image: PerformanceLabLumaSource, rowHint: Int?,
                       buffer: inout [UInt8]) -> (reading: PerformanceLabFrameIDReading, row: Int)? {
        guard image.width > 0, image.height > 0 else { return nil }
        if let rowHint, let hit = readConfirmed(image, row: rowHint, buffer: &buffer) {
            return (hit, rowHint)
        }
        let step = max(2, image.height / 96)
        var y = step / 2
        while y < image.height {
            if let hit = readConfirmed(image, row: y, buffer: &buffer) { return (hit, y) }
            y += step
        }
        return nil
    }

    /// Reads row `row` and confirms on a neighbouring row (one estimated
    /// module away, both directions).
    static func readConfirmed(_ image: PerformanceLabLumaSource, row: Int,
                              buffer: inout [UInt8]) -> PerformanceLabFrameIDReading? {
        guard row >= 0, row < image.height else { return nil }
        image.readRow(row, into: &buffer)
        guard let first = PerformanceLabFrameIDCodec.decodeRow(buffer) else { return nil }
        // A module is at least 1/stripModules of the strip, which is at most
        // the image width; confirm two estimated module heights away, at most.
        let offsets = confirmOffsets(imageWidth: image.width)
        for dy in offsets {
            for candidate in [row + dy, row - dy] where candidate >= 0 && candidate < image.height {
                image.readRow(candidate, into: &buffer)
                if PerformanceLabFrameIDCodec.decodeRow(buffer) == first { return first }
            }
        }
        return nil
    }

    /// Small vertical offsets to confirm on: 1, 2 and 4 px, enough for any
    /// strip at least 4 px per module tall without leaving it.
    static func confirmOffsets(imageWidth: Int) -> [Int] { [1, 2, 4] }
}

/// Unique / duplicate / skipped accounting over successive read IDs.
struct PerformanceLabFrameIDTally: Codable, Equatable, Sendable {
    var read = 0
    var unique = 0
    var duplicate = 0
    var skipped = 0
    var unreadable = 0
    var discontinuities = 0
}

struct PerformanceLabFrameIDTracker: Sendable {
    enum Event: Equatable, Sendable {
        /// A new source frame; `skipped` IDs never seen in between.
        case unique(skipped: Int, intervalMs: Double?)
        case duplicate
        case unreadable
        /// Went backwards or jumped by half the counter range or more: re-baselined.
        case discontinuity
        /// The first ID seen: the baseline.
        case baseline
    }

    private(set) var tally = PerformanceLabFrameIDTally()
    private var lastCounter: UInt32?
    private var lastUniqueMs: Double?

    /// A new stream (session or generation): forget the last ID so the next
    /// read is a baseline, never a skip or discontinuity. The tally stays.
    mutating func rebaseline() {
        lastCounter = nil
        lastUniqueMs = nil
    }

    mutating func observe(_ reading: PerformanceLabFrameIDReading?, atMs nowMs: Double) -> Event {
        guard let reading else {
            tally.unreadable += 1
            return .unreadable
        }
        tally.read += 1
        guard let last = lastCounter else {
            lastCounter = reading.counter
            lastUniqueMs = nowMs
            tally.unique += 1
            return .baseline
        }
        let modulus = PerformanceLabFrameIDCodec.counterModulus
        let delta = (reading.counter &+ modulus &- last) % modulus
        if delta == 0 {
            tally.duplicate += 1
            return .duplicate
        }
        if delta >= modulus / 2 {
            tally.discontinuities += 1
            lastCounter = reading.counter
            lastUniqueMs = nowMs
            return .discontinuity
        }
        let skipped = Int(delta) - 1
        tally.unique += 1
        tally.skipped += skipped
        let interval = lastUniqueMs.map { nowMs - $0 }
        lastCounter = reading.counter
        lastUniqueMs = nowMs
        return .unique(skipped: skipped, intervalMs: interval)
    }
}

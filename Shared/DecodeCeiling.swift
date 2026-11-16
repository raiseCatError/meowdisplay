// Compiled into BOTH the Mac and iOS targets (see project.yml `sources`).
// Pure, platform-neutral math for PROTOCOL.md 6.5 — kept separate from
// `MacSender` so it's directly unit-testable without ScreenCaptureKit.

import Foundation

/// Clamps an encoded-stream size to a receiver's advertised decode ceiling
/// (`hello.maxEncodeWide/High`), preserving aspect ratio and never
/// upscaling. The desktop/virtual-display size is a separate concern —
/// callers pass only the capture/encode dimensions they were about to use.
enum DecodeCeiling {
    /// Returns `(width, height)` unchanged when there is no ceiling, the
    /// ceiling is degenerate (<= 0), or the size already fits inside it.
    /// Otherwise scales both axes down by the same factor so the result
    /// fits within `maxWide x maxHigh` while keeping `width/height`'s ratio,
    /// rounded to even (the encoder wants even dimensions).
    static func clamp(width: Int, height: Int, maxWide: Int?, maxHigh: Int?) -> (width: Int, height: Int) {
        guard let maxWide, let maxHigh, maxWide > 0, maxHigh > 0,
              width > 0, height > 0,
              width > maxWide || height > maxHigh else {
            return (width, height)
        }
        let scale = min(Double(maxWide) / Double(width), Double(maxHigh) / Double(height))
        let clampedWidth = max(even(Double(width) * scale, atMost: maxWide), 2)
        let clampedHeight = max(even(Double(height) * scale, atMost: maxHigh), 2)
        return (clampedWidth, clampedHeight)
    }

    /// `Int(value) & ~1` for a non-negative `value` that is at most about
    /// `limit`. The product can round up to the Double nearest an
    /// `Int`-sized limit (a receiver's `maxEncodeWide` near `Int.max` is
    /// 2^63 as a Double, which `Int(_:)` traps on), so anything at or above
    /// the limit is the limit itself. Unchanged for every real size: such a
    /// value is below `limit + 1`, and `Int` truncates it to `limit` anyway.
    private static func even(_ value: Double, atMost limit: Int) -> Int {
        guard value < Double(limit) else { return limit & ~1 }
        return Int(value) & ~1
    }
}

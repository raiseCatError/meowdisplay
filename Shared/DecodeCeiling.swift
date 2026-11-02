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
        let clampedWidth = max((Int(Double(width) * scale)) & ~1, 2)
        let clampedHeight = max((Int(Double(height) * scale)) & ~1, 2)
        return (clampedWidth, clampedHeight)
    }
}

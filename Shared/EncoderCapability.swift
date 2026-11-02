// Compiled into BOTH the Mac and iOS targets (see project.yml `sources`).
// Pure, platform-neutral math — kept separate from `MacSender` so it's
// directly unit-testable without VideoToolbox.

import Foundation

/// The maximum FPS MEOW will ever knowingly request from ScreenCaptureKit /
/// VideoToolbox at a given encode size, independent of aspect ratio.
///
/// Root cause (see the Extend black-screen regression this exists to
/// prevent): VideoToolbox's H.264 hardware encoder has a macroblock-rate
/// ceiling. `kVTProfileLevel_H264_High_AutoLevel` (see `MacSender.setupEncoder`)
/// lets VideoToolbox pick whatever level covers the frame size, but a level
/// only bounds the *bitstream*, not real hardware throughput — a big-enough
/// size x fps product still makes VTCompressionSessionEncodeFrame emit
/// nil/failed output instead of erroring cleanly. 2796x1572 @ 120 measured
/// on real hardware sits right at the H.264 Level 5.2 MaxMBPS boundary
/// (2,073,600 macroblocks/sec) while 2796x1196 @ 120, comfortably under it,
/// encodes real frames — so that boundary is what this models.
enum EncoderCapability {
    /// H.264 Level 5.2's MaxMBPS (ITU-T Table A-1) — the highest level
    /// `AutoLevel` will select for output this large, and the tightest
    /// throughput bound in the table below that ceiling. Using a fixed,
    /// well-known spec constant (rather than a guessed/measured number) is
    /// deliberate: it is conservative by construction, not tuned to one
    /// machine's benchmark.
    static let maxMacroblocksPerSecond = 2_073_600

    /// User-facing FPS tiers MEOW ever requests or presents in a picker
    /// (PART 1 & 2). Ordered ascending.
    static let supportedFPSTiers = [1, 5, 10, 24, 30, 60, 120]

    /// Number of 16x16 macroblocks in a frame of this size, per the H.264
    /// spec (`ceil(width/16) * ceil(height/16)`).
    static func macroblockCount(width: Int, height: Int) -> Int {
        guard width > 0, height > 0 else { return 0 }
        let mbWide = (width + 15) / 16
        let mbHigh = (height + 15) / 16
        return mbWide * mbHigh
    }

    /// The INTERNAL codec-safe ceiling for `width x height`: an arbitrary
    /// positive integer FPS, NOT quantized to `supportedFPSTiers`. This is
    /// what the sender actually streams at — quantizing it down to the next
    /// picker tier (e.g. flooring 118 to 60) would throw away real,
    /// hardware-safe headroom for no reason. Depends only on the actual
    /// final encode dimensions — never on aspect ratio alone.
    ///
    /// One frame of headroom below the exact theoretical
    /// `maxMacroblocksPerSecond / macroblocks` bound: operating exactly at
    /// that boundary reintroduces the same throughput risk this exists to
    /// avoid (measured real hardware fails right at/just above it — see the
    /// type doc above).
    ///
    /// Invalid/degenerate dimensions (<= 0) fail safe to `1` rather than
    /// returning "no limit" — an unknown size must never be treated as an
    /// unlimited one.
    static func codecSafeFPS(width: Int, height: Int) -> Int {
        let mbCount = macroblockCount(width: width, height: height)
        guard mbCount > 0 else { return 1 }
        let nominal = maxMacroblocksPerSecond / mbCount   // floor, exact boundary
        guard nominal > 1 else { return 1 }
        return nominal - 1
    }

    /// The highest `supportedFPSTiers` entry that fits under
    /// `codecSafeFPS(width:height:)` — for the USER-FACING enforcement
    /// picker only (PART 2). Never the actual streamed rate: an
    /// unenforced/automatic stream runs at the real `codecSafeFPS`, not
    /// this quantized value (e.g. a 118-safe size still streams at 118 —
    /// this only hides 120 from the picker and leaves 60 as the highest
    /// explicit tier).
    static func safeMaxFPSTier(width: Int, height: Int) -> Int {
        let ceiling = codecSafeFPS(width: width, height: height)
        return supportedFPSTiers.last { $0 <= ceiling } ?? supportedFPSTiers.first ?? 1
    }
}

// The display a receiver describes in its `hello` (PROTOCOL.md 6.1). An
// authenticated, paired receiver is still not trusted to send sane numbers: a
// buggy or hostile one must never be able to trap the Mac and end every other
// receiver's session with it. The hello's geometry is checked once, in the
// hello handler, before anything sizes a virtual display, a capture or a
// Window canvas from it; the sizing math below is also total on its own, so a
// value that reaches it some other way still cannot trap.
//
// Compiled into the Mac app and MacTests (see project.yml `sources`).

import Foundation

enum PeerDisplayBounds {
    /// The hello field that was out of range. Its raw value is a constant of
    /// this file, never peer text, so it may be logged.
    enum Field: String, Equatable, Sendable {
        case pixelsWide, pixelsHigh, scale
    }

    /// Pixels per side of the receiver's panel, current orientation. 0 is a
    /// receiver that has not measured its panel yet (the receivers' own
    /// default; a Mac receiver with no screen); today's fallback sizes apply
    /// then. The largest panel a receiver announces today is a 1x 8K display
    /// on the Mac receiver, announced at 2x (15 360 px); 32 768 leaves twice
    /// that. Every size derived from it (at most 32 768 x 32 768 at quality
    /// 1.0) is far inside `Int`, and its macroblock count is about 4.2 million.
    static let pixelsPerSide: ClosedRange<Int> = 0...32_768

    /// The receiver's UI scale: 1 to 3 on Apple hardware (the Mac receiver
    /// announces at least 2), Android's density 0.75 to about 4. Not used for
    /// any size on this build; checked so no later use can see a nonsense one.
    static let scale: ClosedRange<Double> = 0.25...16

    /// The first field of a hello's geometry that no real device sends, or
    /// nil when the geometry is usable. A hello that fails this is refused
    /// (`MacSender.reportMalformedHello`).
    static func violation(pixelsWide: Int, pixelsHigh: Int, scale: Double) -> Field? {
        if !pixelsPerSide.contains(pixelsWide) { return .pixelsWide }
        if !pixelsPerSide.contains(pixelsHigh) { return .pixelsHigh }
        if !scale.isFinite || !Self.scale.contains(scale) { return .scale }
        return nil
    }

    // MARK: - Sizing (total functions)

    /// Beyond this magnitude a size is clamped before it is converted to
    /// `Int`, so the conversion can never trap. Far above any real size.
    static let largestConvertedPixels = Double(1 << 30)

    /// `Int(value) & ~1` (toward zero, then even, as the encoder wants) for
    /// any Double: NaN reads as 0 and a magnitude beyond
    /// `largestConvertedPixels` is clamped first. The same as the plain
    /// conversion for every real size.
    static func evenPixels(_ value: Double) -> Int {
        guard !value.isNaN else { return 0 }
        let bounded = min(max(value, -largestConvertedPixels), largestConvertedPixels)
        return Int(bounded) & ~1
    }

    /// Extend: the capture for a virtual display of `pointsWide` x
    /// `pointsHigh` points (@2x HiDPI) at `scale` (the quality's), then
    /// inside the receiver's decode ceiling (`DecodeCeiling.clamp`).
    /// `native` is the size before the ceiling, `capture` after it.
    static func extendCapture(pointsWide: Int, pointsHigh: Int, scale: Double,
                              maxWide: Int?, maxHigh: Int?)
        -> (native: (width: Int, height: Int), capture: (width: Int, height: Int)) {
        // `Double(points) * 2` equals `Double(points * 2)` exactly for every
        // real size, and cannot overflow `Int` the way `points * 2` can.
        let nativeW = evenPixels(Double(pointsWide) * 2 * scale)
        let nativeH = evenPixels(Double(pointsHigh) * 2 * scale)
        let capture = DecodeCeiling.clamp(width: nativeW, height: nativeH, maxWide: maxWide, maxHigh: maxHigh)
        return ((nativeW, nativeH), capture)
    }

    /// Window mode: the canvas is the receiver's panel at `scale` (the
    /// quality's), inside its decode ceiling, even, at least 64 x 64.
    static func windowCanvas(pixelsWide: Int, pixelsHigh: Int, scale: Double,
                             maxWide: Int?, maxHigh: Int?) -> (width: Int, height: Int) {
        let wide = evenPixels(Double(pixelsWide) * scale)
        let high = evenPixels(Double(pixelsHigh) * scale)
        let (w, h) = DecodeCeiling.clamp(width: wide, height: high, maxWide: maxWide, maxHigh: maxHigh)
        return (max(w & ~1, 64), max(h & ~1, 64))
    }
}

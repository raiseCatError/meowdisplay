import Foundation
import CoreGraphics

/// The physical size (in millimetres) an Extend virtual display declares to
/// macOS. It is metadata: the display's modes and its HiDPI selection are set
/// elsewhere (`VirtualDisplay`). macOS may use it for the default scale and the
/// scale options it offers, and field reports (not documented macOS behaviour)
/// tie very small declared sizes to displays that never come online, so it
/// should describe a plausible monitor for the mode's point size. This is the
/// single source of that policy; `MacSender` calls it once per virtual-display
/// creation.
///
/// The input is the virtual display's own mode in points at creation (after
/// `ExtendDisplaySizing` has fitted the shape) — never the receiver's
/// physical aspect, which no longer decides the display's shape.
enum ExtendPhysicalSize {
    /// Declared density: points per millimetre. Apple's Retina displays
    /// default to roughly 4.3–5.0 pt/mm; 4.5 sits in that band and, at the
    /// 2x HiDPI mode the virtual display runs in, is about 229 ppi. Using
    /// one density on both axes keeps the millimetre aspect equal to the
    /// point aspect, so orientation simply follows the points.
    static let pointsPerMillimetre: CGFloat = 4.5

    /// Sanity cap on the long edge. The largest common monitors are about
    /// 1200 mm wide; beyond that the declared size stops meaning anything.
    /// The minimums below are applied after this cap and always win over it.
    static let upperLongEdge: CGFloat = 1200

    /// Minimum declared width, on the HORIZONTAL edge (not the long edge).
    ///
    /// Like `minimumArea`, this comes from field observations, not from
    /// documented macOS behaviour: displays that never came online, or were
    /// unreliable, when declared below roughly 160 cm² or about 170 mm wide,
    /// with margin added. The declared size is fixed when the display is
    /// created: an in-place rotation (`VirtualDisplay.resize` applies a new
    /// mode only) keeps this width, so a horizontal minimum still holds
    /// after rotating, which a long-edge minimum would not guarantee.
    static let minimumWidth: CGFloat = 180

    /// Minimum declared area in mm² (200 cm²). See `minimumWidth` for where
    /// this number comes from.
    static let minimumArea: CGFloat = 20_000

    /// Point size used when the input is not positive; the same 16:10
    /// fallback `ExtendDisplaySizing.pointSize` returns.
    static let fallbackPoints = (wide: 960, high: 600)

    /// Absorbs floating-point noise before rounding up, so a size that is
    /// mathematically a whole number of millimetres (1170 pt at 4.5 pt/mm is
    /// exactly 260 mm) is not bumped by one millimetre by a last-bit error.
    /// The minimums are re-checked on the integers afterwards.
    private static let roundingTolerance = 1e-9

    /// Declared size for a virtual display whose mode is
    /// `pointsWide`×`pointsHigh` points. Whole millimetres, finite and
    /// positive for any input, including non-positive and extreme values.
    static func millimetres(pointsWide: Int, pointsHigh: Int) -> CGSize {
        // 1. Input: the display's own mode, or the fallback.
        let points = pointsWide > 0 && pointsHigh > 0
            ? (wide: pointsWide, high: pointsHigh)
            : fallbackPoints

        // 2. Isotropic size. Double arithmetic: even Int.max points stay
        //    finite, with no integer overflow.
        let density = Double(pointsPerMillimetre)
        var width = Double(points.wide) / density
        var height = Double(points.high) / density

        // 3. Sanity cap, scaling both axes uniformly. `min` pins the long
        //    edge to exactly the cap despite rounding in the product.
        let cap = Double(upperLongEdge)
        let longEdge = max(width, height)
        if longEdge > cap {
            let scale = cap / longEdge
            width = min(width * scale, cap)
            height = min(height * scale, cap)
        }

        // 4. Minimums, applied last so they win over the cap: scale up
        //    uniformly by the largest factor any of them needs.
        let widthFactor = Double(minimumWidth) / width
        let areaFactor = (Double(minimumArea) / (width * height)).squareRoot()
        let factor = max(1, widthFactor, areaFactor)
        width *= factor
        height *= factor

        // 5. Whole millimetres, rounded up. Re-assert the minimums on the
        //    integers, since the rounding tolerance may sit a hair under them.
        let wholeWidth = max((width - roundingTolerance).rounded(.up), Double(minimumWidth))
        var wholeHeight = max((height - roundingTolerance).rounded(.up), 1)
        if wholeWidth * wholeHeight < Double(minimumArea) {
            wholeHeight = (Double(minimumArea) / wholeWidth).rounded(.up)
        }
        return CGSize(width: wholeWidth, height: wholeHeight)
    }
}

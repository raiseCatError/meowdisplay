// Numbers that came from a peer (#123). An authenticated peer is still not
// trusted to send sane numbers: a buggy or hostile receiver must never be
// able to trap the Mac. Every Double → Int conversion of a peer value checks
// the Double first (finite, inside an explicit range) and treats anything
// else as absent, and every value that goes out on the wire is clamped
// before it is scaled, so JSONSerialization never sees an infinity.
//
// Compiled into every app target and MacTests (see project.yml `sources`).

import Foundation

enum PeerNumber {
    /// Magnitudes at or above this are never converted to `Int`, whatever
    /// the caller's range says (`Double(Int.max)` itself rounds up past
    /// `Int.max`, so `Int(Double(Int.max))` would trap).
    static let largestConvertibleMagnitude = 9.0e18

    /// A finite JSON number that is not a JSON bool. Strings, bools, arrays,
    /// objects, NaN and infinities read as absent.
    static func double(_ value: Any?) -> Double? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        let d = n.doubleValue
        return d.isFinite ? d : nil
    }

    /// `double(_:)` inside `range`; out of range reads as absent.
    static func double(_ value: Any?, in range: ClosedRange<Double>) -> Double? {
        double(value).flatMap { range.contains($0) ? $0 : nil }
    }

    /// A bounded `Int` from a peer Double. The Double is checked before any
    /// conversion: it must be finite and inside `range`, and whole when
    /// `integral` (otherwise it is truncated toward zero, like `Int(_:)`).
    /// Anything else is nil (absent), never a trap.
    static func int(_ value: Double, in range: ClosedRange<Int>, integral: Bool = true) -> Int? {
        guard value.isFinite, abs(value) < largestConvertibleMagnitude,
              value >= Double(range.lowerBound), value <= Double(range.upperBound) else { return nil }
        if integral, value != value.rounded() { return nil }
        let result = Int(value)
        return range.contains(result) ? result : nil
    }

    /// `int(_:in:integral:)` straight from a JSON value.
    static func int(_ value: Any?, in range: ClosedRange<Int>, integral: Bool = true) -> Int? {
        double(value).flatMap { int($0, in: range, integral: integral) }
    }

    /// An outgoing value rounded to 0.1, clamped to ±`limit` BEFORE it is
    /// scaled (so `value * 10` can never overflow to infinity). nil for NaN
    /// and infinities: the key is left out.
    static func roundedTenths(_ value: Double, limit: Double) -> Double? {
        guard value.isFinite, limit.isFinite, limit >= 0 else { return nil }
        let cap = Swift.min(limit, 1e15)
        let bounded = Swift.min(Swift.max(value, -cap), cap)
        return (bounded * 10).rounded() / 10
    }
}

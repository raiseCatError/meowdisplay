import Foundation

/// A cursor position exactly as the `cursor` message carries it (PROTOCOL.md 6.2): normalized,
/// to four decimals. Two positions that print the same are the same on the wire.
///
/// The sender reports a move whenever this value changes. A coarser movement threshold would
/// hold slow, precise moves back until they added up, so the receiver's pointer would step
/// instead of glide, lag behind the Mac cursor, and could rest short of where the Mac cursor
/// actually stopped.
struct CursorWirePosition: Equatable {
    static let scale = 10_000.0

    let x: Double
    let y: Double

    init(x: Double, y: Double) {
        self.x = (x * Self.scale).rounded() / Self.scale
        self.y = (y * Self.scale).rounded() / Self.scale
    }

    /// The `x` and `y` fields of the `cursor` message.
    var fields: String { String(format: "\"x\":%.4f,\"y\":%.4f", x, y) }
}

/// Mirror/Extend: hidden `cursor` reports while the Mac cursor is on another display carry
/// where it is, normalized to the receiver's display (so outside 0...1), with
/// `"why":"display"`. A receiver can point at it (off-screen locator); older receivers ignore
/// both because they never draw a hidden report's position (PROTOCOL.md 6.2). They are capped
/// at `minimumInterval` apart so a cursor moving on another display doesn't send at the 120 Hz
/// poll rate, and are sent only when the position the wire can carry changed. The first report
/// after the cursor leaves is always sent: it is what hides the receiver's cursor.
struct OffDisplayCursorReports {
    static let minimumInterval: Double = 1.0 / 30

    private var last: (wire: CursorWirePosition, at: Double)?

    /// Whether to send `wire` at time `now` (seconds). `leaving`: the cursor was shown before.
    mutating func shouldSend(_ wire: CursorWirePosition, at now: Double, leaving: Bool) -> Bool {
        if !leaving, let last {
            guard wire != last.wire, now - last.at >= Self.minimumInterval else { return false }
        }
        last = (wire, now)
        return true
    }

    /// The cursor is on the receiver's display again (or reporting was reset).
    mutating func reset() { last = nil }

    /// The fields after `"v":0` in such a report.
    static func fields(_ wire: CursorWirePosition) -> String { wire.fields + ",\"why\":\"display\"" }
}

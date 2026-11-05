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

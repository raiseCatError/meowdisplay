// Compiled into BOTH the Mac and iOS targets (and the hostless Mac test
// target). Foundation + CoreGraphics only, so it stays platform-neutral.

import CoreGraphics
import Foundation

/// The two optional messages behind caret-following Zoom While Typing
/// (PROTOCOL.md 6.11), kept together so the sender's encode and the
/// receiver's decode cannot drift apart.
///
/// - `keyboardState` (receiver -> Mac): `{"type":"keyboardState","open":true}`.
///   The receiver's on-screen keyboard opened or closed. The Mac reads the
///   focused text caret only while it is open and this device has control.
/// - `textCaret` (Mac -> receiver): `{"type":"textCaret","v":1,"x":..,"y":..,
///   "w":..,"h":..,"s":..}` — the caret's rectangle, normalized to the
///   streamed display (or, in Window mode, the workspace canvas) with a
///   top-left origin, the same space as `touch.x/y`. `"v":0` means no caret
///   is known (permission missing, no focused text field, the caret is on
///   another display or window). `s` is a sequence number for dropping
///   reordered frames, like `cursor`.
///
/// Both are additive. A Mac advertises `textCaret` in its welcome `features`;
/// a receiver sends `keyboardState` only to a Mac that did, and a peer that
/// does not know either type ignores it (PROTOCOL.md 6). Only a rectangle
/// ever crosses the wire — never the text, its length or its position in it.
enum TextCaretWire {
    /// `welcome.features` entry: this Mac can follow the focused text caret.
    static let welcomeFeature = "textCaret"

    /// Decimal places kept (a caret is a few thousandths of the display wide).
    private static let precision = 1e5

    struct Update: Equatable {
        /// Normalized caret rect; `nil` is "no caret".
        let rect: CGRect?
        let sequence: UInt64?
    }

    static func keyboardStateMessage(open: Bool) -> [String: Any] {
        ["type": WireMessage.keyboardState, "open": open]
    }

    /// `nil` unless `open` is a real boolean.
    static func parseKeyboardState(_ message: [String: Any]) -> Bool? {
        guard message["type"] as? String == WireMessage.keyboardState else { return nil }
        return message["open"] as? Bool
    }

    static func message(rect: CGRect?, sequence: UInt64) -> [String: Any] {
        var message: [String: Any] = ["type": WireMessage.textCaret, "s": sequence]
        guard let rect, rect.origin.x.isFinite, rect.origin.y.isFinite, rect.width.isFinite, rect.height.isFinite else {
            message["v"] = 0
            return message
        }
        message["v"] = 1
        message["x"] = rounded(rect.minX)
        message["y"] = rounded(rect.minY)
        message["w"] = rounded(max(rect.width, 0))
        message["h"] = rounded(max(rect.height, 0))
        return message
    }

    /// `nil` for a malformed message (the receiver ignores it). A visible
    /// caret needs a finite `x` and `y`; `w`/`h` default to zero.
    static func parse(_ message: [String: Any]) -> Update? {
        guard message["type"] as? String == WireMessage.textCaret else { return nil }
        let sequence = (message["s"] as? NSNumber).flatMap { $0.int64Value >= 0 ? UInt64($0.int64Value) : nil }
        guard (message["v"] as? NSNumber)?.intValue == 1 else {
            return Update(rect: nil, sequence: sequence)
        }
        guard let x = number(message["x"]), let y = number(message["y"]) else { return nil }
        let w = min(max(number(message["w"]) ?? 0, 0), 1)
        let h = min(max(number(message["h"]) ?? 0, 0), 1)
        return Update(rect: CGRect(x: x, y: y, width: w, height: h), sequence: sequence)
    }

    private static func number(_ value: Any?) -> Double? {
        // A JSON boolean is an NSNumber too; `true` must not read as 1.
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let d = number.doubleValue
        return d.isFinite ? d : nil
    }

    private static func rounded(_ value: CGFloat) -> Double {
        (Double(value) * precision).rounded() / precision
    }
}

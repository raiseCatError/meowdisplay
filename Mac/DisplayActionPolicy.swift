import CoreGraphics
import Foundation

/// Decisions for the overview's display actions (PROTOCOL.md `displayIdentify`,
/// `cursorToDisplay`). Pure, for tests; the AppKit side is `DisplayIdentifyOverlay` and the
/// cursor move itself happens in `WindowBrowserService`.
enum DisplayActionPolicy {
    /// One Identify at a time: a receiver tapping repeatedly must not stack labels on the Mac.
    static let identifyInterval: Double = 2
    /// How long the labels stay on the Mac's screens.
    static let identifyDuration: Double = 3
    /// Move Cursor Here is a deliberate action, not a stream: at most a few per second.
    static let moveInterval: Double = 0.25

    enum MoveDecision: Equatable {
        case move(UInt32, CGPoint)
        case refuse(String)
    }

    /// Where Move Cursor Here puts the Mac cursor: the centre of a display this session was
    /// listed, only with control. Any other display id (one the receiver made up, or one that
    /// went away since the listing) is refused, never guessed.
    static func moveCursor(_ obj: [String: Any], inputGranted: Bool, listed: [UInt32: CGRect]) -> MoveDecision {
        guard inputGranted else { return .refuse("control") }
        guard let id = (obj["id"] as? Int).flatMap({ UInt32(exactly: $0) }), let frame = listed[id],
              frame.width > 0, frame.height > 0,
              [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite) else { return .refuse("display") }
        return .move(id, CGPoint(x: (frame.midX).rounded(.down), y: (frame.midY).rounded(.down)))
    }

    /// The text Identify shows on one display: its position in the receiver's list (the
    /// catalog order, main first) and its name, so the picture on the receiver and the screen
    /// on the desk can be matched.
    static func identifyLabel(index: Int, name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "\(index + 1)" : "\(index + 1)  \(trimmed.prefix(60))"
    }
}

/// Admits an action at most once per `interval` seconds.
struct DisplayActionRateLimit {
    private var last: Double?

    mutating func admit(now: Double, interval: Double) -> Bool {
        if let last, now - last < interval, now >= last { return false }
        last = now
        return true
    }
}

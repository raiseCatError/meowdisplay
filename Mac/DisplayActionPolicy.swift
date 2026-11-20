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

/// The Mac cursor as the overview shows it: global points rounded to 0.1 and the listed
/// display it is on.
struct OverviewCursorSample: Equatable {
    var x: Double
    var y: Double
    var display: UInt32?

    /// nil for a non-finite point. `listed` is the displays this session was shown; a cursor on
    /// any other display (or none) carries no display id.
    static func make(point: CGPoint, listed: [(id: UInt32, frame: CGRect)]) -> OverviewCursorSample? {
        guard point.x.isFinite, point.y.isFinite else { return nil }
        let id = listed.first { $0.frame.contains(point) }?.id
        return OverviewCursorSample(x: rounded(Double(point.x)), y: rounded(Double(point.y)), display: id)
    }

    static func rounded(_ value: Double) -> Double { (value * 10).rounded() / 10 }

    var wire: [String: Any] {
        var out: [String: Any] = ["type": DisplayActionsWire.overviewCursor, "x": x, "y": y]
        if let display { out["d"] = Int(display) }
        return out
    }
}

/// When the Mac sends `overviewCursor` (PROTOCOL.md 6.10): only while a watch is on and not
/// expired, only when the rounded position or display changed, at most once per `minInterval`.
struct OverviewCursorThrottle {
    static let minInterval: Double = 0.1

    let watchSeconds: Double
    private var watchExpiresAt: Double?
    private var lastSentAt: Double?
    private var lastSent: OverviewCursorSample?

    init(watchSeconds: Double = DisplayActionsWire.overviewCursorWatchSeconds) {
        self.watchSeconds = watchSeconds
    }

    /// A watch (or its renewal) turns it on for `watchSeconds`; off forgets everything, so a
    /// later watch sends the position at once.
    mutating func watch(on: Bool, now: Double) {
        if on {
            watchExpiresAt = now + watchSeconds
        } else {
            reset()
        }
    }

    mutating func reset() {
        watchExpiresAt = nil
        lastSentAt = nil
        lastSent = nil
    }

    func isWatching(now: Double) -> Bool {
        guard let watchExpiresAt else { return false }
        return now < watchExpiresAt
    }

    /// The sample to send now, nil when nothing should go out.
    mutating func admit(_ sample: OverviewCursorSample?, now: Double) -> OverviewCursorSample? {
        guard isWatching(now: now) else {
            reset()
            return nil
        }
        guard let sample, sample != lastSent else { return nil }
        if let lastSentAt, now >= lastSentAt, now - lastSentAt < Self.minInterval { return nil }
        lastSentAt = now
        lastSent = sample
        return sample
    }
}

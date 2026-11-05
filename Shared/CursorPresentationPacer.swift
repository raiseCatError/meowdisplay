import CoreGraphics
import Foundation

/// Draws the Mac-confirmed cursor (PROTOCOL.md 6.2 `cursor`) on the receiver's display refresh.
///
/// Reports arrive whenever the network and the main thread deliver them, not on the display's
/// beat: two can land inside one refresh and none inside the next. Drawing each on arrival then
/// shows the pointer holding for a frame and jumping the next, which reads as stutter even when
/// every report is on time. The pacer keeps the last few confirmed positions with the time they
/// arrived and, at each refresh, shows that confirmed path a short delay behind: about one report
/// interval (the Mac polls every 8 ms and sends only on change). Each refresh then advances by an
/// even amount.
///
/// The Mac stays authoritative:
/// - the point shown is always on the straight segment between two consecutive positions the Mac
///   reported, or exactly the newest one. Nothing is predicted past the newest position.
/// - when reports stop (the Mac cursor is stuck, clamped at a display edge, input is refused, or
///   the connection stalls), the pointer reaches the newest confirmed position within the delay
///   and stays there.
/// - hiding applies at once, and showing, teleports and pane changes jump straight to the
///   reported position instead of sweeping across the screen.
///
/// Times are seconds on one monotonic clock (`CACurrentMediaTime()`). No UI or clock
/// dependency, so the whole policy is unit tested.
struct CursorPresentationPacer {
    struct Report: Equatable {
        var time: Double
        var point: CGPoint
    }

    /// The delay tracks the measured report interval within these bounds: about 8 ms for
    /// fast input, up to one 60 Hz frame for 60 Hz touch input. Longer would add latency
    /// without making motion smoother; shorter leaves refreshes with nothing new to show.
    static let minimumDelay = 0.004
    static let maximumDelay = 1.0 / 60
    /// A pause longer than this means the pointer was at rest: the next move starts from the
    /// resting point straight away instead of being spread across the whole pause.
    static let restGap = 0.1
    /// A step this large (normalized) between consecutive reports is a jump, such as a touch
    /// landing elsewhere. It is shown directly, never swept across the screen.
    static let jumpDistance: CGFloat = 0.15
    private static let historyLimit = 8
    private static let smoothing = 0.25

    private(set) var isVisible = false
    /// Estimated time between reports while the pointer moves.
    private(set) var interval = 0.008
    private var history: [Report] = []
    private var playhead = -Double.infinity
    private var jumpsAtNextReport = false

    /// How far behind the newest report the pointer is drawn.
    var delay: Double { min(max(interval, Self.minimumDelay), Self.maximumDelay) }

    /// The newest confirmed position, or nil while hidden.
    var newest: CGPoint? { isVisible ? history.last?.point : nil }

    /// True once the newest confirmed position is the one shown. Nothing changes until the
    /// next report, so the display link can stop.
    var isSettled: Bool {
        guard isVisible, let last = history.last, history.count > 1 else { return true }
        return playhead >= last.time
    }

    /// Takes one confirmed report. A hidden report hides the pointer at once.
    mutating func receive(_ point: CGPoint, visible: Bool, at time: Double) {
        guard visible else {
            isVisible = false
            history.removeAll()
            playhead = -.infinity
            return
        }
        guard isVisible, !jumpsAtNextReport, let last = history.last,
              hypot(point.x - last.point.x, point.y - last.point.y) <= Self.jumpDistance else {
            jump(to: point, at: time)
            return
        }
        let gap = time - last.time
        if gap > Self.restGap {
            // Already drawn at the resting point; start the move from it one delay ago so
            // the first refresh after this report already begins to move.
            history = [Report(time: time - delay, point: last.point)]
            playhead = -.infinity
        } else {
            interval += (min(max(gap, Self.minimumDelay), Self.maximumDelay) - interval) * Self.smoothing
        }
        history.append(Report(time: max(time, last.time), point: point))
        if history.count > Self.historyLimit { history.removeFirst(history.count - Self.historyLimit) }
    }

    /// The next report is drawn where it is, without a glide from the current point: the
    /// Window-mode pane under the pointer changed, so the old and new positions are in
    /// differently scaled panes.
    mutating func jumpAtNextReport() {
        jumpsAtNextReport = true
    }

    /// Skips straight to the newest report, for when the pointer is drawn there without
    /// pacing (the view left the screen).
    mutating func settle() {
        if let last = history.last { playhead = max(playhead, last.time) }
    }

    /// Advances to the refresh at `time` and returns where to draw the pointer, or nil while
    /// hidden. Never moves backwards along the reported path.
    mutating func frame(at time: Double) -> CGPoint? {
        guard isVisible, let last = history.last else { return nil }
        guard history.count > 1 else { return last.point }
        playhead = max(playhead, time - delay)
        if playhead >= last.time { return last.point }
        guard let index = history.lastIndex(where: { $0.time <= playhead }) else {
            return history[0].point
        }
        let a = history[index], b = history[index + 1]
        let fraction = b.time > a.time ? CGFloat((playhead - a.time) / (b.time - a.time)) : 1
        return CGPoint(x: a.point.x + (b.point.x - a.point.x) * fraction,
                       y: a.point.y + (b.point.y - a.point.y) * fraction)
    }

    private mutating func jump(to point: CGPoint, at time: Double) {
        isVisible = true
        jumpsAtNextReport = false
        history = [Report(time: time, point: point)]
        playhead = -.infinity
    }
}

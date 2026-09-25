// Compiled into the iOS target (presentation) and the hostless Mac test
// target (pure-logic coverage — see MacTests/PointerGestureEngineTests.swift).
// CoreGraphics + Foundation only, so it stays platform-neutral and UIKit-free.

import CoreGraphics
import Foundation

/// One synthetic mouse button the engine can hold down.
enum PointerButton: Equatable {
    case left
    case right

    /// The wire string this button is sent/received as (`"left"`/`"right"`).
    var wireValue: String {
        switch self {
        case .left: return "left"
        case .right: return "right"
        }
    }

    /// Parses an untrusted wire value. Senders MUST ignore an
    /// unrecognized/malformed `button` field rather than treat it as
    /// fatal, mirroring `HIDKeyUsage.parse`.
    static func parse(_ value: Any?) -> PointerButton? {
        switch value as? String {
        case "left": return .left
        case "right": return .right
        default: return nil
        }
    }
}

/// A pure, ordered instruction for the caller to turn into a wire message.
/// `moveAbsolute`/`moveRelative` never imply a button; button state is
/// carried explicitly by `mouseDown`/`mouseUp` (PRODUCT RULE: ordinary
/// cursor movement never implies mouseDown).
enum PointerCommand: Equatable {
    /// Move the Mac cursor to this normalized remote-space point.
    case moveAbsolute(x: Double, y: Double)
    /// Move the Mac cursor relatively by this delta, in the same
    /// view-local point units as the `PointerTouchSample`s that produced
    /// it (i.e. NOT normalized remote-space) — the caller converts through
    /// the current viewport scale into video pixels before sending, the
    /// same conversion `scroll` already applies.
    case moveRelative(dx: Double, dy: Double)
    case mouseDown(button: PointerButton, clickCount: Int)
    case mouseUp(button: PointerButton, clickCount: Int)
    /// Smart Touch (Experimental): ask the Mac what the Accessibility
    /// element under this normalized point is — a scrollable container, a
    /// window title bar, or neither. The answer comes back through
    /// `resolveSmartTouchProbe(id:target:)`.
    case probeScrollTarget(id: Int, x: Double, y: Double)
    /// Smart Touch one-finger scroll delta, in the same view-local point
    /// units as `moveRelative` (natural-scrolling direction, like the
    /// two-finger scroll path).
    case scroll(dx: Double, dy: Double)
    /// The Smart Touch scroll finger lifted (`momentum: true`) or was
    /// cancelled (`momentum: false`).
    case scrollEnded(momentum: Bool)
    /// Smart Touch hold feedback for the receiver to render as haptics.
    /// Local only — nothing goes on the wire.
    case smartTouchFeedback(SmartTouchFeedback)
}

/// The moments of a Smart Touch hold the receiver confirms with haptics.
/// The engine emits these whether or not haptics are on; they never
/// change what the gesture does.
enum SmartTouchFeedback: Equatable {
    /// A long press on an ordinary Smart Touch target dropped this touch
    /// into plain Direct Touch.
    case directTouchOverride
    /// A still finger on a recognized title bar started building toward a
    /// window drag, which arms at `deadline` (touch-sample time base).
    case titleBarHoldBegan(deadline: TimeInterval)
    /// That title bar hold ended without arming: the finger lifted, moved
    /// away, or the touch was cancelled.
    case titleBarHoldCancelled
    /// The title bar hold reached its threshold: the left button is now
    /// held and the window follows the finger.
    case windowDragArmed
}

/// What the Mac confidently identified under a Smart Touch touch-down.
enum SmartTouchTarget: Equatable {
    /// A standard scroll container: a one-finger swipe scrolls it.
    case scroll
    /// A window title bar or empty toolbar space: touch and hold, then
    /// drag, moves the window.
    case windowDrag
}

/// One raw touch sample fed into the engine. `id` must be stable for a
/// given physical finger's lifetime (e.g. `ObjectIdentifier(uiTouch)`).
/// `normalized` is the touch's location mapped through the current
/// `RemoteViewportTransform`; `nil` when it falls outside the rendered
/// video (the engine still tracks it for arbitration/counting purposes but
/// never emits an absolute move for it).
struct PointerTouchSample {
    enum Phase { case began, moved, ended, cancelled }

    let id: AnyHashable
    let phase: Phase
    let viewPoint: CGPoint
    let normalized: CGPoint?
    let time: TimeInterval
}

/// Tunable timing/distance thresholds. Grouped so tests and the real
/// recognizer share one source of truth.
enum PointerGestureConfig {
    /// Movement (view points) under which a released touch still counts
    /// as a tap rather than a plain cursor reposition/drag.
    static let tapMaxMovement: CGFloat = 10
    /// How long after a completed tap the engine waits to see whether a
    /// new touch continues the chain (another tap, or a held drag start)
    /// before flushing the buffered click(s) to the wire. Applies to both
    /// the single-finger left-click chain and the two-finger right-click
    /// chain.
    static let tapChainWindow: TimeInterval = 0.22
    /// Maximum distance between consecutive taps' points to count as the
    /// same chain (mirrors AppKit's double-click distance, kept as a fixed
    /// constant here since the engine has no access to AppKit).
    static let tapChainMaxDistance: CGFloat = 40
    /// A new touch (or chord) held this long without releasing, following
    /// a buffered tap, commits as a drag start rather than another tap —
    /// even with no movement at all (see `poll(now:)`).
    static let holdCommitDelay: TimeInterval = 0.15
    /// Movement (view points) that commits a still-undecided held
    /// touch/chord to a drag immediately, without waiting for
    /// `holdCommitDelay`.
    static let dragSlop: CGFloat = 10
    /// A later finger's (or fresh chord's) release within this long,
    /// under `tapMaxMovement`, is a tap (left click for one later finger,
    /// right click for a fresh/later two-finger chord) rather than the
    /// start of a held drag.
    static let chordTapMaxDuration: TimeInterval = 0.3
    /// How long the very first touch of a fresh sequence is held as
    /// `.firstTouchPending` before committing to a solo absolute-pointer
    /// session with no second finger having joined — but ONLY via this
    /// time-based fallback; movement beyond `dragSlop` commits immediately
    /// regardless (see `moved(_:)`), so this only ever delays a touch that
    /// is genuinely still stationary. A real two-finger chord tap (right-
    /// click) typically doesn't move either finger much, so this is the
    /// value that determines how much real-hand stagger between the two
    /// touches a fresh chord can tolerate before the first finger is
    /// mistaken for a solo pointer — real-device testing showed 80ms was
    /// too tight for a deliberate two-finger tap; 150ms is still well
    /// under the ~250-300ms a stationary hold needs to *read* as
    /// deliberately slow, so single-finger pointing still feels immediate
    /// (the common case commits via the movement path in a frame or two
    /// regardless — this window only ever matters for a finger that isn't
    /// moving yet).
    static let firstTouchArbitrationWindow: TimeInterval = 0.15
    /// Smart Touch (Experimental): once the Mac has confidently classified
    /// the touch-down target, a finger held still this long drops into
    /// plain Direct Touch for the rest of that touch (a long-press
    /// override) instead of committing at `firstTouchArbitrationWindow`.
    static let smartTouchLongPressDelay: TimeInterval = 0.4
    /// Smart Touch window drag: how long a finger must stay still (within
    /// `dragSlop`) on a recognized title bar, measured from touch-down,
    /// before the drag arms. Moving earlier falls back to Direct Touch, so
    /// a window only ever moves after a deliberate hold.
    static let smartTouchTitleBarHoldDelay: TimeInterval = 0.5
    /// Smart Touch scroll direction lock: a first swipe whose dominant
    /// axis is at least this many times the other scrolls on that axis
    /// only, so a vertical list never drifts sideways (and vice versa).
    /// Anything more diagonal pans freely in both axes.
    static let smartScrollAxisLockRatio: CGFloat = 2

    /// Bounds for `PointerGestureEngine.trackpadSensitivity` — a plain
    /// linear multiplier on Trackpad's primary one-finger relative delta,
    /// nothing fancier (no acceleration curve). `1.0` (`defaultTrackpadSensitivity`)
    /// reproduces the exact pre-sensitivity-setting movement speed;
    /// half/double that read as clearly slower/faster on real hardware
    /// without either extreme feeling broken.
    static let trackpadSensitivityRange: ClosedRange<Double> = 0.5...2.0
    static let defaultTrackpadSensitivity: Double = 1.0
}

/// User-selectable primary one-finger pointer model. Persisted receiver
/// preference (see `ReceiverControlPreferences.inputMode`); only changes the
/// FIRST finger's semantics — every multi-finger gesture (scroll, pinch,
/// right-click chord, system gestures) is shared and unaffected by this
/// setting. Stable raw values: written to disk via `ReceiverControlPreferences`.
enum PointerInputMode: String, Codable, CaseIterable, Identifiable {
    /// The first finger maps directly to the corresponding Mac coordinates —
    /// touch-where-you-want-the-pointer. The existing hybrid behavior (a
    /// later finger promotes the session to relative/precision tracking)
    /// still applies on top of this.
    case direct
    /// The first finger moves the Mac cursor RELATIVE to wherever it
    /// already is — touching down never snaps/jumps the cursor to the
    /// finger's location, like a laptop trackpad.
    case trackpad

    var id: String { rawValue }

    /// Direct Touch scrolls target the content under the fingers. Trackpad
    /// scrolls stay at the Mac cursor and must not emit a parallel absolute
    /// touch move while a right-click chord is forming.
    var seedsAbsoluteScrollTarget: Bool { self == .direct }
    var title: String {
        switch self {
        case .direct: return "Direct Touch"
        case .trackpad: return "Trackpad"
        }
    }
    var explanation: String {
        switch self {
        case .direct: return "Touch where you want the pointer."
        case .trackpad: return "Move the pointer relative to your finger."
        }
    }
}

/// Explicit macro-states the engine can be in. Kept small and named after
/// the product model rather than the full cross product of every tracked
/// touch, so ownership reasoning stays legible: once `mode` leaves `.idle`
/// it only ever changes through `PointerGestureEngine`'s own transition
/// methods, never implicitly.
enum PointerEngineMode: Equatable {
    /// Nothing down.
    case idle
    /// Exactly one touch down, not yet committed to anything. Emits NO
    /// wire commands — see `firstTouchArbitrationWindow`'s doc. Resolves
    /// into exactly one of: a fresh two-finger sequence (a second touch
    /// joins), a buffered tap (release under `tapMaxMovement`), a left
    /// drag (continues an already-buffered tap chain), or `.absolutePointer`
    /// (movement evidence or the arbitration window expires with nothing
    /// else happening).
    case firstTouchPending
    /// A solo touch is the committed absolute-pointer anchor and is
    /// physically down, with no later finger having joined yet. No
    /// button held.
    case absolutePointer
    /// No touch is down, but a completed tap (or tap chain) is buffered,
    /// withheld in case a new touch continues the chain (another tap, or
    /// a held drag start) — see `tapChainWindow`. A brand-new touch here
    /// re-enters `.firstTouchPending` (shared `began()` case).
    case tapBuffered
    /// The left button is down and dragging (tap-then-hold committed).
    case leftDragHeld
    /// Two (or three) fingers arrived together, fresh, undecided between
    /// a right-click tap and a right-button drag. (Scroll/pinch is owned
    /// entirely by the existing `TwoFingerViewportGestureRecognizer`; this
    /// mode is only reached once that recognizer's own classifier would
    /// stay `.undecided`, i.e. the fingers lift without crossing its
    /// thresholds — see the type doc in `iOS/OpenSidecarPhoneApp.swift`.)
    case twoFingerPending
    /// The right button is down and dragging.
    case rightDragHeld
    /// A precision/relative pointer session: an anchor plus at least one
    /// later finger, once "intentionally added" (GOAL: M7.1) — the WHOLE
    /// session moves the cursor relatively from here on; no finger in it
    /// may emit `moveAbsolute` again until the entire session ends (every
    /// finger lifts) and a completely fresh sequence begins. A third
    /// finger arriving here promotes the non-anchor member + the new
    /// touch into a right-click/drag chord (`.chordPending`), pausing the
    /// anchor (which resumes relative tracking once that chord resolves,
    /// from its live position — no jump).
    case relativePointerSession
    /// An anchor is active (a `relativePointerSession` paused mid-flight)
    /// and two later fingers are forming a right-click/drag chord; not
    /// yet resolved between a tap and a held drag.
    case chordPending
    /// Smart Touch (Experimental): a solo Direct Touch finger whose
    /// touch-down target the Mac confirmed as scrollable, committed to
    /// one-finger scrolling. Locked until that finger lifts — extra
    /// fingers are ignored, exactly like `.leftDragHeld`. (A Smart Touch
    /// window drag needs no mode of its own: once its title bar hold arms,
    /// it is an ordinary `.leftDragHeld` started at the touch-down point.)
    case smartScroll
    /// 3+ fingers arrived together, fresh, with no established anchor.
    /// The engine steps aside entirely — the existing system-gesture
    /// recognizers own this touch sequence.
    case deferredSystemGesture
}

/// The receiver's pointer/click gesture policy — a pure, testable
/// touch-intent/session model sitting underneath the iOS `VideoView`.
///
/// Ownership rules (see GOAL in the M7 milestone brief):
/// 1. A touch sequence acquires an owner (`mode`) and, once committed,
///    does not oscillate frame-to-frame.
/// 2. Later-added touches can have different semantics from touches that
///    began together — `firstTouchPending`/chord-continuation timing
///    distinguishes them.
/// 3. Mouse buttons are only held while an explicit drag interaction owns
///    the sequence (`leftDragHeld`/`rightDragHeld`).
/// 4. Ordinary cursor movement never implies mouseDown.
/// 5. Once a pointer session goes relative (`.relativePointerSession`), no
///    finger in it may emit `moveAbsolute` again for the rest of that
///    session — see GOAL M7.1's "the original anchor must never snap the
///    cursor back" bug.
///
/// Not thread-safe; drive it from one queue (main, matching UIKit touch
/// delivery).
final class PointerGestureEngine {
    private(set) var mode: PointerEngineMode = .idle

    /// The primary one-finger pointer model — see `PointerInputMode`. Only
    /// consulted at the moment a fresh first-touch session commits
    /// (`commitToAbsolutePointer` vs. `commitToRelativePointerSession`, and
    /// their tap-then-hold-drag counterparts); changing it mid-session does
    /// nothing until the next commit, so the caller MUST pair a change with
    /// `setInputMode(_:)` (never assign this directly) to safely cancel
    /// whatever session is already in flight — see its doc.
    private(set) var inputMode: PointerInputMode = .direct

    /// Linear multiplier on Trackpad's primary one-finger relative delta —
    /// see `PointerGestureConfig.trackpadSensitivityRange`. Clamped on
    /// assignment so a bad persisted/UI value can never leave the sane
    /// range. Safe to change mid-session (it only scales future deltas,
    /// nothing tracked is derived from it), so unlike `inputMode` this
    /// needs no cancellation ceremony.
    var trackpadSensitivity: Double = PointerGestureConfig.defaultTrackpadSensitivity {
        didSet {
            let range = PointerGestureConfig.trackpadSensitivityRange
            let clamped = min(max(trackpadSensitivity, range.lowerBound), range.upperBound)
            guard clamped != trackpadSensitivity else { return }
            trackpadSensitivity = clamped
        }
    }

    /// Smart Touch (Experimental). Only ever consulted for a fresh solo
    /// finger in `.direct` mode with no tap chain buffered; Trackpad and
    /// every multi-finger path ignore it. Safe to change mid-session: it
    /// only affects the next touch-down's probe and commit decision.
    var smartTouchEnabled = false

    private var smartTouchIsActive: Bool { smartTouchEnabled && inputMode == .direct }

    /// Whether the Mac has classified the current `.firstTouchPending`
    /// finger's touch-down target (`resolved(nil)`: nothing Smart Touch
    /// acts on). Meaningful only while that mode lasts; a fresh first
    /// touch always overwrites it.
    private enum SmartTouchProbeState: Equatable {
        case none
        case pending(id: Int)
        case resolved(SmartTouchTarget?)
    }
    private var smartTouchProbe = SmartTouchProbeState.none
    private var nextSmartTouchProbeID = 0
    private var smartScrollLastView: CGPoint?

    /// Axes a Smart Touch scroll may move on, fixed at commit — see
    /// `smartScrollAxisLockRatio`.
    private enum SmartScrollAxis { case horizontal, vertical, free }
    private var smartScrollAxis = SmartScrollAxis.free

    /// Whether a `.titleBarHoldBegan` is outstanding, so every way out of
    /// the hold short of arming reports `.titleBarHoldCancelled` exactly once.
    private var titleBarHoldActive = false

    /// The confidently classified target of a still-undecided Smart Touch
    /// first touch. While set, a stationary finger waits for the long-press
    /// override (or, on a title bar, the window-drag hold) instead of
    /// committing at the arbitration window.
    private var smartTouchDeferredTarget: SmartTouchTarget? {
        guard smartTouchIsActive, tapChain == nil, case .resolved(let target) = smartTouchProbe else { return nil }
        return target
    }

    /// Whether the current `.chordPending`/`.twoFingerPending` chord was
    /// recognized as continuing a just-buffered right tap (see
    /// `PendingChordTap`). Exposed so the UIKit layer can withhold the
    /// legacy scroll/pinch recognizer from a chord this engine has already
    /// claimed as a right-drag candidate — see `VideoView`'s
    /// `gestureRecognizer(_:shouldReceive:)`.
    var isChordContinuation: Bool { chordIsContinuation }

    // The anchor touch (finger 1) once an absolute/relative pointer
    // session exists. Persists as a session identity for the session's
    // whole lifetime — including through a later chord that temporarily
    // pauses it, and even after the anchor's own physical touch lifts
    // while other session fingers remain down — and is cleared only by
    // `resetToIdle()`.
    private var anchorID: AnyHashable?
    private var anchorNormalized: CGPoint?   // last known normalized point (absolute mode only)
    private var anchorViewPoint: CGPoint?    // last known view-local point, kept fresh in every mode

    // Once true (a later finger has been intentionally added to an
    // absolute-pointer session), stays true for the rest of this session —
    // see `PointerEngineMode.relativePointerSession`'s doc.
    private var sessionIsRelative = false

    // Fingers currently contributing relative deltas within
    // `.relativePointerSession` — at most the anchor plus one other at a
    // time; a third arriving promotes the non-anchor member into a chord
    // with it instead (`promoteRelativeSessionToChord`).
    private struct RelativeFinger {
        var lastPoint: CGPoint       // updated every sample; the delta source
        let touchDown: CGPoint       // immutable; for the tap-vs-drag movement check
        let touchDownTime: TimeInterval
    }
    private var relativeFingers: [AnyHashable: RelativeFinger] = [:]

    // A later relative-session finger's touch that MIGHT be continuing a
    // buffered left tap chain (`tapChain`, shared with the solo/anchor
    // path — the two can never be simultaneously in play, since a
    // relative session only exists once an anchor is already committed,
    // which the solo path's own `tapChain` only ever holds *before* that
    // commitment). Tracked separately from `relativeFingers` because it
    // emits nothing while undecided — same "no commands during
    // arbitration" contract as `.firstTouchPending` — and only joins
    // `relativeFingers` once it commits to a held drag.
    private var relativeChainCandidateID: AnyHashable?
    private var relativeChainCandidateStart: (view: CGPoint, time: TimeInterval)?
    // Refreshed on every `moved()` sample so a time-based drag commit
    // (`poll()`'s hold-commit delay) has a current position even though no
    // command was emitted for any of those samples.
    private var relativeChainCandidateLastView: CGPoint?
    // The relative-session finger currently holding the left button down
    // (a tap-then-hold drag committed from `relativeChainCandidateID`).
    // `nil` whenever `heldMouseButton` is not `.left`.
    private var relativeDragFingerID: AnyHashable?

    // Touches composing the current chord (two-finger-tap / right-drag),
    // either fresh (`.twoFingerPending`) or later-added while an anchor is
    // active (`.chordPending`, promoted from a relative session).
    private var chordIDs: Set<AnyHashable> = []
    private var chordStartTime: TimeInterval = 0
    private var chordCentroidStart: CGPoint = .zero
    private var chordCentroidLast: CGPoint = .zero
    private var chordPositions: [AnyHashable: CGPoint] = [:]
    // Whether this chord was recognized as continuing a just-buffered right
    // tap (see `pendingChordTap`) — if so, its resolution replaces the
    // buffered tap rather than adding a second one.
    private var chordIsContinuation = false

    // The single touch tracked while `.firstTouchPending`.
    private var pendingID: AnyHashable?
    private var pendingStart: (point: CGPoint, view: CGPoint, time: TimeInterval)?
    // Refreshed on every `moved()` sample while still `.firstTouchPending`
    // so a time-based commit (arbitration window expiry, or a held tap
    // chain's hold-commit delay) has a current position to work with even
    // though no command was emitted for any of those samples.
    private var pendingLastNormalized: CGPoint?
    private var pendingLastView: CGPoint?

    // Buffered single-finger tap chain: a completed tap (or chain of taps)
    // not yet flushed to the wire because a continuing touch might still
    // arrive (another tap, or a held drag start).
    private struct TapChain {
        var count: Int
        var lastPoint: CGPoint       // view-local, for chain-distance checks
        var lastReleaseTime: TimeInterval
    }
    private var tapChain: TapChain?

    // Buffered right-click chord tap, withheld in case a second chord
    // touches down shortly after and is held (right-button drag) rather
    // than released again (see PRODUCT RULE: a preceding right click
    // would dismiss the context menu a held chord is meant to open).
    private struct PendingChordTap {
        var point: CGPoint
        var time: TimeInterval
    }
    private var pendingChordTap: PendingChordTap?

    // Touches currently down, keyed by id, with their first-seen time — used
    // to decide whether a newly-observed group arrived "together" (fresh)
    // or "later" (a chord/precision touch joining an existing anchor), and
    // to check whether the anchor is still physically down when a chord
    // resolves (`resumeAfterChord`).
    private var liveTouchStart: [AnyHashable: TimeInterval] = [:]

    // Button-held tracking, purely for `releaseHeld()` safety — the source
    // of truth for *which* CGEvent type to post lives on the Mac side
    // (InputInjector), which tracks its own held-button state from the
    // down/up commands this engine emits.
    /// At most one explicit drag may own a mouse button at a time. Tap
    /// clicks are emitted as matched down/up command pairs and never enter
    /// this held state.
    private(set) var heldMouseButton: PointerButton?

    init() {}

    // MARK: - Touch lifecycle

    /// Feed one raw touch sample. Returns the ordered commands to send.
    @discardableResult
    func handle(_ sample: PointerTouchSample) -> [PointerCommand] {
        switch sample.phase {
        case .began: return began(sample)
        case .moved: return moved(sample)
        case .ended: return ended(sample, cancelled: false)
        case .cancelled: return ended(sample, cancelled: true)
        }
    }

    /// Time-driven transitions with no new touch sample: the first-touch
    /// arbitration window, the tap-chain/chord-tap grace windows, and the
    /// hold-commit delay for a held (possibly stationary) touch/chord. The
    /// caller schedules this after the relevant delay (mirroring the
    /// pre-existing `holdTimer` pattern) — the engine itself starts no
    /// timers.
    @discardableResult
    func poll(now: TimeInterval) -> [PointerCommand] {
        var out: [PointerCommand] = []
        if mode == .firstTouchPending, let start = pendingStart, let pid = pendingID {
            if tapChain != nil {
                if now - start.time >= PointerGestureConfig.holdCommitDelay {
                    out += inputMode == .trackpad
                        ? beginTrackpadDrag(id: pid, at: pendingLastView ?? start.view, time: now)
                        : beginLeftDrag(id: pid, normalized: pendingLastNormalized)
                }
            } else if let target = smartTouchDeferredTarget {
                switch target {
                case .scroll:
                    // Smart Touch long-press override: held still on a
                    // confidently classified target, this touch becomes
                    // plain Direct Touch — confirmed with a haptic.
                    if now - start.time >= PointerGestureConfig.smartTouchLongPressDelay {
                        out += commitToAbsolutePointer(id: pid, normalized: pendingLastNormalized,
                                                       viewPoint: pendingLastView ?? start.view)
                        out.append(.smartTouchFeedback(.directTouchOverride))
                    }
                case .windowDrag:
                    // Held still on a title bar long enough: the window
                    // drag arms instead of the Direct Touch override.
                    if now - start.time >= PointerGestureConfig.smartTouchTitleBarHoldDelay {
                        out += armSmartWindowDrag(id: pid)
                    }
                }
            } else if now - start.time >= PointerGestureConfig.firstTouchArbitrationWindow {
                // Same chord-continuation deferral as `moved()` — see its
                // doc. Tied to the buffered tap's OWN `tapChainWindow`
                // (not `firstTouchArbitrationWindow`, which is already
                // exactly this branch's own trigger and so can never
                // distinguish anything here), so this is never left stuck:
                // `pollDelay(now:)`'s `pendingChordTap` branch already
                // schedules a re-check for exactly when that window closes,
                // and the very next `poll()` after that commits normally.
                if inputMode == .trackpad,
                   isPlausibleChordContinuationCandidate(from: start.view, at: now) {
                    // withheld — see above
                } else {
                    let viewPoint = pendingLastView ?? start.view
                    out += inputMode == .trackpad
                        ? commitToRelativePointerSession(id: pid, viewPoint: viewPoint, time: now)
                        : commitToAbsolutePointer(id: pid, normalized: pendingLastNormalized, viewPoint: viewPoint)
                }
            }
        }
        if mode == .relativePointerSession, let candidateID = relativeChainCandidateID,
           let start = relativeChainCandidateStart,
           now - start.time >= PointerGestureConfig.holdCommitDelay {
            out += commitRelativeLeftDrag(id: candidateID, at: relativeChainCandidateLastView ?? start.view)
        }
        if mode == .tapBuffered, let chain = tapChain,
           now - chain.lastReleaseTime >= PointerGestureConfig.tapChainWindow {
            out += flushTapChain()
            mode = .idle
        }
        if mode == .relativePointerSession, relativeChainCandidateID == nil, let chain = tapChain,
           now - chain.lastReleaseTime >= PointerGestureConfig.tapChainWindow {
            out += flushTapChain()
        }
        if let pending = pendingChordTap, now - pending.time >= PointerGestureConfig.tapChainWindow,
           chordIDs.isEmpty, !hasPendingChordContinuationStart(at: now) {
            out += flushPendingChordTap()
        }
        if mode == .chordPending || mode == .twoFingerPending, chordIsContinuation,
           !chordIDs.isEmpty, now - chordStartTime >= PointerGestureConfig.holdCommitDelay {
            out += commitRightDrag()
        }
        return out
    }

    /// Delay until the next state transition that requires `poll(now:)`.
    /// This is independent of `mode`: buffered clicks belong to their own
    /// finger/chord interaction and can outlive the pointer session that
    /// produced them.
    func pollDelay(now: TimeInterval) -> TimeInterval? {
        var deadlines: [TimeInterval] = []

        if mode == .firstTouchPending, let start = pendingStart, pendingID != nil {
            let delay: TimeInterval
            if tapChain != nil {
                delay = PointerGestureConfig.holdCommitDelay
            } else if let target = smartTouchDeferredTarget {
                delay = target == .windowDrag
                    ? PointerGestureConfig.smartTouchTitleBarHoldDelay
                    : PointerGestureConfig.smartTouchLongPressDelay
            } else {
                delay = PointerGestureConfig.firstTouchArbitrationWindow
            }
            deadlines.append(start.time + delay)
        }
        if mode == .relativePointerSession, let start = relativeChainCandidateStart {
            deadlines.append(start.time + PointerGestureConfig.holdCommitDelay)
        }
        if let chain = tapChain, relativeChainCandidateID == nil, mode != .firstTouchPending {
            deadlines.append(chain.lastReleaseTime + PointerGestureConfig.tapChainWindow)
        }
        if let pending = pendingChordTap, chordIDs.isEmpty {
            let tapDeadline = pending.time + PointerGestureConfig.tapChainWindow
            if let startTime = pendingChordContinuationStartTime {
                deadlines.append(max(tapDeadline,
                                     startTime + PointerGestureConfig.firstTouchArbitrationWindow))
            } else {
                deadlines.append(tapDeadline)
            }
        }
        if (mode == .chordPending || mode == .twoFingerPending), chordIsContinuation,
           !chordIDs.isEmpty {
            deadlines.append(chordStartTime + PointerGestureConfig.holdCommitDelay)
        }

        guard let deadline = deadlines.min() else { return nil }
        return max(0, deadline - now)
    }

    /// Keep a right-tap candidate alive when the first finger of its next
    /// chord has landed within the continuation window, even if the partner
    /// finger arrives just after the deadline. Completion is decided from
    /// that first-touch time and the completed chord's centroid.
    private var pendingChordContinuationStartTime: TimeInterval? {
        guard let pending = pendingChordTap else { return nil }

        func isEligibleStart(at point: CGPoint, time: TimeInterval) -> TimeInterval? {
            let elapsed = time - pending.time
            guard elapsed >= 0,
                  elapsed <= PointerGestureConfig.tapChainWindow,
                  hypot(point.x - pending.point.x, point.y - pending.point.y)
                    <= PointerGestureConfig.tapChainMaxDistance else { return nil }
            return time
        }

        if mode == .firstTouchPending, let start = pendingStart {
            return isEligibleStart(at: start.view, time: start.time)
        }
        if mode == .relativePointerSession {
            return relativeFingers
                .filter { $0.key != anchorID }
                .compactMap { isEligibleStart(at: $0.value.touchDown, time: $0.value.touchDownTime) }
                .min()
        }
        return nil
    }

    private func hasPendingChordContinuationStart(at time: TimeInterval) -> Bool {
        guard let start = pendingChordContinuationStartTime else { return false }
        return time - start < PointerGestureConfig.firstTouchArbitrationWindow
    }

    /// Whether a lone `.firstTouchPending` finger sitting at `viewPoint`
    /// (its own touch-down point, not wherever it's since moved to) could
    /// still be joined by a partner to continue `pendingChordTap` into a
    /// chord — see `promoteToChord`'s matching distance/timing check, which
    /// this mirrors. Deliberately tied to the buffered tap's own
    /// `tapChainWindow`, not `firstTouchArbitrationWindow`: the latter is
    /// already this finger's OWN commit trigger in `poll()`, so checking it
    /// again there would always read as "window just closed" — the exact
    /// same instant, never a real signal. Trackpad-mode call sites
    /// (`moved()`/`poll()`) use this to withhold a solo commit until the
    /// continuation possibility has genuinely passed, so a second right-
    /// click's first finger — placed a little slower than the 150ms
    /// arbitration window but still within reach of the just-buffered tap —
    /// is never swallowed into its own solo relative session before its
    /// partner has a real chance to arrive and form the chord instead.
    private func isPlausibleChordContinuationCandidate(from viewPoint: CGPoint, at time: TimeInterval) -> Bool {
        guard let pending = pendingChordTap else { return false }
        let elapsed = time - pending.time
        guard elapsed >= 0, elapsed <= PointerGestureConfig.tapChainWindow else { return false }
        return hypot(viewPoint.x - pending.point.x, viewPoint.y - pending.point.y)
            <= PointerGestureConfig.tapChainMaxDistance
    }

    private func began(_ sample: PointerTouchSample) -> [PointerCommand] {
        liveTouchStart[sample.id] = sample.time

        switch mode {
        case .idle, .tapBuffered:
            // First touch of a fresh sequence (`.idle`), or a new touch
            // following a still-buffered tap (`.tapBuffered` — the
            // tap-then-hold-drag / multi-tap chain path: `tapChain` still
            // reflects its count, so `moved()`/`poll()` below can extend
            // or convert it). Neither emits anything yet — see
            // `.firstTouchPending`'s doc.
            pendingID = sample.id
            pendingStart = (sample.normalized ?? .zero, sample.viewPoint, sample.time)
            pendingLastNormalized = sample.normalized
            pendingLastView = sample.viewPoint
            mode = .firstTouchPending
            smartTouchProbe = .none
            // Smart Touch asks once per touch, at touch-down, so the Mac's
            // Accessibility lookup overlaps the drag-slop movement rather
            // than sitting in the movement path. A buffered tap chain
            // means tap-then-hold-drag, which Smart Touch never changes.
            guard smartTouchIsActive, tapChain == nil, let n = sample.normalized else { return [] }
            nextSmartTouchProbeID &+= 1
            smartTouchProbe = .pending(id: nextSmartTouchProbeID)
            return [.probeScrollTarget(id: nextSmartTouchProbeID, x: Double(n.x), y: Double(n.y))]

        case .firstTouchPending:
            // A second touch joined before the first resolved — always a
            // fresh chord (an anchor never commits while still
            // `.firstTouchPending`).
            return endTitleBarHold() + beginFreshChord(sample)

        case .absolutePointer:
            // The first later finger, intentionally added to an already-
            // established solo pointer session: commit the WHOLE session
            // to relative mode immediately (GOAL M7.1) — the anchor loses
            // absolute mapping from this point on, for the rest of the
            // session.
            return beginRelativeSession(joining: sample)

        case .relativePointerSession:
            if let chain = tapChain,
               sample.time - chain.lastReleaseTime <= PointerGestureConfig.tapChainWindow,
               hypot(sample.viewPoint.x - chain.lastPoint.x, sample.viewPoint.y - chain.lastPoint.y)
                <= PointerGestureConfig.tapChainMaxDistance {
                // Continuing a buffered relative-finger left tap: might
                // become another tap (chain extends) or a held drag start —
                // see `moved`/`ended`/`poll`. Emits nothing yet.
                relativeChainCandidateID = sample.id
                relativeChainCandidateStart = (sample.viewPoint, sample.time)
                relativeChainCandidateLastView = sample.viewPoint
                return []
            }
            if relativeFingers.count < 2 {
                relativeFingers[sample.id] = RelativeFinger(
                    lastPoint: sample.viewPoint, touchDown: sample.viewPoint, touchDownTime: sample.time)
                return []
            }
            // A third finger with the anchor + one relative finger already
            // active: promote the non-anchor member + this new touch into
            // a right-click/drag chord, pausing the anchor.
            return promoteRelativeSessionToChord(newTouch: sample)

        case .chordPending:
            // A 3rd later finger with a chord already at 2: ignore — the
            // existing 2-finger chord semantics still apply.
            return []

        case .twoFingerPending:
            // A 3rd fresh finger joining a still-undecided two-finger tap
            // candidate — treat as the fresh 3-finger system gesture and
            // step aside completely (matches "fresh 3-finger start ->
            // system gesture").
            mode = .deferredSystemGesture
            chordIDs.removeAll()
            chordPositions.removeAll()
            return []

        case .leftDragHeld, .rightDragHeld, .smartScroll:
            // Extra fingers while a drag (or Smart Touch scroll) is
            // already committed don't change its meaning — ignore until
            // release.
            return []

        case .deferredSystemGesture:
            return []
        }
    }

    /// Called when a second touch arrives while `mode == .firstTouchPending`
    /// — the two touches always arrived together (an anchor never commits
    /// while still `.firstTouchPending`), so this is always a fresh chord.
    /// Neither touch has emitted anything on the wire yet, so there is
    /// nothing to undo — CRITICAL: this must never have moved the cursor
    /// to finger 1's location first.
    private func beginFreshChord(_ sample: PointerTouchSample) -> [PointerCommand] {
        let firstID = pendingID
        let firstStart = pendingStart
        pendingID = nil
        pendingStart = nil
        pendingLastNormalized = nil
        pendingLastView = nil
        tapChain = nil
        anchorID = nil
        anchorNormalized = nil

        mode = .twoFingerPending
        chordIDs = [sample.id]
        chordStartTime = sample.time
        chordPositions = [sample.id: sample.viewPoint]
        if let firstID, let firstStart {
            promoteToChord(adding: firstID, at: sample.time, point: firstStart.view,
                           continuationStartedAt: firstStart.time)
        }
        chordCentroidStart = centroid()
        chordCentroidLast = chordCentroidStart
        return []
    }

    /// Commits the whole session to relative mode when a later finger is
    /// intentionally added to an established solo `.absolutePointer`
    /// anchor. Both the anchor and the new finger get fresh relative
    /// baselines at their *current* positions — no jump for either.
    private func beginRelativeSession(joining sample: PointerTouchSample) -> [PointerCommand] {
        guard let anchorID else { return [] }   // defensive; should always be set here
        sessionIsRelative = true
        mode = .relativePointerSession
        let anchorBaseline = anchorViewPoint ?? sample.viewPoint
        relativeFingers = [
            anchorID: RelativeFinger(lastPoint: anchorBaseline, touchDown: anchorBaseline, touchDownTime: sample.time),
            sample.id: RelativeFinger(lastPoint: sample.viewPoint, touchDown: sample.viewPoint, touchDownTime: sample.time),
        ]
        return []
    }

    /// A third finger arrives while the anchor + one relative finger are
    /// already active: pulls the non-anchor member out to pair with the
    /// new touch as a right-click/drag chord — "existing pointer session +
    /// two later fingers" (GOAL). The anchor is left out of
    /// `relativeFingers` (paused) until the chord resolves
    /// (`resumeAfterChord`), at which point it resumes from its live
    /// position.
    private func promoteRelativeSessionToChord(newTouch sample: PointerTouchSample) -> [PointerCommand] {
        // A left-button drag already owns one of the two relative-session
        // slots — never repurpose it into a chord mid-drag (that would
        // strand the held button). Just ignore the extra finger.
        guard relativeDragFingerID == nil else { return [] }
        guard let precisionID = relativeFingers.keys.first(where: { $0 != anchorID }) else {
            // Defensive: no non-anchor finger to pair with — just track
            // this one too rather than lose it.
            relativeFingers[sample.id] = RelativeFinger(
                lastPoint: sample.viewPoint, touchDown: sample.viewPoint, touchDownTime: sample.time)
            return []
        }
        let precisionFinger = relativeFingers[precisionID]
        let precisionPoint = precisionFinger?.lastPoint ?? sample.viewPoint
        let continuationStartedAt = precisionFinger?.touchDownTime ?? sample.time
        relativeFingers.removeAll()

        mode = .chordPending
        chordIDs = [precisionID]
        chordStartTime = sample.time
        chordPositions = [precisionID: precisionPoint]
        promoteToChord(adding: sample.id, at: sample.time, point: sample.viewPoint,
                       continuationStartedAt: continuationStartedAt)
        chordCentroidStart = centroid()
        chordCentroidLast = chordCentroidStart
        return []
    }

    /// Adds a second member to a chord that started with one touch —
    /// either the precision touch being promoted (an anchor's later
    /// finger) or the second half of a fresh two-finger arrival. This is
    /// the one point a chord becomes eligible to continue a just-buffered
    /// right tap into a drag: a solo touch can never itself continue one
    /// (see call sites).
    private func promoteToChord(adding id: AnyHashable, at time: TimeInterval, point: CGPoint,
                                continuationStartedAt: TimeInterval) {
        chordIDs.insert(id)
        chordPositions[id] = point
        // A chord continues a buffered right tap when its first finger
        // landed within the window and its completed centroid is nearby.
        // The second finger may arrive just after the deadline while UIKit
        // is still delivering the chord.
        let chordCenter = centroid()
        if let pending = pendingChordTap,
           continuationStartedAt - pending.time >= 0,
           continuationStartedAt - pending.time <= PointerGestureConfig.tapChainWindow,
           hypot(chordCenter.x - pending.point.x, chordCenter.y - pending.point.y)
            <= PointerGestureConfig.tapChainMaxDistance {
            chordIsContinuation = true
            chordStartTime = time
        } else {
            chordIsContinuation = false
        }
    }

    private func moved(_ sample: PointerTouchSample) -> [PointerCommand] {
        // Keep the anchor's live position fresh in every mode (including
        // while paused mid-chord) so resuming a relative session after a
        // chord resolves never has stale data to jump from.
        if sample.id == anchorID { anchorViewPoint = sample.viewPoint }

        switch mode {
        case .idle, .deferredSystemGesture, .tapBuffered:
            return []

        case .firstTouchPending:
            guard sample.id == pendingID, let start = pendingStart else { return [] }
            pendingLastNormalized = sample.normalized
            pendingLastView = sample.viewPoint
            let moved = hypot(sample.viewPoint.x - start.view.x, sample.viewPoint.y - start.view.y)
            guard moved > PointerGestureConfig.dragSlop else { return [] }
            // Enough movement evidence to commit now, without waiting out
            // the rest of the arbitration window — either a drag
            // continuation of an already-buffered tap chain, or a genuine
            // solo pointer drag.
            if tapChain != nil {
                return inputMode == .trackpad
                    ? beginTrackpadDrag(id: sample.id, at: sample.viewPoint, time: sample.time)
                    : beginLeftDrag(id: sample.id, normalized: sample.normalized)
            }
            if smartTouchIsActive {
                switch smartTouchProbe {
                case .pending:
                    // Withheld until the Mac answers — bounded by the
                    // existing arbitration window, after which `poll()`
                    // commits ordinary Direct Touch as before.
                    return []
                case .resolved(.scroll?):
                    return commitToSmartScroll(id: sample.id, viewPoint: sample.viewPoint)
                case .resolved(.windowDrag?):
                    // Moved before the title bar hold armed: not a
                    // deliberate window drag, so it never becomes one —
                    // plain Direct Touch instead.
                    return endTitleBarHold()
                        + commitToAbsolutePointer(id: sample.id, normalized: sample.normalized,
                                                  viewPoint: sample.viewPoint)
                case .none, .resolved(nil):
                    break
                }
            }
            // Trackpad only: this lone finger might still be joined by a
            // partner to continue a just-buffered right tap into a chord
            // (see `promoteToChord`) — committing it to its own solo
            // relative session first would swallow that continuation into
            // ordinary hybrid precision tracking instead, silencing the
            // right-click entirely (PRODUCT RULE: a chord continuation must
            // always win — see `began()`'s `.firstTouchPending` case, which
            // is exactly where the partner's arrival forms the chord).
            // Withholds any commit — same "no commands during arbitration"
            // contract as the rest of this mode — until either the partner
            // joins or `poll()` resolves the continuation window itself.
            if inputMode == .trackpad, isPlausibleChordContinuationCandidate(from: start.view, at: sample.time) {
                return []
            }
            return inputMode == .trackpad
                ? commitToRelativePointerSession(id: sample.id, viewPoint: sample.viewPoint, time: sample.time)
                : commitToAbsolutePointer(id: sample.id, normalized: sample.normalized, viewPoint: sample.viewPoint)

        case .absolutePointer:
            guard sample.id == anchorID, let n = sample.normalized else { return [] }
            anchorNormalized = n
            return [.moveAbsolute(x: Double(n.x), y: Double(n.y))]

        case .relativePointerSession:
            if sample.id == relativeChainCandidateID, let start = relativeChainCandidateStart {
                relativeChainCandidateLastView = sample.viewPoint
                let movedDist = hypot(sample.viewPoint.x - start.view.x, sample.viewPoint.y - start.view.y)
                guard movedDist > PointerGestureConfig.dragSlop else { return [] }
                // Enough movement to commit now, without waiting out the
                // rest of the hold-commit delay.
                return commitRelativeLeftDrag(id: sample.id, at: sample.viewPoint)
            }
            guard var finger = relativeFingers[sample.id] else { return [] }
            let dx = sample.viewPoint.x - finger.lastPoint.x
            let dy = sample.viewPoint.y - finger.lastPoint.y
            finger.lastPoint = sample.viewPoint
            relativeFingers[sample.id] = finger
            guard dx != 0 || dy != 0 else { return [] }
            // `trackpadSensitivity` scales ONLY this one emission point —
            // the primary one-finger (and its precision-extension) relative
            // delta. It deliberately never touches the tracked `lastPoint`
            // baseline above (so it can't compound error), and this `case`
            // is never reached by the completely separate `.rightDragHeld`
            // two-finger chord delta below, which stays unscaled in both
            // modes — PRODUCT RULE: sensitivity affects only Trackpad's
            // primary one-finger pointer motion, never a multi-finger
            // gesture. In `.direct` mode this same code path is reached
            // only by the pre-existing hybrid second-finger precision
            // move, which the scale factor must also leave untouched.
            let scale = inputMode == .trackpad ? trackpadSensitivity : 1
            return [.moveRelative(dx: Double(dx) * scale, dy: Double(dy) * scale)]

        case .chordPending, .twoFingerPending:
            guard chordIDs.contains(sample.id) else { return [] }
            chordPositions[sample.id] = sample.viewPoint
            let centroid = self.centroid()
            chordCentroidLast = centroid
            let movedDist = hypot(centroid.x - chordCentroidStart.x, centroid.y - chordCentroidStart.y)
            guard chordIsContinuation, movedDist > PointerGestureConfig.dragSlop else { return [] }
            return commitRightDrag()

        case .leftDragHeld:
            guard sample.id == anchorID, let n = sample.normalized else { return [] }
            return [.moveAbsolute(x: Double(n.x), y: Double(n.y))]

        case .smartScroll:
            guard sample.id == anchorID, let last = smartScrollLastView else { return [] }
            smartScrollLastView = sample.viewPoint
            let (dx, dy) = lockedScrollDelta(dx: sample.viewPoint.x - last.x, dy: sample.viewPoint.y - last.y)
            guard dx != 0 || dy != 0 else { return [] }
            return [.scroll(dx: Double(dx), dy: Double(dy))]

        case .rightDragHeld:
            guard chordIDs.contains(sample.id) else { return [] }
            chordPositions[sample.id] = sample.viewPoint
            let centroid = self.centroid()
            let dx = centroid.x - chordCentroidLast.x
            let dy = centroid.y - chordCentroidLast.y
            chordCentroidLast = centroid
            guard dx != 0 || dy != 0 else { return [] }
            return [.moveRelative(dx: Double(dx), dy: Double(dy))]
        }
    }

    private func centroid() -> CGPoint {
        guard !chordPositions.isEmpty else { return chordCentroidLast }
        let points = chordPositions.values
        let x = points.reduce(0) { $0 + $1.x } / CGFloat(points.count)
        let y = points.reduce(0) { $0 + $1.y } / CGFloat(points.count)
        return CGPoint(x: x, y: y)
    }

    private func ended(_ sample: PointerTouchSample, cancelled: Bool) -> [PointerCommand] {
        liveTouchStart.removeValue(forKey: sample.id)
        if sample.id == anchorID { anchorViewPoint = sample.viewPoint }
        var out: [PointerCommand] = []

        switch mode {
        case .idle, .deferredSystemGesture, .tapBuffered:
            break

        case .firstTouchPending:
            guard sample.id == pendingID, let start = pendingStart else { break }
            out += endTitleBarHold()
            pendingID = nil
            pendingStart = nil
            pendingLastNormalized = nil
            pendingLastView = nil
            let moved = hypot(sample.viewPoint.x - start.view.x, sample.viewPoint.y - start.view.y)
            // A Smart Touch target defers the arbitration-window commit
            // (see `poll()`); a press held past that window still reads
            // exactly as before — a pointer placement, never a click.
            let heldPastArbitration = smartTouchDeferredTarget != nil
                && sample.time - start.time >= PointerGestureConfig.firstTouchArbitrationWindow
            let isTap = !cancelled && moved <= PointerGestureConfig.tapMaxMovement && !heldPastArbitration
            if isTap {
                // Confirmed: no second finger ever joined during this
                // touch's life (a fresh chord would already have left
                // `.firstTouchPending`) — safe to move the cursor here,
                // once, so the buffered click lands at the tapped
                // location. Trackpad mode clicks at the cursor's current
                // (unmoved) position instead — PRODUCT RULE: touching down
                // must never snap/jump the cursor.
                if inputMode == .direct, let n = sample.normalized {
                    out.append(.moveAbsolute(x: Double(n.x), y: Double(n.y)))
                }
                extendTapChain(at: sample.viewPoint, time: sample.time)
                mode = .tapBuffered
            } else {
                if heldPastArbitration, !cancelled, let n = sample.normalized {
                    out.append(.moveAbsolute(x: Double(n.x), y: Double(n.y)))
                }
                tapChain = nil
                mode = .idle
            }

        case .absolutePointer:
            guard sample.id == anchorID else { break }
            out += releaseHeld()
            resetToIdle()

        case .relativePointerSession:
            if sample.id == relativeDragFingerID {
                // The finger holding the left button releases it — ends
                // the drag regardless of whether other session fingers
                // (the anchor) remain down.
                relativeDragFingerID = nil
                relativeFingers.removeValue(forKey: sample.id)
                out += releaseHeld()
            } else if sample.id == relativeChainCandidateID {
                // A candidate continuing a buffered tap released without
                // ever committing to a drag — either extends the chain (a
                // genuine tap) or, if cancelled/moved too far, drops it.
                relativeChainCandidateID = nil
                let start = relativeChainCandidateStart
                relativeChainCandidateStart = nil
                relativeChainCandidateLastView = nil
                let movedDist = start.map { hypot(sample.viewPoint.x - $0.view.x, sample.viewPoint.y - $0.view.y) } ?? 0
                if !cancelled, movedDist <= PointerGestureConfig.tapMaxMovement {
                    extendTapChain(at: sample.viewPoint, time: sample.time)
                } else {
                    tapChain = nil
                }
            } else if sample.id == anchorID {
                relativeFingers.removeValue(forKey: sample.id)
            } else if let finger = relativeFingers.removeValue(forKey: sample.id) {
                let heldDuration = sample.time - finger.touchDownTime
                let movedDist = hypot(sample.viewPoint.x - finger.touchDown.x, sample.viewPoint.y - finger.touchDown.y)
                if !cancelled, heldDuration <= PointerGestureConfig.chordTapMaxDuration,
                   movedDist <= PointerGestureConfig.tapMaxMovement {
                    // Quick later-finger tap: buffer it through the SAME
                    // left tap-chain as the solo/anchor path (GOAL: any
                    // relative-session participant gets full click-count/
                    // tap-then-hold-drag semantics, not just a single
                    // click) — flushed by `poll()` or extended/converted by
                    // whatever touches it next, exactly like `tapBuffered`.
                    extendTapChain(at: sample.viewPoint, time: sample.time)
                }
            }
            if relativeFingers.isEmpty, relativeChainCandidateID == nil, relativeDragFingerID == nil {
                // The whole session has ended. A still-buffered click
                // (nobody continued it into a chain or a drag) must still
                // reach the wire — the tap really did happen — rather than
                // being silently lost by `resetToIdle()` below.
                out += flushTapChain()
                resetToIdle()
            }

        case .chordPending:
            chordIDs.remove(sample.id)
            chordPositions.removeValue(forKey: sample.id)
            if chordIDs.isEmpty {
                out += resolveChordRelease(at: sample.time, cancelled: cancelled)
                resumeAfterChord(at: sample.time)
            }

        case .twoFingerPending:
            chordIDs.remove(sample.id)
            chordPositions.removeValue(forKey: sample.id)
            if chordIDs.isEmpty {
                out += resolveChordRelease(at: sample.time, cancelled: cancelled)
                mode = .idle
                anchorID = nil
            }

        case .leftDragHeld:
            if sample.id == anchorID {
                out += releaseHeld()
                resetToIdle()
            }

        case .smartScroll:
            if sample.id == anchorID {
                out.append(.scrollEnded(momentum: !cancelled))
                resetToIdle()
            }

        case .rightDragHeld:
            chordIDs.remove(sample.id)
            chordPositions.removeValue(forKey: sample.id)
            if chordIDs.isEmpty {
                out += releaseHeld()
                chordIsContinuation = false
                resumeAfterChord(at: sample.time)
            }
        }
        return out
    }

    /// A right-click/drag chord (always anchor-based — see
    /// `promoteRelativeSessionToChord`, the only way into `.chordPending`)
    /// has just fully released. Resumes `.relativePointerSession` for the
    /// anchor if it's still physically down (from its live position — no
    /// jump); otherwise the whole session has ended.
    private func resumeAfterChord(at time: TimeInterval) {
        if let anchorID, liveTouchStart[anchorID] != nil {
            mode = .relativePointerSession
            let baseline = anchorViewPoint ?? .zero
            relativeFingers = [anchorID: RelativeFinger(lastPoint: baseline, touchDown: baseline, touchDownTime: time)]
        } else {
            mode = .idle
            self.anchorID = nil
            relativeFingers.removeAll()
        }
    }

    /// A chord (fresh two-finger, or a later-added chord on an active
    /// anchor) released before committing to a drag.
    ///
    /// A quick, low-movement release always buffers a new right tap,
    /// withheld in case a *further* chord continues it into a drag —
    /// exactly like the first tap. If THIS release was itself continuing
    /// an already-buffered tap (`chordIsContinuation`), that earlier tap
    /// is now confirmed final (nothing turned it into a drag — this chord
    /// also just tapped, not held) and is flushed immediately, rather than
    /// silently dropped: two ordinary two-finger taps in a row must both
    /// right-click, not swallow each other just because they landed within
    /// the same continuation window (a real-device bug — see GOAL "fresh
    /// two-finger right click is still broken/finicky"). Anything else
    /// (cancelled, moved too far, or held too long with no drag commit) is
    /// silently dropped — not a recognized gesture — and also finalizes
    /// any earlier continued tap with nothing to show for it.
    private func resolveChordRelease(at time: TimeInterval, cancelled: Bool) -> [PointerCommand] {
        let wasContinuation = chordIsContinuation
        chordIsContinuation = false
        guard !cancelled else { return [] }
        let heldDuration = time - chordStartTime
        let moved = hypot(chordCentroidLast.x - chordCentroidStart.x, chordCentroidLast.y - chordCentroidStart.y)
        guard heldDuration <= PointerGestureConfig.chordTapMaxDuration,
              moved <= PointerGestureConfig.tapMaxMovement else { return [] }
        pendingChordTap = PendingChordTap(point: chordCentroidLast, time: time)
        guard wasContinuation else { return [] }
        return [.mouseDown(button: .right, clickCount: 1), .mouseUp(button: .right, clickCount: 1)]
    }

    // MARK: - Tap-chain buffering (click counting + tap-then-hold drag)

    private func extendTapChain(at point: CGPoint, time: TimeInterval) {
        if let chain = tapChain,
           time - chain.lastReleaseTime <= PointerGestureConfig.tapChainWindow,
           hypot(point.x - chain.lastPoint.x, point.y - chain.lastPoint.y) <= PointerGestureConfig.tapChainMaxDistance {
            tapChain = TapChain(count: chain.count + 1, lastPoint: point, lastReleaseTime: time)
        } else {
            tapChain = TapChain(count: 1, lastPoint: point, lastReleaseTime: time)
        }
    }

    private func flushTapChain() -> [PointerCommand] {
        guard let chain = tapChain else { return [] }
        tapChain = nil
        return [.mouseDown(button: .left, clickCount: chain.count),
                .mouseUp(button: .left, clickCount: chain.count)]
    }

    private func flushPendingChordTap() -> [PointerCommand] {
        guard pendingChordTap != nil else { return [] }
        pendingChordTap = nil
        return [.mouseDown(button: .right, clickCount: 1),
                .mouseUp(button: .right, clickCount: 1)]
    }

    /// Commits `.firstTouchPending` to a solo `.absolutePointer` session —
    /// via movement evidence (`moved()`) or arbitration-window expiry
    /// (`poll()`). Emits the one-time `moveAbsolute` that starts live
    /// absolute tracking from here on, and seeds `anchorViewPoint` so a
    /// later relative-session transition (or chord pause/resume) always
    /// has a real baseline instead of falling back to some other touch's
    /// position or `.zero`.
    private func commitToAbsolutePointer(id: AnyHashable, normalized: CGPoint?, viewPoint: CGPoint) -> [PointerCommand] {
        pendingID = nil
        pendingStart = nil
        pendingLastNormalized = nil
        pendingLastView = nil
        anchorID = id
        anchorViewPoint = viewPoint
        mode = .absolutePointer
        guard let n = normalized else { return [] }
        anchorNormalized = n
        return [.moveAbsolute(x: Double(n.x), y: Double(n.y))]
    }

    /// Smart Touch counterpart of `commitToAbsolutePointer`, reached only
    /// when the Mac confirmed the touch-down target as scrollable. Parks
    /// the cursor once at the touch-down point (the point the Mac
    /// classified, and where macOS will deliver the scroll), fixes the
    /// scroll's axis lock from the first swipe's direction, then replays
    /// the pre-commit movement as the first scroll delta so content tracks
    /// the finger 1:1 from contact.
    private func commitToSmartScroll(id: AnyHashable, viewPoint: CGPoint) -> [PointerCommand] {
        // A probe is only ever issued for a touch-down with a real
        // normalized point, so `start.point` is never the `.zero` stand-in.
        let start = pendingStart
        pendingID = nil
        pendingStart = nil
        pendingLastNormalized = nil
        pendingLastView = nil
        anchorID = id
        anchorViewPoint = viewPoint
        mode = .smartScroll
        smartScrollLastView = viewPoint
        smartScrollAxis = .free
        var out: [PointerCommand] = []
        if let start {
            out.append(.moveAbsolute(x: Double(start.point.x), y: Double(start.point.y)))
            let dx = viewPoint.x - start.view.x
            let dy = viewPoint.y - start.view.y
            let ratio = PointerGestureConfig.smartScrollAxisLockRatio
            if abs(dy) >= abs(dx) * ratio {
                smartScrollAxis = .vertical
            } else if abs(dx) >= abs(dy) * ratio {
                smartScrollAxis = .horizontal
            }
            let (lockedDX, lockedDY) = lockedScrollDelta(dx: dx, dy: dy)
            if lockedDX != 0 || lockedDY != 0 { out.append(.scroll(dx: Double(lockedDX), dy: Double(lockedDY))) }
        }
        return out
    }

    private func lockedScrollDelta(dx: CGFloat, dy: CGFloat) -> (CGFloat, CGFloat) {
        switch smartScrollAxis {
        case .horizontal: return (dx, 0)
        case .vertical: return (0, dy)
        case .free: return (dx, dy)
        }
    }

    /// Smart Touch window drag, armed by a still hold on a recognized
    /// title bar (see `smartTouchTitleBarHoldDelay`): presses and holds the
    /// left button at the touch-down point — the point the Mac classified —
    /// so macOS moves the window exactly as it would for a mouse drag
    /// there. From here on it is an ordinary `.leftDragHeld`: the window
    /// follows the finger and the button releases when it lifts.
    private func armSmartWindowDrag(id: AnyHashable) -> [PointerCommand] {
        let start = pendingStart
        titleBarHoldActive = false
        pendingID = nil
        pendingStart = nil
        pendingLastNormalized = nil
        pendingLastView = nil
        anchorID = id
        mode = .leftDragHeld
        heldMouseButton = .left
        var out: [PointerCommand] = []
        if let start {
            out.append(.moveAbsolute(x: Double(start.point.x), y: Double(start.point.y)))
        }
        out.append(.mouseDown(button: .left, clickCount: 1))
        out.append(.smartTouchFeedback(.windowDragArmed))
        return out
    }

    /// Ends an outstanding title bar hold that did not arm.
    private func endTitleBarHold() -> [PointerCommand] {
        guard titleBarHoldActive else { return [] }
        titleBarHoldActive = false
        return [.smartTouchFeedback(.titleBarHoldCancelled)]
    }

    /// The Mac's answer to a `.probeScrollTarget` (`nil`: nothing Smart
    /// Touch acts on). Ignored unless it matches the current, still-
    /// undecided first touch's own probe, so a late reply from an earlier
    /// touch or session can never classify a newer one. If the finger
    /// already crossed `dragSlop` while waiting, the withheld commit
    /// happens now — a scroll, or plain Direct Touch (a title bar never
    /// drags without its hold). A still finger on a title bar starts the
    /// hold instead.
    @discardableResult
    func resolveSmartTouchProbe(id: Int, target: SmartTouchTarget?) -> [PointerCommand] {
        guard mode == .firstTouchPending, smartTouchProbe == .pending(id: id) else { return [] }
        smartTouchProbe = .resolved(target)
        guard smartTouchIsActive, let pid = pendingID, let start = pendingStart,
              let last = pendingLastView else { return [] }
        let movedPastSlop = hypot(last.x - start.view.x, last.y - start.view.y) > PointerGestureConfig.dragSlop
        switch target {
        case .scroll? where movedPastSlop:
            return commitToSmartScroll(id: pid, viewPoint: last)
        case .windowDrag? where !movedPastSlop:
            titleBarHoldActive = true
            let deadline = start.time + PointerGestureConfig.smartTouchTitleBarHoldDelay
            return [.smartTouchFeedback(.titleBarHoldBegan(deadline: deadline))]
        default:
            guard movedPastSlop else { return [] }
            return commitToAbsolutePointer(id: pid, normalized: pendingLastNormalized, viewPoint: last)
        }
    }

    /// Trackpad-mode counterpart of `commitToAbsolutePointer`: commits
    /// `.firstTouchPending` straight into a single-finger
    /// `.relativePointerSession` — reusing the exact same relative-delta
    /// machinery the existing hybrid (direct-mode second-finger precision)
    /// path already uses, just seeded with only the anchor instead of an
    /// anchor-plus-partner. Emits NO command: unlike the absolute path,
    /// touching down must never move/jump the cursor (PRODUCT RULE). The
    /// baseline is the touch's CURRENT point (not its original touch-down
    /// point), so the small pre-commit movement that crossed `dragSlop` is
    /// absorbed rather than replayed as a jump — same convention as
    /// `commitRelativeLeftDrag`.
    private func commitToRelativePointerSession(id: AnyHashable, viewPoint: CGPoint, time: TimeInterval) -> [PointerCommand] {
        pendingID = nil
        pendingStart = nil
        pendingLastNormalized = nil
        pendingLastView = nil
        anchorID = id
        anchorViewPoint = viewPoint
        sessionIsRelative = true
        mode = .relativePointerSession
        relativeFingers = [id: RelativeFinger(lastPoint: viewPoint, touchDown: viewPoint, touchDownTime: time)]
        return []
    }

    /// Trackpad-mode counterpart of `beginLeftDrag`: a fresh touch
    /// continuing a buffered tap chain commits to a held left-button drag
    /// that tracks RELATIVELY from here on, reusing `commitRelativeLeftDrag`
    /// (normally reached only from within an already-active
    /// `.relativePointerSession`) by first establishing that session with
    /// just this one finger as its anchor. Emits no move — the button posts
    /// at the Mac's current cursor position, exactly like the hybrid path's
    /// tap-then-hold-drag.
    private func beginTrackpadDrag(id: AnyHashable, at point: CGPoint, time: TimeInterval) -> [PointerCommand] {
        pendingID = nil
        pendingStart = nil
        pendingLastNormalized = nil
        pendingLastView = nil
        anchorID = id
        sessionIsRelative = true
        mode = .relativePointerSession
        return commitRelativeLeftDrag(id: id, at: point)
    }

    /// Commits a buffered tap chain into a held left-button drag, starting
    /// at the drag touch's current position (`normalized`) so the drag —
    /// and the cursor — begin exactly where the finger already is, not
    /// wherever the cursor last happened to be.
    private func beginLeftDrag(id: AnyHashable, normalized: CGPoint?) -> [PointerCommand] {
        let clickCount = tapChain?.count ?? 0
        tapChain = nil
        pendingID = nil
        pendingStart = nil
        pendingLastNormalized = nil
        pendingLastView = nil
        anchorID = id
        mode = .leftDragHeld
        heldMouseButton = .left
        var out: [PointerCommand] = []
        if let n = normalized {
            out.append(.moveAbsolute(x: Double(n.x), y: Double(n.y)))
        }
        out.append(.mouseDown(button: .left, clickCount: max(clickCount, 1)))
        return out
    }

    /// Commits a relative-session finger's buffered tap chain into a held
    /// left-button drag — the `.relativePointerSession` counterpart of
    /// `beginLeftDrag`. Deliberately emits NO move command: the button
    /// posts at the Mac's current cursor position (never the touch
    /// location — GOAL "do not switch back to absolute movement"), and
    /// `point` seeds the finger's own relative baseline going forward, so
    /// the small pre-commit drag-slop movement that triggered this is
    /// simply absorbed rather than replayed as a jump.
    private func commitRelativeLeftDrag(id: AnyHashable, at point: CGPoint) -> [PointerCommand] {
        let clickCount = tapChain?.count ?? 0
        tapChain = nil
        relativeChainCandidateID = nil
        relativeChainCandidateStart = nil
        relativeChainCandidateLastView = nil
        relativeFingers[id] = RelativeFinger(lastPoint: point, touchDown: point, touchDownTime: 0)
        relativeDragFingerID = id
        heldMouseButton = .left
        return [.mouseDown(button: .left, clickCount: max(clickCount, 1))]
    }

    private func commitRightDrag() -> [PointerCommand] {
        chordIsContinuation = false
        pendingChordTap = nil
        mode = .rightDragHeld
        heldMouseButton = .right
        return [.mouseDown(button: .right, clickCount: 1)]
    }

    /// Switches the primary one-finger pointer model. A no-op when already
    /// in `newMode`; otherwise fully cancels whatever touch/click/drag
    /// session is in flight (same guarantee as `reset()` — no stuck button,
    /// no stale tracked touch) before adopting the new mode, so the very
    /// next gesture starts completely clean. MUST be called instead of
    /// mutating `inputMode` directly.
    @discardableResult
    func setInputMode(_ newMode: PointerInputMode) -> [PointerCommand] {
        guard newMode != inputMode else { return [] }
        let out = reset()
        inputMode = newMode
        return out
    }

    // MARK: - Safety / cleanup

    /// Releases any held synthetic button and returns the receiver to
    /// `.idle`. MUST be called on disconnect, input-disable, pause, or
    /// gesture cancellation — see `cancelActiveInput` parity on the Mac
    /// side (`InputInjector.cancelActiveInputLocked`). Idempotent.
    @discardableResult
    func releaseHeld() -> [PointerCommand] {
        guard let button = heldMouseButton else { return [] }
        heldMouseButton = nil
        return [.mouseUp(button: button, clickCount: 0)]
    }

    /// Full reset — releases any held button and forgets every tracked
    /// touch. Use for disconnect/pause/system-gesture takeover.
    @discardableResult
    func reset() -> [PointerCommand] {
        let out = endTitleBarHold() + releaseHeld()
        resetToIdle()
        return out
    }

    private func resetToIdle() {
        mode = .idle
        anchorID = nil
        anchorNormalized = nil
        anchorViewPoint = nil
        sessionIsRelative = false
        relativeFingers.removeAll()
        relativeChainCandidateID = nil
        relativeChainCandidateStart = nil
        relativeChainCandidateLastView = nil
        relativeDragFingerID = nil
        chordIDs.removeAll()
        chordPositions.removeAll()
        chordIsContinuation = false
        pendingChordTap = nil
        pendingID = nil
        pendingStart = nil
        pendingLastNormalized = nil
        pendingLastView = nil
        tapChain = nil
        liveTouchStart.removeAll()
        heldMouseButton = nil
        smartTouchProbe = .none
        smartScrollLastView = nil
        smartScrollAxis = .free
        titleBarHoldActive = false
    }
}

// MARK: - App Gesture Command routing (H/I)

/// Converts continuous pinch/rotation magnitude into discrete, rate-limited
/// App Gesture Commands. Pure accumulator, no I/O: the caller (the pinch/
/// rotation gesture recognizer's `.changed` handler) feeds incremental
/// magnitude each update and fires whatever commands come back, in whichever
/// direction they're returned.
///
/// One deterministic routing path only — this replaces continuous native
/// gesture injection (`sendNativeAppGesture`) for App mode, never runs
/// alongside it. Positive `direction` on the returned `AppGestureCommandFire`
/// corresponds to "outward"/"clockwise" (Zoom In / Rotate Right); negative to
/// "inward"/"counter-clockwise" (Zoom Out / Rotate Left).
struct AppGestureCommandAccumulator {
    private var total: Double = 0
    private var direction: Int = 0
    /// How many fires this same directional run has already produced —
    /// tracked so a later call only reports the newly-crossed repeats, not
    /// the ones already returned.
    private var firedCount: Int = 0
    private let threshold: Double
    private let step: Double
    private let maxFiresPerUpdate: Int

    /// `threshold`/`step` are in the caller's own magnitude units (log-scale
    /// ratio for pinch, radians for rotation) — see the call sites below.
    init(threshold: Double, step: Double, maxFiresPerUpdate: Int = 4) {
        self.threshold = threshold
        self.step = step
        self.maxFiresPerUpdate = maxFiresPerUpdate
    }

    /// Gesture start, end, or cancellation all rebase cleanly — no partial
    /// carry-over into the next gesture.
    mutating func reset() {
        total = 0
        direction = 0
        firedCount = 0
    }

    /// `delta` is the incremental magnitude since the last call in this same
    /// gesture (positive one way, negative the other). Returns a signed fire
    /// count: its magnitude is how many commands to send now (0 when still
    /// under threshold — jitter below threshold is silently absorbed), its
    /// sign which direction. A larger `delta` can return more than 1 in a
    /// single call (proportional repeat: the first fire needs `threshold`
    /// total movement, each further one only another `step`), capped at
    /// `maxFiresPerUpdate` per call so a fast flick can't spam commands
    /// unboundedly in one update — any backlog beyond the cap is still
    /// tracked and reported on a later call.
    mutating func advance(by delta: Double) -> Int {
        guard delta.isFinite, delta != 0 else { return 0 }
        let newDirection = delta > 0 ? 1 : -1
        if direction != 0, newDirection != direction {
            // Reversal: a partial in-flight accumulation toward the old
            // direction is discarded rather than partially cancelled, so the
            // new direction starts from a clean, predictable baseline.
            total = 0
            firedCount = 0
        }
        direction = newDirection
        total += abs(delta)

        guard total >= threshold else { return 0 }
        let possibleFires = 1 + Int((total - threshold) / step)
        let newFires = min(possibleFires - firedCount, maxFiresPerUpdate)
        guard newFires > 0 else { return 0 }
        firedCount += newFires
        return direction * newFires
    }
}

enum AppGestureCommandRouting {
    /// ~35% relative pinch before the first Zoom In/Out, then another ~18%
    /// per repeat — deliberately coarser than the viewport's own pinch-to-
    /// zoom feel, since each fire is a whole discrete keyboard command
    /// rather than continuous scale.
    static let pinchThreshold = log(1.35)
    static let pinchStep = log(1.18)
    /// ~25° before the first Rotate Left/Right, then another ~15° per
    /// repeat.
    static let rotationThreshold = Double.pi / 7.2   // 25°
    static let rotationStep = Double.pi / 12          // 15°

    static func makePinchAccumulator() -> AppGestureCommandAccumulator {
        AppGestureCommandAccumulator(threshold: pinchThreshold, step: pinchStep)
    }

    static func makeRotationAccumulator() -> AppGestureCommandAccumulator {
        AppGestureCommandAccumulator(threshold: rotationThreshold, step: rotationStep)
    }
}

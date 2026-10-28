package com.raisecaterror.meowdisplay.core.controls

// Ported from Shared/PointerGestureEngine.swift.

import kotlin.math.abs
import kotlin.math.hypot
import kotlin.math.ln
import kotlin.math.max
import kotlin.math.min

/** One synthetic mouse button the engine can hold down. */
enum class PointerButton {
    Left,
    Right;

    /** The wire string this button is sent/received as (`"left"`/`"right"`). */
    val wireValue: String
        get() = when (this) {
            Left -> "left"
            Right -> "right"
        }

    companion object {
        /**
         * Parses an untrusted wire value. Senders MUST ignore an unrecognized/malformed
         * `button` field rather than treat it as fatal, mirroring `HIDKeyUsage.parse`.
         */
        fun parse(value: Any?): PointerButton? = when (value as? String) {
            "left" -> Left
            "right" -> Right
            else -> null
        }
    }
}

/**
 * A pure, ordered instruction for the caller to turn into a wire message.
 * `MoveAbsolute`/`MoveRelative` never imply a button; button state is carried
 * explicitly by `MouseDown`/`MouseUp` (PRODUCT RULE: ordinary cursor movement
 * never implies mouseDown).
 */
sealed interface PointerCommand {
    /** Move the Mac cursor to this normalized remote-space point. */
    data class MoveAbsolute(val x: Double, val y: Double) : PointerCommand

    /**
     * Move the Mac cursor relatively by this delta, in the same view-local point units as the
     * `PointerTouchSample`s that produced it (NOT normalized remote-space) - the caller converts
     * through the current viewport scale into video pixels before sending, like `Scroll`.
     */
    data class MoveRelative(val dx: Double, val dy: Double) : PointerCommand

    data class MouseDown(val button: PointerButton, val clickCount: Int) : PointerCommand
    data class MouseUp(val button: PointerButton, val clickCount: Int) : PointerCommand

    /**
     * Smart Touch (Experimental): ask the Mac what the Accessibility element under this normalized
     * point is - a scrollable container, a window title bar, or neither. The answer comes back
     * through `resolveSmartTouchProbe(id, target)`.
     */
    data class ProbeScrollTarget(val id: Int, val x: Double, val y: Double) : PointerCommand

    /**
     * Smart Touch one-finger scroll delta, in the same view-local point units as `MoveRelative`
     * (natural-scrolling direction, like the two-finger scroll path).
     */
    data class Scroll(val dx: Double, val dy: Double) : PointerCommand

    /** The Smart Touch scroll finger lifted (`momentum = true`) or was cancelled (`false`). */
    data class ScrollEnded(val momentum: Boolean) : PointerCommand

    /** Smart Touch hold feedback for the receiver to render as haptics. Local only. */
    data class SmartTouchFeedback(
        val feedback: com.raisecaterror.meowdisplay.core.controls.SmartTouchFeedback,
    ) : PointerCommand
}

/**
 * The moments of a Smart Touch hold the receiver confirms with haptics. The engine emits these
 * whether or not haptics are on; they never change what the gesture does.
 */
sealed interface SmartTouchFeedback {
    /** A long press on an ordinary Smart Touch target dropped this touch into plain Direct Touch. */
    data object DirectTouchOverride : SmartTouchFeedback

    /**
     * A still finger on a recognized title bar started building toward a window drag, which arms
     * at [deadline] (touch-sample time base).
     */
    data class TitleBarHoldBegan(val deadline: TimeInterval) : SmartTouchFeedback

    /** That title bar hold ended without arming: the finger lifted, moved away, or was cancelled. */
    data object TitleBarHoldCancelled : SmartTouchFeedback

    /** The title bar hold reached its threshold: the left button is now held and the window follows. */
    data object WindowDragArmed : SmartTouchFeedback
}

/** What the Mac confidently identified under a Smart Touch touch-down. */
enum class SmartTouchTarget {
    /** A standard scroll container: a one-finger swipe scrolls it. */
    Scroll,

    /** A window title bar or empty toolbar space: touch and hold, then drag, moves the window. */
    WindowDrag,
}

/**
 * One raw touch sample fed into the engine. `id` must be stable for a given physical finger's
 * lifetime. `normalized` is the touch's location mapped through the current
 * `RemoteViewportTransform`; null when it falls outside the rendered video (the engine still
 * tracks it for arbitration/counting purposes but never emits an absolute move for it).
 */
data class PointerTouchSample(
    val id: Any,
    val phase: Phase,
    val viewPoint: CGPoint,
    val normalized: CGPoint?,
    val time: TimeInterval,
) {
    enum class Phase { Began, Moved, Ended, Cancelled }
}

/** Tunable timing/distance thresholds. Grouped so tests and the real recognizer share one source of truth. */
object PointerGestureConfig {
    /** Movement (view points) under which a released touch still counts as a tap. */
    const val tapMaxMovement: CGFloat = 10.0

    /**
     * How long after a completed tap the engine waits to see whether a new touch continues the
     * chain (another tap, or a held drag start) before flushing the buffered click(s). Applies to
     * both the single-finger left-click chain and the two-finger right-click chain.
     */
    const val tapChainWindow: TimeInterval = 0.22

    /** Maximum distance between consecutive taps' points to count as the same chain. */
    const val tapChainMaxDistance: CGFloat = 40.0

    /**
     * A new touch (or chord) held this long without releasing, following a buffered tap, commits
     * as a drag start rather than another tap - even with no movement at all (see `poll(now)`).
     */
    const val holdCommitDelay: TimeInterval = 0.15

    /** Movement (view points) that commits a still-undecided held touch/chord to a drag immediately. */
    const val dragSlop: CGFloat = 10.0

    /**
     * A later finger's (or fresh chord's) release within this long, under `tapMaxMovement`, is a
     * tap (left click for one later finger, right click for a fresh/later two-finger chord)
     * rather than the start of a held drag.
     */
    const val chordTapMaxDuration: TimeInterval = 0.3

    /**
     * How long the very first touch of a fresh sequence is held as `FirstTouchPending` before
     * committing to a solo absolute-pointer session with no second finger having joined - ONLY a
     * time-based fallback; movement beyond `dragSlop` commits immediately. Real-device testing
     * showed 80ms was too tight for a deliberate two-finger tap; 150ms is still well under the
     * ~250-300ms a stationary hold needs to read as deliberately slow.
     */
    const val firstTouchArbitrationWindow: TimeInterval = 0.15

    /**
     * Smart Touch (Experimental): once the Mac has confidently classified the touch-down target, a
     * finger held still this long drops into plain Direct Touch for the rest of that touch.
     */
    const val smartTouchLongPressDelay: TimeInterval = 0.4

    /**
     * Smart Touch window drag: how long a finger must stay still (within `dragSlop`) on a
     * recognized title bar, measured from touch-down, before the drag arms.
     */
    const val smartTouchTitleBarHoldDelay: TimeInterval = 0.5

    /**
     * Smart Touch scroll direction lock: a first swipe whose dominant axis is at least this many
     * times the other scrolls on that axis only. Anything more diagonal pans freely.
     */
    const val smartScrollAxisLockRatio: CGFloat = 2.0

    /**
     * Bounds for `PointerGestureEngine.trackpadSensitivity` - a plain linear multiplier on
     * Trackpad's primary one-finger relative delta. `1.0` reproduces the pre-setting speed.
     */
    val trackpadSensitivityRange: ClosedFloatingPointRange<Double> = 0.5..2.0
    const val defaultTrackpadSensitivity: Double = 1.0
}

/**
 * User-selectable primary one-finger pointer model. Persisted receiver preference; only changes
 * the FIRST finger's semantics. Stable raw values: written to disk.
 */
enum class PointerInputMode(val raw: String) {
    /**
     * The first finger maps directly to the corresponding Mac coordinates. The hybrid behavior (a
     * later finger promotes the session to relative/precision tracking) still applies on top.
     */
    Direct("direct"),

    /** The first finger moves the Mac cursor RELATIVE to wherever it already is, like a laptop trackpad. */
    Trackpad("trackpad");

    val id: String get() = raw

    /**
     * Direct Touch scrolls target the content under the fingers. Trackpad scrolls stay at the Mac
     * cursor and must not emit a parallel absolute touch move while a right-click chord is forming.
     */
    val seedsAbsoluteScrollTarget: Boolean get() = this == Direct

    val title: String
        get() = when (this) {
            Direct -> "Direct Touch"
            Trackpad -> "Trackpad"
        }

    val explanation: String
        get() = when (this) {
            Direct -> "Touch where you want the pointer."
            Trackpad -> "Move the pointer relative to your finger."
        }

    companion object {
        fun of(raw: String?): PointerInputMode? = entries.firstOrNull { it.raw == raw }
    }
}

/**
 * Explicit macro-states the engine can be in. Named after the product model rather than the full
 * cross product of every tracked touch; once `mode` leaves `Idle` it only changes through the
 * engine's own transition methods.
 */
enum class PointerEngineMode {
    /** Nothing down. */
    Idle,

    /**
     * Exactly one touch down, not yet committed to anything. Emits NO wire commands. Resolves into
     * a fresh two-finger sequence, a buffered tap, a left drag (continuing a buffered tap chain),
     * or `AbsolutePointer` (movement evidence or the arbitration window expires).
     */
    FirstTouchPending,

    /** A solo touch is the committed absolute-pointer anchor and is physically down. No button held. */
    AbsolutePointer,

    /**
     * No touch is down, but a completed tap (or tap chain) is buffered in case a new touch
     * continues the chain. A brand-new touch here re-enters `FirstTouchPending`.
     */
    TapBuffered,

    /** The left button is down and dragging (tap-then-hold committed). */
    LeftDragHeld,

    /** Two (or three) fingers arrived together, fresh, undecided between a right-click tap and a right-button drag. */
    TwoFingerPending,

    /** The right button is down and dragging. */
    RightDragHeld,

    /**
     * A precision/relative pointer session: an anchor plus at least one later finger - the WHOLE
     * session moves the cursor relatively from here on; no finger in it may emit `MoveAbsolute`
     * again until every finger lifts and a fresh sequence begins. A third finger promotes the
     * non-anchor member + the new touch into a chord (`ChordPending`), pausing the anchor.
     */
    RelativePointerSession,

    /** An anchor is active (a paused relative session) and two later fingers are forming a chord. */
    ChordPending,

    /**
     * Smart Touch (Experimental): a solo Direct Touch finger whose touch-down target the Mac
     * confirmed as scrollable, committed to one-finger scrolling. Locked until that finger lifts.
     * (A Smart Touch window drag needs no mode of its own: it is an ordinary `LeftDragHeld`.)
     */
    SmartScroll,

    /** 3+ fingers arrived together, fresh, with no established anchor. The engine steps aside entirely. */
    DeferredSystemGesture,
}

/**
 * The receiver's pointer/click gesture policy - a pure, testable touch-intent/session model.
 *
 * Ownership rules:
 * 1. A touch sequence acquires an owner (`mode`) and, once committed, does not oscillate.
 * 2. Later-added touches can have different semantics from touches that began together.
 * 3. Mouse buttons are only held while an explicit drag interaction owns the sequence.
 * 4. Ordinary cursor movement never implies mouseDown.
 * 5. Once a pointer session goes relative, no finger in it may emit `MoveAbsolute` again for the
 *    rest of that session.
 *
 * Not thread-safe; drive it from one queue.
 */
class PointerGestureEngine {
    var mode: PointerEngineMode = PointerEngineMode.Idle
        private set

    /**
     * The primary one-finger pointer model. Only consulted when a fresh first-touch session
     * commits; changing it mid-session does nothing until the next commit, so the caller MUST
     * change it through `setInputMode` (which cancels any session in flight).
     */
    var inputMode: PointerInputMode = PointerInputMode.Direct
        private set

    /**
     * Linear multiplier on Trackpad's primary one-finger relative delta. Clamped on assignment so
     * a bad persisted/UI value can never leave the sane range. Safe to change mid-session.
     */
    var trackpadSensitivity: Double = PointerGestureConfig.defaultTrackpadSensitivity
        set(value) {
            val range = PointerGestureConfig.trackpadSensitivityRange
            field = min(max(value, range.start), range.endInclusive)
        }

    /**
     * Smart Touch (Experimental). Only ever consulted for a fresh solo finger in Direct mode with
     * no tap chain buffered; Trackpad and every multi-finger path ignore it.
     */
    var smartTouchEnabled: Boolean = false

    private val smartTouchIsActive: Boolean get() = smartTouchEnabled && inputMode == PointerInputMode.Direct

    /**
     * Whether the Mac has classified the current `FirstTouchPending` finger's touch-down target
     * (`Resolved(null)`: nothing Smart Touch acts on).
     */
    private sealed interface SmartTouchProbeState {
        data object None : SmartTouchProbeState
        data class Pending(val id: Int) : SmartTouchProbeState
        data class Resolved(val target: SmartTouchTarget?) : SmartTouchProbeState
    }

    private var smartTouchProbe: SmartTouchProbeState = SmartTouchProbeState.None
    private var nextSmartTouchProbeID = 0
    private var smartScrollLastView: CGPoint? = null

    /** Axes a Smart Touch scroll may move on, fixed at commit - see `smartScrollAxisLockRatio`. */
    private enum class SmartScrollAxis { Horizontal, Vertical, Free }

    private var smartScrollAxis = SmartScrollAxis.Free

    /** Whether a `TitleBarHoldBegan` is outstanding, so every way out short of arming reports `TitleBarHoldCancelled` once. */
    private var titleBarHoldActive = false

    /**
     * The confidently classified target of a still-undecided Smart Touch first touch. While set, a
     * stationary finger waits for the long-press override (or, on a title bar, the window-drag
     * hold) instead of committing at the arbitration window.
     */
    private val smartTouchDeferredTarget: SmartTouchTarget?
        get() {
            val probe = smartTouchProbe
            if (!smartTouchIsActive || tapChain != null || probe !is SmartTouchProbeState.Resolved) return null
            return probe.target
        }

    /**
     * Whether the current `ChordPending`/`TwoFingerPending` chord was recognized as continuing a
     * just-buffered right tap. Exposed so the UI layer can withhold the legacy scroll/pinch
     * recognizer from a chord this engine has already claimed as a right-drag candidate.
     */
    val isChordContinuation: Boolean get() = chordIsContinuation

    // The anchor touch (finger 1) once an absolute/relative pointer session exists. Persists as a
    // session identity for the session's whole lifetime - including through a later chord that
    // temporarily pauses it - and is cleared only by resetToIdle().
    private var anchorID: Any? = null
    private var anchorNormalized: CGPoint? = null   // last known normalized point (absolute mode only)
    private var anchorViewPoint: CGPoint? = null    // last known view-local point, kept fresh in every mode

    // Once true, stays true for the rest of this session.
    private var sessionIsRelative = false

    // Fingers currently contributing relative deltas within RelativePointerSession - at most the
    // anchor plus one other at a time. Insertion-ordered (Swift's Dictionary order is arbitrary).
    private data class RelativeFinger(
        val lastPoint: CGPoint,       // updated every sample; the delta source
        val touchDown: CGPoint,       // immutable; for the tap-vs-drag movement check
        val touchDownTime: TimeInterval,
    )

    private val relativeFingers: MutableMap<Any, RelativeFinger> = LinkedHashMap()

    // A later relative-session finger's touch that MIGHT be continuing a buffered left tap chain.
    // Emits nothing while undecided; only joins relativeFingers once it commits to a held drag.
    private data class ViewStart(val view: CGPoint, val time: TimeInterval)

    private var relativeChainCandidateID: Any? = null
    private var relativeChainCandidateStart: ViewStart? = null
    // Refreshed on every moved() sample so a time-based drag commit has a current position.
    private var relativeChainCandidateLastView: CGPoint? = null
    // The relative-session finger currently holding the left button down. Null whenever
    // heldMouseButton is not Left.
    private var relativeDragFingerID: Any? = null

    // Touches composing the current chord (two-finger-tap / right-drag).
    private var chordIDs: MutableSet<Any> = LinkedHashSet()
    private var chordStartTime: TimeInterval = 0.0
    private var chordCentroidStart: CGPoint = CGPoint.zero
    private var chordCentroidLast: CGPoint = CGPoint.zero
    private val chordPositions: MutableMap<Any, CGPoint> = LinkedHashMap()
    // Whether this chord was recognized as continuing a just-buffered right tap - if so, its
    // resolution replaces the buffered tap rather than adding a second one.
    private var chordIsContinuation = false

    // The single touch tracked while FirstTouchPending.
    private data class PendingStart(val point: CGPoint, val view: CGPoint, val time: TimeInterval, val normalized: CGPoint? = null)

    private var pendingID: Any? = null
    private var pendingStart: PendingStart? = null
    // Refreshed on every moved() sample while still FirstTouchPending so a time-based commit has a
    // current position even though no command was emitted for any of those samples.
    private var pendingLastNormalized: CGPoint? = null
    private var pendingLastView: CGPoint? = null

    // Buffered single-finger tap chain: a completed tap (or chain) not yet flushed to the wire.
    private data class TapChain(
        val count: Int,
        val lastPoint: CGPoint,       // view-local, for chain-distance checks
        val lastReleaseTime: TimeInterval,
    )

    private var tapChain: TapChain? = null

    // Buffered right-click chord tap, withheld in case a second chord touches down shortly after
    // and is held (right-button drag) rather than released again.
    private data class PendingChordTap(val point: CGPoint, val time: TimeInterval)

    private var pendingChordTap: PendingChordTap? = null

    // Touches currently down, keyed by id, with their first-seen time.
    private val liveTouchStart: MutableMap<Any, TimeInterval> = LinkedHashMap()

    /**
     * At most one explicit drag may own a mouse button at a time. Tap clicks are emitted as
     * matched down/up command pairs and never enter this held state.
     */
    var heldMouseButton: PointerButton? = null
        private set

    // MARK: - Touch lifecycle

    /** Feed one raw touch sample. Returns the ordered commands to send. */
    fun handle(sample: PointerTouchSample): List<PointerCommand> = when (sample.phase) {
        PointerTouchSample.Phase.Began -> began(sample)
        PointerTouchSample.Phase.Moved -> moved(sample)
        PointerTouchSample.Phase.Ended -> ended(sample, cancelled = false)
        PointerTouchSample.Phase.Cancelled -> ended(sample, cancelled = true)
    }

    /**
     * Time-driven transitions with no new touch sample: the first-touch arbitration window, the
     * tap-chain/chord-tap grace windows, and the hold-commit delay for a held (possibly
     * stationary) touch/chord. The caller schedules this after the relevant delay (see
     * `pollDelay`) - the engine itself starts no timers.
     */
    fun poll(now: TimeInterval): List<PointerCommand> {
        val out = ArrayList<PointerCommand>()
        val pStart = pendingStart
        val pid = pendingID
        if (mode == PointerEngineMode.FirstTouchPending && pStart != null && pid != null) {
            if (tapChain != null) {
                if (now - pStart.time >= PointerGestureConfig.holdCommitDelay) {
                    out += if (inputMode == PointerInputMode.Trackpad) {
                        beginTrackpadDrag(pid, pendingLastView ?: pStart.view, now)
                    } else {
                        beginLeftDrag(pid, pStart.normalized, pendingLastNormalized)
                    }
                }
            } else if (smartTouchDeferredTarget != null) {
                when (smartTouchDeferredTarget) {
                    SmartTouchTarget.Scroll -> {
                        // Smart Touch long-press override: held still on a confidently classified
                        // target, this touch becomes plain Direct Touch - confirmed with a haptic.
                        if (now - pStart.time >= PointerGestureConfig.smartTouchLongPressDelay) {
                            out += commitToAbsolutePointer(pid, pendingLastNormalized, pendingLastView ?: pStart.view)
                            out.add(PointerCommand.SmartTouchFeedback(SmartTouchFeedback.DirectTouchOverride))
                        }
                    }
                    SmartTouchTarget.WindowDrag -> {
                        // Held still on a title bar long enough: the window drag arms instead of
                        // the Direct Touch override.
                        if (now - pStart.time >= PointerGestureConfig.smartTouchTitleBarHoldDelay) {
                            out += armSmartWindowDrag(pid)
                        }
                    }
                    null -> {}
                }
            } else if (now - pStart.time >= PointerGestureConfig.firstTouchArbitrationWindow) {
                // Same chord-continuation deferral as moved(). Tied to the buffered tap's OWN
                // tapChainWindow (not firstTouchArbitrationWindow, which is already exactly this
                // branch's own trigger), so this is never left stuck: pollDelay's pendingChordTap
                // branch schedules a re-check for when that window closes.
                if (inputMode == PointerInputMode.Trackpad &&
                    isPlausibleChordContinuationCandidate(pStart.view, now)
                ) {
                    // withheld - see above
                } else {
                    val viewPoint = pendingLastView ?: pStart.view
                    out += if (inputMode == PointerInputMode.Trackpad) {
                        commitToRelativePointerSession(pid, viewPoint, now)
                    } else {
                        commitToAbsolutePointer(pid, pendingLastNormalized, viewPoint)
                    }
                }
            }
        }
        run {
            val candidateID = relativeChainCandidateID
            val start = relativeChainCandidateStart
            if (mode == PointerEngineMode.RelativePointerSession && candidateID != null && start != null &&
                now - start.time >= PointerGestureConfig.holdCommitDelay
            ) {
                out += commitRelativeLeftDrag(candidateID, relativeChainCandidateLastView ?: start.view)
            }
        }
        run {
            val chain = tapChain
            if (mode == PointerEngineMode.TapBuffered && chain != null &&
                now - chain.lastReleaseTime >= PointerGestureConfig.tapChainWindow
            ) {
                out += flushTapChain()
                mode = PointerEngineMode.Idle
            }
        }
        run {
            val chain = tapChain
            if (mode == PointerEngineMode.RelativePointerSession && relativeChainCandidateID == null && chain != null &&
                now - chain.lastReleaseTime >= PointerGestureConfig.tapChainWindow
            ) {
                out += flushTapChain()
            }
        }
        run {
            val pending = pendingChordTap
            if (pending != null && now - pending.time >= PointerGestureConfig.tapChainWindow &&
                chordIDs.isEmpty() && !hasPendingChordContinuationStart(now)
            ) {
                out += flushPendingChordTap()
            }
        }
        if ((mode == PointerEngineMode.ChordPending || mode == PointerEngineMode.TwoFingerPending) &&
            chordIsContinuation && chordIDs.isNotEmpty() &&
            now - chordStartTime >= PointerGestureConfig.holdCommitDelay
        ) {
            out += commitRightDrag()
        }
        return out
    }

    /**
     * Delay until the next state transition that requires `poll(now)`. Independent of `mode`:
     * buffered clicks belong to their own finger/chord interaction and can outlive the pointer
     * session that produced them. Null when nothing is scheduled.
     */
    fun pollDelay(now: TimeInterval): TimeInterval? {
        val deadlines = ArrayList<TimeInterval>()

        val start = pendingStart
        if (mode == PointerEngineMode.FirstTouchPending && start != null && pendingID != null) {
            val target = smartTouchDeferredTarget
            val delay: TimeInterval = if (tapChain != null) {
                PointerGestureConfig.holdCommitDelay
            } else if (target != null) {
                if (target == SmartTouchTarget.WindowDrag) {
                    PointerGestureConfig.smartTouchTitleBarHoldDelay
                } else {
                    PointerGestureConfig.smartTouchLongPressDelay
                }
            } else {
                PointerGestureConfig.firstTouchArbitrationWindow
            }
            deadlines.add(start.time + delay)
        }
        val candidateStart = relativeChainCandidateStart
        if (mode == PointerEngineMode.RelativePointerSession && candidateStart != null) {
            deadlines.add(candidateStart.time + PointerGestureConfig.holdCommitDelay)
        }
        val chain = tapChain
        if (chain != null && relativeChainCandidateID == null && mode != PointerEngineMode.FirstTouchPending) {
            deadlines.add(chain.lastReleaseTime + PointerGestureConfig.tapChainWindow)
        }
        val pending = pendingChordTap
        if (pending != null && chordIDs.isEmpty()) {
            val tapDeadline = pending.time + PointerGestureConfig.tapChainWindow
            val startTime = pendingChordContinuationStartTime
            if (startTime != null) {
                deadlines.add(max(tapDeadline, startTime + PointerGestureConfig.firstTouchArbitrationWindow))
            } else {
                deadlines.add(tapDeadline)
            }
        }
        if ((mode == PointerEngineMode.ChordPending || mode == PointerEngineMode.TwoFingerPending) &&
            chordIsContinuation && chordIDs.isNotEmpty()
        ) {
            deadlines.add(chordStartTime + PointerGestureConfig.holdCommitDelay)
        }

        val deadline = deadlines.minOrNull() ?: return null
        return max(0.0, deadline - now)
    }

    /**
     * Keep a right-tap candidate alive when the first finger of its next chord has landed within
     * the continuation window, even if the partner finger arrives just after the deadline.
     */
    private val pendingChordContinuationStartTime: TimeInterval?
        get() {
            val pending = pendingChordTap ?: return null

            fun isEligibleStart(point: CGPoint, time: TimeInterval): TimeInterval? {
                val elapsed = time - pending.time
                if (!(elapsed >= 0 &&
                        elapsed <= PointerGestureConfig.tapChainWindow &&
                        hypot(point.x - pending.point.x, point.y - pending.point.y) <=
                        PointerGestureConfig.tapChainMaxDistance)
                ) return null
                return time
            }

            val start = pendingStart
            if (mode == PointerEngineMode.FirstTouchPending && start != null) {
                return isEligibleStart(start.view, start.time)
            }
            if (mode == PointerEngineMode.RelativePointerSession) {
                return relativeFingers
                    .filter { it.key != anchorID }
                    .mapNotNull { isEligibleStart(it.value.touchDown, it.value.touchDownTime) }
                    .minOrNull()
            }
            return null
        }

    private fun hasPendingChordContinuationStart(time: TimeInterval): Boolean {
        val start = pendingChordContinuationStartTime ?: return false
        return time - start < PointerGestureConfig.firstTouchArbitrationWindow
    }

    /**
     * Whether a lone `FirstTouchPending` finger sitting at `viewPoint` (its own touch-down point)
     * could still be joined by a partner to continue `pendingChordTap` into a chord - mirrors
     * `promoteToChord`'s distance/timing check. Trackpad-mode call sites use this to withhold a
     * solo commit until the continuation possibility has genuinely passed.
     */
    private fun isPlausibleChordContinuationCandidate(viewPoint: CGPoint, time: TimeInterval): Boolean {
        val pending = pendingChordTap ?: return false
        val elapsed = time - pending.time
        if (!(elapsed >= 0 && elapsed <= PointerGestureConfig.tapChainWindow)) return false
        return hypot(viewPoint.x - pending.point.x, viewPoint.y - pending.point.y) <=
            PointerGestureConfig.tapChainMaxDistance
    }

    private fun began(sample: PointerTouchSample): List<PointerCommand> {
        liveTouchStart[sample.id] = sample.time

        when (mode) {
            PointerEngineMode.Idle, PointerEngineMode.TapBuffered -> {
                // First touch of a fresh sequence, or a new touch following a still-buffered tap
                // (tap-then-hold-drag / multi-tap chain path: tapChain still reflects its count).
                // Neither emits anything yet.
                pendingID = sample.id
                pendingStart = PendingStart(sample.normalized ?: CGPoint.zero, sample.viewPoint, sample.time, sample.normalized)
                pendingLastNormalized = sample.normalized
                pendingLastView = sample.viewPoint
                mode = PointerEngineMode.FirstTouchPending
                smartTouchProbe = SmartTouchProbeState.None
                // Smart Touch asks once per touch, at touch-down, so the Mac's Accessibility lookup
                // overlaps the drag-slop movement. A buffered tap chain means tap-then-hold-drag,
                // which Smart Touch never changes.
                val n = sample.normalized
                if (!smartTouchIsActive || tapChain != null || n == null) return emptyList()
                nextSmartTouchProbeID += 1
                smartTouchProbe = SmartTouchProbeState.Pending(nextSmartTouchProbeID)
                return listOf(PointerCommand.ProbeScrollTarget(nextSmartTouchProbeID, n.x, n.y))
            }

            PointerEngineMode.FirstTouchPending -> {
                // A second touch joined before the first resolved - always a fresh chord.
                return endTitleBarHold() + beginFreshChord(sample)
            }

            PointerEngineMode.AbsolutePointer -> {
                // The first later finger, intentionally added to an established solo pointer
                // session: commit the WHOLE session to relative mode immediately.
                return beginRelativeSession(sample)
            }

            PointerEngineMode.RelativePointerSession -> {
                val chain = tapChain
                if (chain != null &&
                    sample.time - chain.lastReleaseTime <= PointerGestureConfig.tapChainWindow &&
                    hypot(sample.viewPoint.x - chain.lastPoint.x, sample.viewPoint.y - chain.lastPoint.y) <=
                    PointerGestureConfig.tapChainMaxDistance
                ) {
                    // Continuing a buffered relative-finger left tap: might become another tap or
                    // a held drag start. Emits nothing yet.
                    relativeChainCandidateID = sample.id
                    relativeChainCandidateStart = ViewStart(sample.viewPoint, sample.time)
                    relativeChainCandidateLastView = sample.viewPoint
                    return emptyList()
                }
                if (relativeFingers.size < 2) {
                    relativeFingers[sample.id] = RelativeFinger(sample.viewPoint, sample.viewPoint, sample.time)
                    return emptyList()
                }
                // A third finger with the anchor + one relative finger already active: promote the
                // non-anchor member + this new touch into a right-click/drag chord.
                return promoteRelativeSessionToChord(sample)
            }

            PointerEngineMode.ChordPending -> {
                // A 3rd later finger with a chord already at 2: ignore.
                return emptyList()
            }

            PointerEngineMode.TwoFingerPending -> {
                // A 3rd fresh finger joining a still-undecided two-finger tap candidate - treat as
                // the fresh 3-finger system gesture and step aside completely.
                mode = PointerEngineMode.DeferredSystemGesture
                chordIDs.clear()
                chordPositions.clear()
                return emptyList()
            }

            PointerEngineMode.LeftDragHeld, PointerEngineMode.RightDragHeld, PointerEngineMode.SmartScroll -> {
                // Extra fingers while a drag (or Smart Touch scroll) is already committed don't
                // change its meaning - ignore until release.
                return emptyList()
            }

            PointerEngineMode.DeferredSystemGesture -> return emptyList()
        }
    }

    /**
     * Called when a second touch arrives while `FirstTouchPending` - the two touches always
     * arrived together, so this is always a fresh chord. Neither touch has emitted anything yet,
     * so there is nothing to undo - CRITICAL: this must never have moved the cursor to finger 1's
     * location first.
     */
    private fun beginFreshChord(sample: PointerTouchSample): List<PointerCommand> {
        val firstID = pendingID
        val firstStart = pendingStart
        pendingID = null
        pendingStart = null
        pendingLastNormalized = null
        pendingLastView = null
        tapChain = null
        anchorID = null
        anchorNormalized = null

        mode = PointerEngineMode.TwoFingerPending
        chordIDs = linkedSetOf(sample.id)
        chordStartTime = sample.time
        chordPositions.clear()
        chordPositions[sample.id] = sample.viewPoint
        if (firstID != null && firstStart != null) {
            promoteToChord(firstID, sample.time, firstStart.view, firstStart.time)
        }
        chordCentroidStart = centroid()
        chordCentroidLast = chordCentroidStart
        return emptyList()
    }

    /**
     * Commits the whole session to relative mode when a later finger is intentionally added to an
     * established solo `AbsolutePointer` anchor. Both get fresh relative baselines at their
     * current positions - no jump for either.
     */
    private fun beginRelativeSession(sample: PointerTouchSample): List<PointerCommand> {
        val anchor = anchorID ?: return emptyList()   // defensive; should always be set here
        sessionIsRelative = true
        mode = PointerEngineMode.RelativePointerSession
        val anchorBaseline = anchorViewPoint ?: sample.viewPoint
        relativeFingers.clear()
        relativeFingers[anchor] = RelativeFinger(anchorBaseline, anchorBaseline, sample.time)
        relativeFingers[sample.id] = RelativeFinger(sample.viewPoint, sample.viewPoint, sample.time)
        return emptyList()
    }

    /**
     * A third finger arrives while the anchor + one relative finger are active: pulls the
     * non-anchor member out to pair with the new touch as a right-click/drag chord. The anchor is
     * left out of `relativeFingers` (paused) until the chord resolves (`resumeAfterChord`).
     */
    private fun promoteRelativeSessionToChord(sample: PointerTouchSample): List<PointerCommand> {
        // A left-button drag already owns one of the two relative-session slots - never
        // repurpose it into a chord mid-drag (that would strand the held button).
        if (relativeDragFingerID != null) return emptyList()
        val precisionID = relativeFingers.keys.firstOrNull { it != anchorID }
        if (precisionID == null) {
            // Defensive: no non-anchor finger to pair with - just track this one too.
            relativeFingers[sample.id] = RelativeFinger(sample.viewPoint, sample.viewPoint, sample.time)
            return emptyList()
        }
        val precisionFinger = relativeFingers[precisionID]
        val precisionPoint = precisionFinger?.lastPoint ?: sample.viewPoint
        val continuationStartedAt = precisionFinger?.touchDownTime ?: sample.time
        relativeFingers.clear()

        mode = PointerEngineMode.ChordPending
        chordIDs = linkedSetOf(precisionID)
        chordStartTime = sample.time
        chordPositions.clear()
        chordPositions[precisionID] = precisionPoint
        promoteToChord(sample.id, sample.time, sample.viewPoint, continuationStartedAt)
        chordCentroidStart = centroid()
        chordCentroidLast = chordCentroidStart
        return emptyList()
    }

    /**
     * Adds a second member to a chord that started with one touch. This is the one point a chord
     * becomes eligible to continue a just-buffered right tap into a drag.
     */
    private fun promoteToChord(id: Any, time: TimeInterval, point: CGPoint, continuationStartedAt: TimeInterval) {
        chordIDs.add(id)
        chordPositions[id] = point
        // A chord continues a buffered right tap when its first finger landed within the window
        // and its completed centroid is nearby. The second finger may arrive just after the
        // deadline while the platform is still delivering the chord.
        val chordCenter = centroid()
        val pending = pendingChordTap
        if (pending != null &&
            continuationStartedAt - pending.time >= 0 &&
            continuationStartedAt - pending.time <= PointerGestureConfig.tapChainWindow &&
            hypot(chordCenter.x - pending.point.x, chordCenter.y - pending.point.y) <=
            PointerGestureConfig.tapChainMaxDistance
        ) {
            chordIsContinuation = true
            chordStartTime = time
        } else {
            chordIsContinuation = false
        }
    }

    private fun moved(sample: PointerTouchSample): List<PointerCommand> {
        // Keep the anchor's live position fresh in every mode (including while paused mid-chord)
        // so resuming a relative session after a chord resolves never has stale data to jump from.
        if (sample.id == anchorID) anchorViewPoint = sample.viewPoint

        when (mode) {
            PointerEngineMode.Idle, PointerEngineMode.DeferredSystemGesture, PointerEngineMode.TapBuffered ->
                return emptyList()

            PointerEngineMode.FirstTouchPending -> {
                val start = pendingStart
                if (sample.id != pendingID || start == null) return emptyList()
                pendingLastNormalized = sample.normalized
                pendingLastView = sample.viewPoint
                val movedDist = hypot(sample.viewPoint.x - start.view.x, sample.viewPoint.y - start.view.y)
                if (!(movedDist > PointerGestureConfig.dragSlop)) return emptyList()
                // Enough movement evidence to commit now, without waiting out the rest of the
                // arbitration window - either a drag continuation of an already-buffered tap chain,
                // or a genuine solo pointer drag.
                if (tapChain != null) {
                    return if (inputMode == PointerInputMode.Trackpad) {
                        beginTrackpadDrag(sample.id, sample.viewPoint, sample.time)
                    } else {
                        beginLeftDrag(sample.id, start.normalized, sample.normalized)
                    }
                }
                if (smartTouchIsActive) {
                    when (val probe = smartTouchProbe) {
                        is SmartTouchProbeState.Pending ->
                            // Withheld until the Mac answers - bounded by the existing arbitration
                            // window, after which poll() commits ordinary Direct Touch as before.
                            return emptyList()
                        is SmartTouchProbeState.Resolved -> when (probe.target) {
                            SmartTouchTarget.Scroll -> return commitToSmartScroll(sample.id, sample.viewPoint)
                            SmartTouchTarget.WindowDrag ->
                                // Moved before the title bar hold armed: not a deliberate window
                                // drag, so it never becomes one - plain Direct Touch instead.
                                return endTitleBarHold() +
                                    commitToAbsolutePointer(sample.id, sample.normalized, sample.viewPoint)
                            null -> {}
                        }
                        SmartTouchProbeState.None -> {}
                    }
                }
                // Trackpad only: this lone finger might still be joined by a partner to continue a
                // just-buffered right tap into a chord - committing it to its own solo relative
                // session first would silence the right-click entirely (PRODUCT RULE: a chord
                // continuation must always win). Withholds any commit until either the partner
                // joins or poll() resolves the continuation window itself.
                if (inputMode == PointerInputMode.Trackpad &&
                    isPlausibleChordContinuationCandidate(start.view, sample.time)
                ) {
                    return emptyList()
                }
                return if (inputMode == PointerInputMode.Trackpad) {
                    commitToRelativePointerSession(sample.id, sample.viewPoint, sample.time)
                } else {
                    commitToAbsolutePointer(sample.id, sample.normalized, sample.viewPoint)
                }
            }

            PointerEngineMode.AbsolutePointer -> {
                val n = sample.normalized
                if (sample.id != anchorID || n == null) return emptyList()
                anchorNormalized = n
                return listOf(PointerCommand.MoveAbsolute(n.x, n.y))
            }

            PointerEngineMode.RelativePointerSession -> {
                val candidateStart = relativeChainCandidateStart
                if (sample.id == relativeChainCandidateID && candidateStart != null) {
                    relativeChainCandidateLastView = sample.viewPoint
                    val movedDist = hypot(
                        sample.viewPoint.x - candidateStart.view.x,
                        sample.viewPoint.y - candidateStart.view.y,
                    )
                    if (!(movedDist > PointerGestureConfig.dragSlop)) return emptyList()
                    // Enough movement to commit now, without waiting out the hold-commit delay.
                    return commitRelativeLeftDrag(sample.id, sample.viewPoint)
                }
                val finger = relativeFingers[sample.id] ?: return emptyList()
                val dx = sample.viewPoint.x - finger.lastPoint.x
                val dy = sample.viewPoint.y - finger.lastPoint.y
                relativeFingers[sample.id] = finger.copy(lastPoint = sample.viewPoint)
                if (!(dx != 0.0 || dy != 0.0)) return emptyList()
                // trackpadSensitivity scales ONLY this one emission point - the primary one-finger
                // (and its precision-extension) relative delta. It never touches the tracked
                // lastPoint baseline (so it can't compound error), and is never reached by the
                // separate RightDragHeld chord delta, which stays unscaled in both modes. In Direct
                // mode this path is only the hybrid second-finger precision move, left untouched.
                val scale = if (inputMode == PointerInputMode.Trackpad) trackpadSensitivity else 1.0
                return listOf(PointerCommand.MoveRelative(dx * scale, dy * scale))
            }

            PointerEngineMode.ChordPending, PointerEngineMode.TwoFingerPending -> {
                if (!chordIDs.contains(sample.id)) return emptyList()
                chordPositions[sample.id] = sample.viewPoint
                val centroid = centroid()
                chordCentroidLast = centroid
                val movedDist = hypot(centroid.x - chordCentroidStart.x, centroid.y - chordCentroidStart.y)
                if (!(chordIsContinuation && movedDist > PointerGestureConfig.dragSlop)) return emptyList()
                return commitRightDrag()
            }

            PointerEngineMode.LeftDragHeld -> {
                val n = sample.normalized
                if (sample.id != anchorID || n == null) return emptyList()
                return listOf(PointerCommand.MoveAbsolute(n.x, n.y))
            }

            PointerEngineMode.SmartScroll -> {
                val last = smartScrollLastView
                if (sample.id != anchorID || last == null) return emptyList()
                smartScrollLastView = sample.viewPoint
                val (dx, dy) = lockedScrollDelta(sample.viewPoint.x - last.x, sample.viewPoint.y - last.y)
                if (!(dx != 0.0 || dy != 0.0)) return emptyList()
                return listOf(PointerCommand.Scroll(dx, dy))
            }

            PointerEngineMode.RightDragHeld -> {
                if (!chordIDs.contains(sample.id)) return emptyList()
                chordPositions[sample.id] = sample.viewPoint
                val centroid = centroid()
                val dx = centroid.x - chordCentroidLast.x
                val dy = centroid.y - chordCentroidLast.y
                chordCentroidLast = centroid
                if (!(dx != 0.0 || dy != 0.0)) return emptyList()
                return listOf(PointerCommand.MoveRelative(dx, dy))
            }
        }
    }

    private fun centroid(): CGPoint {
        if (chordPositions.isEmpty()) return chordCentroidLast
        val points = chordPositions.values
        val x = points.fold(0.0) { acc, p -> acc + p.x } / points.size.toDouble()
        val y = points.fold(0.0) { acc, p -> acc + p.y } / points.size.toDouble()
        return CGPoint(x, y)
    }

    private fun ended(sample: PointerTouchSample, cancelled: Boolean): List<PointerCommand> {
        liveTouchStart.remove(sample.id)
        if (sample.id == anchorID) anchorViewPoint = sample.viewPoint
        val out = ArrayList<PointerCommand>()

        when (mode) {
            PointerEngineMode.Idle, PointerEngineMode.DeferredSystemGesture, PointerEngineMode.TapBuffered -> {}

            PointerEngineMode.FirstTouchPending -> {
                val start = pendingStart
                if (sample.id != pendingID || start == null) return out
                out += endTitleBarHold()
                pendingID = null
                pendingStart = null
                pendingLastNormalized = null
                pendingLastView = null
                val movedDist = hypot(sample.viewPoint.x - start.view.x, sample.viewPoint.y - start.view.y)
                // A Smart Touch target defers the arbitration-window commit (see poll()); a press
                // held past that window still reads exactly as before - a pointer placement,
                // never a click.
                val heldPastArbitration = smartTouchDeferredTarget != null &&
                    sample.time - start.time >= PointerGestureConfig.firstTouchArbitrationWindow
                val isTap = !cancelled && movedDist <= PointerGestureConfig.tapMaxMovement && !heldPastArbitration
                val n = sample.normalized
                if (isTap) {
                    // Confirmed: no second finger ever joined during this touch's life - safe to
                    // move the cursor here, once, so the buffered click lands at the tapped
                    // location. Trackpad mode clicks at the cursor's current (unmoved) position
                    // instead - PRODUCT RULE: touching down must never snap/jump the cursor.
                    if (inputMode == PointerInputMode.Direct && n != null) {
                        out.add(PointerCommand.MoveAbsolute(n.x, n.y))
                    }
                    extendTapChain(sample.viewPoint, sample.time)
                    mode = PointerEngineMode.TapBuffered
                } else {
                    if (heldPastArbitration && !cancelled && n != null) {
                        out.add(PointerCommand.MoveAbsolute(n.x, n.y))
                    }
                    tapChain = null
                    mode = PointerEngineMode.Idle
                }
            }

            PointerEngineMode.AbsolutePointer -> {
                if (sample.id != anchorID) return out
                out += releaseHeld()
                resetToIdle()
            }

            PointerEngineMode.RelativePointerSession -> {
                if (sample.id == relativeDragFingerID) {
                    // The finger holding the left button releases it - ends the drag regardless of
                    // whether other session fingers (the anchor) remain down.
                    relativeDragFingerID = null
                    relativeFingers.remove(sample.id)
                    out += releaseHeld()
                } else if (sample.id == relativeChainCandidateID) {
                    // A candidate continuing a buffered tap released without ever committing to a
                    // drag - either extends the chain (a genuine tap) or, if cancelled/moved too
                    // far, drops it.
                    relativeChainCandidateID = null
                    val start = relativeChainCandidateStart
                    relativeChainCandidateStart = null
                    relativeChainCandidateLastView = null
                    val movedDist = start?.let { hypot(sample.viewPoint.x - it.view.x, sample.viewPoint.y - it.view.y) } ?: 0.0
                    if (!cancelled && movedDist <= PointerGestureConfig.tapMaxMovement) {
                        extendTapChain(sample.viewPoint, sample.time)
                    } else {
                        tapChain = null
                    }
                } else if (sample.id == anchorID) {
                    relativeFingers.remove(sample.id)
                } else {
                    val finger = relativeFingers.remove(sample.id)
                    if (finger != null) {
                        val heldDuration = sample.time - finger.touchDownTime
                        val movedDist = hypot(sample.viewPoint.x - finger.touchDown.x, sample.viewPoint.y - finger.touchDown.y)
                        if (!cancelled && heldDuration <= PointerGestureConfig.chordTapMaxDuration &&
                            movedDist <= PointerGestureConfig.tapMaxMovement
                        ) {
                            // Quick later-finger tap: buffer it through the SAME left tap-chain as
                            // the solo/anchor path - flushed by poll() or extended/converted by
                            // whatever touches it next, exactly like TapBuffered.
                            extendTapChain(sample.viewPoint, sample.time)
                        }
                    }
                }
                if (relativeFingers.isEmpty() && relativeChainCandidateID == null && relativeDragFingerID == null) {
                    // The whole session has ended. A still-buffered click (nobody continued it
                    // into a chain or a drag) must still reach the wire - the tap really did
                    // happen - rather than being silently lost by resetToIdle() below.
                    out += flushTapChain()
                    resetToIdle()
                }
            }

            PointerEngineMode.ChordPending -> {
                chordIDs.remove(sample.id)
                chordPositions.remove(sample.id)
                if (chordIDs.isEmpty()) {
                    out += resolveChordRelease(sample.time, cancelled)
                    resumeAfterChord(sample.time)
                }
            }

            PointerEngineMode.TwoFingerPending -> {
                chordIDs.remove(sample.id)
                chordPositions.remove(sample.id)
                if (chordIDs.isEmpty()) {
                    out += resolveChordRelease(sample.time, cancelled)
                    mode = PointerEngineMode.Idle
                    anchorID = null
                }
            }

            PointerEngineMode.LeftDragHeld -> {
                if (sample.id == anchorID) {
                    out += releaseHeld()
                    resetToIdle()
                }
            }

            PointerEngineMode.SmartScroll -> {
                if (sample.id == anchorID) {
                    out.add(PointerCommand.ScrollEnded(momentum = !cancelled))
                    resetToIdle()
                }
            }

            PointerEngineMode.RightDragHeld -> {
                chordIDs.remove(sample.id)
                chordPositions.remove(sample.id)
                if (chordIDs.isEmpty()) {
                    out += releaseHeld()
                    chordIsContinuation = false
                    resumeAfterChord(sample.time)
                }
            }
        }
        return out
    }

    /**
     * A right-click/drag chord (always anchor-based - the only way into `ChordPending` is
     * `promoteRelativeSessionToChord`) has just fully released. Resumes `RelativePointerSession`
     * for the anchor if it's still physically down (from its live position - no jump); otherwise
     * the whole session has ended.
     */
    private fun resumeAfterChord(time: TimeInterval) {
        val anchor = anchorID
        if (anchor != null && liveTouchStart[anchor] != null) {
            mode = PointerEngineMode.RelativePointerSession
            val baseline = anchorViewPoint ?: CGPoint.zero
            relativeFingers.clear()
            relativeFingers[anchor] = RelativeFinger(baseline, baseline, time)
        } else {
            mode = PointerEngineMode.Idle
            anchorID = null
            relativeFingers.clear()
        }
    }

    /**
     * A chord (fresh two-finger, or a later-added chord on an active anchor) released before
     * committing to a drag.
     *
     * A quick, low-movement release always buffers a new right tap, withheld in case a further
     * chord continues it into a drag - like the first tap. If THIS release was itself continuing
     * an already-buffered tap, that earlier tap is now confirmed final and is flushed
     * immediately, rather than silently dropped: two ordinary two-finger taps in a row must both
     * right-click. Anything else (cancelled, moved too far, or held too long with no drag commit)
     * is silently dropped.
     */
    private fun resolveChordRelease(time: TimeInterval, cancelled: Boolean): List<PointerCommand> {
        val wasContinuation = chordIsContinuation
        chordIsContinuation = false
        if (cancelled) return emptyList()
        val heldDuration = time - chordStartTime
        val movedDist = hypot(chordCentroidLast.x - chordCentroidStart.x, chordCentroidLast.y - chordCentroidStart.y)
        if (!(heldDuration <= PointerGestureConfig.chordTapMaxDuration &&
                movedDist <= PointerGestureConfig.tapMaxMovement)
        ) return emptyList()
        pendingChordTap = PendingChordTap(chordCentroidLast, time)
        if (!wasContinuation) return emptyList()
        return listOf(
            PointerCommand.MouseDown(PointerButton.Right, 1),
            PointerCommand.MouseUp(PointerButton.Right, 1),
        )
    }

    // MARK: - Tap-chain buffering (click counting + tap-then-hold drag)

    private fun extendTapChain(point: CGPoint, time: TimeInterval) {
        val chain = tapChain
        tapChain = if (chain != null &&
            time - chain.lastReleaseTime <= PointerGestureConfig.tapChainWindow &&
            hypot(point.x - chain.lastPoint.x, point.y - chain.lastPoint.y) <= PointerGestureConfig.tapChainMaxDistance
        ) {
            TapChain(chain.count + 1, point, time)
        } else {
            TapChain(1, point, time)
        }
    }

    private fun flushTapChain(): List<PointerCommand> {
        val chain = tapChain ?: return emptyList()
        tapChain = null
        return listOf(
            PointerCommand.MouseDown(PointerButton.Left, chain.count),
            PointerCommand.MouseUp(PointerButton.Left, chain.count),
        )
    }

    private fun flushPendingChordTap(): List<PointerCommand> {
        if (pendingChordTap == null) return emptyList()
        pendingChordTap = null
        return listOf(
            PointerCommand.MouseDown(PointerButton.Right, 1),
            PointerCommand.MouseUp(PointerButton.Right, 1),
        )
    }

    /**
     * Commits `FirstTouchPending` to a solo `AbsolutePointer` session - via movement evidence or
     * arbitration-window expiry. Emits the one-time `MoveAbsolute` that starts live absolute
     * tracking, and seeds `anchorViewPoint` so a later relative-session transition (or chord
     * pause/resume) always has a real baseline.
     */
    private fun commitToAbsolutePointer(id: Any, normalized: CGPoint?, viewPoint: CGPoint): List<PointerCommand> {
        pendingID = null
        pendingStart = null
        pendingLastNormalized = null
        pendingLastView = null
        anchorID = id
        anchorViewPoint = viewPoint
        mode = PointerEngineMode.AbsolutePointer
        val n = normalized ?: return emptyList()
        anchorNormalized = n
        return listOf(PointerCommand.MoveAbsolute(n.x, n.y))
    }

    /**
     * Smart Touch counterpart of `commitToAbsolutePointer`, reached only when the Mac confirmed
     * the touch-down target as scrollable. Parks the cursor once at the touch-down point, fixes
     * the scroll's axis lock from the first swipe's direction, then replays the pre-commit
     * movement as the first scroll delta so content tracks the finger 1:1 from contact.
     */
    private fun commitToSmartScroll(id: Any, viewPoint: CGPoint): List<PointerCommand> {
        // A probe is only ever issued for a touch-down with a real normalized point, so
        // start.point is never the zero stand-in.
        val start = pendingStart
        pendingID = null
        pendingStart = null
        pendingLastNormalized = null
        pendingLastView = null
        anchorID = id
        anchorViewPoint = viewPoint
        mode = PointerEngineMode.SmartScroll
        smartScrollLastView = viewPoint
        smartScrollAxis = SmartScrollAxis.Free
        val out = ArrayList<PointerCommand>()
        if (start != null) {
            out.add(PointerCommand.MoveAbsolute(start.point.x, start.point.y))
            val dx = viewPoint.x - start.view.x
            val dy = viewPoint.y - start.view.y
            val ratio = PointerGestureConfig.smartScrollAxisLockRatio
            if (abs(dy) >= abs(dx) * ratio) {
                smartScrollAxis = SmartScrollAxis.Vertical
            } else if (abs(dx) >= abs(dy) * ratio) {
                smartScrollAxis = SmartScrollAxis.Horizontal
            }
            val (lockedDX, lockedDY) = lockedScrollDelta(dx, dy)
            if (lockedDX != 0.0 || lockedDY != 0.0) out.add(PointerCommand.Scroll(lockedDX, lockedDY))
        }
        return out
    }

    private fun lockedScrollDelta(dx: CGFloat, dy: CGFloat): Pair<CGFloat, CGFloat> = when (smartScrollAxis) {
        SmartScrollAxis.Horizontal -> Pair(dx, 0.0)
        SmartScrollAxis.Vertical -> Pair(0.0, dy)
        SmartScrollAxis.Free -> Pair(dx, dy)
    }

    /**
     * Smart Touch window drag, armed by a still hold on a recognized title bar: presses and holds
     * the left button at the touch-down point - the point the Mac classified - so macOS moves the
     * window exactly as it would for a mouse drag there. From here on it is an ordinary
     * `LeftDragHeld`: the window follows the finger and the button releases when it lifts.
     */
    private fun armSmartWindowDrag(id: Any): List<PointerCommand> {
        val start = pendingStart
        titleBarHoldActive = false
        pendingID = null
        pendingStart = null
        pendingLastNormalized = null
        pendingLastView = null
        anchorID = id
        mode = PointerEngineMode.LeftDragHeld
        heldMouseButton = PointerButton.Left
        val out = ArrayList<PointerCommand>()
        if (start != null) {
            out.add(PointerCommand.MoveAbsolute(start.point.x, start.point.y))
        }
        out.add(PointerCommand.MouseDown(PointerButton.Left, 1))
        out.add(PointerCommand.SmartTouchFeedback(SmartTouchFeedback.WindowDragArmed))
        return out
    }

    /** Ends an outstanding title bar hold that did not arm. */
    private fun endTitleBarHold(): List<PointerCommand> {
        if (!titleBarHoldActive) return emptyList()
        titleBarHoldActive = false
        return listOf(PointerCommand.SmartTouchFeedback(SmartTouchFeedback.TitleBarHoldCancelled))
    }

    /**
     * The Mac's answer to a `ProbeScrollTarget` (null: nothing Smart Touch acts on). Ignored
     * unless it matches the current, still-undecided first touch's own probe, so a late reply
     * from an earlier touch or session can never classify a newer one. If the finger already
     * crossed `dragSlop` while waiting, the withheld commit happens now - a scroll, or plain
     * Direct Touch (a title bar never drags without its hold). A still finger on a title bar
     * starts the hold instead.
     */
    fun resolveSmartTouchProbe(id: Int, target: SmartTouchTarget?): List<PointerCommand> {
        if (mode != PointerEngineMode.FirstTouchPending || smartTouchProbe != SmartTouchProbeState.Pending(id)) {
            return emptyList()
        }
        smartTouchProbe = SmartTouchProbeState.Resolved(target)
        val pid = pendingID
        val start = pendingStart
        val last = pendingLastView
        if (!smartTouchIsActive || pid == null || start == null || last == null) return emptyList()
        val movedPastSlop = hypot(last.x - start.view.x, last.y - start.view.y) > PointerGestureConfig.dragSlop
        return when {
            target == SmartTouchTarget.Scroll && movedPastSlop -> commitToSmartScroll(pid, last)
            target == SmartTouchTarget.WindowDrag && !movedPastSlop -> {
                titleBarHoldActive = true
                val deadline = start.time + PointerGestureConfig.smartTouchTitleBarHoldDelay
                listOf(PointerCommand.SmartTouchFeedback(SmartTouchFeedback.TitleBarHoldBegan(deadline)))
            }
            else -> {
                if (!movedPastSlop) emptyList()
                else commitToAbsolutePointer(pid, pendingLastNormalized, last)
            }
        }
    }

    /**
     * Trackpad-mode counterpart of `commitToAbsolutePointer`: commits `FirstTouchPending` straight
     * into a single-finger `RelativePointerSession`, seeded with only the anchor. Emits NO
     * command: touching down must never move/jump the cursor (PRODUCT RULE). The baseline is the
     * touch's CURRENT point, so the small pre-commit movement that crossed `dragSlop` is absorbed
     * rather than replayed as a jump.
     */
    private fun commitToRelativePointerSession(id: Any, viewPoint: CGPoint, time: TimeInterval): List<PointerCommand> {
        pendingID = null
        pendingStart = null
        pendingLastNormalized = null
        pendingLastView = null
        anchorID = id
        anchorViewPoint = viewPoint
        sessionIsRelative = true
        mode = PointerEngineMode.RelativePointerSession
        relativeFingers.clear()
        relativeFingers[id] = RelativeFinger(viewPoint, viewPoint, time)
        return emptyList()
    }

    /**
     * Trackpad-mode counterpart of `beginLeftDrag`: a fresh touch continuing a buffered tap chain
     * commits to a held left-button drag that tracks RELATIVELY from here on, by first
     * establishing a session with just this one finger as its anchor. Emits no move - the button
     * posts at the Mac's current cursor position.
     */
    private fun beginTrackpadDrag(id: Any, point: CGPoint, @Suppress("UNUSED_PARAMETER") time: TimeInterval): List<PointerCommand> {
        pendingID = null
        pendingStart = null
        pendingLastNormalized = null
        pendingLastView = null
        anchorID = id
        sessionIsRelative = true
        mode = PointerEngineMode.RelativePointerSession
        return commitRelativeLeftDrag(id, point)
    }

    /**
     * Commits a buffered tap chain into a held left-button drag, starting at the drag touch's
     * current position (`normalized`) so the drag - and the cursor - begin exactly where the
     * finger already is.
     */
    /**
     * Presses where the finger came down ([pressAt]), then drags to where it is now: pressing
     * at the point the drag was recognised would start every drag a slop's distance off target.
     */
    private fun beginLeftDrag(id: Any, pressAt: CGPoint?, current: CGPoint?): List<PointerCommand> {
        val clickCount = tapChain?.count ?: 0
        tapChain = null
        pendingID = null
        pendingStart = null
        pendingLastNormalized = null
        pendingLastView = null
        anchorID = id
        mode = PointerEngineMode.LeftDragHeld
        heldMouseButton = PointerButton.Left
        val out = ArrayList<PointerCommand>()
        (pressAt ?: current)?.let { out.add(PointerCommand.MoveAbsolute(it.x, it.y)) }
        out.add(PointerCommand.MouseDown(PointerButton.Left, max(clickCount, 1)))
        if (pressAt != null && current != null && current != pressAt) {
            out.add(PointerCommand.MoveAbsolute(current.x, current.y))
        }
        return out
    }

    /**
     * Commits a relative-session finger's buffered tap chain into a held left-button drag - the
     * `RelativePointerSession` counterpart of `beginLeftDrag`. Deliberately emits NO move: the
     * button posts at the Mac's current cursor position (never the touch location), and `point`
     * seeds the finger's own relative baseline, so the small pre-commit drag-slop movement is
     * absorbed rather than replayed as a jump.
     */
    private fun commitRelativeLeftDrag(id: Any, point: CGPoint): List<PointerCommand> {
        val clickCount = tapChain?.count ?: 0
        tapChain = null
        relativeChainCandidateID = null
        relativeChainCandidateStart = null
        relativeChainCandidateLastView = null
        relativeFingers[id] = RelativeFinger(point, point, 0.0)
        relativeDragFingerID = id
        heldMouseButton = PointerButton.Left
        return listOf(PointerCommand.MouseDown(PointerButton.Left, max(clickCount, 1)))
    }

    private fun commitRightDrag(): List<PointerCommand> {
        chordIsContinuation = false
        pendingChordTap = null
        mode = PointerEngineMode.RightDragHeld
        heldMouseButton = PointerButton.Right
        return listOf(PointerCommand.MouseDown(PointerButton.Right, 1))
    }

    /**
     * Switches the primary one-finger pointer model. A no-op when already in [newMode]; otherwise
     * fully cancels whatever touch/click/drag session is in flight (same guarantee as `reset()`)
     * before adopting the new mode. MUST be called instead of mutating `inputMode` directly.
     */
    fun setInputMode(newMode: PointerInputMode): List<PointerCommand> {
        if (newMode == inputMode) return emptyList()
        val out = reset()
        inputMode = newMode
        return out
    }

    // MARK: - Safety / cleanup

    /**
     * Releases any held synthetic button and returns the receiver to `Idle`. MUST be called on
     * disconnect, input-disable, pause, or gesture cancellation. Idempotent.
     */
    fun releaseHeld(): List<PointerCommand> {
        val button = heldMouseButton ?: return emptyList()
        heldMouseButton = null
        return listOf(PointerCommand.MouseUp(button, 0))
    }

    /** Full reset - releases any held button and forgets every tracked touch. Use for disconnect/pause/system-gesture takeover. */
    fun reset(): List<PointerCommand> {
        val out = endTitleBarHold() + releaseHeld()
        resetToIdle()
        return out
    }

    private fun resetToIdle() {
        mode = PointerEngineMode.Idle
        anchorID = null
        anchorNormalized = null
        anchorViewPoint = null
        sessionIsRelative = false
        relativeFingers.clear()
        relativeChainCandidateID = null
        relativeChainCandidateStart = null
        relativeChainCandidateLastView = null
        relativeDragFingerID = null
        chordIDs.clear()
        chordPositions.clear()
        chordIsContinuation = false
        pendingChordTap = null
        pendingID = null
        pendingStart = null
        pendingLastNormalized = null
        pendingLastView = null
        tapChain = null
        liveTouchStart.clear()
        heldMouseButton = null
        smartTouchProbe = SmartTouchProbeState.None
        smartScrollLastView = null
        smartScrollAxis = SmartScrollAxis.Free
        titleBarHoldActive = false
    }
}

// MARK: - App Gesture Command routing (H/I)

/**
 * Converts continuous pinch/rotation magnitude into discrete, rate-limited App Gesture Commands.
 * Pure accumulator, no I/O. Positive direction corresponds to "outward"/"clockwise" (Zoom In /
 * Rotate Right); negative to "inward"/"counter-clockwise" (Zoom Out / Rotate Left).
 */
class AppGestureCommandAccumulator(
    private val threshold: Double,
    private val step: Double,
    private val maxFiresPerUpdate: Int = 4,
) {
    private var total: Double = 0.0
    private var direction: Int = 0

    /** How many fires this same directional run has already produced. */
    private var firedCount: Int = 0

    /** Gesture start, end, or cancellation all rebase cleanly - no partial carry-over. */
    fun reset() {
        total = 0.0
        direction = 0
        firedCount = 0
    }

    /**
     * [delta] is the incremental magnitude since the last call in this same gesture. Returns a
     * signed fire count: its magnitude is how many commands to send now (0 when still under
     * threshold), its sign which direction. The first fire needs `threshold` total movement, each
     * further one only another `step`, capped at `maxFiresPerUpdate` per call; any backlog beyond
     * the cap is still tracked and reported on a later call.
     */
    fun advance(delta: Double): Int {
        if (!delta.isFinite() || delta == 0.0) return 0
        val newDirection = if (delta > 0) 1 else -1
        if (direction != 0 && newDirection != direction) {
            // Reversal: a partial in-flight accumulation toward the old direction is discarded
            // rather than partially cancelled.
            total = 0.0
            firedCount = 0
        }
        direction = newDirection
        total += abs(delta)

        if (!(total >= threshold)) return 0
        val possibleFires = 1 + ((total - threshold) / step).toInt()
        val newFires = min(possibleFires - firedCount, maxFiresPerUpdate)
        if (newFires <= 0) return 0
        firedCount += newFires
        return direction * newFires
    }
}

object AppGestureCommandRouting {
    /** ~35% relative pinch before the first Zoom In/Out, then another ~18% per repeat. */
    val pinchThreshold: Double = ln(1.35)
    val pinchStep: Double = ln(1.18)

    /** ~25 degrees before the first Rotate Left/Right, then another ~15 degrees per repeat. */
    val rotationThreshold: Double = Math.PI / 7.2   // 25 degrees
    val rotationStep: Double = Math.PI / 12          // 15 degrees

    fun makePinchAccumulator() = AppGestureCommandAccumulator(pinchThreshold, pinchStep)

    fun makeRotationAccumulator() = AppGestureCommandAccumulator(rotationThreshold, rotationStep)
}

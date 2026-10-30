package com.raisecaterror.meowdisplay.core.controls

import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.exp
import kotlin.math.floor
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.sin

// Stage Peek: the floating window switcher. A 1:1 port of Shared/StagePeek.swift (pure state
// machine and geometry), checked against fixtures/stage-peek/vectors.json. Units are dp, the
// Android counterpart of iOS points; window IDs are Long (CGWindowIDs fit a UInt32).

/** Which window switcher Window mode shows. Persisted as `windowSwitcher`; stable raw values. */
enum class WindowSwitcherStyle(val raw: String) {
    StagePeek("stagePeek"),
    Rail("rail");

    val id: String get() = raw

    companion object {
        fun of(raw: String?): WindowSwitcherStyle? = entries.firstOrNull { it.raw == raw }
    }
}

/** The screen edge Stage Peek opens from. Persisted as `stagePeekEdge`; stable raw values. */
enum class StagePeekEdge(val raw: String) {
    Left("left"),
    Right("right");

    val id: String get() = raw

    companion object {
        fun of(raw: String?): StagePeekEdge? = entries.firstOrNull { it.raw == raw }
    }
}

/** How the compact peek's window Dock sits on screen. Persisted as `stagePeekDock`; stable raw values. */
enum class StagePeekDockStyle(val raw: String, val title: String) {
    /** A bounded column between the search and app carousel above and the buttons below (the default). */
    Compact("compact", "Compact"),

    /** The open column across the whole edge (controls stay on top). */
    Normal("normal", "Normal");

    companion object {
        fun of(raw: String?): StagePeekDockStyle? = entries.firstOrNull { it.raw == raw }
    }
}

/** Thresholds, in dp and seconds. Tests and both apps share them. */
object StagePeekConfig {
    /** The hold strip: this wide, just inside the safe area. */
    const val edgeStripWidth: CGFloat = 20.0

    /** The strip covers this share of the height, centred, capped (Android excludes at most 200 dp per edge from system back gestures). */
    const val edgeStripHeightFraction: CGFloat = 0.7
    const val edgeStripMaxHeight: CGFloat = 200.0

    /** A still finger on the strip opens Stage Peek after this long. */
    const val holdDelay: TimeInterval = 0.3

    /** Moving farther than this before the hold completes cancels it. */
    const val holdSlop: CGFloat = 10.0

    /** Vertical finger travel per window while scrubbing. */
    const val scrubPitch: CGFloat = 52.0

    /** Sideways travel that counts as a flick between compact and expanded. */
    const val flickDistance: CGFloat = 44.0

    /** Inward travel before the expanded browser starts to grow, and the travel at which it is fully expanded. */
    const val expandStart: CGFloat = 56.0
    const val expandFull: CGFloat = 156.0

    /** Expansion kept on lift at or past this share; less springs back. */
    const val expandKeep: Double = 0.6

    /** Scrub ticks closer together than this are skipped (the highlight still changes), so fast scrubs don't buzz. */
    const val tickSpacing: TimeInterval = 0.035

    /** A tap while open: shorter than this and within [tapSlop]. */
    const val tapMaxDuration: TimeInterval = 0.35
    const val tapSlop: CGFloat = 10.0

    /** Scrubbing past either end rubber-bands at most this many windows. */
    const val maxOverrun: Double = 0.45

    /** Overrun that plays the end-of-list haptic, once per excursion. */
    const val boundaryOverrun: Double = 0.25

    /** Camera distance (dp) for the card tilt: renderers and hit testing. */
    const val perspective: CGFloat = 900.0

    /** Compact Dock: the fade at the top and bottom of its region. */
    const val dockFade: CGFloat = 28.0

    /** Compact Dock: room kept between the region and the controls above and below it. */
    const val dockGap: CGFloat = 8.0
}

enum class StagePeekHaptic(val raw: String) { Activate("activate"), Tick("tick"), Boundary("boundary"), Select("select") }

sealed interface StagePeekEffect {
    data object Opened : StagePeekEffect
    data class Haptic(val haptic: StagePeekHaptic) : StagePeekEffect

    /** A tap chose this window. Stage Peek is closed. */
    data class Select(val id: Long) : StagePeekEffect

    /** Closed without choosing anything. */
    data object Dismissed : StagePeekEffect

    /** A sideways swipe on this window's card: show (or, null, hide) its Close Window button. */
    data class RevealClose(val id: Long?) : StagePeekEffect
}

/**
 * The gesture and selection state. Browsing (hold, scrub, expand, lift) never selects; only a
 * separate tap on a card does. Not thread safe: drive it from the main thread.
 */
class StagePeekMachine {
    enum class Phase(val raw: String) { Closed("closed"), Arming("arming"), Scrubbing("scrubbing"), Open("open") }

    /** Swipe up moves the stack up, revealing the windows below (the default). */
    var naturalScrolling = true

    var phase = Phase.Closed
        private set
    var ids: List<Long> = emptyList()
        private set

    /** Fractional index the stack is centred on; follows the finger. */
    var position: Double = 0.0
        private set

    /** 0 compact … 1 expanded browser. */
    var expansion: Double = 0.0
        private set
    var expanded = false
        private set
    private var currentIndex = 0

    private var touchID: Any? = null
    private var start: Mark? = null
    private var anchor: Anchor? = null

    /** Open phase: the touch that may still be a tap. */
    private var tapCandidate = false

    /** A touch Stage Peek owns but ignores until it lifts. */
    private val consumed = mutableSetOf<Any>()
    private var lastTickTime: TimeInterval = Double.NEGATIVE_INFINITY
    private var lastHighlighted = 0
    private var overrunSignalled = false

    /** Open phase: the card the touch started on, when that card can be closed. */
    private var startCard: Int? = null

    /**
     * Open phase: past the tap slop but mostly sideways, so a flick (or a swipe on a card) in
     * progress: it neither taps nor scrubs until it is long enough or turns vertical.
     */
    private var sideways = false

    /** The window whose Close Window button shows (after a swipe left on its card). */
    var closeRevealed: Long? = null
        private set

    private class Mark(val point: CGPoint, val time: TimeInterval)
    private class Anchor(val point: CGPoint, val position: Double)

    val isVisible: Boolean get() = phase == Phase.Scrubbing || phase == Phase.Open
    val highlighted: Int get() = if (ids.isEmpty()) 0 else min(max(position.roundedAwayFromZero().toInt(), 0), ids.size - 1)
    val highlightedID: Long? get() = if (ids.isEmpty()) null else ids[highlighted]

    // MARK: Catalog

    /**
     * New window list. While visible the highlighted window keeps its highlight if it is still
     * listed, so a reorder never jumps to another window; [current] (the active tile's window) is
     * where the next open starts.
     */
    fun setItems(new: List<Long>, current: Long?) {
        val keep = if (isVisible) highlightedID else null
        val fraction = position - position.roundedAwayFromZero()
        ids = new
        currentIndex = current?.let { c -> new.indexOf(c).takeIf { it >= 0 } } ?: 0
        val kept = keep?.let { k -> new.indexOf(k).takeIf { it >= 0 } }
        position = if (kept != null) kept.toDouble() + fraction else clampPosition(if (isVisible) position else currentIndex.toDouble())
        lastHighlighted = highlighted
        if (closeRevealed != null && closeRevealed !in new) closeRevealed = null
        if (isVisible && ids.isEmpty()) closeAll()
    }

    // MARK: Touches

    /**
     * Returns whether Stage Peek owns this touch. Owned touches never reach the Mac: anything
     * starting on the edge strip, and everything while open.
     */
    /**
     * [closableCard]: while open, the card under the touch when it is a window that can be closed
     * (a swipe left on it reveals Close Window instead of flicking the peek).
     */
    fun touchBegan(id: Any, at: CGPoint, time: TimeInterval, onStrip: Boolean, closableCard: Int? = null): Boolean {
        when (phase) {
            Phase.Closed -> {
                if (!onStrip || ids.isEmpty()) return false
                phase = Phase.Arming
                touchID = id
                start = Mark(at, time)
                return true
            }
            Phase.Arming, Phase.Scrubbing -> {
                if (id != touchID) consumed.add(id)
                return true
            }
            Phase.Open -> {
                if (touchID != null) { consumed.add(id); return true }
                touchID = id
                start = Mark(at, time)
                anchor = Anchor(at, position)
                tapCandidate = true
                startCard = closableCard
                return true
            }
        }
    }

    fun touchMoved(id: Any, to: CGPoint, time: TimeInterval, edge: StagePeekEdge): List<StagePeekEffect> {
        val start = start
        if (id != touchID || start == null) return emptyList()
        when (phase) {
            Phase.Arming -> {
                val dx = to.x - start.point.x; val dy = to.y - start.point.y
                if (hypot(dx, dy) > StagePeekConfig.holdSlop) {
                    // The touch stays Stage Peek's until it lifts either way.
                    consumed.add(id)
                    resetTouch()
                    phase = Phase.Closed
                    // A flick inward from the edge opens the peek (it stays open; nothing is chosen).
                    val inward = if (edge == StagePeekEdge.Left) dx else -dx
                    if (inward > abs(dy)) return openDirectly()
                }
                return emptyList()
            }
            Phase.Open -> {
                if (!tapCandidate && !sideways) return emptyList()
                // A sideways flick while open: inward expands, outward compacts (or closes when compact).
                val dx = to.x - start.point.x; val dy = to.y - start.point.y
                if (abs(dx) > StagePeekConfig.flickDistance && abs(dx) > abs(dy) * 1.5) {
                    val card = startCard?.let { ids.getOrNull(it) }
                    consumed.add(id)
                    resetTouch()
                    // On a closable window's card a swipe left reveals Close Window; a swipe right on
                    // the revealed card hides it. Everywhere else the flick works as before.
                    if (card != null && !expanded) {
                        if (dx < 0) { closeRevealed = card; return listOf(StagePeekEffect.Haptic(StagePeekHaptic.Tick), StagePeekEffect.RevealClose(card)) }
                        if (closeRevealed == card) { closeRevealed = null; return listOf(StagePeekEffect.RevealClose(null)) }
                    }
                    if (closeRevealed != null) { closeRevealed = null; return listOf(StagePeekEffect.RevealClose(null)) }
                    val inward = if (edge == StagePeekEdge.Left) dx else -dx
                    if (inward > 0) { expand(); return listOf(StagePeekEffect.Haptic(StagePeekHaptic.Select)) }
                    if (expanded) { compact(); return listOf(StagePeekEffect.Haptic(StagePeekHaptic.Select)) }
                    closeAll()
                    return listOf(StagePeekEffect.Dismissed)
                }
                if (!(hypot(to.x - start.point.x, to.y - start.point.y) > StagePeekConfig.tapSlop)) return emptyList()
                tapCandidate = false
                if (abs(dx) > abs(dy) * 1.5) { sideways = true; return emptyList() }
                sideways = false
                phase = Phase.Scrubbing
                val hid = closeRevealed != null
                closeRevealed = null
                return (if (hid) listOf(StagePeekEffect.RevealClose(null)) else emptyList()) + scrub(to, time, edge)
            }
            Phase.Scrubbing -> return scrub(to, time, edge)
            Phase.Closed -> return emptyList()
        }
    }

    /** [cardAt] answers which card is frontmost under a point (a tap target). */
    fun touchEnded(id: Any, at: CGPoint, time: TimeInterval, cardAt: (CGPoint) -> Int?): List<StagePeekEffect> {
        if (consumed.remove(id)) return emptyList()
        if (id != touchID) return emptyList()
        when (phase) {
            Phase.Arming -> {
                // A quick tap on the edge bar opens the peek (accessible entry); a longer press
                // that lifts before the hold completes opens nothing.
                val wasTap = start?.let { time - it.time <= StagePeekConfig.tapMaxDuration } ?: false
                resetTouch()
                phase = Phase.Closed
                return if (wasTap) openDirectly() else emptyList()
            }
            Phase.Scrubbing -> {
                settleAfterLift()
                resetTouch() // the next touch is a fresh tap candidate
                return emptyList()
            }
            Phase.Open -> {
                val wasTap = tapCandidate && (start?.let { time - it.time <= StagePeekConfig.tapMaxDuration } ?: false)
                resetTouch()
                if (!wasTap) return emptyList()
                // A tap while Close Window shows only hides it (like a swiped list row).
                if (closeRevealed != null) { closeRevealed = null; return listOf(StagePeekEffect.RevealClose(null)) }
                val i = cardAt(at)
                if (i != null && i in ids.indices) {
                    val chosen = ids[i]
                    closeAll()
                    return listOf(StagePeekEffect.Haptic(StagePeekHaptic.Select), StagePeekEffect.Select(chosen))
                }
                closeAll()
                return listOf(StagePeekEffect.Dismissed)
            }
            Phase.Closed -> {
                resetTouch()
                return emptyList()
            }
        }
    }

    /** The system took the touch (rotation, fold, app switch): never selects. */
    fun touchCancelled(id: Any) {
        if (consumed.remove(id)) return
        if (id != touchID) return
        when (phase) {
            Phase.Arming -> phase = Phase.Closed
            Phase.Scrubbing -> settleAfterLift()
            Phase.Open, Phase.Closed -> Unit
        }
        resetTouch()
    }

    // MARK: Time

    fun poll(now: TimeInterval): List<StagePeekEffect> {
        val start = start
        if (phase != Phase.Arming || start == null || !(now - start.time >= StagePeekConfig.holdDelay)) return emptyList()
        phase = Phase.Scrubbing
        expansion = 0.0
        expanded = false
        position = currentIndex.toDouble()
        anchor = Anchor(start.point, position)
        lastHighlighted = highlighted
        overrunSignalled = false
        return listOf(StagePeekEffect.Opened, StagePeekEffect.Haptic(StagePeekHaptic.Activate))
    }

    fun pollDelay(now: TimeInterval): TimeInterval? {
        val start = start
        if (phase != Phase.Arming || start == null) return null
        return max(0.0, start.time + StagePeekConfig.holdDelay - now)
    }

    // MARK: Buttons and outside events

    /** Opens without a hold (TalkBack's activate action, a keyboard shortcut): same stack, nothing selected. */
    fun openDirectly(): List<StagePeekEffect> {
        if (phase != Phase.Closed || ids.isEmpty()) return emptyList()
        resetTouch()
        phase = Phase.Open
        expansion = 0.0
        expanded = false
        position = currentIndex.toDouble()
        lastHighlighted = highlighted
        return listOf(StagePeekEffect.Opened, StagePeekEffect.Haptic(StagePeekHaptic.Activate))
    }

    /** TalkBack adjustable action / arrow keys: move the highlight by one. */
    fun step(delta: Int): List<StagePeekEffect> {
        if (!isVisible || ids.isEmpty()) return emptyList()
        val next = min(max(highlighted + delta, 0), ids.size - 1)
        if (next == highlighted) return listOf(StagePeekEffect.Haptic(StagePeekHaptic.Boundary))
        position = next.toDouble()
        lastHighlighted = next
        return listOf(StagePeekEffect.Haptic(StagePeekHaptic.Tick))
    }

    /** Chooses the highlighted window (TalkBack activate, Enter key). */
    fun selectHighlighted(): List<StagePeekEffect> {
        if (!isVisible) return emptyList()
        val chosen = highlightedID ?: return emptyList()
        closeAll()
        return listOf(StagePeekEffect.Haptic(StagePeekHaptic.Select), StagePeekEffect.Select(chosen))
    }

    /** Chooses the window at [index] (TalkBack activate on a card). */
    fun select(index: Int): List<StagePeekEffect> {
        if (!isVisible || index !in ids.indices) return emptyList()
        val chosen = ids[index]
        closeAll()
        return listOf(StagePeekEffect.Haptic(StagePeekHaptic.Select), StagePeekEffect.Select(chosen))
    }

    fun expand() {
        if (!isVisible) return
        expanded = true
        expansion = 1.0
        closeRevealed = null
    }

    /** Hides Close Window (it was used, or the window went away). */
    fun hideClose() { closeRevealed = null }

    fun compact() {
        if (!isVisible) return
        expanded = false
        expansion = 0.0
    }

    /** Dismiss without choosing (Escape, back, tap outside handled above). */
    fun dismiss(): List<StagePeekEffect> {
        if (phase == Phase.Closed) return emptyList()
        val wasVisible = isVisible
        closeAll()
        return if (wasVisible) listOf(StagePeekEffect.Dismissed) else emptyList()
    }

    /** Fold, resize, disconnect, revocation, leaving Window mode: closes silently and never selects. */
    fun cancelAll() = closeAll()

    // MARK: Internals

    private fun scrub(point: CGPoint, time: TimeInterval, edge: StagePeekEdge): List<StagePeekEffect> {
        val anchor = anchor
        if (anchor == null || ids.isEmpty()) return emptyList()
        val out = mutableListOf<StagePeekEffect>()
        val travel = (point.y - anchor.point.y) / StagePeekConfig.scrubPitch
        val raw = anchor.position + (if (naturalScrolling) -travel else travel)
        val maxIndex = (ids.size - 1).toDouble()
        val overrun = if (raw < 0) -raw else if (raw > maxIndex) raw - maxIndex else 0.0
        position = clampPosition(raw)
        if (overrun >= StagePeekConfig.boundaryOverrun) {
            if (!overrunSignalled) {
                overrunSignalled = true
                out.add(StagePeekEffect.Haptic(StagePeekHaptic.Boundary))
            }
        } else if (overrun == 0.0) {
            overrunSignalled = false
        }
        if (highlighted != lastHighlighted) {
            lastHighlighted = highlighted
            if (time - lastTickTime >= StagePeekConfig.tickSpacing) {
                lastTickTime = time
                out.add(StagePeekEffect.Haptic(StagePeekHaptic.Tick))
            }
        }
        if (!expanded) {
            val inward = if (edge == StagePeekEdge.Left) point.x - anchor.point.x else anchor.point.x - point.x
            val span = StagePeekConfig.expandFull - StagePeekConfig.expandStart
            expansion = min(max((inward - StagePeekConfig.expandStart) / span, 0.0), 1.0)
        }
        return out
    }

    /** Rubber band past the ends, at most `maxOverrun`. */
    private fun clampPosition(raw: Double): Double {
        if (ids.isEmpty()) return 0.0
        val maxIndex = (ids.size - 1).toDouble()
        val m = StagePeekConfig.maxOverrun
        fun band(x: Double): Double = m * (1 - exp(-x / m))
        if (raw < 0) return -band(-raw)
        if (raw > maxIndex) return maxIndex + band(raw - maxIndex)
        return raw
    }

    private fun settleAfterLift() {
        phase = Phase.Open
        position = highlighted.toDouble()
        if (!expanded) {
            expanded = expansion >= StagePeekConfig.expandKeep
            expansion = if (expanded) 1.0 else 0.0
        }
        overrunSignalled = false
    }

    private fun resetTouch() {
        touchID = null
        start = null
        anchor = null
        tapCandidate = false
        startCard = null
        sideways = false
    }

    private fun closeAll() {
        phase = Phase.Closed
        closeRevealed = null
        expansion = 0.0
        expanded = false
        resetTouch()
        position = currentIndex.toDouble()
        lastHighlighted = highlighted
        overrunSignalled = false
    }

    companion object {
        /** The first card in Window mode: back to the whole Mac screen. Never a window ID (CGWindowIDs start at 1). */
        const val fullDesktopID: Long = 0L
    }
}

// MARK: - Geometry

/**
 * One card on screen. [tilt] is degrees around the card's horizontal axis: positive tips its top
 * edge away from the viewer (cards above the highlighted one), negative its bottom edge (cards
 * below). `scale` is already applied to [size].
 */
data class StagePeekCard(
    val index: Int,
    val center: CGPoint,
    val size: CGSize,
    val tilt: Double,
    val z: Double,
    val opacity: Double,
    val highlighted: Boolean,
)

object StagePeekLayout {
    /**
     * The hold strip for an edge inside [safe] (the safe-area rect), clear of [avoiding]
     * (on-screen controls, hinges): the free run of the edge closest to its middle, null when none
     * is tall enough to hold.
     */
    fun strip(edge: StagePeekEdge, safe: CGRect, avoiding: List<CGRect> = emptyList()): CGRect? {
        val width = StagePeekConfig.edgeStripWidth
        val x = if (edge == StagePeekEdge.Left) safe.minX else safe.maxX - width
        val column = CGRect(x, safe.minY, width, safe.height)
        val maxHeight = min(safe.height * StagePeekConfig.edgeStripHeightFraction, StagePeekConfig.edgeStripMaxHeight)
        // Free vertical runs of the column.
        var runs = listOf(safe.minY to safe.maxY)
        for (r in avoiding) {
            if (!r.intersects(column)) continue
            runs = runs.flatMap { run ->
                if (!(r.minY < run.second && r.maxY > run.first)) listOf(run)
                else listOf(run.first to r.minY, r.maxY to run.second).filter { it.second - it.first > 0 }
            }
        }
        val minimum = 60.0
        val mid = safe.midY
        val best = runs.filter { it.second - it.first >= minimum }
            .minByOrNull { abs((it.first + it.second) / 2 - mid) }
            ?: return null
        val height = min(maxHeight, best.second - best.first)
        val center = min(max(mid, best.first + height / 2), best.second - height / 2)
        return CGRect(x, center - height / 2, width, height)
    }

    /**
     * The Compact Dock's region: between the controls above (their bottom edge) and below (their
     * top edge), with a small gap to each. Never shorter than two cards' worth.
     */
    fun dockRegion(safe: CGRect, controlsAbove: Double, controlsBelow: Double): CGRect {
        val top = min(max(controlsAbove + StagePeekConfig.dockGap, safe.minY), safe.maxY)
        val bottom = max(min(controlsBelow - StagePeekConfig.dockGap, safe.maxY), top)
        val minimum = min(160.0, safe.height)
        if (bottom - top >= minimum) return CGRect(safe.minX, top, safe.width, bottom - top)
        val mid = min(max((top + bottom) / 2, safe.minY + minimum / 2), safe.maxY - minimum / 2)
        return CGRect(safe.minX, mid - minimum / 2, safe.width, minimum)
    }

    /**
     * Visible cards, back to front. [aspects] are width / height per window. [region]: the
     * Compact Dock's band (the compact stack centres in it); null for the Normal Dock.
     */
    fun cards(
        aspects: List<Double>, position: Double, expansion: Double, edge: StagePeekEdge,
        safe: CGRect, isPad: Boolean, reduceMotion: Boolean, region: CGRect? = null,
    ): List<StagePeekCard> {
        if (aspects.isEmpty() || !(safe.width > 0) || !(safe.height > 0)) return emptyList()
        val e = min(max(expansion, 0.0), 1.0)
        fun lerp(a: Double, b: Double): Double = a + (b - a) * e
        val compactWidth = min(max(safe.width * (if (isPad) 0.24 else 0.36), 110.0), if (isPad) 300.0 else 210.0)
        val expandedWidth = min(max(safe.width * 0.6, compactWidth), if (isPad) 640.0 else 420.0)
        val maxWidth = lerp(compactWidth, expandedWidth)
        val maxHeight = safe.height * lerp(0.26, 0.42)
        val focus = min(max(position.roundedAwayFromZero().toInt(), 0), aspects.size - 1)
        fun cardSize(i: Int): CGSize {
            val aspect = min(max(aspects[i], 0.5), 2.2)
            var w = maxWidth
            var h = w / aspect
            if (h > maxHeight) { h = maxHeight; w = h * aspect }
            return CGSize(w, h)
        }
        val focusSize = cardSize(focus)
        val margin = 16.0
        // Room for the title under the highlighted card.
        // Room for the title under the highlighted card. The Compact Dock centres in its band.
        val dockCenterY = (region?.midY ?: safe.midY) - 18
        val flowCenterY = safe.midY - 18
        // Compact (e = 0) is Dock magnification: the highlighted card full size and popped out,
        // the rest shrinking smoothly with distance, upright, edge-aligned and not overlapping.
        // Expanded (e = 1) is the layered Cover Flow stack. Positions blend between the two.
        val gap = 8.0
        fun dockScale(u: Double): Double = 0.56 + 0.44 * exp(-u * u / 0.7)
        fun dockHeight(i: Int): Double = cardSize(i).height * dockScale(abs(i.toDouble() - position))
        // Dock centres: stack outward from the (continuous) position so scrubbing glides.
        val dockY = DoubleArray(aspects.size)
        val base = min(max(floor(position).toInt(), 0), aspects.size - 1)
        val frac = position - base
        if (base + 1 < aspects.size) dockY[base + 1] = dockHeight(base) / 2 + gap + dockHeight(base + 1) / 2
        for (i in (base + 2) until aspects.size) dockY[i] = dockY[i - 1] + dockHeight(i - 1) / 2 + gap + dockHeight(i) / 2
        for (i in base - 1 downTo 0) dockY[i] = dockY[i + 1] - dockHeight(i + 1) / 2 - gap - dockHeight(i) / 2
        val shift = if (base + 1 < aspects.size) frac * (dockY[base + 1] - dockY[base]) else 0.0
        val out = mutableListOf<StagePeekCard>()
        for (i in aspects.indices) {
            val k = i.toDouble() - position
            val u = abs(k)
            if (!(u <= (if (e > 0.5) 4.5 else 6.5))) continue
            val near = min(u, 1.0)
            val far = max(0.0, min(u, 3.0) - 1)
            val size = cardSize(i)
            // Cover Flow (expanded).
            val flowScale = 1 - 0.16 * near - 0.07 * far
            val step = if (u <= 1) u * 0.58 else 0.58 + (u - 1) * 0.30
            val flowY = flowCenterY + (if (k < 0) -1.0 else 1.0) * step * focusSize.height
            val flowTilt = if (reduceMotion) 0.0 else min(16 * near + 3 * far, 22.0)
            // Dock (compact).
            val ds = dockScale(u)
            val dw = size.width * ds
            val pop = 10 * max(0.0, 1 - u).pow(2) // only the highlighted card pops out
            val dockX = if (edge == StagePeekEdge.Left) safe.minX + margin + dw / 2 + pop else safe.maxX - margin - dw / 2 - pop
            val dy = dockCenterY + dockY[i] - shift
            val scale = lerp(ds, flowScale)
            out.add(
                StagePeekCard(
                    index = i,
                    center = CGPoint(lerp(dockX, safe.midX), lerp(dy, flowY)),
                    size = CGSize(size.width * scale, size.height * scale),
                    tilt = e * (if (k < 0) flowTilt else -flowTilt),
                    z = -u,
                    opacity = if (u > 3.5 && e > 0.5) max(0.0, 1 - (u - 3.5)) else 1.0,
                    highlighted = i == focus && u < 0.5,
                ),
            )
        }
        return out.sortedBy { it.z }
    }

    /** The four on-screen corners of a tilted card (top-left, top-right, bottom-right, bottom-left), with the renderers' perspective. */
    fun corners(c: StagePeekCard): List<CGPoint> {
        val theta = c.tilt * PI / 180
        val d = StagePeekConfig.perspective
        val hw = c.size.width / 2
        val hh = c.size.height / 2
        return listOf(-hw to -hh, hw to -hh, hw to hh, -hw to hh).map { (x, y) ->
            // Rotate about the horizontal axis; positive tilt sends the top (y < 0) away.
            val yr = y * cos(theta)
            val z = -y * sin(theta)
            val f = d / (d + z)
            CGPoint(c.center.x + x * f, c.center.y + yr * f)
        }
    }

    /**
     * The frontmost card containing [p] (cards fully faded out are ignored). With a Compact Dock
     * [region], nothing outside it (or in its faded edges' outer half) is a card.
     */
    fun hit(p: CGPoint, cards: List<StagePeekCard>, region: CGRect? = null): Int? {
        if (region != null && !region.insetBy(0.0, StagePeekConfig.dockFade / 2).contains(p)) return null
        for (c in cards.sortedByDescending { it.z }) {
            if (c.opacity > 0.05 && contains(corners(c), p)) return c.index
        }
        return null
    }

    private fun contains(quad: List<CGPoint>, p: CGPoint): Boolean {
        var sign = 0.0
        for (i in quad.indices) {
            val a = quad[i]
            val b = quad[(i + 1) % quad.size]
            val cross = (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)
            if (cross == 0.0) continue
            if (sign == 0.0) sign = cross else if ((sign > 0) != (cross > 0)) return false
        }
        return true
    }
}

/**
 * How many columns the expanded gallery uses: as many as fit at a readable card width, wider
 * cards with larger text. Compact sizes (phones, narrow split screens) stop at two, the phone
 * default when it fits. Sizes only, never device names.
 */
object StagePeekGalleryLayout {
    const val spacing = 14.0
    const val sidePadding = 20.0
    const val minimumCompactCard = 150.0
    const val minimumRegularCard = 200.0
    /** The narrowest a phone card gets before the gallery drops to one column. */
    const val smallestPhoneCard = 100.0
    const val maximumCompactColumns = 4
    const val maximumColumns = 6

    /** Phones: two by default (larger text wraps, never one column), up to four when wide; see StagePeek.swift. */
    fun columns(width: Double, compactSize: Boolean, textScale: Double = 1.0): Int {
        val usable = width - 2 * sidePadding
        val card = (if (compactSize) minimumCompactCard else minimumRegularCard) * min(max(textScale, 1.0), 2.0)
        val fit = floor((usable + spacing) / (card + spacing)).toInt()
        if (!compactSize) return min(max(fit, 1), maximumColumns)
        if (usable < 2 * smallestPhoneCard + spacing) return 1
        return min(max(fit, 2), maximumCompactColumns)
    }
}

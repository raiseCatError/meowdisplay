package com.raisecaterror.meowdisplay.core.demo

import com.raisecaterror.meowdisplay.core.controls.CGPoint
import com.raisecaterror.meowdisplay.core.controls.CGRect
import com.raisecaterror.meowdisplay.core.controls.CGSize
import com.raisecaterror.meowdisplay.core.session.DisplayMode
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

// The sample Mac desktop of Explore Demo (port of iOS/DemoDesktop.swift). Pure
// data: nothing here reaches a network, a store or the real session. Every
// effect lands in this object or comes back as a DemoFeedback for the screen.

/** Sample windows. A small, fixed set: each one exists to show a behavior. */
enum class DemoWindowKind(val title: String, val windowID: Long, val bundleID: String, val nativeWidth: Double, val nativeHeight: Double) {
    Notes("Notes", 101, "app.meowdisplay.demo.notes", 520.0, 400.0),
    Files("Files", 102, "app.meowdisplay.demo.files", 480.0, 380.0),
    Preview("Preview", 103, "app.meowdisplay.demo.preview", 560.0, 420.0),
    Displays("Displays", 104, "app.meowdisplay.demo.displays", 460.0, 300.0);

    val nativeSize: CGSize get() = CGSize(nativeWidth, nativeHeight)

    companion object {
        fun ofWindow(id: Long): DemoWindowKind? = entries.firstOrNull { it.windowID == id }
    }
}

data class DemoWindow(val kind: DemoWindowKind, val frame: CGRect, val scrollOffset: Double = 0.0)

data class DemoFile(val id: String, val name: String, val detail: String) {
    companion object {
        val samples = listOf(
            DemoFile("plan", "Project Plan", "Text · 4 KB"),
            DemoFile("sketch", "Interface Sketch", "Drawing · 1.2 MB"),
            DemoFile("chart", "Weekly Chart", "Chart · 88 KB"),
            DemoFile("photo", "Desk Photo", "Image · 2.4 MB"),
            DemoFile("slides", "Team Slides", "Slides · 6.1 MB"),
            DemoFile("recording", "Voice Memo", "Audio · 3.0 MB"),
            DemoFile("budget", "Budget", "Table · 120 KB"),
            DemoFile("archive", "Old Drafts", "Folder · 12 items"),
            DemoFile("map", "Route Map", "Image · 900 KB"),
            DemoFile("readme", "Read Me", "Text · 2 KB"),
        )
    }
}

/** What one demo interaction did, for the screen's feedback chip. */
sealed interface DemoFeedback {
    /** Happened here, on the sample desktop. */
    data class Local(val text: String) : DemoFeedback
    /** A Mac-only action a real session would send (a shortcut, Mission Control, …). */
    data class OnMac(val text: String) : DemoFeedback
}

/** Where a point on a window's own content lands (window-local points, title bar included). */
sealed interface DemoHit {
    data object MenuBar : DemoHit
    data class Dock(val kind: DemoWindowKind) : DemoHit
    data class Close(val kind: DemoWindowKind) : DemoHit
    data class TitleBar(val kind: DemoWindowKind) : DemoHit
    data class FileRow(val kind: DemoWindowKind, val fileID: String) : DemoHit
    data class DisplayCard(val index: Int) : DemoHit
    data class Content(val kind: DemoWindowKind) : DemoHit
    data object Desktop : DemoHit
}

/**
 * The desktop: windows in desktop points (top-left origin) for Mirror and
 * Extend. Window mode draws each window at its own [DemoWindowKind.nativeSize]
 * inside a tile instead, so window content is hit-tested in window-local
 * points ([contentHit]) for both.
 */
class DemoDesktop(mode: DisplayMode, size: CGSize) {
    var mode: DisplayMode = mode; private set
    var size: CGSize = size; private set
    /** Back to front. */
    var windows: List<DemoWindow> = layout(mode, size); private set
    var focused: DemoWindowKind? = windows.lastOrNull()?.kind; private set
    var selectedFile: String? = null; private set
    var previewFile: String = DemoFile.samples[0].id; private set
    var previewZoom: Double = 1.0; private set
    var notes: String = INITIAL_NOTES; private set
    var highlightedDisplay: Int = 1; private set
    var showingDesktop: Boolean = false; private set
    /** Scroll offsets of windows shown in tiles (Window mode keeps them apart from desktop frames). */
    private val tileScroll = mutableMapOf<DemoWindowKind, Double>()
    private val undoStack = ArrayDeque<String>()
    private val redoStack = ArrayDeque<String>()

    val hasDock: Boolean get() = mode == DisplayMode.Mirror
    val visibleWindows: List<DemoWindow> get() = if (showingDesktop) emptyList() else windows

    fun window(kind: DemoWindowKind): DemoWindow? = windows.firstOrNull { it.kind == kind }

    fun scrollOffset(kind: DemoWindowKind): Double =
        if (mode == DisplayMode.Window) tileScroll[kind] ?: 0.0 else window(kind)?.scrollOffset ?: 0.0

    /** New mode or desktop size: a fresh arrangement, with text, selection and preview kept. */
    fun reconfigure(mode: DisplayMode, size: CGSize) {
        if (mode == this.mode && size == this.size) return
        this.mode = mode
        this.size = size
        windows = layout(mode, size)
        val keep = focused
        if (keep != null && windows.any { it.kind == keep }) raise(keep) else focused = windows.lastOrNull()?.kind
        showingDesktop = false
    }

    fun resetLayout() {
        windows = layout(mode, size)
        focused = windows.lastOrNull()?.kind
        showingDesktop = false
        previewZoom = 1.0
    }

    // MARK: Hit testing

    fun dockFrames(): List<Pair<DemoWindowKind, CGRect>> {
        if (!hasDock) return emptyList()
        val kinds = listOf(DemoWindowKind.Notes, DemoWindowKind.Files, DemoWindowKind.Preview)
        val spacing = 10.0
        val total = kinds.size * DOCK_ITEM + (kinds.size - 1) * spacing
        val originX = (size.width - total) / 2
        val y = size.height - DOCK_HEIGHT + (DOCK_HEIGHT - DOCK_ITEM) / 2 - 6
        return kinds.mapIndexed { i, kind -> kind to CGRect(originX + i * (DOCK_ITEM + spacing), y, DOCK_ITEM, DOCK_ITEM) }
    }

    /** A desktop point (Mirror/Extend). */
    fun hit(point: CGPoint): DemoHit {
        if (point.y < MENU_BAR_HEIGHT) return DemoHit.MenuBar
        for ((kind, frame) in dockFrames()) if (frame.insetBy(-4.0, -4.0).contains(point)) return DemoHit.Dock(kind)
        for (window in visibleWindows.asReversed()) {
            if (!window.frame.contains(point)) continue
            return contentHit(window.kind, CGPoint(point.x - window.frame.minX, point.y - window.frame.minY), window.frame.size, window.scrollOffset)
        }
        return DemoHit.Desktop
    }

    /** A point in a window's own coordinates (title bar at the top). */
    fun contentHit(kind: DemoWindowKind, local: CGPoint, windowSize: CGSize, scroll: Double = scrollOffset(kind)): DemoHit {
        if (closeButtonFrame().contains(local)) return DemoHit.Close(kind)
        if (local.y < TITLE_BAR_HEIGHT) return DemoHit.TitleBar(kind)
        when (kind) {
            DemoWindowKind.Files -> {
                val index = ((local.y - TITLE_BAR_HEIGHT + scroll) / ROW_HEIGHT).toInt()
                if (index in DemoFile.samples.indices) return DemoHit.FileRow(kind, DemoFile.samples[index].id)
            }
            DemoWindowKind.Displays -> {
                val index = displayCardFrames(windowSize).indexOfFirst { it.contains(local) }
                if (index >= 0) return DemoHit.DisplayCard(index)
            }
            else -> Unit
        }
        return DemoHit.Content(kind)
    }

    /** The Mac and the receiver in the Displays window, window-local. */
    fun displayCardFrames(windowSize: CGSize): List<CGRect> {
        val content = CGRect(16.0, TITLE_BAR_HEIGHT + 34, windowSize.width - 32, max(windowSize.height - TITLE_BAR_HEIGHT - 46, 30.0))
        val mac = CGRect(content.minX, content.minY + 6, content.width * 0.52, content.height - 12)
        val device = CGRect(mac.maxX + 8, content.minY + content.height * 0.2, content.width - mac.width - 8, content.height * 0.6)
        return listOf(mac, device)
    }

    // MARK: Actions

    fun raise(kind: DemoWindowKind) {
        val index = windows.indexOfFirst { it.kind == kind }
        if (index < 0) return
        windows = windows.toMutableList().also { it.add(it.removeAt(index)) }
        focused = kind
    }

    /** Focus without reordering (Window mode: the tile's window comes to the front on the Mac). */
    fun focus(kind: DemoWindowKind?) {
        focused = kind
    }

    /** One click at a desktop point. */
    fun click(point: CGPoint): DemoFeedback? = apply(hit(point), doubleClick = false)

    fun doubleClick(point: CGPoint): DemoFeedback? = apply(hit(point), doubleClick = true)

    /** One click on window content (Window mode), window-local. */
    fun clickInWindow(kind: DemoWindowKind, local: CGPoint, doubleClick: Boolean): DemoFeedback? {
        focused = kind
        return when (val hit = contentHit(kind, local, kind.nativeSize)) {
            // Closing a tile's window is an explicit, confirmed action on the receiver; a stray tap never closes it here.
            is DemoHit.Close, is DemoHit.TitleBar -> null
            else -> apply(hit, doubleClick)
        }
    }

    private fun apply(hit: DemoHit, doubleClick: Boolean): DemoFeedback? {
        if (doubleClick) {
            when (hit) {
                is DemoHit.FileRow -> {
                    selectedFile = hit.fileID
                    previewFile = hit.fileID
                    if (mode != DisplayMode.Window && window(DemoWindowKind.Preview) == null) reopen(DemoWindowKind.Preview)
                    if (mode != DisplayMode.Window) raise(DemoWindowKind.Preview)
                    return DemoFeedback.Local("Opened ${DemoFile.samples.first { it.id == hit.fileID }.name}")
                }
                is DemoHit.Content -> if (hit.kind == DemoWindowKind.Preview) {
                    if (mode != DisplayMode.Window) raise(DemoWindowKind.Preview)
                    previewZoom = if (previewZoom > 1) 1.0 else 1.6
                    return DemoFeedback.Local(if (previewZoom > 1) "Zoomed in" else "Actual size")
                }
                else -> Unit
            }
        }
        return when (hit) {
            DemoHit.MenuBar -> DemoFeedback.OnMac("Menu bar")
            is DemoHit.Dock -> {
                showingDesktop = false
                if (window(hit.kind) == null) reopen(hit.kind)
                raise(hit.kind)
                DemoFeedback.Local("Opened ${hit.kind.title}")
            }
            is DemoHit.Close -> {
                windows = windows.filterNot { it.kind == hit.kind }
                focused = windows.lastOrNull()?.kind
                DemoFeedback.Local("Closed ${hit.kind.title}")
            }
            is DemoHit.TitleBar -> { raiseOrFocus(hit.kind); null }
            is DemoHit.Content -> { raiseOrFocus(hit.kind); null }
            is DemoHit.FileRow -> { raiseOrFocus(hit.kind); selectedFile = hit.fileID; null }
            is DemoHit.DisplayCard -> { raiseOrFocus(DemoWindowKind.Displays); highlightedDisplay = hit.index; null }
            DemoHit.Desktop -> {
                if (showingDesktop) {
                    showingDesktop = false
                    DemoFeedback.Local("Windows restored")
                } else {
                    focused = null
                    selectedFile = null
                    null
                }
            }
        }
    }

    private fun raiseOrFocus(kind: DemoWindowKind) = if (mode == DisplayMode.Window) focus(kind) else raise(kind)

    private fun reopen(kind: DemoWindowKind) {
        val frame = layout(mode, size).firstOrNull { it.kind == kind }?.frame ?: CGRect(40.0, 60.0, 320.0, 240.0)
        windows = windows + DemoWindow(kind, frame)
    }

    /** Moves a window by its title bar, keeping the bar reachable. */
    fun moveWindow(kind: DemoWindowKind, dx: Double, dy: Double) {
        windows = windows.map { w ->
            if (w.kind != kind) return@map w
            val f = w.frame.offsetBy(dx, dy)
            val x = min(max(f.minX, 40 - f.width), size.width - 40)
            val y = min(max(f.minY, MENU_BAR_HEIGHT), size.height - TITLE_BAR_HEIGHT)
            w.copy(frame = CGRect(x, y, f.width, f.height))
        }
    }

    fun contentHeight(kind: DemoWindowKind): Double = when (kind) {
        DemoWindowKind.Files -> DemoFile.samples.size * ROW_HEIGHT + 8
        DemoWindowKind.Notes -> (notes.split("\n").size + 6) * NOTES_LINE_HEIGHT
        else -> 0.0
    }

    fun maxScroll(kind: DemoWindowKind, windowHeight: Double): Double = max(contentHeight(kind) - (windowHeight - TITLE_BAR_HEIGHT), 0.0)

    /** Scrolls the window under a desktop point by [dy] content points. True when something moved. */
    fun scroll(point: CGPoint, dy: Double): Boolean {
        val kind = when (val hit = hit(point)) {
            is DemoHit.TitleBar -> hit.kind
            is DemoHit.Content -> hit.kind
            is DemoHit.FileRow -> hit.kind
            is DemoHit.Close -> hit.kind
            is DemoHit.DisplayCard -> DemoWindowKind.Displays
            else -> return false
        }
        val window = window(kind) ?: return false
        val next = min(max(window.scrollOffset + dy, 0.0), maxScroll(kind, window.frame.height))
        if (next == window.scrollOffset) return false
        windows = windows.map { if (it.kind == kind) it.copy(scrollOffset = next) else it }
        return true
    }

    /** Scrolls a window shown in a tile (Window mode). */
    fun scrollInWindow(kind: DemoWindowKind, dy: Double): Boolean {
        val current = tileScroll[kind] ?: 0.0
        val next = min(max(current + dy, 0.0), maxScroll(kind, kind.nativeHeight))
        if (next == current) return false
        tileScroll[kind] = next
        return true
    }

    // MARK: Keys and text

    /** Typing goes to Notes only while Notes is the focused window. */
    fun type(text: String): Boolean {
        if (focused != DemoWindowKind.Notes || text.isEmpty()) return false
        if (mode != DisplayMode.Window && window(DemoWindowKind.Notes) == null) return false
        record()
        notes = (notes + text).takeLast(MAX_NOTES)
        return true
    }

    fun deleteBackward(): Boolean {
        if (focused != DemoWindowKind.Notes || notes.isEmpty()) return false
        record()
        notes = notes.dropLast(1)
        return true
    }

    private fun record() {
        undoStack.addLast(notes)
        if (undoStack.size > 50) undoStack.removeFirst()
        redoStack.clear()
    }

    fun undo(): Boolean {
        val previous = undoStack.removeLastOrNull() ?: return false
        redoStack.addLast(notes)
        notes = previous
        return true
    }

    fun redo(): Boolean {
        val next = redoStack.removeLastOrNull() ?: return false
        undoStack.addLast(notes)
        notes = next
        return true
    }

    /** Ordinary keys as HID usages with modifier names. Null: only a Mac could act on it. */
    fun key(usage: Int, modifiers: Set<String>): DemoFeedback? {
        val command = setOf("command")
        when {
            usage == 29 && modifiers == command -> return DemoFeedback.Local(if (undo()) "Undo" else "Nothing to undo")
            usage == 29 && modifiers == setOf("command", "shift") -> return DemoFeedback.Local(if (redo()) "Redo" else "Nothing to redo")
            usage == 46 && modifiers == command && focused == DemoWindowKind.Preview -> {
                previewZoom = min(previewZoom + 0.25, 2.5)
                return DemoFeedback.Local("Preview zoomed in")
            }
            usage == 45 && modifiers == command && focused == DemoWindowKind.Preview -> {
                previewZoom = max(previewZoom - 0.25, 0.5)
                return DemoFeedback.Local("Preview zoomed out")
            }
            usage == 26 && modifiers == command -> {
                val target = focused ?: return null
                if (mode == DisplayMode.Window) return DemoFeedback.OnMac("⌘W closes the window on a Mac")
                windows = windows.filterNot { it.kind == target }
                focused = windows.lastOrNull()?.kind
                return DemoFeedback.Local("Closed ${target.title}")
            }
            usage == 43 && modifiers.isEmpty() -> {
                if (windows.isEmpty()) return null
                if (mode == DisplayMode.Window) return DemoFeedback.OnMac("Tab moves focus on your Mac")
                raise(windows[0].kind)
                return DemoFeedback.Local("Focused ${focused?.title ?: "Notes"}")
            }
            usage == 41 && modifiers.isEmpty() -> {
                if (showingDesktop) { showingDesktop = false; return DemoFeedback.Local("Windows restored") }
                selectedFile = null
                return DemoFeedback.Local("Selection cleared")
            }
            usage == 42 && modifiers.isEmpty() -> return if (deleteBackward()) DemoFeedback.Local("Deleted") else null
            usage == 40 && modifiers.isEmpty() -> return if (type("\n")) DemoFeedback.Local("New line") else null
            (usage == 81 || usage == 82) && modifiers.isEmpty() -> {
                if (focused != DemoWindowKind.Files) return null
                val ids = DemoFile.samples.map { it.id }
                val current = selectedFile?.let { ids.indexOf(it) } ?: -1
                val next = min(max(current + if (usage == 81) 1 else -1, 0), ids.size - 1)
                selectedFile = ids[next]
                return DemoFeedback.Local("Selected ${DemoFile.samples[next].name}")
            }
        }
        if (modifiers.isEmpty() || modifiers == setOf("shift")) {
            val character = character(usage, "shift" in modifiers)
            if (character != null && type(character)) return DemoFeedback.Local("Typed in Notes")
        }
        return null
    }

    fun toggleShowDesktop(): DemoFeedback {
        showingDesktop = !showingDesktop
        return DemoFeedback.Local(if (showingDesktop) "Showing the desktop" else "Windows restored")
    }

    companion object {
        const val LONG_EDGE = 960.0
        const val MENU_BAR_HEIGHT = 24.0
        const val TITLE_BAR_HEIGHT = 28.0
        const val ROW_HEIGHT = 30.0
        const val DOCK_HEIGHT = 56.0
        const val DOCK_ITEM = 44.0
        const val NOTES_LINE_HEIGHT = 22.0
        const val MAX_NOTES = 4_000
        val INITIAL_NOTES = """
            Welcome to MeowDisplay.

            This sample desktop runs on this device, so you can try the controls without a Mac.

            Tap or click to focus a window. Drag a title bar to move it. Scroll the Files list. Double-tap a file to preview it.

            Open the keyboard to type here.
        """.trimIndent()

        /** The sample Mac's own built-in display (points), which Mirror shows. */
        val MIRROR_SOURCE = CGSize(1512.0, 982.0)

        /** Desktop size for an aspect (width / height), long edge fixed. */
        fun sizeForAspect(aspect: Double): CGSize {
            val a = if (aspect.isFinite() && aspect > 0) aspect else 1.6
            return if (a >= 1) CGSize(LONG_EDGE, (LONG_EDGE / a).roundToInt().toDouble())
            else CGSize((LONG_EDGE * a).roundToInt().toDouble(), LONG_EDGE)
        }

        /** Mirror shows the sample Mac's display; Extend and Window take this device's own shape. */
        fun desktopSize(mode: DisplayMode, panelWidth: Int, panelHeight: Int): CGSize = when (mode) {
            DisplayMode.Mirror -> sizeForAspect(MIRROR_SOURCE.width / MIRROR_SOURCE.height)
            else -> sizeForAspect(if (panelWidth > 0 && panelHeight > 0) panelWidth.toDouble() / panelHeight else 1.6)
        }

        fun windowKinds(mode: DisplayMode): List<DemoWindowKind> =
            if (mode == DisplayMode.Mirror) listOf(DemoWindowKind.Files, DemoWindowKind.Preview, DemoWindowKind.Notes)
            else listOf(DemoWindowKind.Displays, DemoWindowKind.Notes, DemoWindowKind.Preview)

        /** Initial frames, back to front. Wide desktops place windows side by side; tall ones stack them. */
        fun layout(mode: DisplayMode, size: CGSize): List<DemoWindow> {
            val top = MENU_BAR_HEIGHT + 12
            val bottom = size.height - if (mode == DisplayMode.Mirror) DOCK_HEIGHT + 16 else 12.0
            val usable = CGRect(12.0, top, size.width - 24, max(bottom - top, 120.0))
            val kinds = windowKinds(mode)
            val frames = mutableMapOf<DemoWindowKind, CGRect>()
            val w = usable.width
            val h = usable.height
            if (size.width >= size.height * 1.15) {
                if (mode == DisplayMode.Mirror) {
                    frames[DemoWindowKind.Notes] = CGRect(usable.minX, usable.minY, w * 0.46, h * 0.78)
                    frames[DemoWindowKind.Files] = CGRect(usable.minX + w * 0.5, usable.minY, w * 0.5, h * 0.52)
                    frames[DemoWindowKind.Preview] = CGRect(usable.minX + w * 0.42, usable.minY + h * 0.4, w * 0.5, h * 0.6)
                } else {
                    frames[DemoWindowKind.Preview] = CGRect(usable.minX, usable.minY, w * 0.58, h * 0.9)
                    frames[DemoWindowKind.Notes] = CGRect(usable.minX + w * 0.6, usable.minY + h * 0.36, w * 0.4, h * 0.64)
                    frames[DemoWindowKind.Displays] = CGRect(usable.minX + w * 0.6, usable.minY, w * 0.4, h * 0.34)
                }
            } else {
                val gap = 10.0
                val each = (h - gap * 2) / 3
                kinds.asReversed().forEachIndexed { i, kind -> frames[kind] = CGRect(usable.minX, usable.minY + i * (each + gap), w, each) }
            }
            return kinds.map { DemoWindow(it, frames.getValue(it).integral()) }
        }

        fun closeButtonFrame(): CGRect = CGRect(8.0, 7.0, 14.0, 14.0).insetBy(-6.0, -6.0)

        fun character(usage: Int, shift: Boolean): String? = when (usage) {
            in 4..29 -> ((usage - 4) + if (shift) 'A'.code else 'a'.code).toChar().toString()
            in 30..38 -> (usage - 29).toString()
            39 -> "0"
            44 -> " "
            else -> null
        }

        private fun CGRect.integral(): CGRect {
            val x0 = kotlin.math.floor(minX); val y0 = kotlin.math.floor(minY)
            return CGRect(x0, y0, kotlin.math.ceil(maxX) - x0, kotlin.math.ceil(maxY) - y0)
        }
    }
}

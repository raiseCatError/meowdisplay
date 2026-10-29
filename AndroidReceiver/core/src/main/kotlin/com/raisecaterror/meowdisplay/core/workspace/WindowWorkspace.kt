package com.raisecaterror.meowdisplay.core.workspace

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToLong

// Port of Shared/WindowWorkspace.swift (window workspaces' layout engine and
// tile transform). Same rules, same numbers: fixtures/workspace/vectors.json,
// written by the Swift tests, is checked here too.

data class WPoint(val x: Double, val y: Double)
data class WSize(val width: Double, val height: Double)

data class WRect(val x: Double, val y: Double, val width: Double, val height: Double) {
    val maxX get() = x + width
    val maxY get() = y + height
    val midX get() = x + width / 2
    val midY get() = y + height / 2
    val area get() = max(width, 0.0) * max(height, 0.0)

    fun contains(p: WPoint) = p.x >= x && p.x < maxX && p.y >= y && p.y < maxY

    fun intersection(o: WRect): WRect? {
        val x0 = max(x, o.x); val y0 = max(y, o.y)
        val x1 = min(maxX, o.maxX); val y1 = min(maxY, o.maxY)
        if (x1 <= x0 || y1 <= y0) return null
        return WRect(x0, y0, x1 - x0, y1 - y0)
    }

    fun scaled(to: WSize) = WRect(x * to.width, y * to.height, width * to.width, height * to.height)

    companion object { val UNIT = WRect(0.0, 0.0, 1.0, 1.0) }
}

enum class WAxis(val wire: String) { Horizontal("horizontal"), Vertical("vertical");
    companion object { fun of(s: String?) = entries.firstOrNull { it.wire == s } }
}

/** Clockwise presentation rotation of a tile; the Mac window never rotates. */
enum class WRotation(val degrees: Int) {
    None(0), Quarter(90), Half(180), ThreeQuarter(270);

    val isQuarterTurn get() = this == Quarter || this == ThreeQuarter
    val clockwise get() = of(degrees + 90)

    companion object {
        fun of(degrees: Int): WRotation = entries.firstOrNull { it.degrees == ((degrees % 360) + 360) % 360 } ?: None
    }
}

enum class WFit(val wire: String) { Fit("fit"), Fill("fill"), Auto("auto");
    companion object {
        fun of(s: String?) = entries.firstOrNull { it.wire == s } ?: Auto
        /** Filling must show at least this share of the window along the cropped side. */
        const val AUTO_FILL_MINIMUM_SHOWN = 0.7
        /** [Auto] resolved for a tile and a (rotated) source size (WorkspaceFit.resolved). */
        fun resolved(fit: WFit, tile: WSize, source: WSize): WFit {
            if (fit != Auto) return fit
            if (tile.width <= 0 || tile.height <= 0 || source.width <= 0 || source.height <= 0) return Fit
            val sx = tile.width / source.width; val sy = tile.height / source.height
            return if (min(sx, sy) / max(sx, sy) >= AUTO_FILL_MINIMUM_SHOWN) Fill else Fit
        }
    }
}

/** Window pixels <-> canvas for one tile. Both directions exact inverses (TileContentTransform). */
data class TileTransform(val tile: WRect, val source: WSize, val rotation: WRotation, val fit: WFit) {
    val rotatedSource get() = if (rotation.isQuarterTurn) WSize(source.height, source.width) else source

    /** [WFit.Auto] resolved for this tile and source. */
    val effectiveFit: WFit get() = WFit.resolved(fit, WSize(tile.width, tile.height), rotatedSource)

    val scale: Double get() {
        val r = rotatedSource
        if (r.width <= 0 || r.height <= 0 || tile.width <= 0 || tile.height <= 0) return 0.0
        val sx = tile.width / r.width; val sy = tile.height / r.height
        return if (effectiveFit == WFit.Fit) min(sx, sy) else max(sx, sy)
    }

    val contentRect: WRect get() {
        val r = rotatedSource; val s = scale
        val w = r.width * s; val h = r.height * s
        return WRect(tile.midX - w / 2, tile.midY - h / 2, w, h)
    }

    val visibleRect get() = contentRect.intersection(tile)

    fun canvasPoint(fromSource: WPoint): WPoint {
        val r = rotated(fromSource); val c = contentRect; val s = scale
        return WPoint(c.x + r.x * s, c.y + r.y * s)
    }

    fun sourcePoint(fromCanvas: WPoint): WPoint? {
        val visible = visibleRect ?: return null
        if (!visible.contains(fromCanvas)) return null
        val c = contentRect; val s = scale
        if (s <= 0) return null
        val p = unrotated(WPoint((fromCanvas.x - c.x) / s, (fromCanvas.y - c.y) / s))
        return WPoint(min(max(p.x, 0.0), source.width), min(max(p.y, 0.0), source.height))
    }

    private fun rotated(p: WPoint): WPoint {
        val w = source.width; val h = source.height
        return when (rotation) {
            WRotation.None -> p
            WRotation.Quarter -> WPoint(h - p.y, p.x)
            WRotation.Half -> WPoint(w - p.x, h - p.y)
            WRotation.ThreeQuarter -> WPoint(p.y, w - p.x)
        }
    }

    private fun unrotated(r: WPoint): WPoint {
        val w = source.width; val h = source.height
        return when (rotation) {
            WRotation.None -> r
            WRotation.Quarter -> WPoint(r.y, h - r.x)
            WRotation.Half -> WPoint(w - r.x, h - r.y)
            WRotation.ThreeQuarter -> WPoint(w - r.y, r.x)
        }
    }
}

enum class WFollow(val wire: String) { Window("window"), App("app");
    companion object { fun of(s: String?) = entries.firstOrNull { it.wire == s } ?: Window }
}

/** What a tile shows. The Mac checks identity; `host` only routes requests. */
data class WSource(val host: String, val windowID: Long, val generation: Long? = null, val bundleID: String? = null, val follow: WFollow = WFollow.Window)

/**
 * One pane. [source] is what it shows (its active tab; only that one streams). [crop] is the
 * zoomed/panned part of the window, normalized, with the pane's own shape (fills it: no bars).
 * [tabs] lists every window in the pane in label order when it holds more than one.
 */
data class WTile(
    val id: String, val source: WSource? = null, val rotation: WRotation = WRotation.None, val fit: WFit = WFit.Auto,
    val crop: WRect? = null, val tabs: List<WSource> = emptyList(),
) {
    val windows: List<WSource> get() = if (tabs.isEmpty()) listOfNotNull(source) else tabs
}

private fun WSource.sameWindow(o: WSource) = host == o.host && windowID == o.windowID

/** Pinch and pan inside one pane (WorkspaceZoom). */
object WZoom {
    const val MAXIMUM = 8.0

    fun fillCrop(window: WSize, tile: WSize, rotation: WRotation): WRect {
        if (window.width <= 0 || window.height <= 0 || tile.width <= 0 || tile.height <= 0) return WRect(0.0, 0.0, 1.0, 1.0)
        val t = if (rotation.isQuarterTurn) WSize(tile.height, tile.width) else tile
        val tileAspect = t.width / t.height; val windowAspect = window.width / window.height
        if (tileAspect >= windowAspect) {
            val h = windowAspect / tileAspect
            return WRect(0.0, (1 - h) / 2, 1.0, h)
        }
        val w = tileAspect / windowAspect
        return WRect((1 - w) / 2, 0.0, w, 1.0)
    }

    fun apply(crop: WRect?, base: WRect, scale: Double, anchor: WPoint, pan: WPoint): WRect? {
        val c = crop ?: base
        if (!scale.isFinite() || scale <= 0 || !listOf(anchor.x, anchor.y, pan.x, pan.y).all { it.isFinite() } ||
            c.width <= 0 || c.height <= 0 || base.width <= 0 || base.height <= 0) return crop
        val k = min(max(c.width / scale, base.width / MAXIMUM), base.width) / c.width
        val w = c.width * k; val h = c.height * k
        val ax = c.x + anchor.x * c.width; val ay = c.y + anchor.y * c.height
        var x = ax - anchor.x * w - pan.x * w; var y = ay - anchor.y * h - pan.y * h
        x = min(max(x, 0.0), max(1 - w, 0.0)); y = min(max(y, 0.0), max(1 - h, 0.0))
        val eps = 1e-6
        if (abs(w - base.width) < eps && abs(h - base.height) < eps && abs(x - base.x) < eps && abs(y - base.y) < eps) return null
        return WRect(x, y, w, h)
    }
}

/** Where a window dragged from Stage Peek (or a pane's label) lands. */
sealed interface WWindowDrop {
    val preview: WRect
    data class Replace(val tile: String, override val preview: WRect) : WWindowDrop
    data class Tab(val tile: String, override val preview: WRect) : WWindowDrop
    data class Split(val index: Int, val edge: WEdge, override val preview: WRect) : WWindowDrop
    data class EmptySlot(val index: Int, override val preview: WRect) : WWindowDrop
}

sealed interface WNode {
    data class Slot(val tile: String?) : WNode
    data class Split(val axis: WAxis, val children: List<WNode>, val ratios: List<Double>) : WNode

    val tileIDs: List<String> get() = when (this) {
        is Slot -> listOfNotNull(tile)
        is Split -> children.flatMap { it.tileIDs }
    }
    val slotCount: Int get() = when (this) {
        is Slot -> 1
        is Split -> children.sumOf { it.slotCount }
    }
}

/** [title]: what a person hears or reads for the layout ("Two side by side"). */
enum class WPreset(val slotCount: Int, val title: String) {
    Single(1, "One window"), SideBySide(2, "Two side by side"), Stacked(2, "Two stacked"),
    PrimaryPlusTwo(3, "One large and two small"), ThreeColumns(3, "Three side by side"), ThreeRows(3, "Three stacked"),
    Grid2x2(4, "Four in a grid"), Grid3x2(6, "Six, three across"), Grid2x3(6, "Six, two across"),
    Grid3x3(9, "Nine in a grid"), PrimaryPlusFour(5, "One large and four small");

    fun node(tiles: List<String?>): WNode {
        val queue = ArrayDeque(tiles)
        fun next(): WNode = WNode.Slot(if (queue.isEmpty()) null else queue.removeFirst())
        fun even(axis: WAxis, count: Int, make: () -> WNode) = WNode.Split(axis, List(count) { make() }, List(count) { 1.0 / count })
        return when (this) {
            Single -> next()
            SideBySide -> even(WAxis.Horizontal, 2, ::next)
            Stacked -> even(WAxis.Vertical, 2, ::next)
            ThreeColumns -> even(WAxis.Horizontal, 3, ::next)
            ThreeRows -> even(WAxis.Vertical, 3, ::next)
            PrimaryPlusTwo -> { val p = next(); WNode.Split(WAxis.Horizontal, listOf(p, even(WAxis.Vertical, 2, ::next)), listOf(0.62, 0.38)) }
            PrimaryPlusFour -> { val p = next(); WNode.Split(WAxis.Horizontal, listOf(p, even(WAxis.Vertical, 4, ::next)), listOf(0.62, 0.38)) }
            Grid2x2 -> even(WAxis.Vertical, 2) { even(WAxis.Horizontal, 2, ::next) }
            Grid3x2 -> even(WAxis.Vertical, 2) { even(WAxis.Horizontal, 3, ::next) }
            Grid2x3 -> even(WAxis.Vertical, 3) { even(WAxis.Horizontal, 2, ::next) }
            Grid3x3 -> even(WAxis.Vertical, 3) { even(WAxis.Horizontal, 3, ::next) }
        }
    }

    companion object {
        fun available(capacity: Int) = entries.filter { it.slotCount <= capacity }

        fun natural(count: Int, landscape: Boolean): WPreset = when {
            count <= 1 -> Single
            count == 2 -> if (landscape) SideBySide else Stacked
            count == 3 -> if (landscape) PrimaryPlusTwo else ThreeRows
            count == 4 -> Grid2x2
            count == 5 -> PrimaryPlusFour
            count == 6 -> if (landscape) Grid3x2 else Grid2x3
            else -> Grid3x3
        }
    }
}

enum class WEdge(val wire: String) {
    Left("left"), Right("right"), Top("top"), Bottom("bottom");
    val axis get() = if (this == Left || this == Right) WAxis.Horizontal else WAxis.Vertical
    val leading get() = this == Left || this == Top
}

sealed interface WDropTarget {
    val preview: WRect
    data class Slot(val index: Int, override val preview: WRect) : WDropTarget
    data class Split(val index: Int, val edge: WEdge, override val preview: WRect) : WDropTarget
}

/** Sentinel for "no such slot" in [WLayout.slotAt]. */
private object NoSlot

class WLayout private constructor(val root: WNode, val tiles: Map<String, WTile>, val maximized: String?) {
    val orderedTileIDs get() = root.tileIDs
    val slotCount get() = root.slotCount

    override fun equals(other: Any?) = other is WLayout && root == other.root && tiles == other.tiles && maximized == other.maximized
    override fun hashCode() = root.hashCode() * 31 + tiles.hashCode()
    override fun toString() = "WLayout(root=$root, tiles=$tiles, maximized=$maximized)"

    fun with(root: WNode = this.root, tiles: Map<String, WTile> = this.tiles, maximized: String? = this.maximized) = of(root, tiles, maximized)

    fun swapping(a: String, b: String): WLayout {
        if (a == b || a !in tiles || b !in tiles) return this
        return with(root = mapSlots(root) { if (it == a) b else if (it == b) a else it })
    }

    fun adding(tile: WTile, landscape: Boolean): WLayout {
        if (tile.id in tiles || tiles.size >= MAXIMUM_TILES) return this
        val newTiles = tiles + (tile.id to tile)
        val empty = (0 until slotCount).firstOrNull { slotAt(root, it) == null && slotExists(root, it) }
        val newRoot = if (empty != null) setSlot(root, empty, tile.id) else split(root, slotCount - 1, if (landscape) WEdge.Right else WEdge.Bottom, tile.id)
        return of(newRoot, newTiles, null)
    }

    fun removing(id: String): WLayout {
        if (id !in tiles) return this
        return of(removeSlot(root, id), tiles - id, if (maximized == id) null else maximized)
    }

    /** Change what a pane shows; in a tabbed pane this replaces the active tab (null removes it). */
    fun replacingSource(id: String, source: WSource?): WLayout {
        var t = tiles[id] ?: return this
        if (t.source != source) t = t.copy(crop = null)
        val current = t.source
        if (t.tabs.isNotEmpty() && current != null) {
            val i = t.tabs.indexOfFirst { it.sameWindow(current) }
            if (i >= 0) {
                if (source == null) {
                    val rest = t.tabs.toMutableList().also { it.removeAt(i) }
                    val shown = if (rest.isEmpty()) null else rest[min(i, rest.size - 1)]
                    return with(tiles = tiles + (id to t.copy(source = shown, tabs = if (rest.size <= 1) emptyList() else rest)))
                }
                val list = t.tabs.toMutableList().also { it[i] = source }.distinctBy { it.host to it.windowID }
                return with(tiles = tiles + (id to t.copy(source = source, tabs = if (list.size <= 1) emptyList() else list)))
            }
        }
        return with(tiles = tiles + (id to t.copy(source = source)))
    }

    fun zooming(id: String, crop: WRect?): WLayout {
        val t = tiles[id] ?: return this
        if (t.crop == crop) return this
        return with(tiles = tiles + (id to t.copy(crop = crop)))
    }

    fun addingTab(source: WSource, id: String): WLayout {
        val t = tiles[id] ?: return this
        val current = t.source ?: return replacingSource(id, source)
        val list = t.windows.toMutableList()
        if (list.none { it.sameWindow(current) }) list += current
        list.removeAll { it.sameWindow(source) }
        list += source
        return with(tiles = tiles + (id to t.copy(source = source, tabs = if (list.size > 1) list else emptyList(), crop = null)))
    }

    fun switchingTab(id: String, index: Int): WLayout {
        val t = tiles[id] ?: return this
        if (index !in t.tabs.indices || t.source == t.tabs[index]) return this
        return with(tiles = tiles + (id to t.copy(source = t.tabs[index], crop = null)))
    }

    fun removingTab(id: String, index: Int): WLayout {
        val t = tiles[id] ?: return this
        if (index !in t.tabs.indices) return this
        val rest = t.tabs.toMutableList(); val removed = rest.removeAt(index)
        var shown = t.source; var crop = t.crop
        if (shown == removed) { shown = if (rest.isEmpty()) null else rest[min(index, rest.size - 1)]; crop = null }
        return with(tiles = tiles + (id to t.copy(source = shown, crop = crop, tabs = if (rest.size <= 1) emptyList() else rest)))
    }

    fun tileHolding(host: String, windowID: Long): String? =
        orderedTileIDs.firstOrNull { id -> tiles[id]?.windows?.any { it.host == host && it.windowID == windowID } == true }

    fun insertingSplit(tile: WTile, index: Int, edge: WEdge): WLayout {
        if (tile.id in tiles || tiles.size >= MAXIMUM_TILES || !slotExists(root, index)) return this
        return of(split(root, index, edge, tile.id), tiles + (tile.id to tile), null)
    }

    fun filling(index: Int, tile: WTile): WLayout {
        if (tile.id in tiles || !slotExists(root, index) || slotAt(root, index) != null) return this
        return of(setSlot(root, index, tile.id), tiles + (tile.id to tile), maximized)
    }

    fun rotating(id: String): WLayout {
        val t = tiles[id] ?: return this
        return with(tiles = tiles + (id to t.copy(rotation = t.rotation.clockwise)))
    }

    fun settingFit(fit: WFit, id: String): WLayout {
        val t = tiles[id] ?: return this
        return with(tiles = tiles + (id to t.copy(fit = fit)))
    }

    fun maximizing(id: String) = if (id in tiles) with(maximized = id) else this
    fun restoringMaximized() = with(maximized = null)

    fun applying(preset: WPreset): Pair<WLayout, List<String>> {
        val ordered = orderedTileIDs
        val kept = ordered.take(preset.slotCount)
        val overflow = ordered.drop(preset.slotCount)
        return of(preset.node(kept), tiles - overflow.toSet(), null) to overflow
    }

    fun moving(id: String, target: WDropTarget): WLayout {
        if (id !in tiles) return this
        return when (target) {
            is WDropTarget.Slot -> {
                if (!slotExists(root, target.index)) return this
                val occupant = slotAt(root, target.index)
                if (occupant != null) return swapping(id, occupant)
                val cleared = mapSlots(root) { if (it == id) null else it }
                of(setSlot(cleared, target.index, id), tiles, maximized)
            }
            is WDropTarget.Split -> {
                if (!slotExists(root, target.index)) return this
                val occupant = slotAt(root, target.index)
                if (occupant == id) return this
                val marker = "\u0000target"; val gone = "\u0000gone"
                var tree = setSlot(root, target.index, occupant ?: marker)
                tree = mapSlots(tree) { if (it == id) gone else it }
                tree = removeSlot(tree, gone)
                val markedIndex = (0 until tree.slotCount).firstOrNull { slotExists(tree, it) && slotAt(tree, it) == (occupant ?: marker) } ?: return this
                tree = split(tree, markedIndex, target.edge, id)
                if (occupant == null) tree = mapSlots(tree) { if (it == marker) null else it }
                of(tree, tiles, null)
            }
        }
    }

    fun materializing(hinge: WHinge?) = WLayout(WGeometry.hingeAdjustedRoot(root, hinge), tiles, maximized)

    companion object {
        const val SCHEMA = 2
        const val MAXIMUM_TILES = 9

        /** Normalizing constructor: drops unknown/duplicate slots and orphan tiles, fixes ratios, flattens. */
        fun of(root: WNode = WNode.Slot(null), tiles: Map<String, WTile> = emptyMap(), maximized: String? = null): WLayout {
            val seen = mutableSetOf<String>()
            val cleaned = mapSlots(root) { id -> if (id != null && id in tiles && seen.add(id)) id else null }
            val kept = tiles.filterKeys { it in seen }
            return WLayout(normalizeNode(cleaned), kept, maximized?.takeIf { it in kept })
        }

        fun preset(preset: WPreset, ordered: List<WTile>): WLayout {
            val used = ordered.take(preset.slotCount)
            return of(preset.node(used.map { it.id }), used.associateBy { it.id })
        }

        /** Tile id at slot [index]; null for an empty slot (check [slotExists] first). */
        fun slotAt(node: WNode, index: Int): String? = findSlot(node, index).let { if (it === NoSlot) null else it as String? }
        fun slotExists(node: WNode, index: Int) = findSlot(node, index) !== NoSlot

        private fun findSlot(node: WNode, index: Int): Any? {
            var i = index
            fun walk(n: WNode): Any? = when (n) {
                is WNode.Slot -> if (i == 0) n.tile else { i -= 1; NoSlot }
                is WNode.Split -> { var found: Any? = NoSlot; for (c in n.children) { found = walk(c); if (found !== NoSlot) break }; found }
            }
            return walk(node)
        }

        fun mapSlots(node: WNode, f: (String?) -> String?): WNode = when (node) {
            is WNode.Slot -> WNode.Slot(f(node.tile))
            is WNode.Split -> WNode.Split(node.axis, node.children.map { mapSlots(it, f) }, node.ratios)
        }

        fun setSlot(node: WNode, index: Int, id: String?): WNode {
            var i = index
            fun walk(n: WNode): WNode = when (n) {
                is WNode.Slot -> { val r = if (i == 0) WNode.Slot(id) else n; i -= 1; r }
                is WNode.Split -> WNode.Split(n.axis, n.children.map(::walk), n.ratios)
            }
            return walk(node)
        }

        fun split(node: WNode, index: Int, edge: WEdge, id: String): WNode {
            var i = index
            fun walk(n: WNode): WNode = when (n) {
                is WNode.Slot -> {
                    val r = if (i == 0) {
                        val pair = if (edge.leading) listOf(WNode.Slot(id), n) else listOf(n, WNode.Slot(id))
                        WNode.Split(edge.axis, pair, listOf(0.5, 0.5))
                    } else n
                    i -= 1; r
                }
                is WNode.Split -> WNode.Split(n.axis, n.children.map(::walk), n.ratios)
            }
            return walk(node)
        }

        fun removeSlot(node: WNode, tileID: String): WNode = when (node) {
            is WNode.Slot -> WNode.Slot(if (node.tile == tileID) null else node.tile)
            is WNode.Split -> {
                val kept = mutableListOf<WNode>(); val ratios = mutableListOf<Double>()
                node.children.forEachIndexed { k, c ->
                    if (c is WNode.Slot && c.tile == tileID) return@forEachIndexed
                    kept += removeSlot(c, tileID); ratios += node.ratios.getOrElse(k) { 1.0 }
                }
                if (kept.isEmpty()) WNode.Slot(null) else WNode.Split(node.axis, kept, ratios)
            }
        }

        fun normalizeNode(node: WNode): WNode = when (node) {
            is WNode.Slot -> node
            is WNode.Split -> {
                val safe = if (node.ratios.size == node.children.size) node.ratios else List(node.children.size) { 1.0 }
                val flat = mutableListOf<WNode>(); val flatRatios = mutableListOf<Double>()
                node.children.forEachIndexed { k, child ->
                    val raw = safe[k]
                    val ratio = if (raw.isFinite() && raw > 0) raw else 1.0 / max(node.children.size, 1)
                    val n = normalizeNode(child)
                    if (n is WNode.Split && n.axis == node.axis) {
                        val total = n.ratios.sum()
                        n.children.forEachIndexed { g, gc -> flat += gc; flatRatios += ratio * n.ratios[g] / max(total, 1e-12) }
                    } else { flat += n; flatRatios += ratio }
                }
                when {
                    flat.isEmpty() -> WNode.Slot(null)
                    flat.size == 1 -> flat[0]
                    else -> { val total = flatRatios.sum(); WNode.Split(node.axis, flat, flatRatios.map { it / total }) }
                }
            }
        }
    }
}

/** A separating/occluding fold, normalized. Nothing interactive goes inside it. */
data class WHinge(val rect: WRect, val orientation: WAxis)

/** Up to 9 panes everywhere (2x2 and 3x3 on phones too); the minimum pane size decides what fits. */
enum class WSizeClass(val tileLimit: Int) {
    Compact(9), Expanded(9);
    companion object {
        /** From the usable window size in dp (not the screen, not the model). */
        fun of(size: WSize): WSizeClass {
            val short = min(size.width, size.height); val long = max(size.width, size.height)
            return if (short >= 600 && long >= 800) Expanded else Compact
        }
    }
}

data class WDivider(val path: List<Int>, val index: Int, val axis: WAxis, val hitRect: WRect)
data class WFrames(val tiles: Map<String, WRect>, val slots: List<WRect>, val dividers: List<WDivider>)

object WGeometry {
    val MINIMUM_TILE = WSize(120.0, 90.0)
    const val DIVIDER_HIT_WIDTH = 24.0

    fun capacity(size: WSize, hinge: WHinge? = null): Int {
        val limit = WSizeClass.of(size).tileLimit
        val landscape = size.width >= size.height
        for (count in limit downTo 1) {
            val ids = (0 until count).map { "c$it" }
            val layout = WLayout.of(WPreset.natural(count, landscape).node(ids), ids.associateWith { WTile(it) })
            val fits = frames(layout, size, hinge).slots.all {
                it.width * size.width >= MINIMUM_TILE.width - 0.5 && it.height * size.height >= MINIMUM_TILE.height - 0.5
            }
            if (fits) return count
        }
        return 1
    }

    fun frames(layout: WLayout, size: WSize, hinge: WHinge? = null): WFrames {
        layout.maximized?.let { m ->
            val region = hinge?.let(::largestRegion) ?: WRect.UNIT
            val index = (0 until layout.slotCount).firstOrNull { WLayout.slotAt(layout.root, it) == m } ?: 0
            val slots = MutableList(layout.slotCount) { WRect(0.0, 0.0, 0.0, 0.0) }
            if (index < slots.size) slots[index] = region
            return WFrames(mapOf(m to region), slots, emptyList())
        }
        val slots = mutableListOf<WRect>(); val dividers = mutableListOf<WDivider>()
        fun place(node: WNode, rect: WRect, path: List<Int>) {
            when (node) {
                is WNode.Slot -> slots += rect
                is WNode.Split -> {
                    val bounds = splitBounds(node.axis, rect, node.ratios, hinge)
                    node.children.forEachIndexed { i, child ->
                        place(child, bounds[i], path + i)
                        if (i < node.children.size - 1) {
                            val a = bounds[i]; val b = bounds[i + 1]
                            val hit = if (node.axis == WAxis.Horizontal) {
                                val cx = (a.maxX + b.x) / 2; val w = DIVIDER_HIT_WIDTH / max(size.width, 1.0)
                                WRect(cx - w / 2, rect.y, w, rect.height)
                            } else {
                                val cy = (a.maxY + b.y) / 2; val h = DIVIDER_HIT_WIDTH / max(size.height, 1.0)
                                WRect(rect.x, cy - h / 2, rect.width, h)
                            }
                            dividers += WDivider(path, i, node.axis, hit)
                        }
                    }
                }
            }
        }
        val root = hingeAdjustedRoot(layout.root, hinge)
        place(root, WRect.UNIT, emptyList())
        val tiles = mutableMapOf<String, WRect>()
        slots.forEachIndexed { i, r -> WLayout.slotAt(root, i)?.let { tiles[it] = r } }
        return WFrames(tiles, slots, dividers)
    }

    fun hingeAdjustedRoot(root: WNode, hinge: WHinge?): WNode {
        hinge ?: return root
        val splitAxis = if (hinge.orientation == WAxis.Vertical) WAxis.Horizontal else WAxis.Vertical
        if (root is WNode.Split && root.axis == splitAxis && root.children.size >= 2) return root
        val first = if (hinge.orientation == WAxis.Vertical) hinge.rect.x else hinge.rect.y
        return WNode.Split(splitAxis, listOf(root, WNode.Slot(null)), listOf(first, 1 - first))
    }

    fun splitBounds(axis: WAxis, rect: WRect, ratios: List<Double>, hinge: WHinge?): List<WRect> {
        val start = if (axis == WAxis.Horizontal) rect.x else rect.y
        val extent = if (axis == WAxis.Horizontal) rect.width else rect.height
        val edges = mutableListOf(start)
        var acc = start
        for (r in ratios) { acc += r * extent; edges += acc }
        edges[edges.size - 1] = start + extent
        val lead = DoubleArray(ratios.size); val trail = DoubleArray(ratios.size)
        if (hinge != null && ratios.size >= 2) {
            val crosses = (axis == WAxis.Horizontal && hinge.orientation == WAxis.Vertical) || (axis == WAxis.Vertical && hinge.orientation == WAxis.Horizontal)
            val h0 = if (axis == WAxis.Horizontal) hinge.rect.x else hinge.rect.y
            val h1 = if (axis == WAxis.Horizontal) hinge.rect.maxX else hinge.rect.maxY
            val spans = if (axis == WAxis.Horizontal) hinge.rect.y <= rect.y + 1e-9 && hinge.rect.maxY >= rect.maxY - 1e-9
            else hinge.rect.x <= rect.x + 1e-9 && hinge.rect.maxX >= rect.maxX - 1e-9
            if (crosses && spans && h0 > start && h1 < start + extent) {
                val mid = (h0 + h1) / 2
                var best = 1
                for (i in 1 until edges.size - 1) if (abs(edges[i] - mid) < abs(edges[best] - mid)) best = i
                edges[best] = mid
                trail[best - 1] = mid - h0
                lead[best] = h1 - mid
                for (i in 1 until best) if (edges[i] > edges[best]) edges[i] = edges[best]
                for (i in best + 1 until edges.size - 1) if (edges[i] < edges[best]) edges[i] = edges[best]
            }
        }
        return ratios.indices.map { i ->
            val a = edges[i] + lead[i]; val b = max(edges[i + 1] - trail[i], a)
            if (axis == WAxis.Horizontal) WRect(a, rect.y, b - a, rect.height) else WRect(rect.x, a, rect.width, b - a)
        }
    }

    fun largestRegion(hinge: WHinge): WRect = if (hinge.orientation == WAxis.Vertical) {
        val l = WRect(0.0, 0.0, hinge.rect.x, 1.0); val r = WRect(hinge.rect.maxX, 0.0, 1 - hinge.rect.maxX, 1.0)
        if (l.area >= r.area) l else r
    } else {
        val t = WRect(0.0, 0.0, 1.0, hinge.rect.y); val b = WRect(0.0, hinge.rect.maxY, 1.0, 1 - hinge.rect.maxY)
        if (t.area >= b.area) t else b
    }

    fun dropTarget(point: WPoint, frames: WFrames, size: WSize, hinge: WHinge? = null, canSplit: Boolean): WDropTarget? {
        if (hinge != null && hinge.rect.contains(point)) return null
        val index = frames.slots.indexOfFirst { it.contains(point) }.takeIf { it >= 0 } ?: return null
        val slot = frames.slots[index]
        if (!canSplit) return WDropTarget.Slot(index, slot)
        val px = slot.width * size.width; val py = slot.height * size.height
        val band = 0.22
        val fx = (point.x - slot.x) / max(slot.width, 1e-12); val fy = (point.y - slot.y) / max(slot.height, 1e-12)
        val nearLeft = fx < band; val nearRight = fx > 1 - band; val nearTop = fy < band; val nearBottom = fy > 1 - band
        val hNear = nearLeft || nearRight; val vNear = nearTop || nearBottom
        val edge = when {
            hNear && vNear -> if (px >= py) (if (nearLeft) WEdge.Left else WEdge.Right) else (if (nearTop) WEdge.Top else WEdge.Bottom)
            hNear -> if (nearLeft) WEdge.Left else WEdge.Right
            vNear -> if (nearTop) WEdge.Top else WEdge.Bottom
            else -> return WDropTarget.Slot(index, slot)
        }
        val halfW = if (edge.axis == WAxis.Horizontal) px / 2 else px
        val halfH = if (edge.axis == WAxis.Vertical) py / 2 else py
        if (halfW < MINIMUM_TILE.width || halfH < MINIMUM_TILE.height) return WDropTarget.Slot(index, slot)
        val preview = when (edge) {
            WEdge.Left -> WRect(slot.x, slot.y, slot.width / 2, slot.height)
            WEdge.Right -> WRect(slot.midX, slot.y, slot.width / 2, slot.height)
            WEdge.Top -> WRect(slot.x, slot.y, slot.width, slot.height / 2)
            WEdge.Bottom -> WRect(slot.x, slot.midY, slot.width, slot.height / 2)
        }
        return WDropTarget.Split(index, edge, preview)
    }

    /** WorkspaceGeometry.windowDrop: label strip = tab, edge band = split, middle = replace. */
    fun windowDrop(point: WPoint, layout: WLayout, frames: WFrames, size: WSize, labelHeight: Double, canSplit: Boolean): WWindowDrop? {
        val index = frames.slots.indexOfFirst { it.contains(point) }
        if (index < 0 || !WLayout.slotExists(layout.root, index)) return null
        val slot = frames.slots[index]
        val tile = WLayout.slotAt(layout.root, index)
        if (tile == null || layout.tiles[tile]?.source == null) return WWindowDrop.EmptySlot(index, slot)
        val strip = min(labelHeight * 1.6, slot.height * 0.25)
        if (point.y - slot.y <= strip) return WWindowDrop.Tab(tile, WRect(slot.x, slot.y, slot.width, strip))
        if (canSplit) {
            val d = dropTarget(point, frames, size, null, true)
            if (d is WDropTarget.Split && d.index == index) return WWindowDrop.Split(d.index, d.edge, d.preview)
        }
        return WWindowDrop.Replace(tile, slot)
    }

    fun resizing(layout: WLayout, divider: WDivider, delta: Double, size: WSize): WLayout {
        if (!delta.isFinite()) return layout
        fun walk(node: WNode, path: List<Int>, rect: WRect): WNode {
            if (node !is WNode.Split) return node
            if (path.isEmpty()) {
                if (node.axis != divider.axis || divider.index + 1 >= node.ratios.size) return node
                val extentPts = if (node.axis == WAxis.Horizontal) rect.width * size.width else rect.height * size.height
                val extentNorm = if (node.axis == WAxis.Horizontal) rect.width else rect.height
                if (extentPts <= 0 || extentNorm <= 0) return node
                val i = divider.index
                val minA = minimumExtent(node.children[i], node.axis) / extentPts
                val minB = minimumExtent(node.children[i + 1], node.axis) / extentPts
                val ratios = node.ratios.toMutableList()
                val pair = ratios[i] + ratios[i + 1]
                var a = min(max(ratios[i] + delta / extentNorm, minA), pair - minB)
                if (pair - minB < minA) a = pair / 2
                ratios[i] = a; ratios[i + 1] = pair - a
                return WNode.Split(node.axis, node.children, ratios)
            }
            val i = path.first()
            if (i >= node.children.size) return node
            val bounds = splitBounds(node.axis, rect, node.ratios, null)
            val children = node.children.toMutableList()
            children[i] = walk(children[i], path.drop(1), bounds[i])
            return WNode.Split(node.axis, children, node.ratios)
        }
        return layout.with(root = walk(layout.root, divider.path, WRect.UNIT))
    }

    fun minimumExtent(node: WNode, axis: WAxis): Double = when (node) {
        is WNode.Slot -> if (axis == WAxis.Horizontal) MINIMUM_TILE.width else MINIMUM_TILE.height
        is WNode.Split -> {
            val mins = node.children.map { minimumExtent(it, axis) }
            if (node.axis == axis) mins.sum() else mins.maxOrNull() ?: 0.0
        }
    }
}

/** The saved arrangement stays; what's shown is derived for the space now (WorkspaceAdaptation). */
object WAdaptation {
    data class Result(val visible: WLayout, val stacked: List<String>)

    fun adapt(saved: WLayout, size: WSize, hinge: WHinge? = null, active: String?): Result {
        val capacity = WGeometry.capacity(size, hinge)
        val ordered = saved.orderedTileIDs
        if (ordered.size <= capacity) return Result(saved, emptyList())
        val shown = ordered.take(capacity).toMutableList()
        if (active != null && active in ordered && active !in shown) shown[shown.size - 1] = active
        val stacked = ordered.filter { it !in shown }
        var visible = WLayout.preset(WPreset.natural(shown.size, size.width >= size.height), shown.mapNotNull { saved.tiles[it] })
        saved.maximized?.takeIf { it in shown }?.let { visible = visible.maximizing(it) }
        return Result(visible, stacked)
    }
}

class WHistory {
    private val past = ArrayDeque<WLayout>()
    private var grouping = false
    private var groupRecorded = false
    val canUndo get() = past.isNotEmpty()
    val depth get() = past.size

    /** Until [endGroup], changes are one undo step (a divider drag sends many). */
    fun beginGroup() {
        if (grouping) return
        grouping = true
        groupRecorded = false
    }

    fun endGroup() {
        grouping = false
        groupRecorded = false
    }

    fun record(layout: WLayout) {
        if (grouping) {
            if (groupRecorded) return
            groupRecorded = true
        }
        if (past.lastOrNull() == layout) return
        past.addLast(layout)
        while (past.size > DEPTH) past.removeFirst()
    }

    fun undo(): WLayout? = past.removeLastOrNull()

    companion object { const val DEPTH = 20 }
}

/** Schema 1 stored/wire form, lenient like WorkspaceLayoutRecord. */
object WLayoutRecord {
    fun encode(layout: WLayout): JsonObject = buildJsonObject {
        put("schema", WLayout.SCHEMA)
        put("root", encodeNode(layout.root))
        put("tiles", buildJsonArray {
            for (id in layout.orderedTileIDs) {
                val t = layout.tiles[id] ?: continue
                add(buildJsonObject {
                    put("id", t.id)
                    t.source?.let { s ->
                        put("host", s.host); put("window", s.windowID)
                        s.generation?.let { put("gen", it) }
                        s.bundleID?.let { put("bundle", it) }
                        put("follow", s.follow.wire)
                    }
                    put("rotation", t.rotation.degrees); put("fit", t.fit.wire)
                    if (t.tabs.isNotEmpty()) put("tabs", buildJsonArray {
                        t.tabs.forEach { s -> add(buildJsonObject {
                            put("host", s.host); put("window", s.windowID)
                            s.bundleID?.let { put("bundle", it) }
                            put("follow", s.follow.wire)
                        }) }
                    })
                })
            }
        })
        layout.maximized?.let { put("maximized", it) }
    }

    private fun encodeNode(n: WNode): JsonObject = when (n) {
        is WNode.Slot -> buildJsonObject { put("tile", n.tile?.let(::JsonPrimitive) ?: JsonNull) }
        is WNode.Split -> buildJsonObject {
            put("axis", n.axis.wire)
            put("children", JsonArray(n.children.map(::encodeNode)))
            put("ratios", JsonArray(n.ratios.map(::JsonPrimitive)))
        }
    }

    fun decode(text: String): WLayout? = runCatching { Json.parseToJsonElement(text).jsonObject }.getOrNull()?.let(::decode)

    fun decode(obj: JsonObject): WLayout? {
        val schema = (obj["schema"] as? JsonPrimitive)?.intOrNull ?: return null
        if (schema < 1) return null
        var budget = 32
        fun node(e: JsonElement?): WNode {
            budget -= 1
            if (budget <= 0) return WNode.Slot(null)
            val o = e as? JsonObject ?: return WNode.Slot(null)
            val children = (o["children"] as? JsonArray)?.take(WLayout.MAXIMUM_TILES)
            val axis = WAxis.of((o["axis"] as? JsonPrimitive)?.contentOrNull())
            if (children != null && axis != null && children.isNotEmpty()) {
                val nodes = children.map(::node)
                val ratios = (o["ratios"] as? JsonArray)?.map { (it as? JsonPrimitive)?.doubleOrNull ?: Double.NaN } ?: emptyList()
                return WNode.Split(axis, nodes, if (ratios.size == nodes.size) ratios else emptyList())
            }
            return WNode.Slot((o["tile"] as? JsonPrimitive)?.contentOrNull())
        }
        val tiles = mutableMapOf<String, WTile>()
        (obj["tiles"] as? JsonArray)?.take(WLayout.MAXIMUM_TILES)?.forEach { e ->
            val t = e as? JsonObject ?: return@forEach
            val id = (t["id"] as? JsonPrimitive)?.contentOrNull() ?: return@forEach
            if (id.isEmpty() || id.length > 64) return@forEach
            val host = (t["host"] as? JsonPrimitive)?.contentOrNull()
            val window = (t["window"] as? JsonPrimitive)?.longOrNull
            val source = if (!host.isNullOrEmpty() && window != null) WSource(
                host, window, (t["gen"] as? JsonPrimitive)?.longOrNull, (t["bundle"] as? JsonPrimitive)?.contentOrNull(),
                WFollow.of((t["follow"] as? JsonPrimitive)?.contentOrNull()),
            ) else null
            // Schema 1 saved every tile as "fit" (no automatic fill then): start them on auto.
            val stored = (t["fit"] as? JsonPrimitive)?.contentOrNull()
            val fit = if (schema < 2 && stored == WFit.Fit.wire) WFit.Auto else WFit.of(stored)
            val tabs = (t["tabs"] as? JsonArray)?.take(8)?.mapNotNull { e ->
                val o = e as? JsonObject ?: return@mapNotNull null
                val h = (o["host"] as? JsonPrimitive)?.contentOrNull()?.takeIf { it.isNotEmpty() } ?: return@mapNotNull null
                val w = (o["window"] as? JsonPrimitive)?.longOrNull ?: return@mapNotNull null
                WSource(h, w, null, (o["bundle"] as? JsonPrimitive)?.contentOrNull(), WFollow.of((o["follow"] as? JsonPrimitive)?.contentOrNull()))
            }?.map { if (source != null && it.sameWindow(source)) source else it } ?: emptyList()
            tiles[id] = WTile(id, source, WRotation.of((t["rotation"] as? JsonPrimitive)?.intOrNull ?: 0), fit,
                tabs = if (tabs.size > 1 && source != null && tabs.any { it.sameWindow(source) }) tabs else emptyList())
        }
        return WLayout.of(node(obj["root"]), tiles, (obj["maximized"] as? JsonPrimitive)?.contentOrNull())
    }

    private fun JsonPrimitive.contentOrNull(): String? = if (isString) content else null
}

/** For the sender's canvas: tile rect to whole pixels (codec-friendly). */
fun WRect.pixelAligned(size: WSize): WRect {
    val x0 = (x * size.width).roundToLong().toDouble(); val y0 = (y * size.height).roundToLong().toDouble()
    val x1 = (maxX * size.width).roundToLong().toDouble(); val y1 = (maxY * size.height).roundToLong().toDouble()
    return WRect(x0, y0, max(x1 - x0, 0.0), max(y1 - y0, 0.0))
}

internal fun JsonObject.arrayOrEmpty(key: String): JsonArray = (this[key] as? JsonArray) ?: JsonArray(emptyList())
internal fun JsonElement.objOrNull(): JsonObject? = this as? JsonObject
internal fun JsonArray.objects(): List<JsonObject> = mapNotNull { it as? JsonObject }

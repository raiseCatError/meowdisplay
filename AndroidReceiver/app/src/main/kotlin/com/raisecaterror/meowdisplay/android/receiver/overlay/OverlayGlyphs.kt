package com.raisecaterror.meowdisplay.android.receiver.overlay

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.PathFillType
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Fill
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.unit.Dp
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.sin

/**
 * The glyphs the overlay draws. SF Symbols do not exist on Android and
 * material-icons-extended is not a dependency, so every glyph is either drawn
 * here on a 24-unit grid (stroke 2, round caps, like SF's semibold weight at
 * these sizes) or, for the five "text" symbols, a typographic character.
 */
internal enum class OverlayGlyph(val text: String? = null) {
    Gear, Keyboard, KeyboardDown, Dock, ZoomIn, ZoomOut, Undo, Redo, Return, MenuBar, Grid, DashedRect, Switch2,
    Move, HandTap, Sparkles, Search, Star, Bolt, Brush, Pencil, Scissors, Folder, Play, Clockwise, Camera,
    Download, Wand, Hammer,
    TextFormat("Aa"), Underline("U"), Bold("B"), Italic("I"), Command("⌘"),

    /** A symbol name this table does not know: a ring with a dot rather than nothing. */
    Unknown,
}

/**
 * The one table from each SF Symbol name MeowDisplay uses (Main tray, Function
 * Tray defaults, the Button Face picker, the Keyboard bar) to its Android glyph.
 */
internal object OverlayGlyphs {
    val table: Map<String, OverlayGlyph> = mapOf(
        "gearshape.fill" to OverlayGlyph.Gear,
        "keyboard" to OverlayGlyph.Keyboard,
        "keyboard.chevron.compact.down" to OverlayGlyph.KeyboardDown,
        "dock.rectangle" to OverlayGlyph.Dock,
        "plus.magnifyingglass" to OverlayGlyph.ZoomIn,
        "minus.magnifyingglass" to OverlayGlyph.ZoomOut,
        "magnifyingglass" to OverlayGlyph.Search,
        "arrow.uturn.backward" to OverlayGlyph.Undo,
        "arrow.uturn.forward" to OverlayGlyph.Redo,
        "return" to OverlayGlyph.Return,
        "menubar.rectangle" to OverlayGlyph.MenuBar,
        "square.grid.3x3" to OverlayGlyph.Grid,
        "rectangle.dashed" to OverlayGlyph.DashedRect,
        "switch.2" to OverlayGlyph.Switch2,
        "arrow.up.and.down.and.arrow.left.and.right" to OverlayGlyph.Move,
        "hand.tap" to OverlayGlyph.HandTap,
        "sparkles" to OverlayGlyph.Sparkles,
        "star" to OverlayGlyph.Star,
        "bolt" to OverlayGlyph.Bolt,
        "paintbrush" to OverlayGlyph.Brush,
        "pencil" to OverlayGlyph.Pencil,
        "scissors" to OverlayGlyph.Scissors,
        "textformat" to OverlayGlyph.TextFormat,
        "underline" to OverlayGlyph.Underline,
        "bold" to OverlayGlyph.Bold,
        "italic" to OverlayGlyph.Italic,
        "folder" to OverlayGlyph.Folder,
        "play" to OverlayGlyph.Play,
        "arrow.clockwise" to OverlayGlyph.Clockwise,
        "camera" to OverlayGlyph.Camera,
        "square.and.arrow.down" to OverlayGlyph.Download,
        "wand.and.stars" to OverlayGlyph.Wand,
        "command" to OverlayGlyph.Command,
        "hammer" to OverlayGlyph.Hammer,
    )

    fun forSymbol(name: String): OverlayGlyph = table[name] ?: OverlayGlyph.Unknown
}

/** A glyph [size] dp square, tinted [color]. */
@Composable
internal fun GlyphIcon(glyph: OverlayGlyph, size: Dp, color: Color, modifier: Modifier = Modifier) {
    val text = glyph.text
    if (text != null) {
        val sp = with(LocalDensity.current) { (size * 0.82f).toSp() }
        Box(modifier.size(size), contentAlignment = Alignment.Center) {
            Text(
                text = text,
                color = color,
                fontSize = sp,
                fontWeight = if (glyph == OverlayGlyph.Bold) FontWeight.Black else FontWeight.SemiBold,
                fontStyle = if (glyph == OverlayGlyph.Italic) FontStyle.Italic else FontStyle.Normal,
                textDecoration = if (glyph == OverlayGlyph.Underline) TextDecoration.Underline else null,
                maxLines = 1,
                softWrap = false,
            )
        }
    } else {
        Canvas(modifier.size(size)) { drawGlyph(glyph, color) }
    }
}

private fun DrawScope.drawGlyph(glyph: OverlayGlyph, color: Color) {
    val s = size.minDimension / 24f
    fun o(x: Float, y: Float) = Offset(x * s, y * s)
    val stroke = Stroke(width = 2f * s, cap = StrokeCap.Round, join = StrokeJoin.Round)
    fun line(x1: Float, y1: Float, x2: Float, y2: Float, w: Float = 2f) =
        drawLine(color, o(x1, y1), o(x2, y2), strokeWidth = w * s, cap = StrokeCap.Round)
    fun ring(cx: Float, cy: Float, r: Float) = drawCircle(color, r * s, o(cx, cy), style = stroke)
    fun dot(cx: Float, cy: Float, r: Float) = drawCircle(color, r * s, o(cx, cy))
    fun box(l: Float, t: Float, r: Float, b: Float, radius: Float = 2.5f, fill: Boolean = false, effect: PathEffect? = null) =
        drawRoundRect(
            color, o(l, t), Size((r - l) * s, (b - t) * s), CornerRadius(radius * s),
            style = if (fill) Fill else Stroke(width = 2f * s, cap = StrokeCap.Round, join = StrokeJoin.Round, pathEffect = effect),
        )
    fun path(fill: Boolean = false, build: Path.() -> Unit) {
        val p = Path().apply(build)
        drawPath(p, color, style = if (fill) Fill else stroke)
    }
    fun Path.m(x: Float, y: Float) = moveTo(x * s, y * s)
    fun Path.l(x: Float, y: Float) = lineTo(x * s, y * s)
    fun star(cx: Float, cy: Float, outer: Float, inner: Float, points: Int, fill: Boolean = true) = path(fill) {
        for (i in 0 until points * 2) {
            val r = if (i % 2 == 0) outer else inner
            val a = -PI / 2 + i * PI / points
            val x = cx + r * cos(a).toFloat()
            val y = cy + r * sin(a).toFloat()
            if (i == 0) m(x, y) else l(x, y)
        }
        close()
    }
    fun chevron(x: Float, y: Float, dx: Float, dy: Float) {
        // Arrowhead at (x, y) whose two barbs trail back along (-dx, -dy) and spread perpendicular.
        line(x, y, x - dx - dy, y - dy + dx, 2f)
        line(x, y, x - dx + dy, y - dy - dx, 2f)
    }

    when (glyph) {
        OverlayGlyph.Gear -> {
            val gear = Path().apply {
                fillType = PathFillType.EvenOdd
                addOval(Rect(o(5.2f, 5.2f), Size(13.6f * s, 13.6f * s)))
                addOval(Rect(o(9.4f, 9.4f), Size(5.2f * s, 5.2f * s)))
            }
            drawPath(gear, color)
            for (i in 0 until 8) {
                val a = i * PI / 4
                line(12f + 6.6f * cos(a).toFloat(), 12f + 6.6f * sin(a).toFloat(), 12f + 9.4f * cos(a).toFloat(), 12f + 9.4f * sin(a).toFloat(), 3.2f)
            }
        }
        OverlayGlyph.Keyboard -> {
            box(2f, 6f, 22f, 18f)
            for (x in listOf(6f, 10f, 14f, 18f)) dot(x, 10f, 0.9f)
            line(8f, 14.5f, 16f, 14.5f, 1.8f)
        }
        OverlayGlyph.KeyboardDown -> {
            box(2f, 3f, 22f, 13f)
            for (x in listOf(6f, 10f, 14f, 18f)) dot(x, 6.5f, 0.9f)
            line(8f, 10f, 16f, 10f, 1.6f)
            path { m(8f, 16.5f); l(12f, 20.5f); l(16f, 16.5f) }
        }
        OverlayGlyph.Dock -> {
            box(3f, 4f, 21f, 20f)
            box(6.5f, 14.5f, 17.5f, 17f, radius = 1.2f, fill = true)
        }
        OverlayGlyph.ZoomIn, OverlayGlyph.ZoomOut, OverlayGlyph.Search -> {
            ring(10f, 10f, 6.5f)
            line(15f, 15f, 21f, 21f)
            if (glyph != OverlayGlyph.Search) line(7.2f, 10f, 12.8f, 10f, 1.8f)
            if (glyph == OverlayGlyph.ZoomIn) line(10f, 7.2f, 10f, 12.8f, 1.8f)
        }
        OverlayGlyph.Undo, OverlayGlyph.Redo -> {
            val flip = glyph == OverlayGlyph.Redo
            fun x(v: Float) = if (flip) 24f - v else v
            path { m(x(5f), 10.5f); l(x(13.5f), 10.5f); cubicTo(x(17.5f) * s, 10.5f * s, x(19.5f) * s, 13f * s, x(19.5f) * s, 16.5f * s) }
            path { m(x(9.5f), 6f); l(x(5f), 10.5f); l(x(9.5f), 15f) }
        }
        OverlayGlyph.Return -> {
            path { m(19f, 5f); l(19f, 13f); l(6f, 13f) }
            path { m(10f, 9f); l(6f, 13f); l(10f, 17f) }
        }
        OverlayGlyph.MenuBar -> {
            box(3f, 4f, 21f, 20f)
            drawRect(color, o(3f, 4f), Size(18f * s, 4.5f * s))
        }
        OverlayGlyph.Grid -> for (cx in listOf(3.5f, 9.75f, 16f)) for (cy in listOf(3.5f, 9.75f, 16f)) {
            drawRoundRect(color, o(cx, cy), Size(4.5f * s, 4.5f * s), CornerRadius(1f * s))
        }
        OverlayGlyph.DashedRect -> box(3f, 5f, 21f, 19f, effect = PathEffect.dashPathEffect(floatArrayOf(3.2f * s, 3f * s)))
        OverlayGlyph.Switch2 -> {
            box(2.5f, 4.5f, 21.5f, 10.5f, radius = 3f)
            dot(18.5f, 7.5f, 1.9f)
            box(2.5f, 13.5f, 21.5f, 19.5f, radius = 3f)
            dot(5.5f, 16.5f, 1.9f)
        }
        OverlayGlyph.Move -> {
            line(12f, 3f, 12f, 21f); line(3f, 12f, 21f, 12f)
            chevron(12f, 3f, 0f, -3f); chevron(12f, 21f, 0f, 3f)
            chevron(3f, 12f, -3f, 0f); chevron(21f, 12f, 3f, 0f)
        }
        OverlayGlyph.HandTap -> {
            ring(12f, 9f, 6.5f)
            dot(12f, 9f, 2.2f)
            line(12f, 12.5f, 12f, 21f)
        }
        OverlayGlyph.Sparkles -> {
            star(10f, 13f, 8f, 2.6f, 4)
            star(18.5f, 5.5f, 4f, 1.3f, 4)
        }
        OverlayGlyph.Star -> star(12f, 12.5f, 9.5f, 4.2f, 5)
        OverlayGlyph.Bolt -> path(fill = true) {
            m(13.5f, 2f); l(5f, 13.5f); l(11f, 13.5f); l(10f, 22f); l(19f, 10f); l(13f, 10f); close()
        }
        OverlayGlyph.Brush -> { line(20f, 4f, 10.5f, 13.5f, 3f); dot(8f, 16f, 3.6f) }
        OverlayGlyph.Pencil -> {
            path { m(4f, 20f); l(5f, 15f); l(15f, 5f); l(19f, 9f); l(9f, 19f); close() }
            line(13f, 7f, 17f, 11f, 1.6f)
        }
        OverlayGlyph.Scissors -> {
            ring(6f, 17f, 2.6f); ring(6f, 7f, 2.6f)
            line(8f, 8.6f, 20f, 18f); line(8f, 15.4f, 20f, 6f)
        }
        OverlayGlyph.Folder -> path { m(3f, 7f); l(9f, 7f); l(11f, 9f); l(21f, 9f); l(21f, 19f); l(3f, 19f); close() }
        OverlayGlyph.Play -> path(fill = true) { m(7f, 5f); l(19f, 12f); l(7f, 19f); close() }
        OverlayGlyph.Clockwise -> {
            drawArc(color, -40f, 290f, false, o(5f, 5f), Size(14f * s, 14f * s), style = stroke)
            // Arrowhead where the arc ends (at -40 + 290 = 250 degrees, i.e. the top-left).
            val a = 250.0 * PI / 180
            val ex = 12f + 7f * cos(a).toFloat()
            val ey = 12f + 7f * sin(a).toFloat()
            chevron(ex + 1.5f, ey - 0.5f, 3.2f, -1.2f)
        }
        OverlayGlyph.Camera -> {
            box(3f, 7f, 21f, 19f)
            ring(12f, 13f, 3.6f)
            path { m(9f, 7f); l(10.5f, 4.5f); l(13.5f, 4.5f); l(15f, 7f) }
        }
        OverlayGlyph.Download -> {
            path { m(4f, 14f); l(4f, 19f); l(20f, 19f); l(20f, 14f) }
            line(12f, 4f, 12f, 15f)
            path { m(8f, 11f); l(12f, 15f); l(16f, 11f) }
        }
        OverlayGlyph.Wand -> {
            line(4.5f, 19.5f, 14.5f, 9.5f, 2.6f)
            star(17.5f, 6.5f, 4.2f, 1.4f, 4)
            star(7f, 5.5f, 2.6f, 0.9f, 4)
        }
        OverlayGlyph.Hammer -> {
            line(5.5f, 20f, 13f, 12.5f, 2.6f)
            line(11f, 6.5f, 18.5f, 12.5f, 5f)
        }
        OverlayGlyph.Unknown -> { ring(12f, 12f, 8f); dot(12f, 12f, 1.8f) }
        // Text glyphs are drawn by GlyphIcon, never here.
        OverlayGlyph.TextFormat, OverlayGlyph.Underline, OverlayGlyph.Bold, OverlayGlyph.Italic, OverlayGlyph.Command -> Unit
    }
}

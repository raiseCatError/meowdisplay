package com.raisecaterror.meowdisplay.android.demo

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Shader
import android.graphics.Typeface
import android.text.Layout
import android.text.StaticLayout
import android.text.TextPaint
import android.util.Base64
import com.raisecaterror.meowdisplay.core.demo.DemoDesktop
import com.raisecaterror.meowdisplay.core.demo.DemoFile
import com.raisecaterror.meowdisplay.core.demo.DemoScene
import com.raisecaterror.meowdisplay.core.demo.DemoWindowKind
import com.raisecaterror.meowdisplay.core.session.DisplayMode
import java.io.ByteArrayOutputStream
import kotlin.math.max
import kotlin.math.min

/**
 * Draws Explore Demo's sample Mac: the desktop for Mirror and Extend, the
 * chosen windows in their tiles for Window mode, and single windows for the
 * window picker's stills. Plain Android drawing, in desktop points scaled to
 * the target; nothing here is a real Mac's content.
 */
object DemoPainter {
    private val fill = Paint(Paint.ANTI_ALIAS_FLAG)
    private val stroke = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE }
    private val text = TextPaint(Paint.ANTI_ALIAS_FLAG)
    private val bold = TextPaint(Paint.ANTI_ALIAS_FLAG).apply { typeface = Typeface.DEFAULT_BOLD }

    private const val ACCENT = 0xFF3B82F6.toInt()
    private const val WINDOW = 0xFFFBFBFD.toInt()
    private const val TITLE = 0xFFECECEF.toInt()
    private const val INK = 0xFF1F2328.toInt()
    private const val SECONDARY = 0xFF6B7280.toInt()

    /** The whole picture, [widthPx] × [heightPx]. */
    fun draw(canvas: Canvas, scene: DemoScene, widthPx: Float, heightPx: Float) {
        if (scene.size.width <= 0 || scene.size.height <= 0 || widthPx <= 0 || heightPx <= 0) return
        canvas.save()
        canvas.scale(widthPx / scene.size.width.toFloat(), heightPx / scene.size.height.toFloat())
        val w = scene.size.width.toFloat()
        val h = scene.size.height.toFloat()
        if (scene.mode == DisplayMode.Window) {
            fill.shader = null
            fill.color = 0xFF101418.toInt()
            canvas.drawRect(0f, 0f, w, h, fill)
            drawTiles(canvas, scene)
        } else {
            wallpaper(canvas, w, h, scene.mode)
            if (scene.mode == DisplayMode.Mirror) menuBar(canvas, w)
            for (window in if (scene.showingDesktop) emptyList() else scene.windows) {
                val f = window.frame
                canvas.save()
                canvas.translate(f.minX.toFloat(), f.minY.toFloat())
                window(canvas, scene, window.kind, f.width.toFloat(), f.height.toFloat(), window.scrollOffset.toFloat(), scene.focused == window.kind)
                canvas.restore()
            }
            if (scene.hasDock) dock(canvas, scene, w, h)
            if (scene.mode == DisplayMode.Extend) extendLabel(canvas, w)
        }
        canvas.restore()
    }

    private fun drawTiles(canvas: Canvas, scene: DemoScene) {
        val size = scene.size
        for (tile in scene.tiles) {
            val r = tile.frame
            val tileRect = RectF((r.x * size.width).toFloat(), (r.y * size.height).toFloat(), (r.maxX * size.width).toFloat(), (r.maxY * size.height).toFloat())
            val source = tile.kind.nativeSize
            val quarter = tile.rotation.isQuarterTurn
            val rw = if (quarter) source.height else source.width
            val rh = if (quarter) source.width else source.height
            val scale = if (tile.fit.wire == "fit") min(tileRect.width() / rw, tileRect.height() / rh) else max(tileRect.width() / rw, tileRect.height() / rh)
            canvas.save()
            canvas.clipRect(tileRect)
            canvas.translate(tileRect.centerX(), tileRect.centerY())
            canvas.rotate(tile.rotation.degrees.toFloat())
            canvas.scale(scale.toFloat(), scale.toFloat())
            canvas.translate(-(source.width / 2).toFloat(), -(source.height / 2).toFloat())
            window(canvas, scene, tile.kind, source.width.toFloat(), source.height.toFloat(), (scene.scrollOffsets[tile.kind] ?: 0.0).toFloat(), scene.activeTile == tile.id)
            canvas.restore()
        }
    }

    private fun wallpaper(canvas: Canvas, w: Float, h: Float, mode: DisplayMode) {
        fill.shader = if (mode == DisplayMode.Mirror) {
            LinearGradient(0f, 0f, w, h, 0xFF6D5BD0.toInt(), 0xFF2E86C1.toInt(), Shader.TileMode.CLAMP)
        } else {
            LinearGradient(0f, 0f, w, h, 0xFF1E3A5F.toInt(), 0xFF3F7F6F.toInt(), Shader.TileMode.CLAMP)
        }
        canvas.drawRect(0f, 0f, w, h, fill)
        fill.shader = null
    }

    private fun menuBar(canvas: Canvas, w: Float) {
        fill.color = 0xCCF3F4F6.toInt()
        canvas.drawRect(0f, 0f, w, DemoDesktop.MENU_BAR_HEIGHT.toFloat(), fill)
        bold.color = INK; bold.textSize = 12f
        canvas.drawText("Sample Mac", 14f, 16f, bold)
        text.color = INK; text.textSize = 12f
        var x = 14f + bold.measureText("Sample Mac") + 18f
        for (item in listOf("File", "Edit", "View", "Window", "Help")) {
            canvas.drawText(item, x, 16f, text)
            x += text.measureText(item) + 16f
        }
        val clock = "DEMO"
        bold.color = ACCENT
        canvas.drawText(clock, w - bold.measureText(clock) - 14f, 16f, bold)
    }

    private fun extendLabel(canvas: Canvas, w: Float) {
        text.color = 0xCCFFFFFF.toInt(); text.textSize = 11f
        val label = "Extended desktop · Sample Mac"
        canvas.drawText(label, w - text.measureText(label) - 14f, 16f, text)
    }

    private fun dock(canvas: Canvas, scene: DemoScene, w: Float, h: Float) {
        val desktop = DemoDesktop(scene.mode, scene.size)
        val frames = desktop.dockFrames()
        if (frames.isEmpty()) return
        val left = frames.first().second.minX.toFloat() - 10f
        val right = frames.last().second.maxX.toFloat() + 10f
        val top = frames.first().second.minY.toFloat() - 6f
        fill.color = 0x66FFFFFF
        canvas.drawRoundRect(RectF(left, top, right, top + DemoDesktop.DOCK_ITEM.toFloat() + 12f), 14f, 14f, fill)
        for ((kind, f) in frames) {
            icon(canvas, kind, RectF(f.minX.toFloat(), f.minY.toFloat(), f.maxX.toFloat(), f.maxY.toFloat()))
            if (scene.windows.any { it.kind == kind }) {
                fill.color = 0xCC1F2328.toInt()
                canvas.drawCircle(f.midX.toFloat(), f.maxY.toFloat() + 4f, 2f, fill)
            }
        }
    }

    private fun iconColor(kind: DemoWindowKind) = when (kind) {
        DemoWindowKind.Notes -> 0xFFF5B83D.toInt()
        DemoWindowKind.Files -> 0xFF3B82F6.toInt()
        DemoWindowKind.Preview -> 0xFF10B981.toInt()
        DemoWindowKind.Displays -> 0xFF8B5CF6.toInt()
    }

    private fun icon(canvas: Canvas, kind: DemoWindowKind, r: RectF) {
        fill.color = iconColor(kind)
        canvas.drawRoundRect(r, r.width() * 0.22f, r.width() * 0.22f, fill)
        bold.color = Color.WHITE; bold.textSize = r.height() * 0.5f
        val letter = kind.title.take(1)
        canvas.drawText(letter, r.centerX() - bold.measureText(letter) / 2, r.centerY() + bold.textSize * 0.36f, bold)
    }

    /** One window at the origin, [w] × [h] points, title bar included. */
    private fun window(canvas: Canvas, scene: DemoScene, kind: DemoWindowKind, w: Float, h: Float, scroll: Float, focused: Boolean) {
        val title = DemoDesktop.TITLE_BAR_HEIGHT.toFloat()
        fill.color = 0x33000000
        canvas.drawRoundRect(RectF(2f, 4f, w + 2f, h + 5f), 10f, 10f, fill)
        fill.color = WINDOW
        canvas.drawRoundRect(RectF(0f, 0f, w, h), 10f, 10f, fill)
        fill.color = if (focused) TITLE else 0xFFF4F4F6.toInt()
        canvas.drawRoundRect(RectF(0f, 0f, w, title + 10f), 10f, 10f, fill)
        canvas.drawRect(0f, title, w, title + 10f, fill.apply { color = WINDOW })
        stroke.color = 0x22000000; stroke.strokeWidth = 1f
        canvas.drawLine(0f, title, w, title, stroke)
        for ((i, color) in listOf(0xFFFF5F57.toInt(), 0xFFFEBC2E.toInt(), 0xFF28C840.toInt()).withIndex()) {
            fill.color = if (focused) color else 0xFFD1D5DB.toInt()
            canvas.drawCircle(15f + i * 18f, title / 2, 6f, fill)
        }
        bold.color = if (focused) INK else SECONDARY; bold.textSize = 12f
        val name = kind.title
        canvas.drawText(name, (w - bold.measureText(name)) / 2, title / 2 + 4f, bold)
        canvas.save()
        canvas.clipRect(0f, title, w, h)
        when (kind) {
            DemoWindowKind.Notes -> notes(canvas, scene, w, h, scroll, focused)
            DemoWindowKind.Files -> files(canvas, scene, w, scroll)
            DemoWindowKind.Preview -> preview(canvas, scene, w, h)
            DemoWindowKind.Displays -> displays(canvas, scene, w, h)
        }
        canvas.restore()
    }

    private fun notes(canvas: Canvas, scene: DemoScene, w: Float, h: Float, scroll: Float, focused: Boolean) {
        val title = DemoDesktop.TITLE_BAR_HEIGHT.toFloat()
        text.color = INK; text.textSize = 14f
        val shown = if (focused) scene.notes + "▏" else scene.notes
        val layout = StaticLayout.Builder.obtain(shown, 0, shown.length, text, max(1, (w - 28f).toInt()))
            .setAlignment(Layout.Alignment.ALIGN_NORMAL).setLineSpacing(4f, 1f).build()
        canvas.save()
        canvas.translate(14f, title + 12f - scroll)
        layout.draw(canvas)
        canvas.restore()
    }

    private fun files(canvas: Canvas, scene: DemoScene, w: Float, scroll: Float) {
        val title = DemoDesktop.TITLE_BAR_HEIGHT.toFloat()
        val row = DemoDesktop.ROW_HEIGHT.toFloat()
        for ((i, file) in DemoFile.samples.withIndex()) {
            val top = title + i * row - scroll
            if (file.id == scene.selectedFile) {
                fill.color = ACCENT
                canvas.drawRoundRect(RectF(6f, top + 2f, w - 6f, top + row - 2f), 6f, 6f, fill)
            }
            val selected = file.id == scene.selectedFile
            fill.color = if (selected) Color.WHITE else 0xFF93C5FD.toInt()
            canvas.drawRoundRect(RectF(14f, top + 8f, 28f, top + row - 8f), 3f, 3f, fill)
            text.color = if (selected) Color.WHITE else INK; text.textSize = 13f
            canvas.drawText(file.name, 38f, top + row / 2 + 5f, text)
            text.color = if (selected) 0xDDFFFFFF.toInt() else SECONDARY; text.textSize = 11f
            canvas.drawText(file.detail, w - text.measureText(file.detail) - 14f, top + row / 2 + 4f, text)
        }
    }

    private fun preview(canvas: Canvas, scene: DemoScene, w: Float, h: Float) {
        val title = DemoDesktop.TITLE_BAR_HEIGHT.toFloat()
        fill.color = 0xFFE5E7EB.toInt()
        canvas.drawRect(0f, title, w, h, fill)
        val file = DemoFile.samples.firstOrNull { it.id == scene.previewFile } ?: DemoFile.samples[0]
        val zoom = scene.previewZoom.toFloat()
        val pageW = min(w * 0.62f, (h - title) * 0.7f) * zoom
        val pageH = pageW * 1.3f
        val cx = w / 2
        val cy = title + (h - title) / 2
        val page = RectF(cx - pageW / 2, cy - pageH / 2, cx + pageW / 2, cy + pageH / 2)
        fill.color = Color.WHITE
        canvas.drawRect(page, fill)
        val hue = (file.id.hashCode() and 0x7FFFFFFF) % 360
        fill.color = Color.HSVToColor(floatArrayOf(hue.toFloat(), 0.45f, 0.9f))
        canvas.drawRect(page.left + pageW * 0.1f, page.top + pageH * 0.08f, page.right - pageW * 0.1f, page.top + pageH * 0.42f, fill)
        fill.color = 0xFFD1D5DB.toInt()
        for (i in 0 until 5) {
            val y = page.top + pageH * (0.5f + i * 0.08f)
            canvas.drawRect(page.left + pageW * 0.1f, y, page.right - pageW * (if (i == 4) 0.4f else 0.1f), y + pageH * 0.025f, fill)
        }
        bold.color = INK; bold.textSize = 13f
        canvas.drawText(file.name, (w - bold.measureText(file.name)) / 2, h - 12f, bold)
    }

    private fun displays(canvas: Canvas, scene: DemoScene, w: Float, h: Float) {
        val title = DemoDesktop.TITLE_BAR_HEIGHT.toFloat()
        text.color = SECONDARY; text.textSize = 12f
        canvas.drawText("Drag to arrange. This device extends the Sample Mac.", 16f, title + 22f, text)
        val desktop = DemoDesktop(DisplayMode.Extend, com.raisecaterror.meowdisplay.core.controls.CGSize(w.toDouble(), h.toDouble()))
        val cards = desktop.displayCardFrames(com.raisecaterror.meowdisplay.core.controls.CGSize(w.toDouble(), h.toDouble()))
        for ((i, r) in cards.withIndex()) {
            val rect = RectF(r.minX.toFloat(), r.minY.toFloat(), r.maxX.toFloat(), r.maxY.toFloat())
            fill.color = if (i == 0) 0xFF6D5BD0.toInt() else 0xFF2E86C1.toInt()
            canvas.drawRoundRect(rect, 6f, 6f, fill)
            if (scene.highlightedDisplay == i) {
                stroke.color = ACCENT; stroke.strokeWidth = 3f
                canvas.drawRoundRect(rect, 6f, 6f, stroke)
            }
            bold.color = Color.WHITE; bold.textSize = 12f
            val label = if (i == 0) "Sample Mac" else "This device"
            canvas.drawText(label, rect.centerX() - bold.measureText(label) / 2, rect.centerY() + 4f, bold)
        }
    }

    // MARK: - Stills for the window picker

    /** A still of one sample window, at most [maxWidth] pixels wide, as base64 JPEG. */
    fun thumbnailBase64(scene: DemoScene, kind: DemoWindowKind, maxWidth: Int): String? = runCatching {
        val source = kind.nativeSize
        val width = maxWidth.coerceIn(64, 320)
        val height = (width * source.height / source.width).toInt().coerceAtLeast(1)
        val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        canvas.drawColor(0xFF101418.toInt())
        canvas.scale(width / source.width.toFloat(), height / source.height.toFloat())
        window(canvas, scene, kind, source.width.toFloat(), source.height.toFloat(), (scene.scrollOffsets[kind] ?: 0.0).toFloat(), scene.focused == kind)
        val out = ByteArrayOutputStream()
        bitmap.compress(Bitmap.CompressFormat.JPEG, 72, out)
        bitmap.recycle()
        Base64.encodeToString(out.toByteArray(), Base64.NO_WRAP)
    }.getOrNull()

    /** A sample app icon as base64 PNG. */
    fun iconBase64(kind: DemoWindowKind): String? = runCatching {
        val bitmap = Bitmap.createBitmap(64, 64, Bitmap.Config.ARGB_8888)
        icon(Canvas(bitmap), kind, RectF(4f, 4f, 60f, 60f))
        val out = ByteArrayOutputStream()
        bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)
        bitmap.recycle()
        Base64.encodeToString(out.toByteArray(), Base64.NO_WRAP)
    }.getOrNull()
}

package com.raisecaterror.meowdisplay.android.receiver.workspace

import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import android.graphics.Bitmap
import android.os.Handler
import android.os.Looper
import android.view.PixelCopy
import android.view.SurfaceView
import android.view.Window
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.snap
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.FilterQuality
import androidx.compose.ui.graphics.drawscope.rotate
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import com.raisecaterror.meowdisplay.core.controls.CGRect
import kotlin.math.atan2
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.sqrt

/**
 * Instant zoom: the pane follows the fingers at once. A copy of the picture the pane showed when
 * the gesture began moves with them; where that copy doesn't reach (zooming out, panning past it)
 * the pane's whole-source still from the Mac shows instead of black. The live video takes over
 * once the controller hears that the Mac's frame with the final view is out (bounded).
 * [frame] is the picture in window dp; [surface] is the video's SurfaceView (null in the demo,
 * where the picture is ordinary window content).
 */
@Composable
fun WorkspaceZoomPreviewLayer(controller: WorkspaceController, frame: CGRect, surface: SurfaceView?) {
    val zoom by controller.zoomPreview.collectAsState()
    val density = LocalDensity.current.density
    val root = LocalView.current
    val window = LocalContext.current.activityWindow()
    var still by remember { mutableStateOf<Pair<Int, ImageBitmap>?>(null) }
    var last by remember { mutableStateOf<WorkspaceController.ZoomPreviewState?>(null) }
    zoom?.let { if (it != last) last = it }

    LaunchedEffect(zoom?.gesture) {
        val z = zoom ?: return@LaunchedEffect
        if (still?.first == z.gesture || frame.isEmpty) return@LaunchedEffect
        val p = z.preview.pane
        // The pane in the picture's own pixels.
        val left = (p.x * frame.width * density).roundToInt()
        val top = (p.y * frame.height * density).roundToInt()
        val width = (p.width * frame.width * density).roundToInt()
        val height = (p.height * frame.height * density).roundToInt()
        if (width <= 0 || height <= 0) return@LaunchedEffect
        val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        val gesture = z.gesture
        val done = PixelCopy.OnPixelCopyFinishedListener { result ->
            if (result == PixelCopy.SUCCESS) still = gesture to bitmap.asImageBitmap()
        }
        val handler = Handler(Looper.getMainLooper())
        runCatching {
            if (surface != null && surface.holder.surface.isValid) {
                // The SurfaceView is exactly the picture, so its pixels are the picture's.
                PixelCopy.request(surface, android.graphics.Rect(left, top, left + width, top + height), bitmap, done, handler)
            } else if (window != null) {
                val at = IntArray(2).also { root.getLocationInWindow(it) }
                val x = at[0] + (frame.minX * density).roundToInt() + left
                val y = at[1] + (frame.minY * density).roundToInt() + top
                PixelCopy.request(window, android.graphics.Rect(x, y, x + width, y + height), bitmap, done, handler)
            }
        }
    }

    val shown = last ?: return
    val image = still?.takeIf { it.first == shown.gesture }?.second
    if (image == null && shown.backdrop == null) return
    val visible = zoom != null
    val alpha by animateFloatAsState(if (visible) 1f else 0f, if (visible) snap() else tween(120), label = "zoomPreview")
    if (!visible && alpha == 0f) return
    val p = shown.preview
    val paneX = frame.minX + p.pane.x * frame.width
    val paneY = frame.minY + p.pane.y * frame.height
    val paneW = p.pane.width * frame.width
    val paneH = p.pane.height * frame.height
    // In pane dp the copy moves by u' = L·u + T. Without a turn L is the scale; with one it is a
    // uniform scale and a turn (the picture's own axes differ in length, so the shear is rescaled).
    val turnedPreview = p.shearB != 0.0 || p.shearC != 0.0
    val la = p.scaleX; val ld = p.scaleY
    val lb = p.shearB * frame.height / frame.width; val lc = p.shearC * frame.width / frame.height
    val px0 = p.pane.x * frame.width; val py0 = p.pane.y * frame.height
    val tx = la * px0 + lc * py0 + p.offsetX * frame.width - px0
    val ty = lb * px0 + ld * py0 + p.offsetY * frame.height - py0
    val turnScale = sqrt(la * la + lb * lb)
    val turnDegrees = Math.toDegrees(atan2(lb, la))
    Box(
        Modifier
            .offset(paneX.dp, paneY.dp)
            .size(paneW.dp, paneH.dp)
            .alpha(alpha)
            .clipToBounds()
            .background(PaneBackground),
    ) {
        shown.backdrop?.let { b ->
            // The whole source where it is drawn now, turned like the pane.
            Canvas(Modifier.size(paneW.dp, paneH.dp)) {
                val sx = this.size.width / p.pane.width.toFloat(); val sy = this.size.height / p.pane.height.toFloat()
                val left = ((p.source.x - p.pane.x) * sx).toFloat(); val top = ((p.source.y - p.pane.y) * sy).toFloat()
                val w = (p.source.width * sx).toFloat(); val h = (p.source.height * sy).toFloat()
                val turned = p.rotation.isQuarterTurn
                val d = p.drawnSource
                val dw = d?.let { (it.width * sx).toFloat() } ?: if (turned) h else w
                val dh = d?.let { (it.height * sy).toFloat() } ?: if (turned) w else h
                val cx = left + w / 2; val cy = top + h / 2
                if (dw >= 1 && dh >= 1) rotate(p.rotation.degrees.toFloat(), Offset(cx, cy)) {
                    drawImage(b, dstOffset = IntOffset((cx - dw / 2).roundToInt(), (cy - dh / 2).roundToInt()),
                        dstSize = IntSize(dw.roundToInt(), dh.roundToInt()), filterQuality = FilterQuality.Low)
                }
            }
        }
        image?.let { img ->
            Canvas(
                Modifier.size(paneW.dp, paneH.dp).graphicsLayer {
                    transformOrigin = TransformOrigin(0f, 0f)
                    scaleX = (if (turnedPreview) turnScale else p.scaleX).toFloat()
                    scaleY = (if (turnedPreview) turnScale else p.scaleY).toFloat()
                    rotationZ = if (turnedPreview) turnDegrees.toFloat() else 0f
                    translationX = (tx * density).toFloat()
                    translationY = (ty * density).toFloat()
                },
            ) {
                // Only the part that showed the source: letterbox bars never cover the still below.
                val fx0 = ((max(p.from.x, p.pane.x) - p.pane.x) / p.pane.width).coerceIn(0.0, 1.0)
                val fy0 = ((max(p.from.y, p.pane.y) - p.pane.y) / p.pane.height).coerceIn(0.0, 1.0)
                val fx1 = ((min(p.from.x + p.from.width, p.pane.x + p.pane.width) - p.pane.x) / p.pane.width).coerceIn(0.0, 1.0)
                val fy1 = ((min(p.from.y + p.from.height, p.pane.y + p.pane.height) - p.pane.y) / p.pane.height).coerceIn(0.0, 1.0)
                if (fx1 <= fx0 || fy1 <= fy0) return@Canvas
                val src = IntOffset((fx0 * img.width).roundToInt(), (fy0 * img.height).roundToInt())
                val srcSize = IntSize(((fx1 - fx0) * img.width).roundToInt().coerceAtLeast(1), ((fy1 - fy0) * img.height).roundToInt().coerceAtLeast(1))
                val dst = IntOffset((fx0 * this.size.width).roundToInt(), (fy0 * this.size.height).roundToInt())
                val dstSize = IntSize(((fx1 - fx0) * this.size.width).roundToInt().coerceAtLeast(1), ((fy1 - fy0) * this.size.height).roundToInt().coerceAtLeast(1))
                drawImage(img, src, srcSize, dst, dstSize, filterQuality = FilterQuality.Low)
            }
        }
    }
}

/** The Mac's pane background, so the instant zoom matches what the Mac composes. */
private val PaneBackground = Color(0.07f, 0.07f, 0.08f)

private tailrec fun Context.activityWindow(): Window? = when (this) {
    is Activity -> window
    is ContextWrapper -> baseContext.activityWindow()
    else -> null
}

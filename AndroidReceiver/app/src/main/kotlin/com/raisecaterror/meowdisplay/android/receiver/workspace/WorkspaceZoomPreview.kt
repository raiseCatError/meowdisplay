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
import androidx.compose.foundation.Image
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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.unit.dp
import com.raisecaterror.meowdisplay.core.controls.CGRect
import kotlin.math.roundToInt

/**
 * Hybrid zoom: while a pinch or two-finger pan is under way, the pane shows a copy of its own
 * picture taken when the gesture began, scaled and moved with the fingers at once. The Mac's sharp
 * frames take over when the controller clears the preview shortly after the gesture ends.
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
    val image = still?.takeIf { it.first == shown.gesture }?.second ?: return
    val visible = zoom != null
    val alpha by animateFloatAsState(if (visible) 1f else 0f, if (visible) snap() else tween(150), label = "zoomPreview")
    if (!visible && alpha == 0f) return
    val p = shown.preview
    val paneX = frame.minX + p.pane.x * frame.width
    val paneY = frame.minY + p.pane.y * frame.height
    val paneW = p.pane.width * frame.width
    val paneH = p.pane.height * frame.height
    // In pane dp the copy moves by L' = scale * L + ((scale - 1) * pane + offset) * picture.
    val tx = ((p.scaleX - 1) * p.pane.x + p.offsetX) * frame.width
    val ty = ((p.scaleY - 1) * p.pane.y + p.offsetY) * frame.height
    Box(
        Modifier
            .offset(paneX.dp, paneY.dp)
            .size(paneW.dp, paneH.dp)
            .alpha(alpha)
            .clipToBounds()
            .background(Color.Black),
    ) {
        Image(
            image, contentDescription = null, contentScale = ContentScale.FillBounds,
            modifier = Modifier.size(paneW.dp, paneH.dp).graphicsLayer {
                transformOrigin = TransformOrigin(0f, 0f)
                scaleX = p.scaleX.toFloat()
                scaleY = p.scaleY.toFloat()
                translationX = (tx * density).toFloat()
                translationY = (ty * density).toFloat()
            },
        )
    }
}

private tailrec fun Context.activityWindow(): Window? = when (this) {
    is Activity -> window
    is ContextWrapper -> baseContext.activityWindow()
    else -> null
}

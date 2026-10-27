package com.raisecaterror.meowdisplay.android.ui

import android.os.SystemClock
import android.util.Log
import android.view.SurfaceHolder
import android.view.SurfaceView
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.viewinterop.AndroidView
import com.raisecaterror.meowdisplay.android.media.MediaPipeline

/** The Mac's picture, letterboxed on black. Controls and input arrive with the receiver controls milestone. */
@Composable
fun ReceiverSurface(pipeline: MediaPipeline) {
    val size by pipeline.videoSize.collectAsState()
    val aspect = size?.let { (w, h) -> w.toFloat() / h } ?: (16f / 9f)
    Box(Modifier.fillMaxSize().background(Color.Black), contentAlignment = Alignment.Center) {
        AndroidView(
            factory = { context ->
                SurfaceView(context).apply {
                    keepScreenOn = true
                    holder.addCallback(object : SurfaceHolder.Callback {
                        override fun surfaceCreated(holder: SurfaceHolder) {
                            Log.i("MeowDecoderTrace", "t=${SystemClock.elapsedRealtime()} surfaceCreated")
                            pipeline.video.setSurface(holder.surface)
                        }

                        override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
                            Log.i("MeowDecoderTrace", "t=${SystemClock.elapsedRealtime()} surfaceChanged ${width}x$height")
                        }

                        override fun surfaceDestroyed(holder: SurfaceHolder) {
                            Log.i("MeowDecoderTrace", "t=${SystemClock.elapsedRealtime()} surfaceDestroyed")
                            pipeline.video.setSurface(null)
                        }
                    })
                }
            },
            modifier = Modifier.aspectRatio(aspect),
        )
    }
}

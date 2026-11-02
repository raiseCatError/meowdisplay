package com.raisecaterror.meowdisplay.android.media

import android.content.Context
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.raisecaterror.meowdisplay.core.video.StreamStats
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/** Settings > Session > Performance Overlay. Device-local, like the iPhone's. */
class DiagnosticsPrefs(context: Context) {
    private val prefs = context.getSharedPreferences("diagnostics", Context.MODE_PRIVATE)
    private val overlay = MutableStateFlow(prefs.getBoolean(KEY_OVERLAY, false))
    val performanceOverlay: StateFlow<Boolean> = overlay.asStateFlow()

    fun setPerformanceOverlay(on: Boolean) {
        prefs.edit().putBoolean(KEY_OVERLAY, on).apply()
        overlay.value = on
    }

    private companion object { const val KEY_OVERLAY = "performanceOverlay" }
}

/** One line of stream numbers, refreshed every second. Never takes touches. */
@Composable
fun PerformanceOverlay(stats: StreamStats, rttMs: () -> Double?, modifier: Modifier = Modifier, route: String? = null) {
    var line by remember { mutableStateOf("") }
    LaunchedEffect(stats, route) {
        while (true) {
            line = describe(stats.snapshot(System.currentTimeMillis().toDouble()), rttMs(), route)
            delay(1000)
        }
    }
    if (line.isEmpty()) return
    Text(
        line, color = Color.White, fontFamily = FontFamily.Monospace, fontSize = 11.sp,
        modifier = modifier.clearAndSetSemantics {}.background(Color.Black.copy(alpha = 0.6f), RoundedCornerShape(8.dp))
            .padding(horizontal = 8.dp, vertical = 4.dp),
    )
}

/** The measured numbers as they are. [route] (`Remote (Tailscale)`) only says how the session got here; the latency is never rounded to look local. */
internal fun describe(s: StreamStats.Snapshot, rtt: Double?, route: String? = null): String = buildList {
    route?.let { add(it) }
    add("${s.fps} fps")
    add("%.1f Mbit/s".format(s.mbps))
    s.decodeP50Ms?.let { add("decode %.1f ms".format(it)) }
    s.latencyP50Ms?.let { p50 -> add("latency %.0f ms".format(p50) + (s.latencyP95Ms?.let { " (p95 %.0f)".format(it) } ?: "")) }
    rtt?.let { add("rtt %.0f ms".format(it)) }
    if (s.dropped > 0) add("dropped ${s.dropped}")
}.joinToString(" · ")

package com.raisecaterror.meowdisplay.android.receiver.workspace

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.raisecaterror.meowdisplay.core.session.InputWireState

/** The session's control state and the one existing way to ask for control (the same request as Settings ▸ Input). */
data class InlineControlRequest(val state: InputWireState, val request: () -> Unit) {
    /** The label for a control-gated button while control is missing. */
    val gatedLabel: String get() = when (state) {
        InputWireState.Requesting -> "Awaiting Approval"
        InputWireState.RequestsDisabled -> "Needs Control"
        else -> "Request Control"
    }
}

val LocalControlRequest = compositionLocalOf<InlineControlRequest?> { null }

/** "Control required · Request Control" in place; Awaiting approval; Ask Again after a no. Never repeats the action. */
@Composable
fun RequestControlInline(compact: Boolean = false, modifier: Modifier = Modifier) {
    val control = LocalControlRequest.current ?: return
    if (control.state == InputWireState.Allowed) return
    val dim = Color.White.copy(alpha = 0.85f)
    Row(modifier, horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
        when (control.state) {
            InputWireState.Requesting -> {
                CircularProgressIndicator(Modifier.size(14.dp), color = dim, strokeWidth = 2.dp)
                Text("Awaiting approval on the Mac…", color = dim, fontSize = 12.sp)
            }
            InputWireState.RequestsDisabled -> Text("This Mac doesn't take control requests from this device.", color = dim, fontSize = 12.sp)
            InputWireState.NotAllowed -> {
                Text("Not allowed.", color = dim, fontSize = 12.sp)
                SmallRequestButton("Ask Again", control.request)
            }
            else -> {
                if (!compact) Text("Control required", color = dim, fontSize = 12.sp)
                SmallRequestButton("Request Control", control.request)
            }
        }
    }
}

@Composable
private fun SmallRequestButton(title: String, onClick: () -> Unit) {
    Button(onClick = onClick, contentPadding = PaddingValues(horizontal = 12.dp, vertical = 2.dp),
        modifier = Modifier.semantics { contentDescription = "$title. Asks the Mac to allow control from this device" }) {
        Text(title, fontSize = 12.sp)
    }
}

package com.raisecaterror.meowdisplay.android.receiver

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/** Hosts the control overlay for the live screen. */
@Composable
fun ReceiverOverlayHost(controller: ReceiverController, window: ReceiverWindow, actions: OverlayActions, inputResetGeneration: Int) {
    val view by controller.view.collectAsState()
    Box(Modifier.fillMaxSize()) {
        // Temporary until the Compose control overlay lands: the permanent Settings gear.
        Box(
            Modifier.align(Alignment.BottomEnd).padding(end = (window.safeInsets.trailing + 12).dp, bottom = (window.safeInsets.bottom + 12).dp)
                .size(46.dp).background(Color(0x99303033), CircleShape).clickable(role = Role.Button) { actions.openSettings() }
                .semantics { contentDescription = "Settings" },
            contentAlignment = Alignment.Center,
        ) { Text("⚙", color = Color.White, fontSize = 20.sp) }
    }
    @Suppress("UNUSED_EXPRESSION") view
    @Suppress("UNUSED_EXPRESSION") inputResetGeneration
}

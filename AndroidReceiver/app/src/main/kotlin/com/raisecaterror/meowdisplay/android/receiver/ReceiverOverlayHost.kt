package com.raisecaterror.meowdisplay.android.receiver

import android.provider.Settings
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.platform.LocalContext
import com.raisecaterror.meowdisplay.android.receiver.overlay.ReceiverControlOverlay

/** The control overlay over the live screen, fed from the window and the session. */
@Composable
fun ReceiverOverlayHost(controller: ReceiverController, window: ReceiverWindow, actions: OverlayActions, inputResetGeneration: Int) {
    val view by controller.view.collectAsState()
    val context = LocalContext.current
    // Android's "Remove animations" is the counterpart of iOS Reduce Motion.
    val reduceMotion = remember { Settings.Global.getFloat(context.contentResolver, Settings.Global.ANIMATOR_DURATION_SCALE, 1f) == 0f }
    val environment = OverlayEnvironment(
        containerSize = window.size,
        safeInsets = window.safeInsets,
        notchSide = window.notchSide,
        reservedRegions = window.reservedRegions,
        keyboardVisibleRect = window.keyboardVisibleRect,
        expanded = window.expanded,
        senderPV = view.senderPV,
        keyboardAvailable = view.inputAllowed && view.senderPV >= KEYBOARD_PV,
        videoEnabled = view.videoEnabled,
        inputState = view.inputState,
        screenReaderRunning = controller.screenReaderRunning,
        reduceMotion = reduceMotion,
    )
    ReceiverControlOverlay(controller.store, environment, actions, inputResetGeneration)
}

private const val KEYBOARD_PV = 4

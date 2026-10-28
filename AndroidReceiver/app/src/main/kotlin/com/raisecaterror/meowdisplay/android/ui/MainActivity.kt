package com.raisecaterror.meowdisplay.android.ui

import android.content.res.Configuration
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.activity.compose.BackHandler
import com.raisecaterror.meowdisplay.android.receiver.ReceiverOverlayHost
import com.raisecaterror.meowdisplay.android.receiver.ReceiverScreen
import com.raisecaterror.meowdisplay.android.receiver.ReceiverSettings
import com.raisecaterror.meowdisplay.android.MeowReceiverApplication

class MainActivity : ComponentActivity() {
    private val app get() = application as MeowReceiverApplication

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        app.pipeline // subscribes the decoders before any session starts
        // And the controls, so the first session's Admitted and input state
        // reach them (C4 F-01: no Request Input prompt in the first session).
        app.receiver
        // Recreated for a rotation: same session, new panel dimensions (PROTOCOL.md 6.1).
        if (savedInstanceState != null) app.media.session.resendHello()
        enableEdgeToEdge()
        setContent {
            MeowTheme {
                val mediaUi by app.media.ui.collectAsState()
                val paired by app.pins.paired.collectAsState()
                var settingsOpen by remember { mutableStateOf(false) }
                // Home while connected: shown over the live picture, so the session, the Mac's
                // display and the decoder are untouched and Return to Display is instant (R-01).
                var homeShown by rememberSaveable { mutableStateOf(false) }
                if (mediaUi.admitted) {
                    val macName = paired.firstOrNull { it.peerID == mediaUi.peerID }?.name ?: "your Mac"
                    ReceiverScreen(
                        app.receiver, app.pipeline,
                        overlay = { window, actions, generation -> ReceiverOverlayHost(app.receiver, window, actions, generation) },
                        onOpenSettings = { settingsOpen = true },
                        onBack = { app.receiver.releaseHeldInput(); homeShown = true },
                        workspace = app.workspace, macName = macName,
                        onMode = { app.media.session.requestDisplayMode(it) },
                        immersive = !homeShown,
                    )
                    if (homeShown) {
                        BackHandler { moveTaskToBack(true) }
                        ReceiverHome(app.identity, app.pins, app.bonjour, app.pairing, app.media,
                            onReturnToDisplay = { homeShown = false }, onOpenSettings = { settingsOpen = true })
                    }
                    if (settingsOpen) ReceiverSettings(app.receiver, app.media, onDismiss = { settingsOpen = false })
                } else {
                    homeShown = false
                    ReceiverHome(app.identity, app.pins, app.bonjour, app.pairing, app.media, onOpenSettings = { settingsOpen = true })
                    if (settingsOpen) ReceiverSettings(app.receiver, app.media, onDismiss = { settingsOpen = false })
                }
            }
        }
    }

    // Pairing and media are offered only while the app is in front, like the
    // Apple receivers' pairing screen: nothing listens in the background.
    // Rotation is handled in place (manifest configChanges): same session, new panel (PROTOCOL.md 6.1).
    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        app.media.session.resendHello()
    }

    override fun onStart() {
        super.onStart()
        app.pairing.start()
        app.media.start()
    }

    override fun onStop() {
        // A rotation recreates the activity: the session and listeners stay.
        if (!isChangingConfigurations) {
            app.pairing.stop()
            // Nothing stays held on the Mac once this device leaves the foreground.
            app.receiver.releaseHeldInput()
            // Backgrounded, not quit: the Mac is told to expect this device back.
            app.media.stop(sleeping = !isFinishing)
        }
        super.onStop()
    }
}

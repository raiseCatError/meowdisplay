package com.raisecaterror.meowdisplay.android.ui

import android.app.PictureInPictureParams
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.os.Build
import android.os.Bundle
import android.util.Rational
import androidx.compose.runtime.LaunchedEffect
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
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.fillMaxSize
import com.raisecaterror.meowdisplay.android.receiver.ReceiverOverlayHost
import com.raisecaterror.meowdisplay.android.receiver.ReceiverScreen
import com.raisecaterror.meowdisplay.android.receiver.ReceiverSettings
import com.raisecaterror.meowdisplay.android.MeowReceiverApplication

class MainActivity : ComponentActivity() {
    private val app get() = application as MeowReceiverApplication
    /** In picture-in-picture: only the picture shows, view only. */
    private val inPictureInPicture = mutableStateOf(false)
    private val supportsPictureInPicture by lazy { packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE) }

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
                val prefs by app.receiver.store.preferences.collectAsState()
                val pip by inPictureInPicture
                // Android 12+: leaving the app during a session slides the picture into a small window.
                LaunchedEffect(mediaUi.admitted, prefs.pictureInPictureEnabled) { updatePictureInPicture() }
                if (pip) {
                    if (mediaUi.admitted) ReceiverScreen(app.receiver, app.pipeline, overlay = { _, _, _ -> }, onOpenSettings = {},
                        workspace = app.workspace, pictureInPicture = true)
                    else PictureInPictureEnded()
                    return@MeowTheme
                }
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
                    if (settingsOpen) ReceiverSettings(app.receiver, app.media, onDismiss = { settingsOpen = false },
                        onStartPictureInPicture = if (supportsPictureInPicture) ({ enterPictureInPicture() }) else null)
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
        updatePictureInPicture()
    }

    private fun pictureInPictureAllowed(): Boolean =
        supportsPictureInPicture && app.media.ui.value.admitted && app.receiver.store.preferences.value.pictureInPictureEnabled

    private fun pictureInPictureParams(): PictureInPictureParams {
        val builder = PictureInPictureParams.Builder()
        val w = window.decorView.width
        val h = window.decorView.height
        // The Mac streams this screen's shape; Android accepts 1:2.39 to 2.39:1.
        if (w > 0 && h > 0) builder.setAspectRatio(Rational(w, h).let { r ->
            when {
                r.toFloat() > 2.39f -> Rational(239, 100)
                r.toFloat() < 1 / 2.39f -> Rational(100, 239)
                else -> r
            }
        })
        if (Build.VERSION.SDK_INT >= 31) builder.setAutoEnterEnabled(pictureInPictureAllowed())
        return builder.build()
    }

    private fun updatePictureInPicture() {
        if (supportsPictureInPicture) runCatching { setPictureInPictureParams(pictureInPictureParams()) }
    }

    private fun enterPictureInPicture() {
        if (supportsPictureInPicture && app.media.ui.value.admitted) runCatching { enterPictureInPictureMode(pictureInPictureParams()) }
    }

    // Before Android 12 there is no auto-enter: going Home starts it here.
    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        if (Build.VERSION.SDK_INT < 31 && pictureInPictureAllowed()) enterPictureInPicture()
    }

    override fun onPictureInPictureModeChanged(isInPictureInPictureMode: Boolean, newConfig: Configuration) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        inPictureInPicture.value = isInPictureInPictureMode
        // View only while small: nothing stays pressed on the Mac.
        if (isInPictureInPictureMode) app.receiver.releaseHeldInput()
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

/** The session ended while the picture was small. */
@androidx.compose.runtime.Composable
private fun PictureInPictureEnded() {
    androidx.compose.foundation.layout.Box(
        androidx.compose.ui.Modifier.fillMaxSize().background(androidx.compose.ui.graphics.Color.Black),
        contentAlignment = androidx.compose.ui.Alignment.Center,
    ) {
        androidx.compose.material3.Text("Disconnected", color = androidx.compose.ui.graphics.Color.White)
    }
}

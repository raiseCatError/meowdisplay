package com.raisecaterror.meowdisplay.android.ui

import android.content.res.Configuration
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import com.raisecaterror.meowdisplay.android.MeowReceiverApplication

class MainActivity : ComponentActivity() {
    private val app get() = application as MeowReceiverApplication

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        app.pipeline // subscribes the decoders before any session starts
        // Recreated for a rotation: same session, new panel dimensions (PROTOCOL.md 6.1).
        if (savedInstanceState != null) app.media.session.resendHello()
        enableEdgeToEdge()
        setContent {
            MeowTheme {
                val mediaUi by app.media.ui.collectAsState()
                if (mediaUi.admitted) {
                    ReceiverSurface(app.pipeline)
                } else {
                    ReceiverHome(app.identity, app.pins, app.bonjour, app.pairing, app.media)
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
            // Backgrounded, not quit: the Mac is told to expect this device back.
            app.media.stop(sleeping = !isFinishing)
        }
        super.onStop()
    }
}

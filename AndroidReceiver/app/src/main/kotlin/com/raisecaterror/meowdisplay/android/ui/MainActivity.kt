package com.raisecaterror.meowdisplay.android.ui

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import com.raisecaterror.meowdisplay.android.MeowReceiverApplication

class MainActivity : ComponentActivity() {
    private val app get() = application as MeowReceiverApplication

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            MeowTheme {
                ReceiverHome(app.identity, app.pins, app.bonjour, app.pairing)
            }
        }
    }

    // Pairing is offered only while the app is in front, like the Apple
    // receivers' pairing screen: nothing listens in the background.
    override fun onStart() {
        super.onStart()
        app.pairing.start()
    }

    override fun onStop() {
        app.pairing.stop()
        super.onStop()
    }
}

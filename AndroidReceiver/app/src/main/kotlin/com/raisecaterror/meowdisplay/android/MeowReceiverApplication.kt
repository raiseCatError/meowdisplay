package com.raisecaterror.meowdisplay.android

import android.app.Application
import android.view.WindowManager
import com.raisecaterror.meowdisplay.android.discovery.Bonjour
import com.raisecaterror.meowdisplay.android.identity.DeviceIdentity
import com.raisecaterror.meowdisplay.android.media.MediaPipeline
import com.raisecaterror.meowdisplay.android.pairing.PairingController
import com.raisecaterror.meowdisplay.android.session.MediaController
import com.raisecaterror.meowdisplay.android.session.SessionPolicyPrefs
import com.raisecaterror.meowdisplay.android.trust.PinStore
import com.raisecaterror.meowdisplay.core.session.HelloFields
import kotlin.math.roundToInt

/** Process-wide receiver services: one identity, one pin store, one pairing listener, one media listener. */
class MeowReceiverApplication : Application() {
    val identity: DeviceIdentity by lazy { DeviceIdentity.load(this) }
    val pins: PinStore by lazy { PinStore(this) }
    val bonjour: Bonjour by lazy { Bonjour(this) }
    val pairing: PairingController by lazy {
        PairingController(identity, pins, bonjour, localName = { DeviceIdentity.displayName(this) })
    }
    val media: MediaController by lazy {
        MediaController(identity, pins, SessionPolicyPrefs(this), bonjour, localName = { DeviceIdentity.displayName(this) }, panel = ::panel)
    }

    val pipeline: MediaPipeline by lazy { MediaPipeline(media) }

    /** The panel in its current orientation; the receiver surface refines this once it is on screen. */
    private fun panel(): HelloFields {
        val metrics = resources.displayMetrics
        @Suppress("DEPRECATION")
        val refresh = (getSystemService(WINDOW_SERVICE) as WindowManager).defaultDisplay.refreshRate
        return HelloFields(
            pixelsWide = metrics.widthPixels, pixelsHigh = metrics.heightPixels, scale = metrics.density.toDouble(),
            installID = identity.installID, maxFPS = refresh.roundToInt().takeIf { it > 0 },
        )
    }
}

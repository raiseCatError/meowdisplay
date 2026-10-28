package com.raisecaterror.meowdisplay.android

import android.app.Application
import android.os.Build
import android.util.DisplayMetrics
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

    /**
     * The panel: the whole current display in its current orientation, never
     * the app's window. Rotation and fold/unfold change it (and re-announce
     * it to the Mac); split-screen, freeform resizing and on-screen controls
     * don't, so local layout changes never rebuild the Mac's display.
     */
    private fun panel(): HelloFields {
        val windows = getSystemService(WINDOW_SERVICE) as WindowManager
        val (wide, high) = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            windows.maximumWindowMetrics.bounds.let { it.width() to it.height() }
        } else {
            @Suppress("DEPRECATION")
            DisplayMetrics().also { windows.defaultDisplay.getRealMetrics(it) }.let { it.widthPixels to it.heightPixels }
        }
        @Suppress("DEPRECATION")
        val refresh = windows.defaultDisplay.refreshRate
        return HelloFields(
            pixelsWide = wide, pixelsHigh = high, scale = resources.displayMetrics.density.toDouble(),
            installID = identity.installID, maxFPS = refresh.roundToInt().takeIf { it > 0 },
        )
    }
}

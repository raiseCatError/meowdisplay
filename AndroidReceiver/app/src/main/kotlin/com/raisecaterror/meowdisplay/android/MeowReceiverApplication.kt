package com.raisecaterror.meowdisplay.android

import android.app.Application
import android.os.Build
import android.util.DisplayMetrics
import android.view.WindowManager
import com.raisecaterror.meowdisplay.android.controls.ReceiverControlStore
import com.raisecaterror.meowdisplay.android.controls.SharedPreferenceBlobStore
import com.raisecaterror.meowdisplay.android.discovery.Bonjour
import com.raisecaterror.meowdisplay.android.receiver.ReceiverController
import com.raisecaterror.meowdisplay.android.receiver.workspace.WorkspaceController
import com.raisecaterror.meowdisplay.core.workspace.WorkspaceWire
import com.raisecaterror.meowdisplay.android.identity.DeviceIdentity
import com.raisecaterror.meowdisplay.android.media.MediaPipeline
import com.raisecaterror.meowdisplay.android.pairing.PairingController
import com.raisecaterror.meowdisplay.android.session.InputAutoRequestPrefs
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
        MediaController(identity, pins, SessionPolicyPrefs(this), bonjour, localName = { DeviceIdentity.displayName(this) }, panel = ::panel,
            inputAutoRequest = InputAutoRequestPrefs(this))
    }

    val pipeline: MediaPipeline by lazy { MediaPipeline(media, avSyncOffsetMs = { controls.current.avSyncOffsetMs }) }

    /** Device-local diagnostics switches (the performance overlay). */
    val diagnostics: com.raisecaterror.meowdisplay.android.media.DiagnosticsPrefs by lazy {
        com.raisecaterror.meowdisplay.android.media.DiagnosticsPrefs(this)
    }

    /** The receiver controls' preferences (iOS JSON format) and their transient state. */
    val controls: ReceiverControlStore by lazy { ReceiverControlStore(SharedPreferenceBlobStore(this)) }

    /** Input, viewport and control wiring for the live receiver surface. */
    val receiver: ReceiverController by lazy {
        ReceiverController(media, controls, pipeline.videoSize).also {
            media.session.audioPreferred = controls.current.audioPreferred
            media.session.autoReconnectEnabled = controls.current.autoReconnectEnabled
            it.workspace = workspace
        }
    }

    /** Window mode: the arrangement of Mac windows on this device (per Mac). */
    val workspace: WorkspaceController by lazy { WorkspaceController(this, media) }

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
            trayEnabled = controls.current.trayEnabled, keyboardButtonEnabled = controls.current.keyboardButtonEnabled,
            windowWorkspace = WorkspaceWire.VERSION,
        )
    }
}

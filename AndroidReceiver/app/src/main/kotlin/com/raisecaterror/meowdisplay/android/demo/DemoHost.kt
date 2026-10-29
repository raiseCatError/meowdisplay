package com.raisecaterror.meowdisplay.android.demo

import android.content.Context
import android.os.Handler
import android.os.Looper
import com.raisecaterror.meowdisplay.android.controls.ReceiverControlStore
import com.raisecaterror.meowdisplay.android.receiver.ReceiverController
import com.raisecaterror.meowdisplay.android.receiver.workspace.WorkspaceController
import com.raisecaterror.meowdisplay.android.session.InputAutoRequestPrefs
import com.raisecaterror.meowdisplay.android.session.MediaUiState
import com.raisecaterror.meowdisplay.android.session.SessionHost
import com.raisecaterror.meowdisplay.core.demo.DemoMac
import com.raisecaterror.meowdisplay.core.session.HelloFields
import com.raisecaterror.meowdisplay.core.session.InMemorySessionPolicyStore
import com.raisecaterror.meowdisplay.core.session.ReceiverSession
import com.raisecaterror.meowdisplay.core.session.SessionEvent
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update

/**
 * Explore Demo's session: a separate [ReceiverSession] connected to the
 * in-process [DemoMac]. It shares nothing with the real receiver: no pin
 * store (its only "pin" is a placeholder for the demo Mac's id, held in
 * memory), an in-memory connection policy, no listener, no Bonjour, no
 * socket. Main thread only.
 */
class DemoHost(panel: () -> HelloFields) : SessionHost {
    private val main = Handler(Looper.getMainLooper())
    private val state = MutableStateFlow(MediaUiState())
    override val ui: StateFlow<MediaUiState> = state.asStateFlow()
    @Volatile override var controlEvents: ((SessionEvent) -> Unit)? = null
    override val inputAutoRequest: InputAutoRequestPrefs? = null
    override val isDemo: Boolean = true
    override fun macName(peerID: String?): String = DemoMac.MAC_NAME

    val mac: DemoMac = DemoMac(
        post = { main.post(it) },
        thumbnail = { kind, width -> DemoPainter.thumbnailBase64(macScene(), kind, width) },
        appIcon = DemoPainter::iconBase64,
    )
    private fun macScene(): com.raisecaterror.meowdisplay.core.demo.DemoScene = mac.scene.value

    override val session = ReceiverSession(
        InMemorySessionPolicyStore(automaticallyAllow = true),
        { mapOf(DemoMac.PEER_ID to DEMO_PLACEHOLDER_PIN) },
        { panel().copy(requestedMode = null) },
        ::onEvent,
    )

    private val size = MutableStateFlow<Pair<Int, Int>?>(null)
    /** The sample picture's size in "video" pixels, like the decoder's size in a real session. */
    val pictureSize: StateFlow<Pair<Int, Int>?> = size.asStateFlow()

    fun start() {
        mac.attach { bytes -> session.onFrame(mac.link, bytes) }
        session.adopt(mac.link)
    }

    fun stop() {
        session.disconnect()
    }

    private fun onEvent(event: SessionEvent) {
        controlEvents?.invoke(event)
        when (event) {
            is SessionEvent.Phase -> state.update { it.copy(phase = event.phase) }
            is SessionEvent.Connected -> state.update { it.copy(peerID = event.peerID, admitted = false) }
            is SessionEvent.Disconnected -> {
                size.value = null
                state.update { it.copy(admitted = false, source = null) }
            }
            is SessionEvent.Admitted -> state.update { it.copy(admitted = true) }
            SessionEvent.AdmissionWithdrawn -> state.update { it.copy(admitted = false) }
            is SessionEvent.InputState -> state.update { it.copy(input = event.state) }
            is SessionEvent.DisplayModeConfirmed -> state.update { it.copy(source = event.mode.wire) }
            is SessionEvent.VideoState -> size.value = if (event.enabled && event.width != null && event.height != null) event.width!! to event.height!! else null
            else -> Unit
        }
    }

    private companion object {
        /** Not a key: the demo session needs *a* pinned peer to admit, and this one is the demo Mac only. */
        val DEMO_PLACEHOLDER_PIN = byteArrayOf(0x44, 0x45, 0x4D, 0x4F)
    }
}

/** Preferences that live only as long as the demo run. */
private class MemoryBlobStore : com.raisecaterror.meowdisplay.core.controls.PreferenceBlobStore {
    private val values = HashMap<String, String>()
    override fun read(key: String): String? = values[key]
    override fun write(key: String, value: String) {
        values[key] = value
    }
}

/**
 * One run of Explore Demo: the demo session plus its own controls,
 * preferences file and window arrangement file. Both files are cleared when
 * a run starts and when it ends, so nothing a reviewer tries reaches the
 * real receiver, and the next run starts fresh.
 */
class DemoRuntime(context: Context, panel: () -> HelloFields) {
    private val appContext = context.applicationContext
    val host: DemoHost
    val store: ReceiverControlStore
    val controller: ReceiverController
    val workspace: WorkspaceController

    init {
        clearFiles(appContext)
        host = DemoHost(panel)
        // In memory only: a demo's control settings never reach the disk.
        store = ReceiverControlStore(MemoryBlobStore()).also {
            it.update { prefs ->
                prefs.audioPreferred = false
                // The demo's guide explains Natural Touch; its one-time hint would cover the DEMO badge.
                prefs.naturalTouchHintShown = true
            }
        }
        workspace = WorkspaceController(appContext, host, WORKSPACE_FILE).also {
            // The guide and the empty Windows card offer Window view; the top-centre offer would cover the DEMO badge.
            it.windowPromptAnswered.value = true
        }
        controller = ReceiverController(host, store, host.pictureSize).also { it.workspace = workspace }
        host.start()
    }

    fun close() {
        controller.releaseHeldInput()
        host.stop()
        clearFiles(appContext)
        // Once more after the session's last events: a late arrangement save never outlives the demo.
        Handler(Looper.getMainLooper()).postDelayed({ clearFiles(appContext) }, 1_500)
    }

    companion object {
        const val CONTROLS_FILE = "demoReceiverControls"
        const val WORKSPACE_FILE = "demoWorkspace"

        /** Earlier builds kept demo controls in [CONTROLS_FILE]; it is removed too. Cleared in memory first: Android keeps a loaded preferences file cached after its file is deleted. */
        fun clearFiles(context: Context) {
            for (name in listOf(CONTROLS_FILE, WORKSPACE_FILE)) {
                context.getSharedPreferences(name, Context.MODE_PRIVATE).edit().clear().commit()
                context.deleteSharedPreferences(name)
            }
        }
    }
}

package com.raisecaterror.meowdisplay.android.controls

import android.annotation.SuppressLint
import android.content.Context
import android.os.Handler
import android.os.Looper
import com.raisecaterror.meowdisplay.core.controls.ControlAutoHidePolicy
import com.raisecaterror.meowdisplay.core.controls.ControlModifier
import com.raisecaterror.meowdisplay.core.controls.ControlProfile
import com.raisecaterror.meowdisplay.core.controls.FunctionTrayProfile
import com.raisecaterror.meowdisplay.core.controls.PadControlLayoutMode
import com.raisecaterror.meowdisplay.core.controls.PreferenceBlobStore
import com.raisecaterror.meowdisplay.core.controls.ReceiverControlPreferences
import com.raisecaterror.meowdisplay.core.controls.ReceiverControlPreferencesRepository
import com.raisecaterror.meowdisplay.core.controls.ReceiverUIPreferenceUpdate
import com.raisecaterror.meowdisplay.core.controls.activeCustomLayout
import com.raisecaterror.meowdisplay.core.controls.atProcessStart
import com.raisecaterror.meowdisplay.core.controls.initial
import com.raisecaterror.meowdisplay.core.session.InputWireState
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/** The preference blob in app-private SharedPreferences (never backed up, like pins). */
class SharedPreferenceBlobStore(context: Context, name: String = "receiverControls") : PreferenceBlobStore {
    private val prefs = context.getSharedPreferences(name, Context.MODE_PRIVATE)
    override fun read(key: String): String? = prefs.getString(key, null)

    @SuppressLint("UseKtx")
    override fun write(key: String, value: String) {
        prefs.edit().putString(key, value).apply()
    }
}

/**
 * The receiver's control state (iOS/ReceiverControls.swift ReceiverControlStore).
 * Preferences persist; everything else here is transient and never outlives
 * the process or a session: auto-hidden, Move View, the projected chord, the
 * Mac's input state. Main thread only.
 *
 * Android has one store for every window size: it starts from the iPad
 * defaults (the radial Custom layout), which the compact iPhone-style tray
 * never reads, so a window that grows past compact opens on the iPad's
 * default and a user's own layout choice is kept across every transition.
 */
class ReceiverControlStore(private val blobs: PreferenceBlobStore) {
    private val repository = ReceiverControlPreferencesRepository(blobs)
    private val handler = Handler(Looper.getMainLooper())
    private val prefsState = MutableStateFlow(repository.load(ReceiverControlPreferences.initial(isPad = true)).atProcessStart())
    private val transientState = MutableStateFlow(Transient())

    val preferences: StateFlow<ReceiverControlPreferences> = prefsState.asStateFlow()

    // iOS keeps Zoom While Typing beside the control preferences (its own AppStorage key), so it isn't in their JSON.
    private val zoomWhileTypingState = MutableStateFlow(blobs.read(ZOOM_WHILE_TYPING) != "false")

    /** Input → Zoom While Typing: enlarge the area being typed in while the keyboard is open. */
    val zoomWhileTyping: StateFlow<Boolean> = zoomWhileTypingState.asStateFlow()

    fun setZoomWhileTyping(on: Boolean) {
        blobs.write(ZOOM_WHILE_TYPING, on.toString())
        zoomWhileTypingState.value = on
    }
    val transient: StateFlow<Transient> = transientState.asStateFlow()

    /** Called whenever held input must be released (tray off, profile change, input off, input-mode change). */
    var onInputResetRequested: (() -> Unit)? = null

    /** Whether the expanded (iPad-style) presentation is in effect — set by the window layout, not the device. */
    var isExpanded: Boolean = false
        set(value) {
            if (field == value) return
            field = value
            resetAutoHide()
        }

    data class Transient(
        val autoHidden: Boolean = false,
        val moveViewActive: Boolean = false,
        val viewportResetGeneration: Int = 0,
        val activeChordModifiers: Set<ControlModifier> = emptySet(),
        val userTurnedOffInput: Boolean = false,
        val sessionInputState: InputWireState = InputWireState.Off,
    )

    val current: ReceiverControlPreferences get() = prefsState.value

    /** Custom needs a layout to show; otherwise it presents as Overlay. */
    val effectivePadLayout: PadControlLayoutMode
        get() = current.padControlLayout.let { stored ->
            if (stored == PadControlLayoutMode.Custom && current.activeCustomLayout == null) PadControlLayoutMode.Overlay else stored
        }

    val activeProfile: ControlProfile get() = current.profile(current.activeControlProfile)

    /** Independent of [activeProfile]: the two trays' profiles never move in lockstep. */
    val activeFunctionTrayProfile: FunctionTrayProfile get() = current.functionTrayProfile(current.activeFunctionTrayProfile)

    private val autoHideRunnable = Runnable {
        if (autoHideAllowed) {
            android.util.Log.i("MeowControls", "auto-hide")
            mutate { it.copy(autoHidden = true) }
        }
    }

    fun projectChord(modifiers: Set<ControlModifier>) {
        if (modifiers != transientState.value.activeChordModifiers) mutate { it.copy(activeChordModifiers = modifiers) }
    }

    fun noteInputTurnedOffByUser(turnedOff: Boolean) = mutate { it.copy(userTurnedOffInput = turnedOff) }

    fun setMoveViewActive(active: Boolean) {
        if (transientState.value.moveViewActive == active) return
        mutate { it.copy(moveViewActive = active) }
        if (active) beginAutoHideActivity() else scheduleAutoHide()
    }

    fun requestViewportReset() = mutate { it.copy(viewportResetGeneration = it.viewportResetGeneration + 1) }

    /** Any meaningful interaction anywhere on the surface: reveal now and suspend the countdown. */
    fun beginAutoHideActivity() {
        handler.removeCallbacks(autoHideRunnable)
        if (transientState.value.autoHidden) mutate { it.copy(autoHidden = false) }
    }

    /** (Re)starts the 9 s countdown, unless hiding isn't appropriate right now. Re-validated when it fires. */
    fun scheduleAutoHide(interactionIdle: Boolean = true) {
        handler.removeCallbacks(autoHideRunnable)
        if (!autoHideAllowed || !interactionIdle) return
        handler.postDelayed(autoHideRunnable, AUTO_HIDE_DELAY_MS)
    }

    fun resetAutoHide() {
        beginAutoHideActivity()
        scheduleAutoHide()
    }

    /** Move View keeps its controls up so the mode can always be left. */
    private val autoHideAllowed: Boolean
        get() = current.autoHideEnabled && current.trayCanBeShown && !current.trayCollapsed && !transientState.value.moveViewActive &&
            ControlAutoHidePolicy.applies(isPad = isExpanded, layout = effectivePadLayout)

    /**
     * Mutates a deep copy, saves it and publishes it. Input that a change
     * makes stale (tray off, a profile switch, input turned off, a new pointer
     * model) is released through [onInputResetRequested].
     */
    fun update(change: (ReceiverControlPreferences) -> Unit) {
        val previous = current
        val previousProfile = activeProfile
        val previousFunctionProfile = activeFunctionTrayProfile
        val next = previous.deepCopy()
        change(next)
        if (next == previous) return
        repository.save(next)
        prefsState.value = next
        val profileChanged = previous.activeControlProfile != next.activeControlProfile || previousProfile != activeProfile
        val functionProfileChanged = previous.activeFunctionTrayProfile != next.activeFunctionTrayProfile ||
            previousFunctionProfile != activeFunctionTrayProfile
        val allowInputDisabled = previous.allowInput && !next.allowInput
        val inputModeChanged = previous.inputMode != next.inputMode
        if ((previous.trayEnabled && !next.trayEnabled) || profileChanged || functionProfileChanged || allowInputDisabled || inputModeChanged) {
            onInputResetRequested?.invoke()
        }
    }

    fun updateActiveProfile(change: (ControlProfile) -> Unit) {
        val profile = activeProfile.copy()
        change(profile)
        update { it.updateProfile(profile) }
    }

    fun updateActiveFunctionTrayProfile(change: (FunctionTrayProfile) -> Unit) {
        val profile = activeFunctionTrayProfile.copy()
        change(profile)
        update { it.updateFunctionTrayProfile(profile) }
    }

    /** A Mac-pushed `receiverUI` update: only the fields it carried. */
    fun applyRemote(update: ReceiverUIPreferenceUpdate) = update { update.apply(it) }

    /**
     * The Mac is authoritative for input consent: its confirmed state always
     * overwrites ours, and nothing is set ahead of it. Android's session gate
     * enforces the grant on every message regardless of this mirror.
     */
    fun applySessionInputState(state: InputWireState) {
        mutate { it.copy(sessionInputState = state) }
        update { it.allowInput = state == InputWireState.Allowed }
    }

    private fun mutate(change: (Transient) -> Transient) {
        transientState.value = change(transientState.value)
    }

    companion object {
        private const val ZOOM_WHILE_TYPING = "zoomWhileTyping"
        const val AUTO_HIDE_DELAY_MS = 9_000L
    }
}

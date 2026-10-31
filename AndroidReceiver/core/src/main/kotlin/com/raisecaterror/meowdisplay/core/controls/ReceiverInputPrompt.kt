package com.raisecaterror.meowdisplay.core.controls

// Ported from Shared/ReceiverInputPrompt.swift.

import com.raisecaterror.meowdisplay.core.session.InputWireState

/**
 * The on-surface "Request Control" affordance: when a touch was meant for the
 * Mac but input isn't allowed, offer the existing request flow right there.
 * Ephemeral, never spams requests; the Mac stays the only authority.
 */
class ReceiverInputPrompt {
    enum class Kind {
        /** The user turned input off themselves. */
        EnableInput,

        /** Input isn't granted for this session yet (or was declined). */
        RequestInput,

        /** A request is waiting for the Mac. */
        Requesting,

        /** Just granted — shown briefly, then gone. */
        Enabled,

        /** The Mac isn't accepting requests from this device. */
        Unavailable,
    }

    enum class Effect {
        /** Send the existing allow-input request. */
        SendRequest,
    }

    var kind: Kind? = null
        private set
    var visibleUntil: TimeInterval = 0.0
        private set
    var lastRequestAt: TimeInterval? = null
        private set
    private var state = InputWireState.Off
    private var sessionLive = false

    fun isVisible(now: TimeInterval): Boolean = kind != null && now < visibleUntil

    /** The live session came or went. No prompt without a live session. */
    fun setSessionLive(live: Boolean) {
        sessionLive = live
        if (!live) kind = null
    }

    /** The Mac-confirmed input state changed. */
    fun inputStateChanged(newState: InputWireState, now: TimeInterval) {
        val previous = state
        state = newState
        if (kind == null || !(now < visibleUntil || kind == Kind.Requesting)) return
        when (newState) {
            InputWireState.Allowed -> if (previous != InputWireState.Allowed) {
                kind = Kind.Enabled
                visibleUntil = now + ENABLED_DURATION
            }
            InputWireState.Requesting -> kind = Kind.Requesting
            InputWireState.RequestsDisabled -> {
                kind = Kind.Unavailable
                visibleUntil = maxOf(visibleUntil, now + VISIBLE_DURATION)
            }
            InputWireState.NotAllowed, InputWireState.Off -> if (kind == Kind.Requesting) {
                kind = Kind.RequestInput
                visibleUntil = now + VISIBLE_DURATION
            }
        }
    }

    /**
     * A touch that would have reached the Mac was dropped. With [autoRequest]
     * (the user opted this Mac into automatic requests) the first attempt sends
     * the request itself, at most once per interval.
     */
    fun blockedAttempt(now: TimeInterval, userTurnedOff: Boolean, autoRequest: Boolean): List<Effect> {
        if (!sessionLive || state == InputWireState.Allowed) return emptyList()
        visibleUntil = now + VISIBLE_DURATION
        return when (state) {
            InputWireState.Requesting -> {
                kind = Kind.Requesting
                emptyList()
            }
            InputWireState.RequestsDisabled -> {
                kind = Kind.Unavailable
                emptyList()
            }
            InputWireState.Off, InputWireState.NotAllowed, InputWireState.Allowed -> {
                kind = if (userTurnedOff) Kind.EnableInput else Kind.RequestInput
                if (!autoRequest || userTurnedOff || state == InputWireState.NotAllowed || !canRequest(now, MINIMUM_AUTOMATIC_INTERVAL)) {
                    emptyList()
                } else {
                    lastRequestAt = now
                    kind = Kind.Requesting
                    listOf(Effect.SendRequest)
                }
            }
        }
    }

    /** The user tapped Request/Enable Input. */
    fun requestTapped(now: TimeInterval): List<Effect> {
        if (!sessionLive || state == InputWireState.Allowed || state == InputWireState.RequestsDisabled ||
            state == InputWireState.Requesting || !canRequest(now, MINIMUM_TAPPED_INTERVAL)
        ) return emptyList()
        lastRequestAt = now
        kind = Kind.Requesting
        visibleUntil = now + VISIBLE_DURATION
        return listOf(Effect.SendRequest)
    }

    /** Drops a prompt whose time is up. */
    fun tick(now: TimeInterval) {
        if (kind != null && now >= visibleUntil) kind = null
    }

    private fun canRequest(now: TimeInterval, interval: TimeInterval): Boolean = lastRequestAt?.let { now - it >= interval } ?: true

    companion object {
        /** How long the prompt lingers after the last blocked attempt. */
        const val VISIBLE_DURATION: TimeInterval = 3.5
        const val ENABLED_DURATION: TimeInterval = 1.6

        /** Automatic requests at most this often. */
        const val MINIMUM_AUTOMATIC_INTERVAL: TimeInterval = 8.0

        /** A tapped request can't be re-sent faster than this. */
        const val MINIMUM_TAPPED_INTERVAL: TimeInterval = 1.5
    }
}

/**
 * Which dropped touch sequences count as trying to control the Mac. A
 * two-finger sequence is Local View Navigation, never a reason to ask for
 * input; nor is anything in Move View.
 */
object BlockedInputAttemptPolicy {
    /** [selectedPane]: the touch only chose another Window-mode pane (local, never for the Mac). */
    fun isRemoteIntent(maximumTouchCount: Int, moveViewActive: Boolean, selectedPane: Boolean = false): Boolean {
        if (moveViewActive || selectedPane || maximumTouchCount <= 0) return false
        return maximumTouchCount != 2
    }
}

/**
 * Whether a blocked touch may send the input request by itself. Only an
 * explicit, per-Mac, input-specific opt-in counts — never the connection
 * policy. Even then this only sends the normal request.
 */
object InputAutoRequestPolicy {
    fun shouldAutoRequest(peerOptedIn: Boolean): Boolean = peerOptedIn
}

/** What the receiver's own controls show. */
enum class ReceiverControlPresentation {
    /** Strip, Overlay, Custom, or the compact tray. */
    Normal,

    /** The software keyboard is up: a flat accessory bar right above it. */
    KeyboardBar;

    companion object {
        fun mode(softwareKeyboardVisible: Boolean): ReceiverControlPresentation = if (softwareKeyboardVisible) KeyboardBar else Normal
    }
}

/** The keyboard accessory bar's contents — keyboard companions only, never the session controls. */
sealed interface KeyboardBarItem {
    data class Modifier(val modifier: ControlModifier) : KeyboardBarItem
    data object Escape : KeyboardBarItem
    data object Tab : KeyboardBarItem

    /** One Return press, beside Escape and Tab for ⌘↵ and ⇧↵. */
    data object ReturnKey : KeyboardBarItem

    /** Dismisses the software keyboard. */
    data object DismissKeyboard : KeyboardBarItem

    companion object {
        val defaultItems: List<KeyboardBarItem> =
            ControlModifier.entries.map(::Modifier) + listOf(Escape, Tab, ReturnKey, DismissKeyboard)
    }
}

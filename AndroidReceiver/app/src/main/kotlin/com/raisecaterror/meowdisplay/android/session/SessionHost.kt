package com.raisecaterror.meowdisplay.android.session

import com.raisecaterror.meowdisplay.core.session.ReceiverSession
import com.raisecaterror.meowdisplay.core.session.SessionEvent
import kotlinx.coroutines.flow.StateFlow

/**
 * What the receiver surface, its controls, Window mode and Settings need from
 * a session: the session itself (its input gate and requests), the UI state
 * and its events. The real [MediaController] is one; Explore Demo's
 * [com.raisecaterror.meowdisplay.android.demo.DemoHost] is another, with its
 * own session, so a demo can never reach the real one's trust or input.
 */
interface SessionHost {
    val session: ReceiverSession
    val ui: StateFlow<MediaUiState>

    /** The receiver controls subscribe here: every session event, in order. */
    var controlEvents: ((SessionEvent) -> Unit)?

    /** Per-Mac "Request Control Automatically"; null: never. */
    val inputAutoRequest: InputAutoRequestPrefs?

    /** A Mac's name for the UI ("your Mac" when unknown). */
    fun macName(peerID: String?): String

    /** True for Explore Demo: no Mac, no network, nothing kept. */
    val isDemo: Boolean get() = false
}

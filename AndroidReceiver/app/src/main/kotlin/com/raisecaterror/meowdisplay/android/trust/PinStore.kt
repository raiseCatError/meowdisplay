package com.raisecaterror.meowdisplay.android.trust

import android.annotation.SuppressLint
import android.content.Context
import com.raisecaterror.meowdisplay.core.crypto.base64
import com.raisecaterror.meowdisplay.core.crypto.base64Bytes
import com.raisecaterror.meowdisplay.core.pairing.PeerDirectory
import com.raisecaterror.meowdisplay.core.pairing.PeerTrustStore
import com.raisecaterror.meowdisplay.core.pairing.TrustPinPolicy
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/** [pairedAtMillis]: when this pin was saved; null for pins saved before dates were recorded. */
/** [user]: who uses that Mac, as it said over the authenticated session (null: hidden or not yet). */
data class PairedMac(val peerID: String, val name: String, val spki: ByteArray, val pairedAtMillis: Long? = null, val user: String? = null) {
    override fun equals(other: Any?) = other is PairedMac && peerID == other.peerID && spki.contentEquals(other.spki)
    override fun hashCode() = peerID.hashCode()
}

/**
 * Pinned Mac identities (the receiver role's trust store). Pins are public
 * keys, so they need integrity, not secrecy: app-private storage, excluded
 * from backup and device transfer (res/xml/data_extraction_rules.xml).
 * Reads come from an in-memory snapshot, never storage, so TLS handshakes
 * never touch disk.
 */
class PinStore(context: Context) : PeerTrustStore {
    private val prefs = context.getSharedPreferences("pins", Context.MODE_PRIVATE)
    private val state = MutableStateFlow(load())

    val paired: StateFlow<List<PairedMac>> = state.asStateFlow()

    /** The pin set for TLS: an in-memory snapshot. */
    fun pinnedSPKIs(): List<ByteArray> = state.value.map { it.spki }

    override fun pin(peerID: String): ByteArray? = state.value.firstOrNull { it.peerID == peerID }?.spki

    override fun pinnedPeers(): Map<String, ByteArray> = state.value.associate { it.peerID to it.spki }

    // commit(), not apply(): a pin must be on disk before pairing reports
    // success, and a failed write must fail the pairing.
    @SuppressLint("ApplySharedPref", "UseKtx")
    @Synchronized
    override fun setPin(peerID: String, spki: ByteArray, displayName: String, allowIdentityChange: Boolean): Boolean {
        // Keys with this prefix hold pairing dates in the same file (so pin and date are one write):
        // a Mac id using it could hide its pin or erase another Mac's date.
        if (peerID.isEmpty() || peerID.startsWith(DATE_PREFIX) || peerID.startsWith(USER_PREFIX)) return false
        if (PeerDirectory.isHeldByAnotherPeer(pinnedPeers(), peerID, spki)) return false
        val decision = TrustPinPolicy.decision(pin(peerID), spki)
        if (decision == TrustPinPolicy.Decision.IdentityChanged && !allowIdentityChange) return false
        val now = System.currentTimeMillis()
        val entry = PairedMac(peerID, displayName, spki, now, user = state.value.firstOrNull { it.peerID == peerID }?.user)
        // The date goes in the same write: a pin without one counts as older than every dated pin
        // (Clean Up), so a new pin must never be saved undated.
        val stored = prefs.edit().putString(peerID, encode(entry)).putLong(DATE_PREFIX + peerID, now).commit()
        if (stored) state.value = state.value.filterNot { it.peerID == peerID } + entry
        return stored
    }

    // A forgotten Mac must stay forgotten across a crash right after Forget.
    @SuppressLint("ApplySharedPref", "UseKtx")
    @Synchronized
    override fun forget(peerID: String) {
        prefs.edit().remove(peerID).remove(DATE_PREFIX + peerID).remove(USER_PREFIX + peerID).commit()
        state.value = state.value.filterNot { it.peerID == peerID }
    }

    /** What a paired Mac said about its user in its welcome (only for a pinned Mac; null removes it). */
    @Synchronized
    fun setUser(peerID: String, name: String?) {
        val current = state.value.firstOrNull { it.peerID == peerID } ?: return
        if (current.user == name) return
        prefs.edit().apply { if (name == null) remove(USER_PREFIX + peerID) else putString(USER_PREFIX + peerID, name) }.apply()
        state.value = state.value.map { if (it.peerID == peerID) it.copy(user = name) else it }
    }

    private fun load(): List<PairedMac> {
        val all = prefs.all
        return all.filterKeys { !it.startsWith(DATE_PREFIX) && !it.startsWith(USER_PREFIX) }.mapNotNull { (peerID, value) ->
            (value as? String)?.let { decode(peerID, it) }
                ?.copy(pairedAtMillis = all[DATE_PREFIX + peerID] as? Long, user = all[USER_PREFIX + peerID] as? String)
        }.sortedBy { it.name }
    }

    private companion object {
        /** `paired:<peerID>` holds when that pin was saved (epoch milliseconds). */
        const val DATE_PREFIX = "paired:"
        /** `user:<peerID>` holds who uses that Mac ([PairedMac.user]). */
        const val USER_PREFIX = "user:"
        fun encode(entry: PairedMac) = entry.spki.base64() + "\n" + entry.name

        fun decode(peerID: String, text: String): PairedMac? {
            val spki = text.substringBefore('\n').base64Bytes() ?: return null
            return PairedMac(peerID, text.substringAfter('\n', ""), spki)
        }
    }
}

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

data class PairedMac(val peerID: String, val name: String, val spki: ByteArray) {
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
        if (PeerDirectory.isHeldByAnotherPeer(pinnedPeers(), peerID, spki)) return false
        val decision = TrustPinPolicy.decision(pin(peerID), spki)
        if (decision == TrustPinPolicy.Decision.IdentityChanged && !allowIdentityChange) return false
        val entry = PairedMac(peerID, displayName, spki)
        val stored = prefs.edit().putString(peerID, encode(entry)).commit()
        if (stored) state.value = state.value.filterNot { it.peerID == peerID } + entry
        return stored
    }

    // A forgotten Mac must stay forgotten across a crash right after Forget.
    @SuppressLint("ApplySharedPref", "UseKtx")
    @Synchronized
    override fun forget(peerID: String) {
        prefs.edit().remove(peerID).commit()
        state.value = state.value.filterNot { it.peerID == peerID }
    }

    private fun load(): List<PairedMac> = prefs.all.mapNotNull { (peerID, value) ->
        (value as? String)?.let { decode(peerID, it) }
    }.sortedBy { it.name }

    private companion object {
        fun encode(entry: PairedMac) = entry.spki.base64() + "\n" + entry.name

        fun decode(peerID: String, text: String): PairedMac? {
            val spki = text.substringBefore('\n').base64Bytes() ?: return null
            return PairedMac(peerID, text.substringAfter('\n', ""), spki)
        }
    }
}

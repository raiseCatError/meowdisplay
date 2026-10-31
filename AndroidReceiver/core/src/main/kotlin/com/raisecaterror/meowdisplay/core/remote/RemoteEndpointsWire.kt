package com.raisecaterror.meowdisplay.core.remote

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.add
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import java.security.MessageDigest

/**
 * `remoteEndpoints` (PROTOCOL.md 6.17; Shared/RemoteEndpointsWire.swift): after admission, each side
 * tells the other where it can be reached over Tailscale. Additive and capability-gated: the Mac lists
 * [WELCOME_FEATURE] in `welcome.features`, a receiver sends `hello.remoteEndpoints: 1`, and neither
 * sends the message unless the other said so.
 *
 * A report is a routing hint about the sender itself: no ports, no peer field. It is filtered
 * ([TailnetEndpointFilter]), kept apart from typed addresses ([AutomaticRemoteEndpointStore]), and
 * only ever dialed through the same pinned handshake.
 */
object RemoteEndpointsWire {
    const val TYPE = "remoteEndpoints"
    const val WELCOME_FEATURE = "remoteEndpoints"
    const val HELLO_FIELD = "remoteEndpoints"
    const val HELLO_VERSION = 1

    /** A larger frame is dropped whole. */
    const val MAX_FRAME_BYTES = 1024
    /** More values than this in either list drops the message (the filter keeps fewer still). */
    const val MAX_LISTED_VALUES = 8
    const val MAX_VALUE_LENGTH = 253
    /** A side sends at most one report per this interval, and ignores reports closer together. */
    const val MIN_INTERVAL_MS = 10_000L

    data class Report(val names: List<String> = emptyList(), val ips: List<String> = emptyList()) {
        /** Nothing to report: the receiving side forgets what it learned from this peer. */
        val isEmpty: Boolean get() = names.isEmpty() && ips.isEmpty()
    }

    fun message(report: Report): JsonObject = buildJsonObject {
        put("type", TYPE)
        putJsonArray("names") { report.names.forEach { add(it) } }
        putJsonArray("ips") { report.ips.forEach { add(it) } }
    }

    /** The report in a control frame, filtered, or null when the frame is dropped. */
    fun decode(frame: ByteArray, tailnet: String? = null): Report? {
        if (frame.size > MAX_FRAME_BYTES) return null
        val root = runCatching { Json.parseToJsonElement(frame.decodeToString(throwOnInvalidSequence = true)).jsonObject }
            .getOrNull() ?: return null
        val type = root["type"] as? JsonPrimitive
        if (type == null || !type.isString || type.content != TYPE) return null
        val names = list(root["names"]) ?: return null
        val ips = list(root["ips"]) ?: return null
        val kept = TailnetEndpointFilter.filter(names, ips, tailnet)
        return Report(kept.names, kept.addresses)
    }

    private fun list(value: kotlinx.serialization.json.JsonElement?): List<String>? {
        if (value == null) return emptyList()
        val array = value as? JsonArray ?: return null
        if (array.size > MAX_LISTED_VALUES) return null
        return array.map { element ->
            val primitive = element as? JsonPrimitive ?: return null
            if (primitive is JsonNull || !primitive.isString) return null
            // Swift counts UTF-8 bytes.
            if (primitive.content.encodeToByteArray().size > MAX_VALUE_LENGTH) return null
            primitive.content
        }
    }

    /** The pin a stored report is bound to: SHA-256 of the peer's pinned SPKI, hex. */
    fun pinDigest(spki: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(spki).joinToString("") { "%02x".format(it.toInt() and 0xFF) }
}

/** One report per [RemoteEndpointsWire.MIN_INTERVAL_MS] from a peer; the rest are ignored. */
class RemoteEndpointsRateGate {
    var lastAcceptedMs: Long? = null
        private set

    fun admit(nowMs: Long): Boolean {
        val last = lastAcceptedMs
        if (last != null && nowMs >= last && nowMs - last < RemoteEndpointsWire.MIN_INTERVAL_MS) return false
        lastAcceptedMs = nowMs
        return true
    }
}

/**
 * This device's own Tailscale addresses, for its report: the addresses of a VPN network
 * (Tailscale's tunnel) that fall in the tailnet ranges. A cellular interface's CGNAT address can be
 * in 100.64.0.0/10 too, so only VPN networks count.
 */
object TailnetInterfaces {
    data class Candidate(val isVpn: Boolean, val address: String)

    /** IPv4 first, normalized and capped as a report is. */
    fun select(candidates: List<Candidate>): List<String> {
        val tunnel = candidates.filter { it.isVpn }.map { it.address.substringBefore('%') }
        val ordered = tunnel.filter { ':' !in it } + tunnel.filter { ':' in it }
        return TailnetEndpointFilter.filter(emptyList(), ordered).addresses
    }
}

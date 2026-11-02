package com.raisecaterror.meowdisplay.core.remote

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.add
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.long
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray

/**
 * Tailscale addresses a paired Mac reported about itself (`remoteEndpoints`), kept apart from the
 * address a person typed ([RemoteMacStore]), which they never replace or change
 * (Shared/AutomaticRemoteEndpointStore.swift).
 *
 * An entry is bound to the Mac's pin when it was learned: re-paired with another key, or forgotten,
 * and it is gone. It also expires after [LIFETIME_MS] without a refresh. Routing only.
 *
 * Persisted as `{ "<peerID>": { "version": 1, "pin": "<sha256 hex>", "names": [...], "ips": [...],
 * "updatedAt": <ms> } }`; anything else is discarded.
 */
class AutomaticRemoteEndpointStore(private val storage: RemoteMacStorage) {
    data class Entry(val pin: String, val names: List<String>, val ips: List<String>, val updatedAtMs: Long)

    private var entries: Map<String, Entry> = load()

    /** What [peerID] reported, while its pin is still [currentPin] and the entry is fresh. */
    @Synchronized
    fun entry(peerID: String, currentPin: ByteArray?, nowMs: Long): Entry? {
        val entry = entries[peerID] ?: return null
        if (currentPin == null || entry.pin != RemoteEndpointsWire.pinDigest(currentPin)) return null
        if (!fresh(entry, nowMs) || entry.updatedAtMs - nowMs >= FUTURE_SLACK_MS) return null
        return entry
    }

    /** Records a report from the authenticated, admitted [peerID] whose pin is [pin]. Empty removes. */
    @Synchronized
    fun record(report: RemoteEndpointsWire.Report, peerID: String, pin: ByteArray, nowMs: Long): Boolean {
        if (peerID.isEmpty()) return false
        val next = if (report.isEmpty) {
            if (peerID !in entries) return true
            entries - peerID
        } else {
            entries + (peerID to Entry(RemoteEndpointsWire.pinDigest(pin), report.names, report.ips, nowMs))
        }
        return commit(next)
    }

    @Synchronized
    fun remove(peerID: String): Boolean = if (peerID !in entries) true else commit(entries - peerID)

    /** Drops entries for Macs no longer paired and expired ones. */
    @Synchronized
    fun prune(pairedPeerIDs: Set<String>, nowMs: Long) {
        val next = entries.filter { (peerID, entry) -> peerID in pairedPeerIDs && fresh(entry, nowMs) }
        if (next.size != entries.size) commit(next)
    }

    private fun fresh(entry: Entry, nowMs: Long) = nowMs - entry.updatedAtMs < LIFETIME_MS

    private fun commit(next: Map<String, Entry>): Boolean {
        if (!storage.write(encode(next))) return false
        entries = next
        return true
    }

    private fun load(): Map<String, Entry> {
        val text = storage.read() ?: return emptyMap()
        val root = runCatching { Json.parseToJsonElement(text).jsonObject }.getOrNull() ?: return emptyMap()
        val out = LinkedHashMap<String, Entry>()
        for ((peerID, value) in root) {
            val o = value as? JsonObject ?: continue
            val version = runCatching { (o["version"] as JsonPrimitive).takeIf { !it.isString }?.int }.getOrNull()
            if (version != SCHEMA_VERSION) continue
            val pin = (o["pin"] as? JsonPrimitive)?.takeIf { it.isString }?.content ?: continue
            val updatedAt = runCatching { (o["updatedAt"] as JsonPrimitive).takeIf { !it.isString }?.long }.getOrNull() ?: continue
            val names = strings(o["names"]) ?: continue
            val ips = strings(o["ips"]) ?: continue
            // Whatever is stored must still pass the filter unchanged.
            val checked = TailnetEndpointFilter.filter(names, ips)
            if (checked.names != names || checked.addresses != ips) continue
            out[peerID] = Entry(pin, names, ips, updatedAt)
        }
        return out
    }

    private fun strings(value: kotlinx.serialization.json.JsonElement?): List<String>? =
        (value as? JsonArray)?.map { (it as? JsonPrimitive)?.takeIf { p -> p.isString }?.content ?: return null }

    private fun encode(entries: Map<String, Entry>): String = buildJsonObject {
        for ((peerID, entry) in entries.toSortedMap()) {
            put(peerID, buildJsonObject {
                put("version", SCHEMA_VERSION)
                put("pin", entry.pin)
                putJsonArray("names") { entry.names.forEach { add(it) } }
                putJsonArray("ips") { entry.ips.forEach { add(it) } }
                put("updatedAt", entry.updatedAtMs)
            })
        }
    }.toString()

    companion object {
        const val SCHEMA_VERSION = 1
        /** Refreshed by every session; an entry not refreshed for this long is ignored and dropped. */
        const val LIFETIME_MS = 30L * 24 * 3600 * 1000
        private const val FUTURE_SLACK_MS = 3600L * 1000
    }
}

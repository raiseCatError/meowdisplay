package com.raisecaterror.meowdisplay.core.remote

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put

/** A saved remote address for one paired Mac. Routing only: it never identifies or trusts anything. */
data class RemoteMac(val peerID: String, val endpoint: RemoteEndpoint)

/** One blob of app-private text (SharedPreferences on Android, memory in tests). */
interface RemoteMacStorage {
    fun read(): String?

    /** True once the text is durably stored. */
    fun write(text: String): Boolean
}

class InMemoryRemoteMacStorage(var text: String? = null) : RemoteMacStorage {
    var failWrites = false

    override fun read() = text

    override fun write(text: String): Boolean {
        if (failWrites) return false
        this.text = text
        return true
    }
}

/**
 * Remote Access hints keyed by the verified Mac peer ID (Shared/RemoteEndpointStore.swift): one
 * address per Mac, never keyed by the address. Several Macs may share an address (it is allowed,
 * and [sharedWith] lets the screen say so); the pinned handshake alone decides who answers.
 *
 * Persisted as `{ "<peerID>": { "version": 1, "host": "...", "port": 9003 } }`. Anything that
 * isn't exactly that shape, or carries another version, is discarded rather than guessed at.
 */
class RemoteMacStore(private val storage: RemoteMacStorage) {
    private val state = MutableStateFlow(load())

    val macs: StateFlow<Map<String, RemoteMac>> = state.asStateFlow()

    fun endpoint(peerID: String): RemoteEndpoint? = state.value[peerID]?.endpoint

    /** The saved address, or false when it could not be stored (the old one then stays). */
    @Synchronized
    fun save(peerID: String, endpoint: RemoteEndpoint): Boolean {
        if (peerID.isEmpty()) return false
        val next = state.value + (peerID to RemoteMac(peerID, endpoint))
        if (!storage.write(encode(next))) return false
        state.value = next
        return true
    }

    /** Removes the address only. The pin is untouched: the Mac stays paired and reachable locally. */
    @Synchronized
    fun remove(peerID: String): Boolean {
        if (peerID !in state.value) return true
        val next = state.value - peerID
        if (!storage.write(encode(next))) return false
        state.value = next
        return true
    }

    /** Forget: the address goes with the pin and is never offered for that Mac again. */
    fun forget(peerID: String) {
        remove(peerID)
    }

    /** Drops addresses whose Mac is no longer paired (e.g. forgotten while this app wasn't running). */
    @Synchronized
    fun retainOnly(pairedPeerIDs: Set<String>) {
        val next = state.value.filterKeys { it in pairedPeerIDs }
        if (next.size == state.value.size) return
        if (storage.write(encode(next))) state.value = next
    }

    /** Other Macs saved with the same address (host compared without case, and the port). */
    fun sharedWith(peerID: String): List<String> {
        val mine = state.value[peerID]?.endpoint ?: return emptyList()
        return state.value.values.filter { it.peerID != peerID && it.endpoint.sameAddress(mine) }.map { it.peerID }.sorted()
    }

    private fun RemoteEndpoint.sameAddress(other: RemoteEndpoint) = port == other.port && host.equals(other.host, ignoreCase = true)

    private fun load(): Map<String, RemoteMac> {
        val text = storage.read() ?: return emptyMap()
        val root = runCatching { Json.parseToJsonElement(text).jsonObject }.getOrNull() ?: return emptyMap()
        val macs = LinkedHashMap<String, RemoteMac>()
        for ((peerID, value) in root) {
            val entry = runCatching { value.jsonObject }.getOrNull() ?: continue
            val version = entry.number("version") ?: continue
            if (version != SCHEMA_VERSION) continue
            val host = (entry["host"] as? JsonPrimitive)?.takeIf { it.isString }?.content ?: continue
            val port = entry.number("port") ?: continue
            // Whatever is stored must still be something the editor would accept.
            val checked = RemoteEndpoints.make(host, port.toString(), RemotePorts.CONNECT_REQUEST)
            if (checked is EndpointParse.Valid && checked.endpoint.host == host) macs[peerID] = RemoteMac(peerID, checked.endpoint)
        }
        return macs
    }

    private fun JsonObject.number(key: String): Int? = runCatching { getValue(key).jsonPrimitive.takeIf { !it.isString }?.int }.getOrNull()

    private fun encode(macs: Map<String, RemoteMac>): String = buildJsonObject {
        for ((peerID, mac) in macs.toSortedMap()) {
            put(peerID, buildJsonObject {
                put("version", SCHEMA_VERSION)
                put("host", mac.endpoint.host)
                put("port", mac.endpoint.port)
            })
        }
    }.toString()

    companion object {
        /** Bump if the persisted shape changes; an older or newer one is discarded, not migrated by guesswork. */
        const val SCHEMA_VERSION = 1
    }
}

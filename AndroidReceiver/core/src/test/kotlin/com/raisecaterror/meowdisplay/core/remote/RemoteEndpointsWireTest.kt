package com.raisecaterror.meowdisplay.core.remote

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * `remoteEndpoints` decoding against the vectors MacTests/RemoteEndpointsWireTests.swift runs too
 * (fixtures/remote/remote-endpoints-wire.json), the rate limit, the store and own-address selection.
 */
class RemoteEndpointsWireTest {
    private val cases: List<JsonObject> by lazy {
        val dir = requireNotNull(System.getProperty("meow.remoteFixtures")) { "meow.remoteFixtures not set" }
        Json.parseToJsonElement(File(dir, "remote-endpoints-wire.json").readText())
            .jsonObject.getValue("cases").jsonArray.map { it.jsonObject }
    }

    @Test
    fun decodingMatchesTheSharedVectors() {
        assertTrue(cases.size >= 15)
        for (case in cases) {
            val name = case.getValue("name").jsonPrimitive.content
            val decoded = RemoteEndpointsWire.decode(case.getValue("frame").jsonPrimitive.content.encodeToByteArray())
            val expect = case["expect"]
            if (expect == null || expect is JsonNull) {
                assertNull(name, decoded)
            } else {
                val o = expect.jsonObject
                val want = RemoteEndpointsWire.Report(
                    o.getValue("names").jsonArray.map { it.jsonPrimitive.content },
                    o.getValue("ips").jsonArray.map { it.jsonPrimitive.content },
                )
                assertEquals(name, want, decoded)
            }
        }
    }

    @Test
    fun anEncodedReportDecodesToItself() {
        val report = RemoteEndpointsWire.Report(listOf("mac.tail1234.ts.net"), listOf("100.64.0.1", "fd7a:115c:a1e0::1"))
        assertEquals(report, RemoteEndpointsWire.decode(RemoteEndpointsWire.message(report).toString().encodeToByteArray()))
        assertNull("another type", RemoteEndpointsWire.decode("""{"type":"wakeInfo","ips":[]}""".encodeToByteArray()))
    }

    @Test
    fun oneReportPerTenSeconds() {
        val gate = RemoteEndpointsRateGate()
        assertTrue(gate.admit(100_000))
        assertFalse(gate.admit(105_000))
        assertFalse(gate.admit(109_900))
        assertTrue(gate.admit(110_000))
        assertTrue("a clock that went back doesn't lock reports out", gate.admit(50_000))
    }

    @Test
    fun thePinDigestIsSha256Hex() {
        assertEquals(
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
            RemoteEndpointsWire.pinDigest("abc".encodeToByteArray()),
        )
    }

    @Test
    fun onlyTailnetAddressesOnTheVpn() {
        val found = TailnetInterfaces.select(
            listOf(
                TailnetInterfaces.Candidate(isVpn = false, address = "192.168.1.5"),
                TailnetInterfaces.Candidate(isVpn = false, address = "100.70.1.2"),
                TailnetInterfaces.Candidate(isVpn = true, address = "fe80::1%tun0"),
                TailnetInterfaces.Candidate(isVpn = true, address = "fd7a:115c:a1e0::5"),
                TailnetInterfaces.Candidate(isVpn = true, address = "100.101.1.5"),
            ),
        )
        assertEquals("IPv4 first; CGNAT on cellular isn't a tailnet", listOf("100.101.1.5", "fd7a:115c:a1e0::5"), found)
    }
}

class AutomaticRemoteEndpointStoreTest {
    private val pin = byteArrayOf(1, 2, 3)
    private val report = RemoteEndpointsWire.Report(listOf("mac.t.ts.net"), listOf("100.64.0.1"))
    private val now = 1_800_000_000_000L
    private val lifetime = AutomaticRemoteEndpointStore.LIFETIME_MS

    @Test
    fun aReportIsKeptForThePinItCameWith() {
        val store = AutomaticRemoteEndpointStore(InMemoryRemoteMacStorage())
        assertTrue(store.record(report, "A", pin, now))
        assertEquals(listOf("100.64.0.1"), store.entry("A", pin, now)?.ips)
        assertNull("re-paired with another key", store.entry("A", byteArrayOf(9), now))
        assertNull("forgotten", store.entry("A", null, now))
        assertNull(store.entry("B", pin, now))
    }

    @Test
    fun entriesExpireAndAreNotFromTheFuture() {
        val store = AutomaticRemoteEndpointStore(InMemoryRemoteMacStorage())
        store.record(report, "A", pin, now)
        assertNotNull(store.entry("A", pin, now + lifetime - 1))
        assertNull(store.entry("A", pin, now + lifetime))
        assertNull(store.entry("A", pin, now - 7_200_000))
    }

    @Test
    fun anEmptyReportForgetsWhatTheMacSaid() {
        val store = AutomaticRemoteEndpointStore(InMemoryRemoteMacStorage())
        store.record(report, "A", pin, now)
        store.record(RemoteEndpointsWire.Report(), "A", pin, now)
        assertNull(store.entry("A", pin, now))
    }

    @Test
    fun itSurvivesARestartAndDropsAnythingMalformed() {
        val storage = InMemoryRemoteMacStorage()
        AutomaticRemoteEndpointStore(storage).record(report, "A", pin, now)
        assertEquals(listOf("mac.t.ts.net"), AutomaticRemoteEndpointStore(storage).entry("A", pin, now)?.names)
        val digest = RemoteEndpointsWire.pinDigest(pin)
        storage.text = """{"A":{"version":1,"pin":"$digest","names":[],"ips":["192.168.1.2"],"updatedAt":$now},""" +
            """"B":{"version":2,"pin":"$digest","names":[],"ips":["100.64.0.1"],"updatedAt":$now},""" +
            """"C":{"version":1,"pin":"$digest","names":[],"ips":["100.64.0.1"],"updatedAt":$now}}"""
        val reloaded = AutomaticRemoteEndpointStore(storage)
        assertNull("not a tailnet address", reloaded.entry("A", pin, now))
        assertNull("another version", reloaded.entry("B", pin, now))
        assertNotNull(reloaded.entry("C", pin, now))
    }

    @Test
    fun aFailedWriteKeepsTheOldEntry() {
        val storage = InMemoryRemoteMacStorage()
        val store = AutomaticRemoteEndpointStore(storage)
        store.record(report, "A", pin, now)
        storage.failWrites = true
        assertFalse(store.record(RemoteEndpointsWire.Report(ips = listOf("100.64.0.2")), "A", pin, now))
        assertEquals(listOf("100.64.0.1"), store.entry("A", pin, now)?.ips)
    }

    @Test
    fun pruneDropsUnpairedAndExpiredMacs() {
        val store = AutomaticRemoteEndpointStore(InMemoryRemoteMacStorage())
        store.record(report, "A", pin, now)
        store.record(report, "B", pin, now - lifetime)
        store.record(report, "C", pin, now)
        store.prune(setOf("A", "B"), now)
        assertNotNull(store.entry("A", pin, now))
        assertNull(store.entry("B", pin, now - 1))
        assertNull(store.entry("C", pin, now))
        store.remove("A")
        assertNull(store.entry("A", pin, now))
    }
}

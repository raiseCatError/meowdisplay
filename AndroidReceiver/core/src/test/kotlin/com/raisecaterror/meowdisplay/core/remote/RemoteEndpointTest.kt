package com.raisecaterror.meowdisplay.core.remote

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * Endpoint syntax, against the vectors the Swift tests run too (fixtures/remote/endpoint-vectors.json,
 * MacTests/RemoteEndpointVectorTests.swift), plus the Android-only single Address field.
 */
class RemoteEndpointTest {
    private val vectors: JsonObject by lazy {
        val dir = requireNotNull(System.getProperty("meow.remoteFixtures")) { "meow.remoteFixtures not set" }
        Json.parseToJsonElement(File(dir, "endpoint-vectors.json").readText()).jsonObject
    }

    private fun JsonObject.str(key: String) = getValue(key).jsonPrimitive.content

    private fun check(case: JsonObject, actual: EndpointParse) {
        val name = case.str("name")
        val expect = case.getValue("expect").jsonObject
        val error = expect["error"]?.jsonPrimitive?.content
        if (error != null) {
            assertTrue("$name: expected $error, got $actual", actual is EndpointParse.Invalid)
            assertEquals(name, error, (actual as EndpointParse.Invalid).error.name.replaceFirstChar { it.lowercase() })
        } else {
            assertTrue("$name: expected valid, got $actual", actual is EndpointParse.Valid)
            val endpoint = (actual as EndpointParse.Valid).endpoint
            assertEquals(name, expect.str("host"), endpoint.host)
            assertEquals(name, expect.getValue("port").jsonPrimitive.int, endpoint.port)
        }
    }

    @Test
    fun validateMatchesTheSharedVectors() {
        val cases = vectors.getValue("validate").jsonArray.map { it.jsonObject }
        assertTrue(cases.size >= 60)
        for (case in cases) check(case, RemoteEndpointValidation.validate(case.str("host"), case.str("port")))
    }

    @Test
    fun pairingEndpointMatchesTheSharedVectors() {
        val cases = vectors.getValue("pairingEndpoint").jsonArray.map { it.jsonObject }
        assertTrue(cases.size >= 10)
        for (case in cases) check(case, RemoteEndpoints.make(case.str("host"), case.str("port"), RemotePorts.PAIRING))
    }

    @Test
    fun theAddressFieldSplitsAndThenAppliesTheSameRules() {
        val cases = vectors.getValue("address").jsonArray.map { it.jsonObject }
        assertTrue(cases.size >= 30)
        for (case in cases) check(case, RemoteEndpoints.parseAddress(case.str("input"), case.getValue("defaultPort").jsonPrimitive.int))
    }

    @Test
    fun defaultPortsFollowThePurpose() {
        assertEquals(9004, RemotePorts.PAIRING)
        assertEquals(9003, RemotePorts.CONNECT_REQUEST)
        assertEquals(RemoteEndpoint("mac.ts.net", 9004), (RemoteEndpoints.parseAddress("mac.ts.net", RemotePorts.PAIRING) as EndpointParse.Valid).endpoint)
        assertEquals(RemoteEndpoint("mac.ts.net", 9003), (RemoteEndpoints.parseAddress("mac.ts.net", RemotePorts.CONNECT_REQUEST) as EndpointParse.Valid).endpoint)
    }

    @Test
    fun theAddressIsNeverRewritten() {
        val typed = (RemoteEndpoints.parseAddress("  MAC.Tailnet.TS.net:9003 ", 9004) as EndpointParse.Valid).endpoint
        assertEquals("case and spelling stay as typed", "MAC.Tailnet.TS.net", typed.host)
        assertEquals("[fd7a:115c:a1e0::1]:9010", RemoteEndpoint("fd7a:115c:a1e0::1", 9010).display)
        assertEquals("mac.ts.net", RemoteEndpoint("mac.ts.net", 9003).typed(9003))
        assertEquals("mac.ts.net:9010", RemoteEndpoint("mac.ts.net", 9010).typed(9003))
    }

    @Test
    fun ipLiteralsAreParsedStrictlyAndTailscaleRangesAreRecognised() {
        assertNull(IpLiteral.parse("1.2.3"))
        assertNull(IpLiteral.parse("1.2.3.04"))
        assertNull(IpLiteral.parse("fe80::1%en0"))
        assertEquals(16, IpLiteral.parse("::1")!!.size)
        assertEquals(4, IpLiteral.parse("100.64.0.1")!!.size)
        assertTrue(IpLiteral.isTailscaleRange(IpLiteral.parse("100.64.0.1")!!))
        assertTrue(IpLiteral.isTailscaleRange(IpLiteral.parse("100.127.255.254")!!))
        assertTrue(!IpLiteral.isTailscaleRange(IpLiteral.parse("100.63.255.255")!!))
        assertTrue(!IpLiteral.isTailscaleRange(IpLiteral.parse("100.128.0.1")!!))
        assertTrue(IpLiteral.isTailscaleRange(IpLiteral.parse("fd7a:115c:a1e0:ab12::1")!!))
        assertTrue(!IpLiteral.isTailscaleRange(IpLiteral.parse("fd7a:115c:a1e1::1")!!))
        assertNotNull(IpLiteral.parse("::ffff:1.2.3.4"))
    }

    @Test
    fun logsNameTheKindOfAddressNeverTheAddress() {
        assertEquals("ipv4", IpLiteral.logKind("192.168.1.20"))
        assertEquals("tailscale-range", IpLiteral.logKind("100.101.102.103"))
        assertEquals("tailscale-range", IpLiteral.logKind("[fd7a:115c:a1e0::1]"))
        assertEquals("ipv6", IpLiteral.logKind("2001:db8::1"))
        assertEquals("dns", IpLiteral.logKind("mac.tailnet.ts.net"))
        assertEquals("dns", IpLiteral.logKind("mac"))
    }
}

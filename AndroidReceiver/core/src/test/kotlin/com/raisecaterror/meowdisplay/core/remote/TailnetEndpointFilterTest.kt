package com.raisecaterror.meowdisplay.core.remote

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * The Tailscale endpoint filter against the vectors MacTests/TailnetEndpointFilterTests.swift runs too
 * (fixtures/remote/tailnet-endpoint-vectors.json).
 */
class TailnetEndpointFilterTest {
    private val cases: List<JsonObject> by lazy {
        val dir = requireNotNull(System.getProperty("meow.remoteFixtures")) { "meow.remoteFixtures not set" }
        Json.parseToJsonElement(File(dir, "tailnet-endpoint-vectors.json").readText())
            .jsonObject.getValue("cases").jsonArray.map { it.jsonObject }
    }

    private fun JsonObject.strings(key: String) = getValue(key).jsonArray.map { it.jsonPrimitive.content }

    @Test
    fun theFilterMatchesTheSharedVectors() {
        assertTrue(cases.size >= 30)
        for (case in cases) {
            val name = case.getValue("name").jsonPrimitive.content
            val expect = case.getValue("expect").jsonObject
            val result = TailnetEndpointFilter.filter(
                case.strings("names"), case.strings("ips"), case["tailnet"]?.jsonPrimitive?.content,
            )
            assertEquals(name, expect.strings("names"), result.names)
            assertEquals(name, expect.strings("ips"), result.addresses)
            val rejected = expect.getValue("rejected").jsonArray.map {
                val o = it.jsonObject
                o.getValue("value").jsonPrimitive.content to o.getValue("reason").jsonPrimitive.content
            }
            assertEquals(name, rejected, result.rejected.map { it.value to it.reason.wire })
        }
    }

    @Test
    fun ipv6IsWrittenInRfc5952Form() {
        fun format(text: String) = IpLiteral.parse(text)?.let(TailnetEndpointFilter::formatIPv6)
        assertEquals("the first of two equal runs", "2001:db8::1:0:0:1", format("2001:0db8:0000:0000:0001:0000:0000:0001"))
        assertEquals("a single zero group is not shortened", "2001:db8:0:1:1:1:1:1", format("2001:db8:0:1:1:1:1:1"))
        assertEquals("::", format("::"))
        assertEquals("::1", format("::1"))
        assertEquals("fd7a:115c:a1e0::", format("fd7a:115c:a1e0::"))
        assertEquals("the longer run wins", "0:0:1::1:0", format("0:0:1:0:0:0:1:0"))
        assertNull(format("1::2::3"))
        assertNull("an embedded IPv4 follows the dotted-quad rules", format("::ffff:100.064.0.1"))
    }
}

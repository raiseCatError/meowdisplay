package com.raisecaterror.meowdisplay.core.remote

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class TailscaleGuidanceTest {
    private fun v4(vararg b: Int) = b.map { it.toByte() }.toByteArray()

    @Test
    fun tailnetAddressesAreRecognized() {
        assertTrue(TailscaleGuidance.isTailnetAddress(v4(100, 85, 71, 93)))
        assertTrue(TailscaleGuidance.isTailnetAddress(v4(100, 127, 255, 1)))
        assertFalse("100.128/9 is outside 100.64/10", TailscaleGuidance.isTailnetAddress(v4(100, 128, 0, 1)))
        assertFalse(TailscaleGuidance.isTailnetAddress(v4(192, 168, 1, 2)))
        val v6 = ByteArray(16).also { listOf(0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe0).forEachIndexed { i, b -> it[i] = b.toByte() } }
        assertTrue(TailscaleGuidance.isTailnetAddress(v6))
    }

    @Test
    fun reachDependsOnAVpnWithATailnetAddress() {
        val wifi = NetworkFacts(Transport.WiFi, listOf(v4(100, 64, 0, 9)), null, isDefault = true)
        assertEquals("a CGNAT address on Wi-Fi isn't Tailscale", TailscaleReach.Off, TailscaleGuidance.reach(listOf(wifi)))
        assertEquals(TailscaleReach.OtherVpn, TailscaleGuidance.reach(listOf(wifi, NetworkFacts(Transport.Vpn, listOf(v4(10, 8, 0, 2)), null))))
        assertEquals(TailscaleReach.Connected, TailscaleGuidance.reach(listOf(wifi, NetworkFacts(Transport.Vpn, listOf(v4(100, 85, 71, 93)), null))))
    }
}

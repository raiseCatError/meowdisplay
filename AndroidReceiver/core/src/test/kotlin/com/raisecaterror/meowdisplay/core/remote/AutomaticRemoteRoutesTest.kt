package com.raisecaterror.meowdisplay.core.remote

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** Which reported address is dialed, by verified family (Shared/AutomaticRemoteRoutes.swift has the same cases). */
class AutomaticRemoteRoutesTest {
    private val names = listOf("mac.tail1.ts.net")
    private val ips = listOf("fd7a:115c:a1e0::1", "100.64.0.1")

    @Test
    fun onlyVerifiedFamiliesAreUsedNamesFirstThenIpv4ThenIpv6() {
        assertEquals("100.64.0.1", AutomaticRemoteRoutes.host(names, ips, TailnetFamilies.ANDROID))
        assertNull(AutomaticRemoteRoutes.host(names, ips, TailnetFamilies.NONE))
        assertEquals("mac.tail1.ts.net", AutomaticRemoteRoutes.host(names, ips, TailnetFamilies(ipv4 = true, ipv6 = true, names = true)))
        assertEquals("fd7a:115c:a1e0::1", AutomaticRemoteRoutes.host(names, ips, TailnetFamilies(ipv4 = false, ipv6 = true, names = false)))
        assertNull("no IPv4 reported", AutomaticRemoteRoutes.host(emptyList(), listOf("fd7a:115c:a1e0::1"), TailnetFamilies.ANDROID))
    }
}

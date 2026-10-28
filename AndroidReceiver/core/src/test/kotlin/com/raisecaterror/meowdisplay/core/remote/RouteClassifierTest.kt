package com.raisecaterror.meowdisplay.core.remote

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class RouteClassifierTest {
    private fun ip(text: String) = IpLiteral.parse(text)!!
    private fun prefix(text: String, length: Int) = IpPrefix(ip(text), length)

    private fun wifi(local: String = "192.168.1.20", default: Boolean = false) =
        NetworkFacts(Transport.WiFi, listOf(ip(local)), listOf(prefix("192.168.1.0", 24)), default)
    private fun cellular(local: String = "10.20.30.40", default: Boolean = false) =
        NetworkFacts(Transport.Cellular, listOf(ip(local)), listOf(prefix("0.0.0.0", 0)), default)
    private fun ethernet(local: String = "10.0.0.5") = NetworkFacts(Transport.Ethernet, listOf(ip(local)), null)
    private fun tailscaleVpn(routes: List<IpPrefix>? = listOf(prefix("100.64.0.0", 10), prefix("fd7a:115c:a1e0::", 48))) =
        NetworkFacts(Transport.Vpn, listOf(ip("100.101.102.103")), routes, isDefault = true)

    @Test
    fun tailscaleNeedsTheRangeAndAVpnRouteThatCoversIt() {
        val route = RouteClassifier.classify(ip("100.88.1.2"), ip("100.101.102.103"), listOf(wifi(), tailscaleVpn()))
        assertEquals(RouteKind.Tailscale, route.kind)
        assertTrue(route.remote)
        assertEquals("Remote · Tailscale", route.sessionLabel)
        assertEquals("Remote (Tailscale)", route.overlayLabel)
        val v6 = RouteClassifier.classify(ip("fd7a:115c:a1e0::5"), null, listOf(wifi(), tailscaleVpn()))
        assertEquals(RouteKind.Tailscale, v6.kind)
    }

    @Test
    fun aTailscaleRangeAddressWithoutACoveringVpnRouteIsNotTailscale() {
        val noVpn = RouteClassifier.classify(ip("100.88.1.2"), ip("10.20.30.40"), listOf(cellular(default = true)))
        assertEquals("carrier-grade NAT on a mobile network is not a tailnet", RouteKind.Cellular, noVpn.kind)
        val otherRoutes = tailscaleVpn(listOf(prefix("10.0.0.0", 8)))
        val vpnElsewhere = RouteClassifier.classify(ip("100.88.1.2"), ip("192.168.1.20"), listOf(wifi(), otherRoutes))
        assertEquals(RouteKind.WiFi, vpnElsewhere.kind)
        val defaultRouteOnly = tailscaleVpn(listOf(prefix("0.0.0.0", 0)))
        assertEquals("a catch-all route is not evidence of Tailscale", RouteKind.WiFi,
            RouteClassifier.classify(ip("100.88.1.2"), ip("192.168.1.20"), listOf(wifi(), defaultRouteOnly)).kind)
    }

    @Test
    fun routesThatCantBeReadMeanPlainVpn() {
        val route = RouteClassifier.classify(ip("100.88.1.2"), ip("100.101.102.103"), listOf(wifi(), tailscaleVpn(routes = null)))
        assertEquals(RouteKind.Vpn, route.kind)
        assertEquals("Remote (VPN)", route.overlayLabel)
    }

    @Test
    fun theNetworkThatCarriesTheSocketNamesTheTransport() {
        val networks = listOf(wifi(default = true), cellular())
        assertEquals(RouteKind.WiFi, RouteClassifier.classify(ip("192.168.1.99"), ip("192.168.1.20"), networks).kind)
        assertEquals(RouteKind.Cellular, RouteClassifier.classify(ip("203.0.113.9"), ip("10.20.30.40"), networks).kind)
        assertEquals(RouteKind.Ethernet, RouteClassifier.classify(ip("10.0.0.9"), ip("10.0.0.5"), listOf(ethernet())).kind)
        assertEquals("a socket on a VPN's address is VPN", RouteKind.Vpn,
            RouteClassifier.classify(ip("172.16.0.9"), ip("100.101.102.103"), listOf(wifi(), tailscaleVpn())).kind)
    }

    @Test
    fun withoutALocalAddressTheDefaultNetworkIsUsed() {
        assertEquals(RouteKind.Cellular, RouteClassifier.classify(ip("203.0.113.9"), null, listOf(wifi(), cellular(default = true))).kind)
        assertEquals(RouteKind.Other, RouteClassifier.classify(ip("203.0.113.9"), null, listOf(wifi())).kind)
        assertNull(RouteInfo(RouteKind.Other, true).label)
        assertEquals("Remote", RouteInfo(RouteKind.Other, true).overlayLabel)
    }

    @Test
    fun aLocalSessionIsLocalAndSaysNothingInTheOverlay() {
        val route = RouteClassifier.classify(ip("192.168.1.99"), ip("192.168.1.20"), listOf(wifi(default = true)))
        assertFalse(route.remote)
        assertEquals("Local", route.sessionLabel)
        assertNull(route.overlayLabel)
    }

    @Test
    fun aKnockOrAPublicAddressMakesItRemoteWhateverTheNetwork() {
        val knocked = RouteClassifier.classify(ip("192.168.1.99"), ip("192.168.1.20"), listOf(wifi(default = true)), startedByKnock = true)
        assertTrue(knocked.remote)
        assertEquals("Remote (Wi-Fi)", knocked.overlayLabel)
        val publicPeer = RouteClassifier.classify(ip("203.0.113.9"), ip("192.168.1.20"), listOf(wifi(default = true)))
        assertTrue(publicPeer.remote)
        val cell = RouteClassifier.classify(ip("10.9.9.9"), ip("10.20.30.40"), listOf(cellular(default = true)))
        assertTrue("anything over the mobile network is remote", cell.remote)
    }

    @Test
    fun localAddressesAreRecognised() {
        for (local in listOf("127.0.0.1", "10.1.2.3", "172.16.0.1", "172.31.255.255", "192.168.0.1", "169.254.1.1", "::1", "fe80::1", "fd12:3456::1", "::ffff:192.168.1.2"))
            assertTrue(local, RouteClassifier.isLocalAddress(ip(local)))
        for (remote in listOf("172.32.0.1", "8.8.8.8", "100.64.0.1", "2001:db8::1", "fd7a:115c:a1e0::1", "::", "::ffff:8.8.8.8"))
            assertFalse(remote, RouteClassifier.isLocalAddress(ip(remote)))
    }

    @Test
    fun prefixesMatchByBits() {
        assertTrue(prefix("100.64.0.0", 10).contains(ip("100.127.1.1")))
        assertFalse(prefix("100.64.0.0", 10).contains(ip("100.128.0.1")))
        assertTrue(prefix("192.168.1.0", 24).contains(ip("192.168.1.255")))
        assertFalse(prefix("192.168.1.0", 24).contains(ip("192.168.2.1")))
        assertFalse("different families never match", prefix("0.0.0.0", 0).contains(ip("::1")))
        assertTrue(prefix("fd7a:115c:a1e0::", 48).contains(ip("fd7a:115c:a1e0:1::1")))
    }
}

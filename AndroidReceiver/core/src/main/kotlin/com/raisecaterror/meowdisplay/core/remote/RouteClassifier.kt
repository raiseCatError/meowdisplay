package com.raisecaterror.meowdisplay.core.remote

/** What carries a network. */
enum class Transport { WiFi, Cellular, Ethernet, Vpn, Other }

/** An address prefix (a LinkProperties route destination). [address] is 4 or 16 bytes. */
class IpPrefix(val address: ByteArray, val length: Int) {
    fun contains(other: ByteArray): Boolean {
        if (other.size != address.size || length !in 0..address.size * 8) return false
        val whole = length / 8
        for (i in 0 until whole) if (address[i] != other[i]) return false
        val rest = length % 8
        if (rest == 0) return true
        val mask = (0xFF shl (8 - rest)) and 0xFF
        return (address[whole].toInt() and mask) == (other[whole].toInt() and mask)
    }
}

/**
 * One network as the system describes it. [routes] is null when they could not be read (a VPN is
 * then only known to be "a VPN"); [addresses] are this device's addresses on the network.
 */
class NetworkFacts(
    val transport: Transport,
    val addresses: List<ByteArray>,
    val routes: List<IpPrefix>?,
    val isDefault: Boolean = false,
)

enum class RouteKind(val label: String) {
    Tailscale("Tailscale"), Vpn("VPN"), WiFi("Wi-Fi"), Cellular("Cellular"), Ethernet("Ethernet"), Other("")
}

/**
 * The honest description of the path a connection took. [remote] is true when the session did not
 * stay on the local network (a VPN or Tailscale, a mobile network, or a non-private address).
 */
data class RouteInfo(val kind: RouteKind, val remote: Boolean) {
    /** `Tailscale`, `VPN`, `Wi-Fi`, `Cellular`, `Ethernet`, or null when the network is unknown. */
    val label: String? get() = kind.label.takeIf { it.isNotEmpty() }

    /** `Local`, or `Remote · Tailscale`. */
    val sessionLabel: String get() = if (!remote) "Local" else listOfNotNull("Remote", label).joinToString(" · ")

    /** For the performance overlay: `Remote (Tailscale)`, or null for a local session (it says nothing). */
    val overlayLabel: String? get() = if (!remote) null else "Remote" + (label?.let { " ($it)" } ?: "")
}

object RouteClassifier {
    /**
     * Classifies a connection from the peer's address, this device's own address on it and the
     * networks the system knows. Tailscale needs evidence: the peer in Tailscale's address space
     * AND a VPN network whose routes cover that address. A VPN whose routes can't be read is just
     * "VPN". Otherwise the network that carries the socket (found by our local address, else the
     * default network) names the transport.
     */
    fun classify(peer: ByteArray, local: ByteArray?, networks: List<NetworkFacts>, startedByKnock: Boolean = false): RouteInfo {
        val carrier = local?.let { mine -> networks.firstOrNull { network -> network.addresses.any { it.contentEquals(mine) } } }
            ?: networks.firstOrNull { it.isDefault }
        val vpns = networks.filter { it.transport == Transport.Vpn }
        val kind = when {
            IpLiteral.isTailscaleRange(peer) && vpns.isNotEmpty() && vpns.any { it.routes != null && it.covers(peer) } -> RouteKind.Tailscale
            IpLiteral.isTailscaleRange(peer) && vpns.isNotEmpty() && vpns.all { it.routes == null } -> RouteKind.Vpn
            carrier == null -> RouteKind.Other
            else -> when (carrier.transport) {
                Transport.Vpn -> RouteKind.Vpn
                Transport.WiFi -> RouteKind.WiFi
                Transport.Cellular -> RouteKind.Cellular
                Transport.Ethernet -> RouteKind.Ethernet
                Transport.Other -> RouteKind.Other
            }
        }
        val remote = startedByKnock || kind == RouteKind.Tailscale || kind == RouteKind.Vpn || kind == RouteKind.Cellular ||
            !isLocalAddress(peer)
        return RouteInfo(kind, remote)
    }

    private fun NetworkFacts.covers(address: ByteArray) = routes.orEmpty().any { it.length > 0 && it.contains(address) }

    /** Loopback, link-local, private (RFC 1918) and unique-local addresses are on the local network. */
    fun isLocalAddress(address: ByteArray): Boolean {
        fun b(i: Int) = address[i].toInt() and 0xFF
        return when (address.size) {
            4 -> b(0) == 127 || b(0) == 10 || (b(0) == 172 && b(1) in 16..31) || (b(0) == 192 && b(1) == 168) || (b(0) == 169 && b(1) == 254)
            16 -> when {
                IpLiteral.isTailscaleRange(address) || address.all { it == 0.toByte() } -> false
                address.take(15).all { it == 0.toByte() } && b(15) == 1 -> true
                b(0) == 0xFE && (b(1) and 0xC0) == 0x80 -> true
                (b(0) and 0xFE) == 0xFC -> true
                // ::ffff:a.b.c.d is judged by its IPv4 part.
                address.take(10).all { it == 0.toByte() } && b(10) == 0xFF && b(11) == 0xFF -> isLocalAddress(address.copyOfRange(12, 16))
                else -> false
            }
            else -> false
        }
    }
}

package com.raisecaterror.meowdisplay.core.session

// "Use less data" (issue #123, PROTOCOL.md 6.20). The wire names and values are exactly what the
// Mac parses (Shared/AdaptiveStreamingWiring.swift `AdaptiveHelloFields.parse`, lines 160-172, and
// Shared/NetworkCost.swift `Cost`, `Interface`, `Confidence`, `DataPreference`). Android sends only
// `saveData` and `cost`; never `effHz`, `adaptiveTelemetry`, `saveDataAnswer` or any stats.

/**
 * The receiver's "Use less data" setting. [raw] is both the persisted value and the hello `saveData`
 * string (`NetworkCost.DataPreference`: "off", "on", "auto").
 */
enum class UseLessData(val raw: String, val title: String) {
    /** Save only when the path is clearly constrained (Data Saver). The default, like iOS. */
    Automatic("auto", "Automatic"),
    On("on", "On"),
    Off("off", "Off");

    companion object {
        /** Null for anything this build doesn't know: callers fall back to [Automatic]. */
        fun of(raw: String?): UseLessData? = entries.firstOrNull { it.raw == raw }
    }
}

/** `cost.cost` (`NetworkCost.Cost`). Android only ever reports the three it can know; unknown is never sent. */
enum class PathCost(val wire: String) {
    Unmetered("unmetered"),

    /** Metered: cellular or a hotspot (no `NET_CAPABILITY_NOT_METERED`). */
    Expensive("expensive"),

    /** Data Saver is on and the path is metered (iOS: Low Data Mode). */
    Constrained("constrained"),
}

/** `cost.conf` (`NetworkCost.Confidence`): high is the connection's own path. */
enum class PathConfidence(val wire: String) {
    Low("low"), Medium("medium"), High("high")
}

/** `cost.iface` (`NetworkCost.Interface`). A VPN is [Tunnel], never [Cellular]. */
enum class PathInterface(val wire: String) {
    WiFi("wifi"), Wired("wired"), Cellular("cellular"), Tunnel("tunnel"), Unknown("unknown")
}

/** The hello `cost` object: class and flags only, never an SSID, address, interface name or carrier. */
data class NetworkCostHint(val cost: PathCost, val confidence: PathConfidence, val iface: PathInterface)

/** What `NetworkCapabilities` says about one network, as plain booleans (no Android types in the core). */
data class PathCostFlags(
    val cellular: Boolean = false,
    val wifi: Boolean = false,
    val ethernet: Boolean = false,
    val vpn: Boolean = false,
    /** `NET_CAPABILITY_NOT_METERED` is present. */
    val notMetered: Boolean = false,
)

/**
 * Maps a network to the hello cost hint, following `NetworkCost.endpointReport` (Swift):
 *  - A VPN is a tunnel first, even when it also reports the transport it rides on (a VPN over
 *    cellular is `tunnel`, never `cellular`).
 *  - Cellular, Wi-Fi and Ethernet are known paths: metered (no NOT_METERED) is `expensive`, metered
 *    with Data Saver on is `constrained`, otherwise `unmetered`.
 *  - Through a tunnel (or an interface of no known kind) "not metered" is unknown, so nothing is
 *    reported for it; only Data Saver (`constrained`) or a metered flag (`expensive`, tunnels only)
 *    counts, at medium confidence.
 *  - Unknown stays unknown: the result is null and the hello carries no `cost`.
 *
 * Data Saver is a setting for metered networks, so on a known unmetered network (home Wi-Fi) it does
 * not make the path `constrained`. Through a tunnel the underlying network can't be seen, so it does.
 *
 * [ownPath] is true when the network was found as the one carrying the connection's socket; false
 * when it is only the system's default network, which caps the confidence at medium
 * (`NetworkCost.Confidence`: "medium: the process-wide default path").
 */
object NetworkCostMapper {
    fun hint(flags: PathCostFlags, dataSaver: Boolean, ownPath: Boolean = true): NetworkCostHint? {
        val iface = when {
            flags.vpn -> PathInterface.Tunnel
            flags.cellular -> PathInterface.Cellular
            flags.wifi -> PathInterface.WiFi
            flags.ethernet -> PathInterface.Wired
            else -> PathInterface.Unknown
        }
        val metered = !flags.notMetered
        val knownPath = iface != PathInterface.Tunnel && iface != PathInterface.Unknown
        val cost: PathCost = if (knownPath) {
            when {
                metered && dataSaver -> PathCost.Constrained
                metered -> PathCost.Expensive
                else -> PathCost.Unmetered
            }
        } else {
            when {
                dataSaver -> PathCost.Constrained
                iface == PathInterface.Tunnel && metered -> PathCost.Expensive
                else -> return null
            }
        }
        val confidence = if (knownPath && ownPath) PathConfidence.High else PathConfidence.Medium
        return NetworkCostHint(cost, confidence, iface)
    }
}

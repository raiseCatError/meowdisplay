package com.raisecaterror.meowdisplay.android.remote

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import com.raisecaterror.meowdisplay.core.remote.IpPrefix
import com.raisecaterror.meowdisplay.core.remote.NetworkFacts
import com.raisecaterror.meowdisplay.core.remote.RouteClassifier
import com.raisecaterror.meowdisplay.core.remote.RouteInfo
import com.raisecaterror.meowdisplay.core.remote.Transport
import java.net.InetAddress

/**
 * What the system says about this device's networks, for naming the path of a connection
 * (RouteClassifier) and for noticing that the default network changed. It only ever LOOKS at
 * `ConnectivityManager` (ACCESS_NETWORK_STATE): no tailnet peer is listed, nothing is scanned,
 * no VPN service is created and no Tailscale token is needed. Runs only while the app is in front.
 */
class RouteMonitor(context: Context) {
    private val connectivity = context.getSystemService(ConnectivityManager::class.java)
    private val main = Handler(Looper.getMainLooper())
    private val lock = Any()
    private val known = HashMap<Network, Known>()
    private var defaultNetwork: Network? = null
    private var started = false
    private var quietUntil = 0L

    private class Known(val transport: Transport, val addresses: List<ByteArray>, val routes: List<IpPrefix>?)

    /** The default network appeared or its link properties changed (debounced: one call per change). */
    @Volatile var onDefaultNetworkChanged: (() -> Unit)? = null

    private val announce = Runnable { onDefaultNetworkChanged?.invoke() }

    private inner class Watcher : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) = refresh(network)
        override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) = refresh(network)
        override fun onLinkPropertiesChanged(network: Network, linkProperties: android.net.LinkProperties) {
            refresh(network)
            if (network == defaultNetwork) changed()
        }
        override fun onLost(network: Network) {
            synchronized(lock) { known.remove(network) }
        }
    }

    private val others = Watcher()
    private val vpns = Watcher()
    private val defaults = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) {
            synchronized(lock) { defaultNetwork = network }
            refresh(network)
            changed()
        }
        override fun onLost(network: Network) {
            synchronized(lock) { if (defaultNetwork == network) defaultNetwork = null }
        }
    }

    @Synchronized
    fun start() {
        if (started) return
        started = true
        // The callbacks replay the current networks at once; those are not changes.
        quietUntil = SystemClock.elapsedRealtime() + SETTLE_MS
        runCatching {
            connectivity.registerNetworkCallback(NetworkRequest.Builder().addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET).build(), others)
            // A VPN is only visible to a request that asks for one.
            connectivity.registerNetworkCallback(
                NetworkRequest.Builder().addTransportType(NetworkCapabilities.TRANSPORT_VPN)
                    .removeCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN).build(),
                vpns,
            )
            connectivity.registerDefaultNetworkCallback(defaults)
        }.onFailure { started = false }
    }

    @Synchronized
    fun stop() {
        if (!started) return
        started = false
        main.removeCallbacks(announce)
        for (callback in listOf(others, vpns, defaults)) runCatching { connectivity.unregisterNetworkCallback(callback) }
        synchronized(lock) {
            known.clear()
            defaultNetwork = null
        }
    }

    private fun changed() {
        if (SystemClock.elapsedRealtime() < quietUntil) return
        main.removeCallbacks(announce)
        main.postDelayed(announce, DEBOUNCE_MS)
    }

    private fun refresh(network: Network) {
        val capabilities = connectivity.getNetworkCapabilities(network) ?: return
        val properties = connectivity.getLinkProperties(network)
        val transport = when {
            // A VPN often also reports the transport it rides on: it is a VPN first.
            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_VPN) -> Transport.Vpn
            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> Transport.WiFi
            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> Transport.Cellular
            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> Transport.Ethernet
            else -> Transport.Other
        }
        val addresses = properties?.linkAddresses?.map { it.address.address }.orEmpty()
        // If the routes can't be read the VPN is only ever called "VPN".
        val routes = runCatching { properties?.routes?.map { IpPrefix(it.destination.address.address, it.destination.prefixLength) } }.getOrNull()
        synchronized(lock) { known[network] = Known(transport, addresses, routes) }
    }

    /** The system's networks right now, the default one marked. */
    fun snapshot(): List<NetworkFacts> = synchronized(lock) {
        known.map { (network, facts) -> NetworkFacts(facts.transport, facts.addresses, facts.routes, isDefault = network == defaultNetwork) }
    }

    /** The honest label for a connection with [peer], reached from our own address [local]. */
    fun classify(peer: InetAddress, local: InetAddress?, startedByKnock: Boolean): RouteInfo =
        RouteClassifier.classify(peer.address, local?.address, snapshot(), startedByKnock)

    private companion object {
        const val SETTLE_MS = 1_500L
        const val DEBOUNCE_MS = 1_000L
    }
}

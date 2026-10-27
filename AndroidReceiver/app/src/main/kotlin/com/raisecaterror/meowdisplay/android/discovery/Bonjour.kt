package com.raisecaterror.meowdisplay.android.discovery

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.suspendCancellableCoroutine
import java.net.InetAddress
import java.util.concurrent.Executors
import kotlin.coroutines.resume

/** DNS-SD service types and TXT records (PROTOCOL.md 2.1 and 2.2a). */
object ServiceTypes {
    const val MEDIA = "_opensidecar._tcp"
    const val PAIRING = "_opendisplay-pair._tcp"
    const val MAC_PAIRING = "_opendisplay-mac-pair._tcp"

    const val MEDIA_PORT = 9001
    const val PAIRING_PORT = 9002

    /** The media advertisement (2.1): `id` must equal hello's `id`. Never carries trust. */
    fun mediaTxt(installID: String, protocolVersion: Int) = mapOf("id" to installID, "pv" to protocolVersion.toString())

    /** The pairing advertisement: discovery metadata only, never a secret. */
    fun pairingTxt(installID: String, protocolVersion: Int, pairingVersion: Int) =
        mapOf("id" to installID, "pv" to protocolVersion.toString(), "pp" to pairingVersion.toString())
}

data class NearbyMac(val serviceName: String)

data class ResolvedMac(val serviceName: String, val host: InetAddress, val port: Int, val installID: String?)

/** Publishes this receiver's services and browses for Macs through `NsdManager`. */
class Bonjour(context: Context) {
    private val nsd = context.getSystemService(NsdManager::class.java)
    private val registrations = mutableMapOf<String, NsdManager.RegistrationListener>()
    private var browse: NsdManager.DiscoveryListener? = null
    private val found = MutableStateFlow<List<NearbyMac>>(emptyList())
    private val callbackExecutor = Executors.newSingleThreadExecutor()

    val nearbyMacs: StateFlow<List<NearbyMac>> = found.asStateFlow()

    fun advertise(type: String, name: String, port: Int, txt: Map<String, String>) {
        withdraw(type)
        val info = NsdServiceInfo().apply {
            serviceName = name
            serviceType = type
            setPort(port)
            for ((key, value) in txt) setAttribute(key, value)
        }
        val listener = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(info: NsdServiceInfo) {}
            override fun onRegistrationFailed(info: NsdServiceInfo, errorCode: Int) {}
            override fun onServiceUnregistered(info: NsdServiceInfo) {}
            override fun onUnregistrationFailed(info: NsdServiceInfo, errorCode: Int) {}
        }
        registrations[type] = listener
        nsd.registerService(info, NsdManager.PROTOCOL_DNS_SD, listener)
    }

    fun withdraw(type: String) {
        registrations.remove(type)?.let { runCatching { nsd.unregisterService(it) } }
    }

    fun browseMacs() {
        if (browse != null) return
        val listener = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(serviceType: String) {}
            override fun onDiscoveryStopped(serviceType: String) {}
            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) { browse = null }
            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {}
            override fun onServiceFound(info: NsdServiceInfo) {
                found.update { macs ->
                    (macs.filterNot { it.serviceName == info.serviceName } + NearbyMac(info.serviceName))
                        .sortedBy { it.serviceName.lowercase() }
                }
            }
            override fun onServiceLost(info: NsdServiceInfo) {
                found.update { macs -> macs.filterNot { it.serviceName == info.serviceName } }
            }
        }
        browse = listener
        nsd.discoverServices(ServiceTypes.MAC_PAIRING, NsdManager.PROTOCOL_DNS_SD, listener)
    }

    fun stopBrowsing() {
        browse?.let { runCatching { nsd.stopServiceDiscovery(it) } }
        browse = null
        found.value = emptyList()
    }

    /** Resolves one Mac's address and TXT `id` when the user asks to pair with it. */
    suspend fun resolve(mac: NearbyMac): ResolvedMac? = suspendCancellableCoroutine { continuation ->
        val query = NsdServiceInfo().apply {
            serviceName = mac.serviceName
            serviceType = ServiceTypes.MAC_PAIRING
        }
        fun finish(info: NsdServiceInfo?) {
            val host = info?.let { if (Build.VERSION.SDK_INT >= 34) it.hostAddresses.firstOrNull() else @Suppress("DEPRECATION") it.host }
            val resolved = if (info != null && host != null) {
                ResolvedMac(mac.serviceName, host, info.port, info.attributes["id"]?.toString(Charsets.UTF_8))
            } else null
            if (continuation.isActive) continuation.resume(resolved)
        }
        if (Build.VERSION.SDK_INT >= 34) {
            val callback = object : NsdManager.ServiceInfoCallback {
                override fun onServiceInfoCallbackRegistrationFailed(errorCode: Int) = finish(null)
                override fun onServiceUpdated(info: NsdServiceInfo) {
                    finish(info)
                    runCatching { nsd.unregisterServiceInfoCallback(this) }
                }
                override fun onServiceLost() = finish(null)
                override fun onServiceInfoCallbackUnregistered() {}
            }
            nsd.registerServiceInfoCallback(query, callbackExecutor, callback)
            continuation.invokeOnCancellation { runCatching { nsd.unregisterServiceInfoCallback(callback) } }
        } else {
            @Suppress("DEPRECATION")
            nsd.resolveService(query, object : NsdManager.ResolveListener {
                override fun onResolveFailed(info: NsdServiceInfo, errorCode: Int) = finish(null)
                override fun onServiceResolved(info: NsdServiceInfo) = finish(info)
            })
        }
    }
}

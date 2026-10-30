package com.raisecaterror.meowdisplay.android.remote

import android.content.Context
import android.os.SystemClock
import android.util.Log
import com.raisecaterror.meowdisplay.android.discovery.Bonjour
import com.raisecaterror.meowdisplay.android.identity.DeviceIdentity
import com.raisecaterror.meowdisplay.android.session.MediaController
import com.raisecaterror.meowdisplay.android.trust.PinStore
import com.raisecaterror.meowdisplay.core.remote.RemoteConnectCoordinator
import com.raisecaterror.meowdisplay.core.remote.RemoteKnockClient
import com.raisecaterror.meowdisplay.core.remote.RemoteKnocker
import com.raisecaterror.meowdisplay.core.remote.RemoteMacStore
import com.raisecaterror.meowdisplay.core.remote.RouteClassifier
import com.raisecaterror.meowdisplay.core.remote.HomeRows
import com.raisecaterror.meowdisplay.core.session.DisplayMode
import com.raisecaterror.meowdisplay.core.session.SessionEvent
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.launch

/**
 * Remote Access for this device: connecting to a paired Mac that isn't on this Wi-Fi (typically over
 * Tailscale). The receiver still LISTENS on pinned mutual-TLS 9001 and the Mac still DIALS it; all
 * this adds is the authenticated knock that asks the Mac to dial, a saved address per Mac to knock
 * at, and honest status. It creates no VpnService, scans nothing and enumerates no tailnet peers.
 */
class RemoteAccess(
    context: Context,
    identity: DeviceIdentity,
    private val pins: PinStore,
    private val media: MediaController,
    private val bonjour: Bonjour,
) {
    val store = RemoteMacStore(RemoteMacPrefs(context)).also { it.retainOnly(pins.paired.value.map { mac -> mac.peerID }.toSet()) }
    val routes = RouteMonitor(context)

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    private val host = object : RemoteConnectCoordinator.Host {
        override fun isPaired(peerID: String) = pins.pin(peerID) != null
        // Recovery ignores a Bonjour entry that outlived the phone's Wi-Fi: with no Wi-Fi/Ethernet the Mac can't be local.
        override fun isNearby(peerID: String) = nearby(peerID) && RouteClassifier.mayReachLocalNetwork(routes.snapshot())
        override fun autoReconnectEnabled() = media.session.autoReconnectEnabled
        override fun liveSessionPeer() = media.ui.value.takeIf { it.admitted }?.peerID
        override fun markConnectPending(peerID: String, mode: DisplayMode?) = media.markRemoteConnect(peerID, mode)
        override fun clearConnectPending(peerID: String) = media.clearRemoteConnect(peerID)
        override fun log(message: String) { Log.i(TAG, message) }
    }

    val coordinator = RemoteConnectCoordinator(
        scope = scope,
        nowMs = SystemClock::elapsedRealtime,
        store = store,
        knocker = RemoteKnocker(RemoteKnockClient(identity.keyManager, pins::pinnedPeers), scope),
        host = host,
    )

    init {
        media.routeOf = { peer, local, peerID -> routes.classify(peer, local, startedByKnock = coordinator.isKnockPending(peerID)) }
        media.remoteEvents = { event ->
            when (event) {
                is SessionEvent.Admitted -> coordinator.onAdmitted(event.peerID, remote = media.ui.value.route?.remote == true)
                is SessionEvent.Disconnected -> coordinator.onSessionLost(event.peerID, event.reason)
                else -> Unit
            }
        }
        routes.onDefaultNetworkChanged = { coordinator.onNetworkChanged() }
        // A Mac that appears on Bonjour lets the normal local path take over.
        scope.launch { bonjour.nearbyMacs.drop(1).collect { coordinator.onNearbyChanged() } }
    }

    /** Bonjour shows the Mac: by its TXT install ID, else by the name it was paired under. */
    fun nearby(peerID: String): Boolean = nearbyEntry(peerID) != null

    /** The Mac's login session is on Bonjour but switched out (Fast User Switching): it can't share now. */
    fun switchedOut(peerID: String): Boolean = nearbyEntry(peerID)?.advert?.switchedOut == true

    /** The Mac advertises that macOS blocks its connections to devices (Local Network privacy). */
    fun macLocalNetworkBlocked(peerID: String): Boolean = nearbyEntry(peerID)?.advert?.localNetworkBlocked == true

    private fun nearbyEntry(peerID: String): HomeRows.Nearby? {
        val name = pins.paired.value.firstOrNull { it.peerID == peerID }?.name ?: return null
        return HomeRows.nearbyEntry(peerID, name, bonjour.nearbyMacs.value.map { HomeRows.Nearby(it.serviceName, it.advert) })
    }

    /**
     * The one Connect. A Mac that is nearby keeps today's local path; a Mac that is not, and has a
     * saved address, is asked through a `manual` knock; with neither, the local request goes out as
     * before (the Mac may show up).
     */
    fun connect(peerID: String, mode: DisplayMode? = null) {
        if (!nearby(peerID) && store.endpoint(peerID) != null) {
            coordinator.connect(peerID, mode)
        } else {
            media.requestConnect(peerID, mode)
        }
    }

    /** Connect over the saved address even though the Mac is also visible locally. */
    fun connectRemotely(peerID: String, mode: DisplayMode? = null) {
        coordinator.connect(peerID, mode)
    }

    /** Cancel on a row that is waiting: the knock, the local request, or the wait for the Mac's own user. */
    fun cancel(peerID: String) {
        coordinator.cancel(peerID)
        media.cancelConnect()
        if (media.ui.value.let { it.peerID == peerID && it.awaitingMacApproval }) media.session.cancelOwnRequest()
    }

    /** Forget: the pin, its policy, any live session, every attempt and the saved address all go. */
    fun forget(peerID: String) {
        media.forget(peerID)
        coordinator.onForget(peerID)
    }

    fun onForeground() {
        routes.start()
        coordinator.onForeground()
    }

    /** Call BEFORE the media listener stops: a live remote session is remembered for the way back. */
    fun onBackground(resumable: Boolean) {
        val live = media.ui.value.takeIf { it.admitted && it.route?.remote == true && resumable }?.peerID
        coordinator.onBackground(live)
        routes.stop()
    }

    private companion object { const val TAG = "MeowRemote" }
}

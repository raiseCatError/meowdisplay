package com.raisecaterror.meowdisplay.core.remote

/** Why a remote attempt failed, in words the user can act on. */
enum class OfflineReason(val summary: String, val hint: String) {
    Dns("address not found", "Check the address, and that Tailscale is on for both devices."),
    TimedOut("timed out", "Is your Mac awake and online? Is Tailscale on for both devices?"),
    Refused("connection refused", "Open MeowDisplay on your Mac."),
    Unreachable("no route", "This device has no route to that address. Is Tailscale or the VPN on?"),
    Failed("couldn't connect", "Something answered, but it didn't speak MeowDisplay. Check the address.");
}

/**
 * The state of this device's last attempt to reach a Mac over Remote Access. Every state is the
 * direct consequence of a real event (a knock result, a dial-back timeout, an admitted session);
 * nothing is polled or inferred.
 */
sealed interface RemoteAttempt {
    /** The knock is in flight (resolving, handshaking, sending). */
    data class Knocking(val automatic: Boolean) : RemoteAttempt

    /** The knock was delivered: the Mac was asked and should dial this device within [RemoteConnectCoordinator.DIAL_BACK_MS]. */
    data object WaitingForDialBack : RemoteAttempt

    /** Between automatic recovery knocks after a remote session dropped. */
    data object Recovering : RemoteAttempt

    /** The knock was delivered but the Mac never connected back. */
    data object DialBackMissed : RemoteAttempt

    data class Offline(val reason: OfflineReason) : RemoteAttempt

    /** The address answered with another key than this Mac's pin ([otherPeerID]: another paired Mac's, if any). */
    data class DifferentMac(val otherPeerID: String?) : RemoteAttempt

    /** The Mac ended the TLS session itself: it does not accept this device. */
    data object NotAccepted : RemoteAttempt

    val isFailure: Boolean
        get() = this is Offline || this is DifferentMac || this == NotAccepted || this == DialBackMissed
}

/** The facts the home row for one paired Mac is made from. */
data class MacFacts(
    val peerID: String,
    val name: String,
    /** Bonjour currently shows this Mac on the local network. */
    val nearby: Boolean = false,
    /** The saved remote address, if any. */
    val remote: RemoteEndpoint? = null,
    /** This Mac is the live, admitted session. */
    val connected: Boolean = false,
    val route: RouteInfo? = null,
    /** The Mac accepted this device's invitation but its own user has not approved yet (`awaitingSender`). */
    val awaitingMacApproval: Boolean = false,
    /** A local Connect (the Bonjour `cr` token) is waiting for this Mac. */
    val localConnectPending: Boolean = false,
    val attempt: RemoteAttempt? = null,
    /** Bonjour shows this Mac's login session as switched out (Fast User Switching). */
    val switchedOut: Boolean = false,
)

enum class ConnectingStep(val text: String) {
    LocalRequest("Asking it to connect…"),
    ContactingMac("Contacting your Mac…"),
    WaitingForMac("Waiting for your Mac to connect…"),
    Reconnecting("Reconnecting…"),
}

sealed interface MacStatus {
    val text: String

    /** The primary button: what a tap does, or null when there is nothing to tap. */
    val action: RowAction

    data class Connected(val route: RouteInfo?) : MacStatus {
        override val text get() = "Connected" + (route?.let { " · ${it.sessionLabel}" } ?: "")
        override val action get() = RowAction.Show
    }

    data object NeedsMacApproval : MacStatus {
        override val text get() = "Needs approval on your Mac"
        override val action get() = RowAction.Cancel
    }

    data class Connecting(val step: ConnectingStep) : MacStatus {
        override val text get() = step.text
        override val action get() = RowAction.Cancel
    }

    data class Offline(val reason: OfflineReason) : MacStatus {
        override val text get() = "Offline · ${reason.summary}"
        override val action get() = RowAction.Retry
    }

    data class DifferentMac(val otherName: String?) : MacStatus {
        override val text get() = "Connection failed: different Mac at this address"
        override val action get() = RowAction.Retry
    }

    data object NotAccepted : MacStatus {
        override val text get() = "This Mac doesn't accept this device"
        override val action get() = RowAction.Retry
    }

    data object DialBackMissed : MacStatus {
        override val text get() = "The Mac didn't connect back"
        override val action get() = RowAction.Retry
    }

    /** The Mac's user switched to another account: this session can't share until they switch back. */
    data object SwitchedOut : MacStatus {
        override val text get() = "Switched Out"
        override val action get() = RowAction.None
    }

    /** Bonjour sees the Mac (the local path). */
    data object AvailableLocally : MacStatus {
        override val text get() = "Nearby"
        override val action get() = RowAction.Connect
    }

    data class SavedRemote(val host: String) : MacStatus {
        override val text get() = "Saved remote · $host"
        override val action get() = RowAction.Connect
    }

    data object NotFound : MacStatus {
        override val text get() = "Not found"
        override val action get() = RowAction.Connect
    }

    /** A longer explanation for the failure states, or null. */
    val hint: String?
        get() = when (this) {
            is Offline -> reason.hint
            is DifferentMac -> "Whatever answered isn't the Mac you paired" +
                (otherName?.let { ", but it is $it" } ?: "") + ". Check the address. Nothing was connected."
            NotAccepted -> "Forget it here and pair again, or pair it again from the Mac."
            DialBackMissed -> "Is your Mac awake, with Auto-Reconnect on? A firewall on the Mac can also block the connection."
            SwitchedOut -> "Another user is using this Mac. It can share again once its user switches back to this account."
            else -> null
        }

    val isFailure: Boolean get() = this is Offline || this is DifferentMac || this == NotAccepted || this == DialBackMissed
}

enum class RowAction(val label: String) {
    Connect("Connect"), Retry("Retry"), Cancel("Cancel"), Show("Show"),
    /** Nothing to tap (the Mac can't share right now). */
    None(""),
}

object MacStatusReducer {
    /**
     * The row's one status. Precedence: a live session; the Mac waiting on its own user; an attempt
     * in progress; a nearby Mac (the local path takes over a stale failure); the last failure; a
     * saved address; nothing.
     */
    fun reduce(facts: MacFacts, nameOf: (String) -> String? = { null }): MacStatus {
        if (facts.connected) return MacStatus.Connected(facts.route)
        if (facts.awaitingMacApproval) return MacStatus.NeedsMacApproval
        when (val attempt = facts.attempt) {
            is RemoteAttempt.Knocking -> return MacStatus.Connecting(if (attempt.automatic) ConnectingStep.Reconnecting else ConnectingStep.ContactingMac)
            RemoteAttempt.WaitingForDialBack -> return MacStatus.Connecting(ConnectingStep.WaitingForMac)
            RemoteAttempt.Recovering -> return MacStatus.Connecting(ConnectingStep.Reconnecting)
            else -> Unit
        }
        if (facts.localConnectPending) return MacStatus.Connecting(ConnectingStep.LocalRequest)
        if (facts.nearby && facts.switchedOut) return MacStatus.SwitchedOut
        if (facts.nearby) return MacStatus.AvailableLocally
        return when (val attempt = facts.attempt) {
            is RemoteAttempt.Offline -> MacStatus.Offline(attempt.reason)
            is RemoteAttempt.DifferentMac -> MacStatus.DifferentMac(attempt.otherPeerID?.let(nameOf))
            RemoteAttempt.NotAccepted -> MacStatus.NotAccepted
            RemoteAttempt.DialBackMissed -> MacStatus.DialBackMissed
            else -> facts.remote?.let { MacStatus.SavedRemote(it.host) } ?: MacStatus.NotFound
        }
    }
}

/** Which Macs appear on the home screen: one row per paired peer ID, however it was found. */
object HomeRows {
    data class Paired(val peerID: String, val name: String)

    class Result(val paired: List<Paired>, val toPair: List<String>)

    /**
     * Paired Macs (first row wins per peer ID, so a Mac that is nearby, saved remotely or both is
     * one row), then nearby Bonjour names that aren't any paired Mac's. Saved addresses of Macs that
     * aren't paired never make a row.
     */
    fun build(paired: List<Paired>, nearbyNames: List<String>): Result {
        val unique = paired.distinctBy { it.peerID }
        val pairedNames = unique.map { it.name }.toSet()
        return Result(unique, nearbyNames.filter { it !in pairedNames }.distinct())
    }

    /** One nearby Bonjour entry: its service name and what its TXT said (null until resolved). */
    data class Nearby(val serviceName: String, val advert: MacAdvertisement? = null)

    /**
     * Like [build], but a nearby entry whose TXT names a paired Mac's install ID is that Mac, whatever
     * its service name (two sessions of one Mac share a name). Only an entry without an ID falls back
     * to the name match.
     */
    fun buildFromNearby(paired: List<Paired>, nearby: List<Nearby>): Result {
        val unique = paired.distinctBy { it.peerID }
        val pairedIDs = unique.map { it.peerID }.toSet()
        val pairedNames = unique.map { it.name }.toSet()
        val toPair = nearby.filter { entry ->
            val id = entry.advert?.installID
            if (id != null) id !in pairedIDs else entry.serviceName !in pairedNames
        }.map { it.serviceName }.distinct()
        return Result(unique, toPair)
    }

    /** The nearby entry for paired Mac [peerID] (by install ID, else by the name it was paired under). */
    fun nearbyEntry(peerID: String, pairedName: String?, nearby: List<Nearby>): Nearby? {
        val claims = nearby.filter { it.advert?.installID == peerID }
        if (claims.size > 1) {
            // Bonjour TXT is unauthenticated, so several services claiming this Mac are ambiguous:
            // a conflicting Switched Out claim never wins, and among equals the paired name does.
            val usable = claims.filter { it.advert?.switchedOut != true }.ifEmpty { claims }
            return usable.firstOrNull { it.serviceName == pairedName } ?: usable.first()
        }
        return claims.firstOrNull()
            ?: pairedName?.let { name -> nearby.firstOrNull { it.advert?.installID == null && it.serviceName == name } }
    }
}

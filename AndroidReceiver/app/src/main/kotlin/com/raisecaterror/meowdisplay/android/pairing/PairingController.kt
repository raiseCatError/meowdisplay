package com.raisecaterror.meowdisplay.android.pairing

import com.raisecaterror.meowdisplay.android.discovery.Bonjour
import com.raisecaterror.meowdisplay.android.discovery.NearbyMac
import com.raisecaterror.meowdisplay.android.discovery.ServiceTypes
import com.raisecaterror.meowdisplay.android.identity.DeviceIdentity
import com.raisecaterror.meowdisplay.android.trust.PinStore
import com.raisecaterror.meowdisplay.core.pairing.PairingAttempt
import com.raisecaterror.meowdisplay.core.pairing.PairingClassification
import com.raisecaterror.meowdisplay.core.pairing.PairingCommitThrottle
import com.raisecaterror.meowdisplay.core.pairing.PairingError
import com.raisecaterror.meowdisplay.core.pairing.PairingException
import com.raisecaterror.meowdisplay.core.pairing.PairingProtocol
import com.raisecaterror.meowdisplay.core.pairing.PendingPairing
import com.raisecaterror.meowdisplay.core.pairing.SocketPairingTransport
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.runInterruptible
import kotlinx.coroutines.withTimeoutOrNull
import java.io.IOException
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket

/** The code on screen, waiting for the user. */
data class SasPrompt(
    val peerName: String,
    val sas: String,
    val classification: PairingClassification,
    internal val answer: CompletableDeferred<Boolean>,
    internal val attempt: PairingAttempt,
)

data class PairingUiState(
    val prompt: SasPrompt? = null,
    val pairingWith: String? = null,
    val message: String? = null,
)

/**
 * First pairing in both directions (PROTOCOL.md 2.3): the responder listener
 * on TCP 9002 that Macs pair with, and the initiator for "nearby Mac -> Pair".
 * Trust is written only by the core's `PairingFinalizer`, after both people
 * confirmed the same code.
 */
class PairingController(
    private val identity: DeviceIdentity,
    private val pins: PinStore,
    private val bonjour: Bonjour,
    private val localName: () -> String,
) {
    /** Must match the media protocol version this receiver speaks once media lands. */
    private val advertisedProtocolVersion = 22

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val throttle = PairingCommitThrottle()
    private val state = MutableStateFlow(PairingUiState())
    private var listenerJob: Job? = null
    @Volatile private var server: ServerSocket? = null

    val ui: StateFlow<PairingUiState> = state.asStateFlow()

    fun start() {
        if (listenerJob != null) return
        listenerJob = scope.launch { listen() }
        bonjour.advertise(
            ServiceTypes.PAIRING, localName(), ServiceTypes.PAIRING_PORT,
            ServiceTypes.pairingTxt(identity.installID, advertisedProtocolVersion, PairingProtocol.VERSION),
        )
        bonjour.browseMacs()
    }

    fun stop() {
        listenerJob?.cancel()
        listenerJob = null
        // A blocking accept() ignores cancellation; closing the socket ends it.
        server?.let { runCatching { it.close() } }
        bonjour.withdraw(ServiceTypes.PAIRING)
        bonjour.stopBrowsing()
        state.value.prompt?.let { cancel() }
    }

    /** The user compared the codes: true when they match. */
    fun answer(matches: Boolean) {
        val prompt = state.value.prompt ?: return
        if (!matches) prompt.attempt.cancel()
        prompt.answer.complete(matches)
        state.update { it.copy(prompt = null) }
    }

    fun cancel() = answer(false)

    fun dismissMessage() = state.update { it.copy(message = null) }

    /** "Nearby Mac -> Pair": this receiver initiates; the code appears on both screens. */
    fun pair(mac: NearbyMac) {
        if (state.value.pairingWith != null || state.value.prompt != null) return
        state.update { it.copy(pairingWith = mac.serviceName, message = null) }
        scope.launch {
            val outcome = try {
                val resolved = bonjour.resolve(mac) ?: throw IOException("could not reach ${mac.serviceName}")
                Socket().use { socket ->
                    socket.tcpNoDelay = true
                    runInterruptible { socket.connect(InetSocketAddress(resolved.host, resolved.port), 10_000) }
                    val attempt = attempt(socket)
                    withTimeoutOrNull(ATTEMPT_TIMEOUT_MS) {
                        attempt.runInitiator(expectedPeerID = resolved.installID, decide = { ask(it, attempt) })
                    } ?: throw PairingException(PairingError.Rejected)
                }
                "Paired with ${mac.serviceName}"
            } catch (e: CancellationException) {
                throw e
            } catch (e: PairingException) {
                e.error.userMessage
            } catch (_: IOException) {
                "Couldn't reach ${mac.serviceName}"
            }
            state.update { it.copy(pairingWith = null, prompt = null, message = outcome) }
        }
    }

    private suspend fun listen() {
        while (scope.isActive) {
            val server = try {
                ServerSocket().apply {
                    reuseAddress = true
                    bind(InetSocketAddress(ServiceTypes.PAIRING_PORT), 4)
                }.also { this.server = it }
            } catch (_: IOException) {
                // Busy (a restart, another app): try again, as the Apple receivers do.
                delay(1_000)
                continue
            }
            server.use {
                while (scope.isActive) {
                    val socket = try {
                        server.accept()
                    } catch (_: IOException) {
                        break
                    }
                    scope.launch { respond(socket) }
                }
            }
        }
    }

    private suspend fun respond(socket: Socket) = socket.use {
        socket.tcpNoDelay = true
        val attempt = attempt(socket)
        val outcome = try {
            val paired = withTimeoutOrNull(ATTEMPT_TIMEOUT_MS) {
                attempt.runResponder(throttle, decide = { ask(it, attempt) })
            } ?: throw PairingException(PairingError.Rejected)
            "Paired with ${paired.peerName}"
        } catch (e: CancellationException) {
            throw e
        } catch (e: PairingException) {
            // A malformed or throttled attempt never showed anything: stay quiet.
            if (e.error == PairingError.MalformedMessage || e.error == PairingError.TooManyAttempts) null
            else e.error.userMessage
        }
        if (outcome != null) state.update { it.copy(message = outcome) }
    }

    private fun attempt(socket: Socket) = PairingAttempt(
        transport = SocketPairingTransport(socket),
        store = pins,
        localID = identity.installID,
        localName = localName(),
        identitySPKI = identity.spki,
    )

    /**
     * Shows the code and waits for the user, at most 60 seconds. A second
     * attempt reaching its code while one is on screen is declined; it never
     * replaces the code the user is comparing.
     */
    private suspend fun ask(pending: PendingPairing, attempt: PairingAttempt): Boolean {
        val answer = CompletableDeferred<Boolean>()
        val prompt = SasPrompt(pending.peerName, pending.sas, pending.classification, answer, attempt)
        var shown = false
        state.update {
            // `update` may retry this block: decide afresh each time.
            shown = it.prompt == null
            if (shown) it.copy(prompt = prompt) else it
        }
        if (!shown) return false
        val accepted = withTimeoutOrNull(PROMPT_TIMEOUT_MS) { answer.await() } ?: false
        state.update { if (it.prompt === prompt) it.copy(prompt = null) else it }
        return accepted
    }

    private companion object {
        const val PROMPT_TIMEOUT_MS = 60_000L
        // Slightly later than the prompt, so the prompt's own timeout rejection goes out first.
        const val ATTEMPT_TIMEOUT_MS = 65_000L
    }
}

package com.raisecaterror.meowdisplay.core.pairing

import com.raisecaterror.meowdisplay.core.crypto.Hkdf
import com.raisecaterror.meowdisplay.core.crypto.P256
import com.raisecaterror.meowdisplay.core.crypto.constantTimeEquals
import com.raisecaterror.meowdisplay.core.crypto.lengthPrefixed
import com.raisecaterror.meowdisplay.core.crypto.sha256
import com.raisecaterror.meowdisplay.core.crypto.uint32BE
import com.raisecaterror.meowdisplay.core.crypto.utf8
import java.security.SecureRandom

// Port of Shared/Pairing.swift (pairing v13, PROTOCOL.md 2.3). Every byte that
// is hashed, derived or authenticated here must match the Swift side exactly;
// fixtures/receiver-protocol/swift-vectors.json holds both to it.

object PairingProtocol {
    const val VERSION = 13
    const val MAX_FRAME_BYTES = 64 * 1024
}

enum class PairingError(val userMessage: String) {
    MalformedMessage("Invalid pairing message"),
    UnsupportedVersion("This device must be updated before pairing"),
    InvalidKey("Pairing could not be verified"),
    InvalidConfirmation("Pairing could not be verified"),
    Rejected("Pairing was cancelled"),
    IdentityChanged("Device identity changed"),
    CancelledByPeer("Pairing was cancelled on the other device"),
    CancelledLocally("Pairing was cancelled"),
    TrustStateChanged("Trust changed during pairing. Try again"),
    CommitmentMismatch("Pairing could not be verified"),
    TooManyAttempts("Too many pairing attempts. Try again in 30 seconds."),
}

class PairingException(val error: PairingError) : Exception(error.name)

internal fun fail(error: PairingError): Nothing = throw PairingException(error)

private val uuidPattern = Regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")

fun isUuidString(value: String): Boolean = uuidPattern.matches(value)

/**
 * Only an identity a TLS handshake could ever present may become a pin: a
 * P-256 SPKI in the exact DER the handshake re-encodes (PinnedTls.spki).
 * Every real peer sends its TLS certificate's key, so this refuses nothing a
 * genuine peer sends; it stops a pairing from storing a pin that can never
 * authenticate yet still occupies that peer ID.
 */
fun isPinnableIdentity(spki: ByteArray): Boolean =
    P256.publicKeyFromSpki(spki)?.encoded?.contentEquals(spki) == true

/** First-pairing hello. Never accepted on the media port. */
class PairingHello(
    val version: Int,
    val deviceID: String,
    val displayName: String,
    val identitySPKI: ByteArray,
    val ephemeralPublicKey: ByteArray,
    val nonce: ByteArray,
) {
    fun validate() {
        val valid = version == PairingProtocol.VERSION &&
            isUuidString(deviceID) &&
            displayName.isNotBlank() &&
            displayName.utf8.size <= 128 &&
            identitySPKI.size <= 512 &&
            isPinnableIdentity(identitySPKI) &&
            ephemeralPublicKey.size == 65 &&
            nonce.size == 32 &&
            P256.publicKey(ephemeralPublicKey) != null
        if (!valid) fail(if (version == PairingProtocol.VERSION) PairingError.MalformedMessage else PairingError.UnsupportedVersion)
    }

    /** Canonical encoding shared by the commitment and the transcript. */
    internal fun canonical(role: PairingRole): ByteArray =
        byteArrayOf(role.wire) + uint32BE(version.toLong()) + deviceID.utf8.lengthPrefixed() +
            displayName.utf8.lengthPrefixed() + identitySPKI.lengthPrefixed() +
            ephemeralPublicKey.lengthPrefixed() + nonce.lengthPrefixed()

    override fun equals(other: Any?): Boolean = other is PairingHello && version == other.version &&
        deviceID == other.deviceID && displayName == other.displayName &&
        identitySPKI.contentEquals(other.identitySPKI) &&
        ephemeralPublicKey.contentEquals(other.ephemeralPublicKey) && nonce.contentEquals(other.nonce)

    override fun hashCode(): Int = deviceID.hashCode() * 31 + nonce.contentHashCode()
}

class PairingConfirmation(val accepted: Boolean, val authenticator: ByteArray) {
    override fun equals(other: Any?): Boolean =
        other is PairingConfirmation && accepted == other.accepted && authenticator.contentEquals(other.authenticator)

    override fun hashCode(): Int = authenticator.contentHashCode() * 2 + if (accepted) 1 else 0
}

enum class PairingRole(val wire: Byte) { Initiator(1), Responder(2) }

/**
 * The initiator's commitment to its real hello, sent before the responder has
 * seen it, so the responder cannot choose its own hello to grind the SAS.
 */
object PairingHelloCommitment {
    private const val DOMAIN = "MeowDisplay-Pairing-HelloCommit-v13"

    fun compute(initiatorHello: PairingHello): ByteArray =
        sha256(DOMAIN.utf8.lengthPrefixed() + initiatorHello.canonical(PairingRole.Initiator))

    fun verify(commitment: ByteArray, revealedInitiatorHello: PairingHello): Boolean =
        commitment.size == 32 && constantTimeEquals(commitment, compute(revealedInitiatorHello))
}

enum class PairingClassification { NewPeer, RePairSameKey, IdentityChanged }

data class PendingPairing(
    val peerID: String,
    val peerName: String,
    val peerSPKI: ByteArray,
    val sas: String,
    val classification: PairingClassification = PairingClassification.NewPeer,
) {
    override fun equals(other: Any?): Boolean = other is PendingPairing && peerID == other.peerID &&
        peerName == other.peerName && peerSPKI.contentEquals(other.peerSPKI) && sas == other.sas &&
        classification == other.classification

    override fun hashCode(): Int = peerID.hashCode()
}

/**
 * Ephemeral P-256 ECDH with transcript-bound HKDF/HMAC confirmation. The
 * six-digit SAS authenticates both identities, ephemeral keys, nonces, roles,
 * names and the version; it is display authentication only, never a key.
 */
class PairingHandshake(
    val role: PairingRole,
    deviceID: String,
    displayName: String,
    identitySPKI: ByteArray,
    private val ephemeralKey: P256.EphemeralKey = P256.generateEphemeral(),
    nonce: ByteArray = ByteArray(32).also { SecureRandom().nextBytes(it) },
) {
    val localHello = PairingHello(
        version = PairingProtocol.VERSION,
        deviceID = deviceID,
        displayName = displayName,
        identitySPKI = identitySPKI,
        ephemeralPublicKey = ephemeralKey.x963,
        nonce = nonce,
    )

    fun result(peerHello: PairingHello): PairingResult {
        localHello.validate()
        peerHello.validate()
        if (peerHello.deviceID == localHello.deviceID ||
            peerHello.identitySPKI.contentEquals(localHello.identitySPKI)
        ) fail(PairingError.MalformedMessage)
        val peerKey = P256.publicKey(peerHello.ephemeralPublicKey) ?: fail(PairingError.InvalidKey)
        val shared = P256.sharedSecret(ephemeralKey.privateKey, peerKey)
        val transcriptHash = sha256(
            transcript(
                initiator = if (role == PairingRole.Initiator) localHello else peerHello,
                responder = if (role == PairingRole.Responder) localHello else peerHello,
            ),
        )
        val root = Hkdf.derive(shared, salt = transcriptHash, info = "OpenDisplay pairing v13".utf8, length = 32)
        shared.fill(0)
        val sasBytes = Hkdf.derive(root, salt = "sas".utf8, info = transcriptHash, length = 4)
        // Big-endian u32 (unsigned, hence Long) reduced to six digits.
        val number = sasBytes.fold(0L) { acc, byte -> (acc shl 8) or (byte.toLong() and 0xFF) } % 1_000_000
        val peerRole = if (role == PairingRole.Initiator) PairingRole.Responder else PairingRole.Initiator
        return PairingResult(
            pending = PendingPairing(
                peerID = peerHello.deviceID,
                // Shown on screen and stored: without control, bidi or line-separator
                // characters. The transcript above already bound the name as sent.
                peerName = PairingNames.display(peerHello.displayName),
                peerSPKI = peerHello.identitySPKI,
                sas = String.format(java.util.Locale.ROOT, "%03d %03d", number / 1000, number % 1000),
            ),
            localConfirmationKey = confirmationKey(root, role),
            peerConfirmationKey = confirmationKey(root, peerRole),
            transcriptHash = transcriptHash,
        )
    }

    private companion object {
        fun confirmationKey(root: ByteArray, role: PairingRole): ByteArray =
            Hkdf.derive(root, salt = "confirmation".utf8, info = byteArrayOf(role.wire), length = 32)

        fun transcript(initiator: PairingHello, responder: PairingHello): ByteArray =
            "OpenDisplay-Pairing-Transcript-v13".utf8.lengthPrefixed() +
                initiator.canonical(PairingRole.Initiator) + responder.canonical(PairingRole.Responder)
    }
}

class PairingResult internal constructor(
    val pending: PendingPairing,
    private val localConfirmationKey: ByteArray,
    private val peerConfirmationKey: ByteArray,
    private val transcriptHash: ByteArray,
) {
    /** Live finalization steps after both SAS confirmations. */
    enum class Step(val wire: Byte) { Commit(0x10), CommitAck(0x11), Abort(0x12) }

    fun confirmation(accepted: Boolean): PairingConfirmation =
        PairingConfirmation(accepted, Hkdf.hmac(localConfirmationKey, confirmationBody(accepted)))

    fun stepAuthenticator(step: Step): ByteArray =
        Hkdf.hmac(localConfirmationKey, transcriptHash + byteArrayOf(step.wire))

    fun verifyStep(step: Step, authenticator: ByteArray) {
        val expected = Hkdf.hmac(peerConfirmationKey, transcriptHash + byteArrayOf(step.wire))
        if (!constantTimeEquals(expected, authenticator)) fail(PairingError.InvalidConfirmation)
    }

    /** Throws unless the peer's confirmation is authentic and accepted. */
    fun verify(confirmation: PairingConfirmation) {
        val expected = Hkdf.hmac(peerConfirmationKey, confirmationBody(confirmation.accepted))
        if (!constantTimeEquals(expected, confirmation.authenticator)) fail(PairingError.InvalidConfirmation)
        if (!confirmation.accepted) fail(PairingError.Rejected)
    }

    private fun confirmationBody(accepted: Boolean) = transcriptHash + byteArrayOf(if (accepted) 1 else 0)
}

/**
 * A peer's self-chosen name (from an unauthenticated hello) as this device shows and stores it,
 * the same rule as Shared/RemotePairing.swift `OwnerAuthPolicy.displayName`: no control
 * characters and none of the bidi, zero-width and line-separator characters that can reorder,
 * hide or fake text in a prompt (ZWJ/ZWNJ stay: emoji and several scripts need them), trimmed,
 * at most 40 characters, and "Device" when nothing printable is left.
 */
object PairingNames {
    private val dangerous: Set<Int> = buildSet {
        addAll(listOf(0x061C, 0x200B, 0x200E, 0x200F, 0x2028, 0x2029, 0x2060, 0xFEFF))
        addAll(0x202A..0x202E)
        addAll(0x2066..0x2069)
    }
    const val MAX_CHARACTERS = 40
    const val FALLBACK = "Device"

    fun display(raw: String): String {
        val kept = StringBuilder()
        raw.codePoints().forEach { cp ->
            if (Character.getType(cp) != Character.CONTROL.toInt() && cp !in dangerous) kept.appendCodePoint(cp)
        }
        val text = kept.toString().trim()
        // 40 user-perceived characters (grapheme clusters), as Swift's String.prefix counts them.
        val breaks = java.text.BreakIterator.getCharacterInstance(java.util.Locale.ROOT).apply { setText(text) }
        var end = 0
        var count = 0
        while (count < MAX_CHARACTERS) {
            val next = breaks.next()
            if (next == java.text.BreakIterator.DONE) { end = text.length; break }
            end = next
            count += 1
        }
        return text.substring(0, end).trim().ifEmpty { FALLBACK }
    }
}

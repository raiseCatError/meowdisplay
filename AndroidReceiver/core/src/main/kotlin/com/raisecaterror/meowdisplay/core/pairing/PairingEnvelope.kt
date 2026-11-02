package com.raisecaterror.meowdisplay.core.pairing

import com.raisecaterror.meowdisplay.core.crypto.base64
import com.raisecaterror.meowdisplay.core.crypto.base64Bytes
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.put

/**
 * One pairing frame (Shared/PairingSession.swift `PairingEnvelope`). JSON with
 * base64 `Data` fields, exactly as Swift's `JSONEncoder`/`JSONDecoder` read and
 * write it: absent and `null` optionals are the same, unknown keys are
 * ignored, and anything of the wrong type is malformed.
 */
class PairingEnvelope private constructor(
    val kind: Kind,
    val hello: PairingHello? = null,
    val confirmation: PairingConfirmation? = null,
    val authenticator: ByteArray? = null,
    val helloCommitment: ByteArray? = null,
) {
    /**
     * `helloCommit` / `hello` / `helloReveal` are the strictly ordered pre-SAS
     * ceremony; `commit` / `commitAck` / `abort` are the later authenticated
     * trust-finalization steps.
     */
    enum class Kind(val wire: String) {
        HelloCommit("helloCommit"), Hello("hello"), HelloReveal("helloReveal"),
        Confirmation("confirmation"), Commit("commit"), CommitAck("commitAck"), Abort("abort"),
    }

    fun encode(): String = buildJsonObject {
        put("kind", kind.wire)
        hello?.let { put("hello", helloJson(it)) }
        confirmation?.let {
            put("confirmation", buildJsonObject {
                put("accepted", it.accepted)
                put("authenticator", it.authenticator.base64())
            })
        }
        authenticator?.let { put("authenticator", it.base64()) }
        helloCommitment?.let { put("helloCommitment", it.base64()) }
    }.toString()

    companion object {
        fun helloCommit(commitment: ByteArray) = PairingEnvelope(Kind.HelloCommit, helloCommitment = commitment)
        fun hello(value: PairingHello) = PairingEnvelope(Kind.Hello, hello = value)
        fun helloReveal(value: PairingHello) = PairingEnvelope(Kind.HelloReveal, hello = value)
        fun confirmation(value: PairingConfirmation) = PairingEnvelope(Kind.Confirmation, confirmation = value)
        fun step(kind: Kind, authenticator: ByteArray) = PairingEnvelope(kind, authenticator = authenticator)

        /** Throws `PairingException(MalformedMessage)` for anything Swift's decoder would refuse. */
        fun decode(text: String): PairingEnvelope = try {
            val root = Json.parseToJsonElement(text) as? JsonObject ?: fail(PairingError.MalformedMessage)
            val kindText = root.string("kind") ?: fail(PairingError.MalformedMessage)
            val kind = Kind.entries.firstOrNull { it.wire == kindText } ?: fail(PairingError.MalformedMessage)
            PairingEnvelope(
                kind = kind,
                hello = root.optionalObject("hello")?.let(::parseHello),
                confirmation = root.optionalObject("confirmation")?.let {
                    PairingConfirmation(
                        accepted = it.boolean("accepted") ?: fail(PairingError.MalformedMessage),
                        authenticator = it.bytes("authenticator") ?: fail(PairingError.MalformedMessage),
                    )
                },
                authenticator = root.optionalBytes("authenticator"),
                helloCommitment = root.optionalBytes("helloCommitment"),
            )
        } catch (e: PairingException) {
            throw e
        } catch (_: Exception) {
            fail(PairingError.MalformedMessage)
        }

        private fun helloJson(hello: PairingHello) = buildJsonObject {
            put("version", hello.version)
            put("deviceID", hello.deviceID)
            put("displayName", hello.displayName)
            put("identitySPKI", hello.identitySPKI.base64())
            put("ephemeralPublicKey", hello.ephemeralPublicKey.base64())
            put("nonce", hello.nonce.base64())
        }

        private fun parseHello(json: JsonObject) = PairingHello(
            version = json.int("version") ?: fail(PairingError.MalformedMessage),
            deviceID = json.string("deviceID") ?: fail(PairingError.MalformedMessage),
            displayName = json.string("displayName") ?: fail(PairingError.MalformedMessage),
            identitySPKI = json.bytes("identitySPKI") ?: fail(PairingError.MalformedMessage),
            ephemeralPublicKey = json.bytes("ephemeralPublicKey") ?: fail(PairingError.MalformedMessage),
            nonce = json.bytes("nonce") ?: fail(PairingError.MalformedMessage),
        )

        private fun JsonObject.present(key: String): JsonElement? = get(key)?.takeUnless { it is JsonNull }

        private fun JsonObject.string(key: String): String? =
            (present(key) as? JsonPrimitive)?.takeIf { it.isString }?.content

        private fun JsonObject.int(key: String): Int? =
            (present(key) as? JsonPrimitive)?.takeUnless { it.isString }?.intOrNull

        private fun JsonObject.boolean(key: String): Boolean? =
            (present(key) as? JsonPrimitive)?.takeUnless { it.isString }?.booleanOrNull

        private fun JsonObject.bytes(key: String): ByteArray? = string(key)?.base64Bytes()

        private fun JsonObject.optionalObject(key: String): JsonObject? {
            val value = present(key) ?: return null
            return value as? JsonObject ?: fail(PairingError.MalformedMessage)
        }

        private fun JsonObject.optionalBytes(key: String): ByteArray? {
            if (present(key) == null) return null
            return bytes(key) ?: fail(PairingError.MalformedMessage)
        }
    }
}

package com.raisecaterror.meowdisplay.core

import com.raisecaterror.meowdisplay.core.Fixtures.b64
import com.raisecaterror.meowdisplay.core.Fixtures.obj
import com.raisecaterror.meowdisplay.core.Fixtures.str
import com.raisecaterror.meowdisplay.core.crypto.P256
import com.raisecaterror.meowdisplay.core.crypto.base64
import com.raisecaterror.meowdisplay.core.pairing.PairingConfirmation
import com.raisecaterror.meowdisplay.core.pairing.PairingEnvelope
import com.raisecaterror.meowdisplay.core.pairing.PairingError
import com.raisecaterror.meowdisplay.core.pairing.PairingException
import com.raisecaterror.meowdisplay.core.pairing.PairingHelloCommitment
import com.raisecaterror.meowdisplay.core.pairing.PairingProtocol
import com.raisecaterror.meowdisplay.core.pairing.PairingResult
import com.raisecaterror.meowdisplay.core.pairing.PairingRole
import com.raisecaterror.meowdisplay.core.tls.PinnedTls
import com.raisecaterror.meowdisplay.core.wire.AudioMediaFrame
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/**
 * Replays the Swift implementation's recorded pairing ceremonies, pin
 * fingerprints and audio frames: every value the Kotlin port computes must
 * equal the Swift one byte for byte.
 */
class SwiftVectorsTest {
    @Test
    fun theVectorsAreForThisPairingVersion() {
        assertEquals(PairingProtocol.VERSION, Fixtures.vectors.getValue("pairingVersion").jsonPrimitive.int)
        assertEquals(2, Fixtures.pairingCases.size)
    }

    @Test
    fun commitmentSasConfirmationsAndStepsMatchSwift() {
        for (case in Fixtures.pairingCases) {
            val name = case.str("name")
            val initiator = Fixtures.handshake(case.obj("initiator"), PairingRole.Initiator)
            val responder = Fixtures.handshake(case.obj("responder"), PairingRole.Responder)
            assertArrayEquals(name, case.obj("initiator").b64("ephemeralPublicKey"), initiator.localHello.ephemeralPublicKey)

            assertEquals(name, case.str("helloCommitment"), PairingHelloCommitment.compute(initiator.localHello).base64())

            val initiatorResult = initiator.result(responder.localHello)
            val responderResult = responder.result(initiator.localHello)
            assertEquals(name, case.str("sas"), initiatorResult.pending.sas)
            assertEquals(name, case.str("sas"), responderResult.pending.sas)

            assertEquals(name, case.str("initiatorConfirmationAccepted"), initiatorResult.confirmation(true).authenticator.base64())
            assertEquals(name, case.str("initiatorConfirmationRejected"), initiatorResult.confirmation(false).authenticator.base64())
            assertEquals(name, case.str("responderConfirmationAccepted"), responderResult.confirmation(true).authenticator.base64())
            assertEquals(name, case.str("responderConfirmationRejected"), responderResult.confirmation(false).authenticator.base64())

            for ((role, result) in listOf("initiatorSteps" to initiatorResult, "responderSteps" to responderResult)) {
                val steps = case.obj(role)
                assertEquals("$name $role", steps.str("commit"), result.stepAuthenticator(PairingResult.Step.Commit).base64())
                assertEquals("$name $role", steps.str("commitAck"), result.stepAuthenticator(PairingResult.Step.CommitAck).base64())
                assertEquals("$name $role", steps.str("abort"), result.stepAuthenticator(PairingResult.Step.Abort).base64())
            }
        }
    }

    /** The other direction: Swift's recorded values verify on the Kotlin side. */
    @Test
    fun swiftConfirmationsAndStepsVerifyInKotlin() {
        for (case in Fixtures.pairingCases) {
            val initiator = Fixtures.handshake(case.obj("initiator"), PairingRole.Initiator)
            val responder = Fixtures.handshake(case.obj("responder"), PairingRole.Responder)
            val initiatorResult = initiator.result(responder.localHello)
            val responderResult = responder.result(initiator.localHello)

            initiatorResult.verify(PairingConfirmation(true, case.b64("responderConfirmationAccepted")))
            responderResult.verify(PairingConfirmation(true, case.b64("initiatorConfirmationAccepted")))
            assertFails(PairingError.Rejected) {
                initiatorResult.verify(PairingConfirmation(false, case.b64("responderConfirmationRejected")))
            }
            // An accepted flag on a rejection's authenticator is forged.
            assertFails(PairingError.InvalidConfirmation) {
                initiatorResult.verify(PairingConfirmation(true, case.b64("responderConfirmationRejected")))
            }
            // The initiator's own confirmation never verifies as the responder's.
            assertFails(PairingError.InvalidConfirmation) {
                initiatorResult.verify(PairingConfirmation(true, case.b64("initiatorConfirmationAccepted")))
            }
            initiatorResult.verifyStep(PairingResult.Step.CommitAck, case.obj("responderSteps").b64("commitAck"))
            responderResult.verifyStep(PairingResult.Step.Commit, case.obj("initiatorSteps").b64("commit"))
            responderResult.verifyStep(PairingResult.Step.Abort, case.obj("initiatorSteps").b64("abort"))
            assertFails(PairingError.InvalidConfirmation) {
                responderResult.verifyStep(PairingResult.Step.Commit, case.obj("initiatorSteps").b64("abort"))
            }
        }
    }

    /** Swift's exact wire envelopes (escaped slashes, its key order) decode to the same values. */
    @Test
    fun swiftEnvelopesDecodeAndKotlinEnvelopesRoundTrip() {
        for (case in Fixtures.pairingCases) {
            val envelopes = case.obj("envelopes")
            val initiator = Fixtures.handshake(case.obj("initiator"), PairingRole.Initiator)
            val responder = Fixtures.handshake(case.obj("responder"), PairingRole.Responder)
            val responderResult = responder.result(initiator.localHello)
            val initiatorResult = initiator.result(responder.localHello)

            val commit = PairingEnvelope.decode(envelopes.str("helloCommit"))
            assertEquals(PairingEnvelope.Kind.HelloCommit, commit.kind)
            assertEquals(case.str("helloCommitment"), commit.helloCommitment?.base64())

            val hello = PairingEnvelope.decode(envelopes.str("hello"))
            assertEquals(PairingEnvelope.Kind.Hello, hello.kind)
            assertEquals(responder.localHello, hello.hello)

            val reveal = PairingEnvelope.decode(envelopes.str("helloReveal"))
            assertEquals(PairingEnvelope.Kind.HelloReveal, reveal.kind)
            assertEquals(initiator.localHello, reveal.hello)
            assertTrue(PairingHelloCommitment.verify(case.b64("helloCommitment"), reveal.hello!!))

            val confirmation = PairingEnvelope.decode(envelopes.str("confirmation"))
            assertEquals(responderResult.confirmation(true), confirmation.confirmation)

            val step = PairingEnvelope.decode(envelopes.str("commit"))
            assertEquals(PairingEnvelope.Kind.Commit, step.kind)
            assertArrayEquals(initiatorResult.stepAuthenticator(PairingResult.Step.Commit), step.authenticator)

            for (envelope in listOf(commit, hello, reveal, confirmation, step)) {
                val again = PairingEnvelope.decode(envelope.encode())
                assertEquals(envelope.encode(), again.encode())
            }
        }
    }

    @Test
    fun malformedEnvelopesAreRefused() {
        val hello = Fixtures.pairingCases.first().obj("envelopes").str("hello")
        val bad = listOf(
            "", "[]", "{}", """{"kind":"bogus"}""", """{"kind":7}""",
            """{"kind":"helloCommit","helloCommitment":"%%%"}""",
            """{"kind":"helloCommit","helloCommitment":12}""",
            """{"kind":"confirmation","confirmation":{"accepted":"yes","authenticator":"AA=="}}""",
            """{"kind":"hello","hello":"x"}""",
            hello.replace("\"version\":13", "\"version\":\"13\""),
            hello.replace("\"nonce\"", "\"nonceX\""),
        )
        for (text in bad) assertFails(PairingError.MalformedMessage, text) { PairingEnvelope.decode(text) }
        // Unknown keys and explicit nulls are what Swift's decoder tolerates.
        val tolerant = PairingEnvelope.decode("""{"kind":"commitAck","authenticator":null,"extra":[1,2]}""")
        assertEquals(PairingEnvelope.Kind.CommitAck, tolerant.kind)
    }

    @Test
    fun recordedHellosValidateAndTamperedOnesDoNot() {
        val case = Fixtures.pairingCases.first()
        val initiator = Fixtures.handshake(case.obj("initiator"), PairingRole.Initiator)
        val responder = Fixtures.handshake(case.obj("responder"), PairingRole.Responder)
        responder.localHello.validate()
        val offCurve = initiator.localHello.ephemeralPublicKey.copyOf().also { it[64] = (it[64] + 1).toByte() }
        val tampered = com.raisecaterror.meowdisplay.core.pairing.PairingHello(
            13, initiator.localHello.deviceID, initiator.localHello.displayName,
            initiator.localHello.identitySPKI, offCurve, initiator.localHello.nonce,
        )
        assertFails(PairingError.MalformedMessage) { responder.result(tampered) }
        val oldVersion = com.raisecaterror.meowdisplay.core.pairing.PairingHello(
            12, initiator.localHello.deviceID, initiator.localHello.displayName,
            initiator.localHello.identitySPKI, initiator.localHello.ephemeralPublicKey, initiator.localHello.nonce,
        )
        assertFails(PairingError.UnsupportedVersion) { responder.result(oldVersion) }
        // Any change to a committed field breaks the commitment.
        assertTrue(!PairingHelloCommitment.verify(case.b64("helloCommitment"), responder.localHello))
    }

    @Test
    fun fingerprintsMatchSwiftAndSpkisAreCanonicalP256() {
        val fingerprints = Fixtures.vectors.getValue("fingerprints").jsonArray.map { it.jsonObject }
        assertEquals(4, fingerprints.size)
        for (entry in fingerprints) {
            val spki = entry.b64("spki")
            assertEquals(entry.str("fingerprint"), PinnedTls.fingerprint(spki))
            // Java re-encodes CryptoKit's derRepresentation byte for byte.
            val key = assertNotNullReturn(P256.publicKeyFromSpki(spki))
            assertArrayEquals(spki, key.encoded)
        }
    }

    @Test
    fun audioFramesMatchSwiftBothWays() {
        val frames = Fixtures.vectors.getValue("audioFrames").jsonArray.map { it.jsonObject }
        for (entry in frames) {
            val bytes = entry.b64("bytes")
            val expected: AudioMediaFrame = when (entry.str("kind")) {
                "config" -> AudioMediaFrame.Config(
                    entry.getValue("sampleRate").jsonPrimitive.long, entry.getValue("channelCount").jsonPrimitive.int,
                    AudioMediaFrame.Bytes(entry.b64("cookie")),
                )
                "packet" -> AudioMediaFrame.Packet(
                    entry.getValue("sequence").jsonPrimitive.long, entry.getValue("capturedAtMs").jsonPrimitive.long,
                    entry.getValue("durationMs").jsonPrimitive.long, AudioMediaFrame.Bytes(entry.b64("payload")),
                )
                "pcmConfig" -> AudioMediaFrame.PcmConfig(
                    entry.getValue("sampleRate").jsonPrimitive.long, entry.getValue("channelCount").jsonPrimitive.int,
                )
                "pcmPacket" -> AudioMediaFrame.PcmPacket(
                    entry.getValue("sequence").jsonPrimitive.long, entry.getValue("capturedAtMs").jsonPrimitive.long,
                    entry.getValue("frameCount").jsonPrimitive.long, AudioMediaFrame.Bytes(entry.b64("payload")),
                )
                else -> error("unknown kind")
            }
            assertEquals(expected, AudioMediaFrame.decode(bytes))
            assertArrayEquals(bytes, expected.encode())
        }
    }

    private fun <T> assertNotNullReturn(value: T?): T {
        assertNotNull(value)
        return value!!
    }

    private fun assertFails(expected: PairingError, message: String = "", block: () -> Unit) {
        try {
            block()
            fail("expected $expected: $message")
        } catch (e: PairingException) {
            assertEquals(message, expected, e.error)
        }
    }
}

package com.raisecaterror.meowdisplay.core

import com.raisecaterror.meowdisplay.core.Fixtures.b64
import com.raisecaterror.meowdisplay.core.Fixtures.obj
import com.raisecaterror.meowdisplay.core.pairing.InMemoryPeerTrustStore
import com.raisecaterror.meowdisplay.core.pairing.PairingError
import com.raisecaterror.meowdisplay.core.pairing.PairingException
import com.raisecaterror.meowdisplay.core.pairing.PairingHello
import com.raisecaterror.meowdisplay.core.pairing.PairingProtocol
import com.raisecaterror.meowdisplay.core.pairing.PeerDirectory
import com.raisecaterror.meowdisplay.core.pairing.isPinnableIdentity
import com.raisecaterror.meowdisplay.core.crypto.P256
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.security.KeyPairGenerator
import java.security.spec.ECGenParameterSpec

/** Only keys a TLS handshake could present become pins, and each key belongs to one peer. */
class PairingIdentityTest {
    private fun hello(spki: ByteArray) = PairingHello(
        version = PairingProtocol.VERSION,
        deviceID = "AAAAAAAA-0000-0000-0000-000000000001",
        displayName = "Mac",
        identitySPKI = spki,
        ephemeralPublicKey = P256.x963(P256.generateEphemeral().publicKey),
        nonce = ByteArray(32) { 1 },
    )

    private fun assertMalformed(spki: ByteArray) {
        try {
            hello(spki).validate()
            fail("accepted ${spki.size}-byte identity")
        } catch (e: PairingException) {
            assertEquals(PairingError.MalformedMessage, e.error)
        }
    }

    @Test
    fun everySwiftPeerIdentityIsPinnable() {
        for (case in Fixtures.pairingCases) {
            for (party in listOf("initiator", "responder")) {
                assertTrue("$party SPKI", isPinnableIdentity(case.obj(party).b64("identitySPKI")))
            }
        }
        hello(TestIdentity("mac").spki).validate()
    }

    @Test
    fun anIdentityNoHandshakeCouldPresentIsRefusedAtTheHello() {
        assertMalformed(ByteArray(0))
        assertMalformed(ByteArray(91) { 7 })
        assertMalformed(TestIdentity("rsa", keyAlgorithm = "RSA").spki.copyOf(512))
        val p384 = KeyPairGenerator.getInstance("EC").run { initialize(ECGenParameterSpec("secp384r1")); generateKeyPair() }
        assertMalformed(p384.public.encoded)
        // A P-256 key in a non-canonical encoding (trailing byte) could never equal a handshake's SPKI.
        assertMalformed(TestIdentity("mac").spki + byteArrayOf(0))
    }

    @Test
    fun aKeyIdentifiesAPeerOnlyWhenExactlyOnePeerHoldsIt() {
        val a = TestIdentity("a").spki
        val b = TestIdentity("b").spki
        assertEquals("A", PeerDirectory.uniquePeerID(mapOf("A" to a, "B" to b), a))
        assertNull(PeerDirectory.uniquePeerID(mapOf("A" to a, "B" to a), a))
        assertNull(PeerDirectory.uniquePeerID(mapOf("B" to b), a))
        val store = InMemoryPeerTrustStore()
        assertTrue(store.setPin("A", a, "A"))
        assertFalse("another peer already holds this key", store.setPin("B", a, "B"))
        assertFalse(store.setPin("B", a, "B", allowIdentityChange = true))
        assertTrue("re-pairing the same peer with its own key", store.setPin("A", a, "A"))
    }
}

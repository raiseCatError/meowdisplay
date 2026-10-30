package com.raisecaterror.meowdisplay.core.crypto

import java.math.BigInteger
import java.security.AlgorithmParameters
import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.interfaces.ECPrivateKey
import java.security.interfaces.ECPublicKey
import java.security.spec.ECFieldFp
import java.security.spec.ECGenParameterSpec
import java.security.spec.ECParameterSpec
import java.security.spec.ECPoint
import java.security.spec.ECPrivateKeySpec
import java.security.spec.ECPublicKeySpec
import java.security.spec.X509EncodedKeySpec
import javax.crypto.KeyAgreement

/**
 * P-256 in the encodings the Swift side uses: X9.63 uncompressed points
 * (`x963Representation`, 65 bytes) for ephemeral keys and SubjectPublicKeyInfo
 * DER (`derRepresentation`) for identity pins.
 */
object P256 {
    val params: ECParameterSpec by lazy {
        AlgorithmParameters.getInstance("EC").run {
            init(ECGenParameterSpec("secp256r1"))
            getParameterSpec(ECParameterSpec::class.java)
        }
    }

    private val fieldPrime: BigInteger get() = (params.curve.field as ECFieldFp).p

    class EphemeralKey(val privateKey: ECPrivateKey, val publicKey: ECPublicKey) {
        val x963: ByteArray get() = x963(publicKey)
    }

    fun generateEphemeral(): EphemeralKey {
        val pair = KeyPairGenerator.getInstance("EC").run {
            initialize(ECGenParameterSpec("secp256r1"))
            generateKeyPair()
        }
        return EphemeralKey(pair.private as ECPrivateKey, pair.public as ECPublicKey)
    }

    /** A fixed key (tests and vectors only): raw scalar plus its public point. */
    fun ephemeral(rawPrivateKey: ByteArray, x963PublicKey: ByteArray): EphemeralKey {
        val factory = KeyFactory.getInstance("EC")
        val private = factory.generatePrivate(ECPrivateKeySpec(BigInteger(1, rawPrivateKey), params)) as ECPrivateKey
        val public = requireNotNull(publicKey(x963PublicKey)) { "invalid public key" }
        return EphemeralKey(private, public)
    }

    fun x963(key: ECPublicKey): ByteArray =
        byteArrayOf(0x04) + fixed32(key.w.affineX) + fixed32(key.w.affineY)

    /**
     * Parses an X9.63 uncompressed point and checks that it lies on the curve,
     * as CryptoKit's `PublicKey(x963Representation:)` does. Never trust a
     * provider to reject an off-curve point during key agreement.
     */
    fun publicKey(x963: ByteArray): ECPublicKey? {
        if (x963.size != 65 || x963[0] != 0x04.toByte()) return null
        val x = BigInteger(1, x963.copyOfRange(1, 33))
        val y = BigInteger(1, x963.copyOfRange(33, 65))
        if (!isOnCurve(x, y)) return null
        return try {
            KeyFactory.getInstance("EC").generatePublic(ECPublicKeySpec(ECPoint(x, y), params)) as ECPublicKey
        } catch (_: Exception) {
            null
        }
    }

    fun isOnCurve(x: BigInteger, y: BigInteger): Boolean {
        val p = fieldPrime
        if (x.signum() < 0 || x >= p || y.signum() < 0 || y >= p) return false
        // BigInteger.TWO needs API 33 on Android; this runs there too.
        val left = y.modPow(BigInteger.valueOf(2), p)
        val right = x.modPow(BigInteger.valueOf(3), p).add(params.curve.a.multiply(x)).add(params.curve.b).mod(p)
        return left == right
    }

    /** ECDH: the shared point's x-coordinate (CryptoKit's `SharedSecret`). */
    fun sharedSecret(privateKey: ECPrivateKey, peer: ECPublicKey): ByteArray =
        KeyAgreement.getInstance("ECDH").run {
            init(privateKey)
            doPhase(peer, true)
            generateSecret()
        }

    /** The P-256 public key in an SPKI DER, or null for anything else. */
    fun publicKeyFromSpki(spki: ByteArray): ECPublicKey? = try {
        val key = KeyFactory.getInstance("EC").generatePublic(X509EncodedKeySpec(spki)) as? ECPublicKey
        key?.takeIf { it.params.curve == params.curve && isOnCurve(it.w.affineX, it.w.affineY) }
    } catch (_: Exception) {
        null
    }

    private fun fixed32(value: BigInteger): ByteArray {
        val bytes = value.toByteArray()
        return when {
            bytes.size == 32 -> bytes
            bytes.size == 33 && bytes[0] == 0.toByte() -> bytes.copyOfRange(1, 33)
            bytes.size < 32 -> ByteArray(32 - bytes.size) + bytes
            else -> error("coordinate too large")
        }
    }
}

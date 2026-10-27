package com.raisecaterror.meowdisplay.core

import org.bouncycastle.asn1.x500.X500Name
import org.bouncycastle.cert.jcajce.JcaX509CertificateConverter
import org.bouncycastle.cert.jcajce.JcaX509v3CertificateBuilder
import org.bouncycastle.operator.jcajce.JcaContentSignerBuilder
import java.math.BigInteger
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.cert.X509Certificate
import java.security.spec.ECGenParameterSpec
import java.util.Date
import javax.net.ssl.KeyManagerFactory
import javax.net.ssl.X509KeyManager

/** A persistent self-signed identity, as each app has (P-256 unless a test needs otherwise). */
class TestIdentity(name: String, keyAlgorithm: String = "EC") {
    val keyManager: X509KeyManager
    val certificate: X509Certificate

    init {
        val pair = KeyPairGenerator.getInstance(keyAlgorithm).run {
            if (keyAlgorithm == "EC") initialize(ECGenParameterSpec("secp256r1")) else initialize(2048)
            generateKeyPair()
        }
        val subject = X500Name("CN=$name")
        val now = System.currentTimeMillis()
        val signer = JcaContentSignerBuilder(if (keyAlgorithm == "EC") "SHA256withECDSA" else "SHA256withRSA").build(pair.private)
        certificate = JcaX509CertificateConverter().getCertificate(
            JcaX509v3CertificateBuilder(subject, BigInteger.valueOf(now), Date(now - 60_000), Date(now + 86_400_000), subject, pair.public)
                .build(signer),
        )
        val store = KeyStore.getInstance("PKCS12").apply {
            load(null, null)
            setKeyEntry("identity", pair.private, CharArray(0), arrayOf(certificate))
        }
        keyManager = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm()).run {
            init(store, CharArray(0))
            keyManagers.single() as X509KeyManager
        }
    }

    val spki: ByteArray get() = certificate.publicKey.encoded
}

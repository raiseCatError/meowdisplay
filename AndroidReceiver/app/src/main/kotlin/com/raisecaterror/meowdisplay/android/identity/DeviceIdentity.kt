package com.raisecaterror.meowdisplay.android.identity

import android.annotation.SuppressLint
import android.content.Context
import android.provider.Settings
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import com.raisecaterror.meowdisplay.core.tls.PinnedTls
import com.raisecaterror.meowdisplay.core.tls.SingleIdentityKeyManager
import java.math.BigInteger
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.PrivateKey
import java.security.SecureRandom
import java.security.cert.X509Certificate
import java.security.spec.ECGenParameterSpec
import java.util.Date
import java.util.UUID
import javax.security.auth.x500.X500Principal

/**
 * This receiver's persistent identity (PROTOCOL.md 2.2a): a stable install id
 * and a P-256 key in the Android Keystore whose self-signed certificate is
 * presented in every TLS handshake. Its pin is the SPKI DER of that key.
 */
class DeviceIdentity private constructor(
    val installID: String,
    private val privateKey: PrivateKey,
    val certificate: X509Certificate,
) {
    val spki: ByteArray = requireNotNull(PinnedTls.spki(certificate)) { "identity key is not P-256" }
    val fingerprint: String = PinnedTls.fingerprint(spki)
    val keyManager get() = SingleIdentityKeyManager(privateKey, certificate)

    companion object {
        private const val KEY_ALIAS = "meowdisplay.identity.v1"
        private const val PREFS = "identity"
        private const val INSTALL_ID = "installID"

        // commit() with its result checked: the install id must be durable
        // before anything is paired under it.
        @SuppressLint("UseKtx")
        fun load(context: Context): DeviceIdentity {
            val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val installID = prefs.getString(INSTALL_ID, null) ?: UUID.randomUUID().toString().uppercase().also {
                check(prefs.edit().putString(INSTALL_ID, it).commit()) { "could not store the install id" }
            }
            val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
            if (!keyStore.containsAlias(KEY_ALIAS)) generate()
            val entry = keyStore.getEntry(KEY_ALIAS, null) as KeyStore.PrivateKeyEntry
            return DeviceIdentity(installID, entry.privateKey, entry.certificate as X509Certificate)
        }

        private fun generate() {
            val serial = BigInteger(64, SecureRandom()).abs().add(BigInteger.ONE)
            val spec = KeyGenParameterSpec.Builder(KEY_ALIAS, KeyProperties.PURPOSE_SIGN)
                .setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1"))
                .setDigests(KeyProperties.DIGEST_SHA256, KeyProperties.DIGEST_NONE)
                .setCertificateSubject(X500Principal("CN=MeowDisplay Receiver"))
                .setCertificateSerialNumber(serial)
                .setCertificateNotBefore(Date(System.currentTimeMillis() - 86_400_000L))
                // Self-signed and pinned: expiry is never checked, but keep it far out.
                .setCertificateNotAfter(Date(4_102_444_800_000L))
                .build()
            KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC, "AndroidKeyStore").run {
                initialize(spec)
                generateKeyPair()
            }
        }

        /** The name shown to Macs: the device name the user set, else the model. */
        fun displayName(context: Context): String =
            Settings.Global.getString(context.contentResolver, Settings.Global.DEVICE_NAME)?.takeIf { it.isNotBlank() }
                ?: android.os.Build.MODEL
    }
}

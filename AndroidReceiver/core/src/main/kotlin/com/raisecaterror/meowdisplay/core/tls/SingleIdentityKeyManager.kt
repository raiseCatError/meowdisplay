package com.raisecaterror.meowdisplay.core.tls

import java.net.Socket
import java.security.Principal
import java.security.PrivateKey
import java.security.cert.X509Certificate
import javax.net.ssl.SSLEngine
import javax.net.ssl.X509ExtendedKeyManager

/**
 * Presents exactly one identity in both roles: the device's persistent
 * self-signed P-256 certificate. On Android the private key is a Keystore
 * handle that never leaves secure hardware; the TLS stack signs through it.
 */
class SingleIdentityKeyManager(
    private val privateKey: PrivateKey,
    private val certificate: X509Certificate,
) : X509ExtendedKeyManager() {
    private val alias = "meowdisplay-identity"

    override fun getClientAliases(keyType: String?, issuers: Array<out Principal>?) = arrayOf(alias)
    override fun getServerAliases(keyType: String?, issuers: Array<out Principal>?) = arrayOf(alias)
    override fun chooseClientAlias(keyType: Array<out String>?, issuers: Array<out Principal>?, socket: Socket?) = alias
    override fun chooseServerAlias(keyType: String?, issuers: Array<out Principal>?, socket: Socket?) = alias
    override fun chooseEngineClientAlias(keyType: Array<out String>?, issuers: Array<out Principal>?, engine: SSLEngine?) = alias
    override fun chooseEngineServerAlias(keyType: String?, issuers: Array<out Principal>?, engine: SSLEngine?) = alias
    override fun getCertificateChain(alias: String?): Array<X509Certificate>? = if (alias == this.alias) arrayOf(certificate) else null
    override fun getPrivateKey(alias: String?): PrivateKey? = if (alias == this.alias) privateKey else null
}

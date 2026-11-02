package com.raisecaterror.meowdisplay.core.crypto

import java.security.MessageDigest
import java.util.Base64

/** Big-endian 4-byte length prefix followed by the bytes (`PairingCanonical.lp`). */
fun ByteArray.lengthPrefixed(): ByteArray = uint32BE(size.toLong()) + this

fun uint32BE(value: Long): ByteArray = byteArrayOf(
    (value ushr 24).toByte(), (value ushr 16).toByte(), (value ushr 8).toByte(), value.toByte(),
)

fun sha256(vararg parts: ByteArray): ByteArray {
    val digest = MessageDigest.getInstance("SHA-256")
    for (part in parts) digest.update(part)
    return digest.digest()
}

/** Constant-time comparison: timing must not leak how much of a secret matched. */
fun constantTimeEquals(a: ByteArray, b: ByteArray): Boolean = MessageDigest.isEqual(a, b)

/** Standard padded base64, the encoding Swift's `JSONEncoder` uses for `Data`. */
fun ByteArray.base64(): String = Base64.getEncoder().encodeToString(this)

fun String.base64Bytes(): ByteArray? = try {
    Base64.getDecoder().decode(this)
} catch (_: IllegalArgumentException) {
    null
}

fun String.hexBytes(): ByteArray {
    require(length % 2 == 0) { "odd hex length" }
    return ByteArray(length / 2) { substring(it * 2, it * 2 + 2).toInt(16).toByte() }
}

val String.utf8: ByteArray get() = toByteArray(Charsets.UTF_8)

package com.raisecaterror.meowdisplay.core.pairing

import com.raisecaterror.meowdisplay.core.crypto.uint32BE
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import java.io.DataInputStream
import java.io.EOFException
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.Socket
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/** The byte stream a pairing attempt runs over (a socket, or in-memory in tests). */
interface PairingTransport {
    suspend fun send(envelope: PairingEnvelope)
    suspend fun receive(): PairingEnvelope

    /** Queue one last frame (if any), then close. Never suspends. */
    fun sendLastAndClose(envelope: PairingEnvelope?)
}

/** `[4-byte big-endian length][JSON]`, at most 64 KiB, never empty (Shared/PairingNetwork.swift). */
object PairingFraming {
    fun encode(envelope: PairingEnvelope): ByteArray {
        val body = envelope.encode().toByteArray(Charsets.UTF_8)
        if (body.size > PairingProtocol.MAX_FRAME_BYTES) fail(PairingError.MalformedMessage)
        return uint32BE(body.size.toLong()) + body
    }

    fun read(input: InputStream): PairingEnvelope {
        val data = DataInputStream(input)
        val length = try {
            data.readInt().toLong() and 0xFFFF_FFFFL
        } catch (_: EOFException) {
            fail(PairingError.MalformedMessage)
        }
        if (length <= 0 || length > PairingProtocol.MAX_FRAME_BYTES) fail(PairingError.MalformedMessage)
        val body = ByteArray(length.toInt())
        try {
            data.readFully(body)
        } catch (_: EOFException) {
            fail(PairingError.MalformedMessage)
        }
        return PairingEnvelope.decode(String(body, Charsets.UTF_8))
    }
}

/** `PairingTransport` over a connected TCP socket. */
class SocketPairingTransport(private val socket: Socket) : PairingTransport {
    private val input: InputStream = socket.getInputStream()
    private val output: OutputStream = socket.getOutputStream()
    private val writeLock = Any()

    override suspend fun send(envelope: PairingEnvelope) {
        val bytes = PairingFraming.encode(envelope)
        withContext(Dispatchers.IO) {
            synchronized(writeLock) {
                output.write(bytes)
                output.flush()
            }
        }
    }

    /**
     * A blocking socket read ignores coroutine cancellation, so cancelling a
     * receive (the reveal deadline, the end of an attempt) closes the socket:
     * the attempt is over either way.
     */
    override suspend fun receive(): PairingEnvelope = suspendCancellableCoroutine { continuation ->
        continuation.invokeOnCancellation { runCatching { socket.close() } }
        Thread {
            try {
                continuation.resume(PairingFraming.read(input))
            } catch (e: PairingException) {
                continuation.resumeWithException(e)
            } catch (_: IOException) {
                continuation.resumeWithException(PairingException(PairingError.MalformedMessage))
            }
        }.apply { isDaemon = true }.start()
    }

    override fun sendLastAndClose(envelope: PairingEnvelope?) {
        val bytes = envelope?.let { runCatching { PairingFraming.encode(it) }.getOrNull() }
        Thread {
            try {
                if (bytes != null) synchronized(writeLock) {
                    output.write(bytes)
                    output.flush()
                }
            } catch (_: IOException) {
            } finally {
                runCatching { socket.close() }
            }
        }.apply { isDaemon = true }.start()
    }
}

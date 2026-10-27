package com.raisecaterror.meowdisplay.core.session

import com.raisecaterror.meowdisplay.core.pairing.PeerDirectory
import com.raisecaterror.meowdisplay.core.tls.PinnedTls
import com.raisecaterror.meowdisplay.core.wire.WireFraming
import java.io.Closeable
import java.io.FilterInputStream
import java.io.IOException
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.ThreadFactory
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLServerSocket
import javax.net.ssl.SSLSocket

/**
 * The pinned mutual-TLS 1.3 media listener (PROTOCOL.md 1, 2.1, 2.2a): the
 * only way into a [ReceiverSession]. There is no plaintext listener and no
 * fallback. A connection reaches the session only after:
 *
 * 1. the TLS 1.3 handshake completed with a client certificate whose key was
 *    pinned at handshake time (PinnedTls' trust manager), within a hard
 *    deadline;
 * 2. the authenticated key is re-checked against the CURRENT pins (a resumed
 *    session skips the trust manager, and Forget may have happened since);
 * 3. that key resolves to exactly one paired peer ID.
 *
 * Handshakes in flight are bounded, so unauthenticated peers cannot pile up
 * threads; everything after admission to the session is per frame, bounded
 * by [WireFraming.MAX_INCOMING_BYTES].
 */
class MediaListener(
    private val tls: SSLContext,
    private val pins: () -> Map<String, ByteArray>,
    private val session: ReceiverSession,
    private val port: Int = WireProtocol.MEDIA_PORT,
    private val handshakeTimeoutMs: Long = 8_000,
    private val maxPendingHandshakes: Int = 4,
    private val tickIntervalMs: Long = 250,
) : Closeable {
    private val workers: ExecutorService = Executors.newCachedThreadPool(daemon("meow-media"))
    private val timers: ScheduledExecutorService = Executors.newSingleThreadScheduledExecutor(daemon("meow-media-timer"))
    private val pending = AtomicInteger()
    private val closed = AtomicBoolean()

    @Volatile private var server: SSLServerSocket? = null

    val localPort: Int get() = server?.localPort ?: -1

    /** Binds the listener; throws when the port is unavailable. */
    fun start() {
        check(server == null && !closed.get()) { "already started" }
        val socket = PinnedTls.serverSocket(tls, port)
        server = socket
        workers.execute { acceptLoop(socket) }
        timers.scheduleWithFixedDelay({ runCatching { session.tick() } }, tickIntervalMs, tickIntervalMs, TimeUnit.MILLISECONDS)
    }

    override fun close() = close(sleeping = false)

    /**
     * Stops listening and ends the live connection with `sleeping` (this
     * device went to the background and expects the Mac back) or `closing`
     * (the session is over).
     */
    fun close(sleeping: Boolean) {
        if (!closed.compareAndSet(false, true)) return
        runCatching { server?.close() }
        session.disconnect(sleeping)
        timers.shutdownNow()
        workers.shutdownNow()
    }

    private fun acceptLoop(listener: SSLServerSocket) {
        while (!listener.isClosed) {
            val socket = try {
                listener.accept() as SSLSocket
            } catch (_: IOException) {
                break
            }
            if (pending.incrementAndGet() > maxPendingHandshakes) {
                pending.decrementAndGet()
                closeQuietly(socket)
                continue
            }
            workers.execute { serve(socket) }
        }
    }

    private fun serve(socket: SSLSocket) {
        val link = try {
            authenticate(socket)
        } finally {
            pending.decrementAndGet()
        } ?: return
        // A Mac this device blocked is closed without touching the live session.
        if (!session.adopt(link)) return
        try {
            val counted = object : FilterInputStream(socket.inputStream) {
                override fun read(b: ByteArray, off: Int, len: Int): Int =
                    super.read(b, off, len).also { if (it > 0) session.onBytes(link) }
            }
            val input = WireFraming.reader(counted)
            while (true) {
                val payload = WireFraming.read(input) ?: break
                session.onFrame(link, payload)
            }
        } catch (_: Exception) {
            // Oversized or zero-length frame, a frame cut short, TLS failure,
            // or the socket closed underneath: all end this connection.
        } finally {
            session.onClosed(link)
            link.close()
        }
    }

    /** The authenticated link, or null after closing a socket that is not a current, unique, pinned peer. */
    private fun authenticate(socket: SSLSocket): TlsLink? {
        val done = AtomicBoolean()
        // SO_TIMEOUT bounds each read; this bounds the whole handshake.
        val deadline = timers.schedule({ if (!done.get()) closeQuietly(socket) }, handshakeTimeoutMs, TimeUnit.MILLISECONDS)
        return try {
            socket.tcpNoDelay = true
            socket.soTimeout = handshakeTimeoutMs.toInt()
            socket.startHandshake()
            val current = pins()
            val spki = PinnedTls.verifiedPeerSPKI(socket, current.values) ?: throw IOException("peer is not pinned")
            val peerID = PeerDirectory.uniquePeerID(current, spki) ?: throw IOException("peer key is not one paired Mac")
            // From here the session's watchdog judges liveness.
            socket.soTimeout = 0
            done.set(true)
            TlsLink(socket, peerID, workers)
        } catch (_: Exception) {
            closeQuietly(socket)
            null
        } finally {
            done.set(true)
            deadline.cancel(false)
        }
    }

    private class TlsLink(private val socket: SSLSocket, override val peerID: String, private val closer: ExecutorService) : MediaLink {
        private val output = socket.outputStream
        private val closed = AtomicBoolean()

        override fun send(payload: ByteArray): Boolean {
            if (closed.get()) return false
            return try {
                val frame = WireFraming.frame(payload)
                synchronized(this) {
                    output.write(frame)
                    output.flush()
                }
                true
            } catch (_: Exception) {
                close()
                false
            }
        }

        /** Never blocks the caller: TLS close_notify can wait on a peer that stopped reading. */
        override fun close() {
            if (!closed.compareAndSet(false, true)) return
            runCatching { closer.execute { closeQuietly(socket) } }.onFailure { closeQuietly(socket) }
        }
    }

    private companion object {
        fun closeQuietly(socket: SSLSocket) {
            runCatching { socket.close() }
        }

        fun daemon(name: String) = ThreadFactory { runnable -> Thread(runnable, name).apply { isDaemon = true } }
    }
}


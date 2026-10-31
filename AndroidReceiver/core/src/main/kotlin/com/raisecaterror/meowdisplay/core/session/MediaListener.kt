package com.raisecaterror.meowdisplay.core.session

import com.raisecaterror.meowdisplay.core.pairing.PeerDirectory
import com.raisecaterror.meowdisplay.core.tls.PinnedTls
import com.raisecaterror.meowdisplay.core.wire.WireFraming
import java.io.Closeable
import java.io.FilterInputStream
import java.io.IOException
import java.util.concurrent.ExecutorService
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.ThreadFactory
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import kotlin.concurrent.thread
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
    private val maxPendingHandshakes: Int = 8,
    /** One address can hold only this many of them, so a single host can't lock out the Mac. */
    private val maxPendingPerHost: Int = 2,
    private val tickIntervalMs: Long = 250,
    private val log: (String) -> Unit = {},
) : Closeable {
    private val workers: ExecutorService = Executors.newCachedThreadPool(daemon("meow-media"))
    private val timers: ScheduledExecutorService = Executors.newSingleThreadScheduledExecutor(daemon("meow-media-timer"))
    private val pending = AtomicInteger()
    private val pendingByHost = HashMap<java.net.InetAddress?, Int>()

    /** Connections still in their TLS handshake (for tests). */
    val pendingHandshakes: Int get() = pending.get()
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
        // Not shutdownNow: that interrupted the closing link's grace wait (it runs on these
        // workers), so the socket was closed at once and the `sleeping`/`closing` goodbye
        // could be lost, leaving the Mac to treat a sleeping device as a dropped one. Let the
        // goodbye go out, then stop whatever is left.
        workers.shutdown()
        thread(isDaemon = true, name = "meow-media-close") {
            if (!workers.awaitTermination(2 * CLOSE_GRACE_MS, TimeUnit.MILLISECONDS)) workers.shutdownNow()
        }
    }

    private fun acceptLoop(listener: SSLServerSocket) {
        while (!listener.isClosed) {
            val socket = try {
                listener.accept() as SSLSocket
            } catch (_: IOException) {
                break
            }
            val host = socket.inetAddress
            if (!reservePending(host)) {
                closeQuietly(socket)
                continue
            }
            workers.execute { serve(socket, host) }
        }
    }

    /** A handshake slot for [host], within both the overall and the per-address bound. */
    private fun reservePending(host: java.net.InetAddress?): Boolean = synchronized(pendingByHost) {
        val forHost = pendingByHost[host] ?: 0
        if (pending.get() >= maxPendingHandshakes || forHost >= maxPendingPerHost) return false
        pendingByHost[host] = forHost + 1
        pending.incrementAndGet()
        true
    }

    private fun releasePending(host: java.net.InetAddress?) = synchronized(pendingByHost) {
        val left = (pendingByHost[host] ?: 1) - 1
        if (left > 0) pendingByHost[host] = left else pendingByHost.remove(host)
        pending.decrementAndGet()
    }

    private fun serve(socket: SSLSocket, host: java.net.InetAddress?) {
        val link = try {
            authenticate(socket)
        } finally {
            releasePending(host)
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
            TlsLink(socket, peerID, workers, log)
        } catch (_: Exception) {
            closeQuietly(socket)
            null
        } finally {
            done.set(true)
            deadline.cancel(false)
        }
    }

    /**
     * One authenticated connection. Every write happens on the link's own
     * ordered writer thread, never the caller's: the UI thread may not touch
     * a socket on Android, and a peer that stops reading must not stall the
     * session. The backlog is bounded; a peer that lets it overflow is closed.
     */
    private class TlsLink(
        private val socket: SSLSocket,
        override val peerID: String,
        private val closer: ExecutorService,
        private val log: (String) -> Unit,
    ) : MediaLink {
        override val remoteAddress get() = socket.inetAddress
        override val localAddress get() = socket.localAddress
        private val output = socket.outputStream
        private val closed = AtomicBoolean()
        private val queuedBytes = AtomicLong()
        private val writer = Executors.newSingleThreadExecutor(daemon("meow-media-writer"))

        override fun send(payload: ByteArray): Boolean {
            if (closed.get()) return false
            val frame = try {
                WireFraming.frame(payload)
            } catch (e: IllegalArgumentException) {
                log("refused outgoing frame: ${e.message}")
                return false
            }
            if (queuedBytes.addAndGet(frame.size.toLong()) > MAX_QUEUED_BYTES) {
                log("peer stopped reading: closing")
                close()
                return false
            }
            return try {
                writer.execute {
                    try {
                        output.write(frame)
                        output.flush()
                    } catch (e: Exception) {
                        log("write failed: $e")
                        close()
                    } finally {
                        queuedBytes.addAndGet(-frame.size.toLong())
                    }
                }
                true
            } catch (_: RejectedExecutionException) {
                false
            }
        }

        /**
         * Never blocks the caller. Frames already queued (a final `closing` or
         * `sleeping`) still go out first; a peer that stopped reading gets a
         * second before the socket is closed underneath the writer.
         */
        override fun close() {
            if (!closed.compareAndSet(false, true)) return
            runCatching { writer.execute { closeQuietly(socket) } }
            writer.shutdown()
            runCatching {
                closer.execute { if (!awaitQuietly(writer, CLOSE_GRACE_MS)) closeQuietly(socket) }
            }.onFailure { closeQuietly(socket) }
        }
    }

    internal companion object {
        /**
         * Waits for [executor] to finish; false on timeout or when this thread is interrupted
         * (session teardown). An interruption escaping a pool thread killed the app when the
         * Moto's session ended (2026-10-31 00:45:33, InterruptedException in awaitTermination).
         */
        fun awaitQuietly(executor: java.util.concurrent.ExecutorService, ms: Long): Boolean = try {
            executor.awaitTermination(ms, TimeUnit.MILLISECONDS)
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
            false
        }

        fun closeQuietly(socket: SSLSocket) {
            runCatching { socket.close() }
        }

        const val MAX_QUEUED_BYTES = 8L shl 20
        const val CLOSE_GRACE_MS = 1_000L

        fun daemon(name: String) = ThreadFactory { runnable -> Thread(runnable, name).apply { isDaemon = true } }
    }
}


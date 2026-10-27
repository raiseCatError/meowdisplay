package com.raisecaterror.meowdisplay.core

import com.raisecaterror.meowdisplay.core.crypto.uint32BE
import com.raisecaterror.meowdisplay.core.pairing.InMemoryPeerTrustStore
import com.raisecaterror.meowdisplay.core.pairing.PairingAttempt
import com.raisecaterror.meowdisplay.core.pairing.SocketPairingTransport
import com.raisecaterror.meowdisplay.core.tls.PinnedTls
import com.raisecaterror.meowdisplay.core.wire.WireFraming
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket
import java.util.UUID
import java.util.concurrent.TimeUnit

/**
 * The installed debug app on an emulator, driven the way a Mac drives it:
 * pair over 9002 (the person taps "Codes Match"), then a pinned mutual-TLS
 * session on 9001. Runs only when MEOW_EMULATOR_SERIAL names a booted
 * device with the debug APK installed; skipped everywhere else.
 */
class EmulatorSmokeTest {
    private val serial: String? = System.getenv("MEOW_EMULATOR_SERIAL")
    private val adbPath = System.getenv("ANDROID_HOME")?.let { "$it/platform-tools/adb" } ?: "adb"

    private fun adb(vararg args: String): String {
        val process = ProcessBuilder(listOf(adbPath, "-s", serial!!) + args).redirectErrorStream(true).start()
        val output = process.inputStream.bufferedReader().readText()
        process.waitFor(60, TimeUnit.SECONDS)
        return output
    }

    private fun screen(): String = adb("exec-out", "uiautomator", "dump", "/dev/tty")

    private fun waitFor(what: String, timeoutMs: Long = 20_000, condition: (String) -> Boolean): String {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (true) {
            val xml = screen()
            if (condition(xml)) return xml
            check(System.currentTimeMillis() < deadline) { "timed out waiting for $what; screen:\n${xml.take(4000)}" }
            Thread.sleep(500)
        }
    }

    private fun tap(text: String, timeoutMs: Long = 30_000) {
        val bounds = Regex("text=\"${Regex.escape(text)}\"[^>]*?bounds=\"\\[(\\d+),(\\d+)\\]\\[(\\d+),(\\d+)\\]\"")
        val xml = waitFor("'$text'", timeoutMs) { bounds.containsMatchIn(it) }
        val (x1, y1, x2, y2) = bounds.find(xml)!!.destructured
        adb("shell", "input", "tap", ((x1.toInt() + x2.toInt()) / 2).toString(), ((y1.toInt() + y2.toInt()) / 2).toString())
    }

    private fun admit(session: Mac) {
        session.send("{\"type\":\"welcome\",\"pv\":22,\"min\":1}")
        session.send("{\"type\":\"sessionInvite\",\"id\":\"smoke\",\"initiator\":\"sender\",\"intent\":\"automatic\",\"mode\":\"extend\",\"awaitingSender\":false}")
        session.expect("kf")
        assertEquals("accepted", session.expect("sessionInviteResponse")["result"]!!.jsonPrimitive.content)
    }

    private fun rotate(quarterTurns: Int) {
        adb("shell", "settings", "put", "system", "accelerometer_rotation", "0")
        adb("shell", "settings", "put", "system", "user_rotation", quarterTurns.toString())
    }

    private fun assertNoLog(text: String) {
        val log = adb("logcat", "-d", "-s", "MeowDecoder")
        check(!log.contains(text)) { "unexpected '$text' in:\n$log" }
    }

    private fun JsonObject.int(key: String) = getValue(key).jsonPrimitive.content.toDouble().toInt()

    private fun waitForLog(text: String, timeoutMs: Long = 20_000) {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (!adb("logcat", "-d", "-s", "MeowDecoder").contains(text)) {
            if (System.currentTimeMillis() >= deadline) {
                val trace = adb("logcat", "-d", "-s", "MeowDecoder", "MeowDecoderTrace", "MeowAudio")
                File(System.getProperty("meow.smoke.trace", "build/decoder-trace.txt")).writeText(trace)
                error("timed out waiting for log '$text' (full trace in build/decoder-trace.txt):\n" + trace.lines().take(40).joinToString("\n"))
            }
            Thread.sleep(250)
        }
    }

    private fun resource(path: String) = requireNotNull(javaClass.getResource("/$path")) { path }.readBytes()

    /** One access unit per wire frame with the telemetry prefix and 4-byte start codes, at 30 fps. */
    private fun stream(session: Mac, units: List<List<ByteArray>>) {
        for (unit in units) {
            val now = System.currentTimeMillis()
            session.sendFrame("{\"cap\":$now,\"snd\":$now}".toByteArray() + unit.fold(ByteArray(0)) { out, nal -> out + START + nal })
            Thread.sleep(33)
        }
    }

    /** Splits an encoder's Annex B output into pictures: parameter sets and SEI travel with the next slice. */
    private fun accessUnits(stream: ByteArray, hevc: Boolean): List<List<ByteArray>> {
        val nals = mutableListOf<ByteArray>()
        var start = -1
        var i = 0
        while (i + 3 <= stream.size) {
            if (stream[i] == 0.toByte() && stream[i + 1] == 0.toByte() && stream[i + 2] == 1.toByte()) {
                if (start >= 0) nals += stream.copyOfRange(start, if (i > start && stream[i - 1] == 0.toByte()) i - 1 else i)
                start = i + 3
                i += 3
            } else {
                i++
            }
        }
        if (start >= 0) nals += stream.copyOfRange(start, stream.size)
        val units = mutableListOf<List<ByteArray>>()
        var pending = mutableListOf<ByteArray>()
        for (nal in nals) {
            val first = nal[0].toInt() and 0xFF
            val vcl = if (hevc) (first shr 1) and 0x3F < 32 else (first and 0x1F) in 1..5
            pending += nal
            if (vcl) {
                units += pending
                pending = mutableListOf()
            }
        }
        return units
    }

    private class Mac(identity: TestIdentity, receiverSPKI: ByteArray) : AutoCloseable {
        val socket = PinnedTls.clientSocket(
            PinnedTls.context(identity.keyManager) { listOf(receiverSPKI) },
            InetSocketAddress(InetAddress.getLoopbackAddress(), MEDIA), 5_000,
        ).apply { soTimeout = 8_000; startHandshake() }
        private val input = WireFraming.reader(socket.inputStream)

        // Like the Mac: something at least every 2 s, or the receiver's 5 s watchdog drops us.
        private val liveness = java.util.concurrent.Executors.newSingleThreadScheduledExecutor { Thread(it).apply { isDaemon = true } }.apply {
            scheduleWithFixedDelay({ runCatching { send("{\"type\":\"ping\"}") } }, 2, 2, TimeUnit.SECONDS)
        }

        fun send(json: String) = sendFrame(json.toByteArray())

        @Synchronized
        fun sendFrame(payload: ByteArray) {
            socket.outputStream.write(uint32BE(payload.size.toLong()) + payload)
            socket.outputStream.flush()
        }

        fun expect(type: String): JsonObject {
            while (true) {
                val frame = WireFraming.read(input) ?: error("closed waiting for $type")
                val message = Json.parseToJsonElement(String(frame)).jsonObject
                if (message["type"]!!.jsonPrimitive.content == type) return message
            }
        }

        override fun close() {
            liveness.shutdownNow()
            socket.close()
        }
    }

    @Test
    fun pairThenRunAnAdmittedSessionAgainstTheInstalledApp() = runBlocking {
        assumeTrue("set MEOW_EMULATOR_SERIAL to run against an emulator", serial != null)
        adb("forward", "tcp:$PAIRING", "tcp:9002")
        adb("forward", "tcp:$MEDIA", "tcp:9001")
        adb("shell", "am", "start", "-W", "-n", "$APP/com.raisecaterror.meowdisplay.android.ui.MainActivity")
        waitFor("home") { it.contains("Paired Macs") }

        val mac = TestIdentity("smoke-mac")
        val macName = "Smoke Mac " + UUID.randomUUID().toString().take(4)
        val macStore = InMemoryPeerTrustStore()
        var macSas = ""
        val tapper = async(Dispatchers.IO) { tap("Codes Match") }
        val pending = Socket(InetAddress.getLoopbackAddress(), PAIRING).use { socket ->
            withTimeout(60_000) {
                PairingAttempt(SocketPairingTransport(socket), macStore, UUID.randomUUID().toString().uppercase(), macName, mac.spki)
                    .runInitiator(decide = { macSas = it.sas; true })
            }
        }
        tapper.await()
        val receiverSPKI = macStore.pin(pending.peerID)!!
        waitFor("paired row") { it.contains(macName) }

        val h264 = accessUnits(resource("video/testsrc-320x180.h264"), hevc = false)
        val hevc = accessUnits(resource("video/testsrc-320x180.h265"), hevc = true)
        Mac(mac, receiverSPKI).use { session ->
            val hello = session.expect("hello")
            assertEquals("Android", hello["device"]!!.jsonPrimitive.content)
            assertEquals(pending.peerID, hello["id"]!!.jsonPrimitive.content)
            assertEquals("22", hello["pv"]!!.jsonPrimitive.content)
            assertEquals("TLSv1.3", session.socket.session.protocol)
            adb("logcat", "-c")
            admit(session)
            // The receiver surface appears on admission and asks for a keyframe once it can show one.
            session.expect("kf")
            val ping = session.expect("ping")
            session.send("{\"type\":\"pong\",\"t\":${ping["t"]!!.jsonPrimitive.content},\"mt\":${System.currentTimeMillis()}}")

            // 1. Initial connection: only the first GOP. Without a second keyframe to fall back
            // on, 16 decoded pictures prove the first keyframe rendered and its dependents followed.
            stream(session, h264.take(30))
            waitForLog("output 320x180 (h264)")
            waitForLog("decoded 16 frames (h264)")
            stream(session, h264.drop(30))
            waitForLog("decoded 31 frames (h264)")
            assertNoLog("fell behind")

            // 2. Orientation: the session survives, hello announces the new panel, and the Mac's
            // rebuilt stream (new SPS) reconfigures the decoder on the same surface.
            adb("logcat", "-c")
            rotate(1)
            val landscape = session.expect("hello")
            assertTrue("landscape hello: $landscape", landscape.int("pixelsWide") > landscape.int("pixelsHigh"))
            stream(session, accessUnits(resource("video/testsrc-180x320.h264"), hevc = false))
            waitForLog("output 180x320 (h264)")
            waitForLog("decoded 16 frames (h264)")
            rotate(0)
            val portrait = session.expect("hello")
            assertTrue("portrait hello: $portrait", portrait.int("pixelsWide") < portrait.int("pixelsHigh"))
            stream(session, h264)
            waitForLog("output 320x180 (h264)")

            // 3. HEVC on the same session.
            adb("logcat", "-c")
            session.send("{\"type\":\"streamCodecState\",\"codec\":\"hevc\",\"reason\":\"smoke\"}")
            stream(session, hevc)
            waitForLog("output 320x180 (hevc)")
            waitForLog("decoded 31 frames (hevc)")
            // Dropped without `closing`: a transport loss, not the end of the session.
        }

        // 4. Reconnect: the Mac redials, the same session is admitted without a prompt and decodes again.
        adb("logcat", "-c")
        Mac(mac, receiverSPKI).use { session ->
            session.expect("hello")
            admit(session)
            session.expect("kf")
            stream(session, h264)
            waitForLog("output 320x180 (h264)")
            waitForLog("decoded 31 frames (h264)")
            session.send("{\"type\":\"closing\"}")
            waitFor("peer closed status") { it.contains("$macName ended the session") }
        }

        // An unpaired Mac and a Mac pinning the wrong receiver never get a session.
        assertTrue(runCatching { Mac(TestIdentity("stranger"), receiverSPKI).use { it.expect("hello") } }.isFailure)
        assertTrue(runCatching { Mac(mac, TestIdentity("other-receiver").spki).use { it.expect("hello") } }.isFailure)

        File(System.getProperty("meow.smoke.out", "build/emulator-smoke.txt")).writeText(
            "paired ${pending.peerID} sas=$macSas; first keyframe rendered (first GOP only); rotation kept the session and decoded again; HEVC decoded; reconnect re-admitted and decoded; closing; stranger refused\n" +
                adb("logcat", "-d", "-s", "MeowDecoder"),
        )
    }

    private companion object {
        const val APP = "com.raisecaterror.meowdisplay.android.debug"
        const val PAIRING = 19002
        const val MEDIA = 19001
        val START = byteArrayOf(0, 0, 0, 1)
    }
}

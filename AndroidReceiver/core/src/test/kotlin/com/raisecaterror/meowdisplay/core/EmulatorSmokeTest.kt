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

    private class Mac(identity: TestIdentity, receiverSPKI: ByteArray) : AutoCloseable {
        val socket = PinnedTls.clientSocket(
            PinnedTls.context(identity.keyManager) { listOf(receiverSPKI) },
            InetSocketAddress(InetAddress.getLoopbackAddress(), MEDIA), 5_000,
        ).apply { soTimeout = 8_000; startHandshake() }
        private val input = WireFraming.reader(socket.inputStream)

        fun send(json: String) = json.toByteArray().let {
            socket.outputStream.write(uint32BE(it.size.toLong()) + it)
            socket.outputStream.flush()
        }

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

        override fun close() = socket.close()
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

        Mac(mac, receiverSPKI).use { session ->
            val hello = session.expect("hello")
            assertEquals("Android", hello["device"]!!.jsonPrimitive.content)
            assertEquals(pending.peerID, hello["id"]!!.jsonPrimitive.content)
            assertEquals("22", hello["pv"]!!.jsonPrimitive.content)
            assertEquals("TLSv1.3", session.socket.session.protocol)
            session.send("{\"type\":\"welcome\",\"pv\":22,\"min\":1}")
            session.send("{\"type\":\"sessionInvite\",\"id\":\"smoke\",\"initiator\":\"sender\",\"intent\":\"automatic\",\"mode\":\"extend\",\"awaitingSender\":false}")
            session.expect("kf")
            assertEquals("accepted", session.expect("sessionInviteResponse")["result"]!!.jsonPrimitive.content)
            waitFor("admitted status") { it.contains("Showing $macName") }
            val ping = session.expect("ping")
            session.send("{\"type\":\"pong\",\"t\":${ping["t"]!!.jsonPrimitive.content},\"mt\":${System.currentTimeMillis()}}")
            session.sendFrame(START + byteArrayOf(0x67, 1) + START + byteArrayOf(0x68, 2) + START + byteArrayOf(0x65, 3))
            session.expect("ping")
            session.send("{\"type\":\"closing\"}")
            waitFor("peer closed status") { it.contains("$macName ended the session") }
        }

        // An unpaired Mac and a Mac pinning the wrong receiver never get a session.
        assertTrue(runCatching { Mac(TestIdentity("stranger"), receiverSPKI).use { it.expect("hello") } }.isFailure)
        assertTrue(runCatching { Mac(mac, TestIdentity("other-receiver").spki).use { it.expect("hello") } }.isFailure)

        File(System.getProperty("meow.smoke.out", "build/emulator-smoke.txt")).writeText(
            "paired ${pending.peerID} sas=$macSas; session admitted; ping/pong; closing; stranger refused\n",
        )
    }

    private companion object {
        const val APP = "com.raisecaterror.meowdisplay.android.debug"
        const val PAIRING = 19002
        const val MEDIA = 19001
        val START = byteArrayOf(0, 0, 0, 1)
    }
}

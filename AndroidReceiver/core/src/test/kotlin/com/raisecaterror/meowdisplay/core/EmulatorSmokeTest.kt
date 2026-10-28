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
            if (System.currentTimeMillis() >= deadline) {
                runCatching { shot("timeout-" + what.filter { it.isLetterOrDigit() }) }
                error("timed out waiting for $what; on screen: ${describe(xml)}")
            }
            Thread.sleep(500)
        }
    }

    private val profile: String = System.getenv("MEOW_EMULATOR_PROFILE") ?: "phone"
    private val shots = File(System.getenv("MEOW_SMOKE_SHOTS") ?: "build/smoke-shots").apply { mkdirs() }

    /** A PNG of the emulator screen, for the visual parity review. */
    private fun shot(name: String) {
        ProcessBuilder(adbPath, "-s", serial!!, "exec-out", "screencap", "-p")
            .redirectOutput(File(shots, "$profile-$name.png")).start().waitFor(30, TimeUnit.SECONDS)
    }

    private fun screenSize(): Pair<Int, Int> {
        val match = Regex("(\\d+)x(\\d+)").findAll(adb("shell", "wm", "size")).last()
        val (w, h) = match.destructured
        val rotation = adb("shell", "dumpsys", "input").let { Regex("SurfaceOrientation: (\\d)").find(it)?.groupValues?.get(1)?.toInt() ?: 0 }
        return if (rotation % 2 == 1) h.toInt() to w.toInt() else w.toInt() to h.toInt()
    }

    private val descBounds = { desc: String -> Regex("content-desc=\"${Regex.escape(desc)}\"[^>]*?bounds=\"\\[(\\d+),(\\d+)\\]\\[(\\d+),(\\d+)\\]\"") }

    /** The center of the element described as [desc] (Compose contentDescription). */
    private fun center(desc: String, timeoutMs: Long = 15_000): Pair<Int, Int> {
        val pattern = descBounds(desc)
        val xml = waitFor("'$desc'", timeoutMs) { pattern.containsMatchIn(it) }
        val (x1, y1, x2, y2) = pattern.find(xml)!!.destructured
        return (x1.toInt() + x2.toInt()) / 2 to (y1.toInt() + y2.toInt()) / 2
    }

    /** The center of [desc] in an already captured dump, or null. */
    private fun centerIn(xml: String, desc: String): Pair<Int, Int>? =
        descBounds(desc).find(xml)?.destructured?.let { (x1, y1, x2, y2) -> (x1.toInt() + x2.toInt()) / 2 to (y1.toInt() + y2.toInt()) / 2 }

    private fun tapDesc(desc: String) {
        val (x, y) = center(desc)
        adb("shell", "input", "tap", x.toString(), y.toString())
    }

    private fun tapAt(x: Int, y: Int) = adb("shell", "input", "tap", x.toString(), y.toString())

    private fun JsonObject.type(): String = this["type"]!!.jsonPrimitive.content
    private fun List<JsonObject>.input(): List<JsonObject> = filter { it.type() in INPUT_TYPES }

    /** Compact (iPhone-style) tray: Command sits in the bottom row of a portrait window. */
    private fun assertCompactControls(what: String, xml: String = screen()) {
        val (w, h) = screenSize()
        val (x, y) = centerIn(xml, "Command") ?: error("$what: no Command chip; on screen: ${describe(xml)}")
        if (h > w) assertTrue("$what: compact tray at the bottom ($x,$y in ${w}x$h)", y > h * 0.8)
    }

    /** Expanded (iPad-style) radial Custom layout: Settings anchors the bottom-right corner. */
    private fun assertExpandedControls(what: String, xml: String = screen()) {
        val (w, h) = screenSize()
        val (x, y) = centerIn(xml, "Settings") ?: error("$what: no Settings anchor; on screen: ${describe(xml)}")
        assertTrue("$what: radial Settings anchor bottom-right ($x,$y in ${w}x$h)", x > w * 0.75 && y > h * 0.75)
        checkNotNull(centerIn(xml, "Command")) { "$what: no Command chip" }
    }

    /** Every content description and text on screen, with bounds: a readable failure message. */
    private fun describe(xml: String): String =
        Regex("(text|content-desc)=\"([^\"]+)\"[^>]*?bounds=\"([^\"]+)\"").findAll(xml).joinToString("; ") { "${it.groupValues[2]} ${it.groupValues[3]}" }

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

    private fun JsonObject.int(key: String): Int = getValue(key).jsonPrimitive.content.toDouble().toInt()

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
        ).apply { soTimeout = 8_000; startHandshake(); soTimeout = 0 }
        private val input = WireFraming.reader(socket.inputStream)
        private val inbox = java.util.concurrent.LinkedBlockingQueue<JsonObject>()

        // Reads everything the receiver sends, so a test can also prove that nothing arrived.
        private val reader: Thread = Thread(::readAll).apply { isDaemon = true; start() }

        private fun readAll() {
            try {
                while (true) {
                    val frame: ByteArray = WireFraming.read(input) ?: return
                    val message: JsonObject = runCatching { Json.parseToJsonElement(String(frame)).jsonObject }.getOrNull() ?: continue
                    inbox.put(message)
                }
            } catch (_: Exception) {
                // Closed.
            }
        }

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

        fun expect(type: String, timeoutMs: Long = 20_000): JsonObject {
            val deadline = System.currentTimeMillis() + timeoutMs
            while (true) {
                val message = inbox.poll(deadline - System.currentTimeMillis(), TimeUnit.MILLISECONDS) ?: error("nothing of type $type within $timeoutMs ms")
                if (message["type"]!!.jsonPrimitive.content == type) return message
            }
        }

        /** Everything received until [done] accepts a message (inclusive). */
        fun collectUntil(timeoutMs: Long = 20_000, done: (JsonObject) -> Boolean): List<JsonObject> {
            val deadline = System.currentTimeMillis() + timeoutMs
            val seen = mutableListOf<JsonObject>()
            while (true) {
                val message = inbox.poll(deadline - System.currentTimeMillis(), TimeUnit.MILLISECONDS) ?: error("timed out; saw ${seen.map { it.toString() }}")
                seen += message
                if (done(message)) return seen
            }
        }

        /** Everything received during the next [ms]. */
        fun drain(ms: Long): List<JsonObject> {
            val deadline = System.currentTimeMillis() + ms
            val seen = mutableListOf<JsonObject>()
            while (true) {
                val left = deadline - System.currentTimeMillis()
                if (left <= 0) return seen
                inbox.poll(left, TimeUnit.MILLISECONDS)?.let(seen::add)
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

            // 1b. Input (C3). Nothing leaves before the Mac's grant; then a tap is a click where
            // it landed, the tray, Function Tray and keyboard reach the Mac in the iOS shapes, and
            // revocation stops everything again.
            val (width, height) = screenSize()
            tapAt(width / 2, height / 2)
            assertEquals("no input without a grant", emptyList<JsonObject>(), session.drain(1_500).input())
            shot("view-only-prompt")
            session.send("{\"type\":\"allowInputState\",\"allowed\":true,\"state\":\"allowed\"}")
            // Controls auto-hide after 9 s without interaction (iOS Auto-hide), and each UI dump
            // takes over a second: tap cached positions and keep interacting.
            // One dump for every position: controls auto-hide after 9 s idle, and dumps are slow.
            val controls = waitFor("controls") { descBounds("Command").containsMatchIn(it) && descBounds("Undo").containsMatchIn(it) }
            val command = centerIn(controls, "Command")!!
            val undo = centerIn(controls, "Undo")!!
            val keyboard = centerIn(controls, "Keyboard")
            shot("controls")
            File(shots, "$profile-controls.txt").writeText(describe(controls))
            if (profile == "phone") assertCompactControls("phone", controls) else assertExpandedControls(profile, controls)
            tapAt(width / 2, height / 2)
            val click = session.collectUntil { it.type() == "pointer" && it["action"]!!.jsonPrimitive.content == "up" }.input()
            val move = click.first { it.type() == "pointer" && it["action"]!!.jsonPrimitive.content == "move" }
            assertEquals(0.5, move["x"]!!.jsonPrimitive.content.toDouble(), 0.02)
            assertEquals(0.5, move["y"]!!.jsonPrimitive.content.toDouble(), 0.02)
            assertEquals(listOf("move", "down", "up"), click.filter { it.type() == "pointer" }.map { it["action"]!!.jsonPrimitive.content })

            tapAt(command.first, command.second)
            assertEquals("command", session.expect("keyboard")["modifier"]!!.jsonPrimitive.content)
            Thread.sleep(600)
            shot("command-latched")
            // A latched chord keeps its palette open (no auto-hide while a chord is held).
            val latched = screen()
            File(shots, "$profile-command-latched.txt").writeText(describe(latched))
            checkNotNull(centerIn(latched, "Copy")) { "the Command palette should be open; on screen: ${describe(latched)}" }
            tapAt(command.first, command.second)
            assertEquals("modifierUp", session.expect("keyboard")["action"]!!.jsonPrimitive.content)

            tapAt(undo.first, undo.second)
            assertEquals("{\"type\":\"keyboard\",\"action\":\"press\",\"usage\":29,\"modifiers\":[\"command\"]}", session.expect("keyboard").toString())

            if (keyboard != null) tapAt(keyboard.first, keyboard.second) else tapDesc("Keyboard")
            Thread.sleep(1_500)
            adb("shell", "input", "text", "hello")
            val typed = StringBuilder()
            session.collectUntil { message ->
                if (message.type() == "keyboard" && message["action"]?.jsonPrimitive?.content == "text") typed.append(message["text"]!!.jsonPrimitive.content)
                typed.toString() == "hello"
            }
            adb("shell", "input", "keyevent", "KEYCODE_DPAD_LEFT")
            val arrow = session.collectUntil { it.type() == "keyboard" && it["action"]?.jsonPrimitive?.content == "up" }.filter { it.type() == "keyboard" }
            assertEquals(listOf("down", "up"), arrow.map { it["action"]!!.jsonPrimitive.content })
            assertTrue(arrow.all { it["usage"]!!.jsonPrimitive.content == "80" })
            shot("keyboard")
            adb("shell", "input", "keyevent", "KEYCODE_BACK")

            // Auto-hide: idle for longer than 9 s and the controls retreat; the next touch brings them back.
            Thread.sleep(10_500)
            shot("auto-hidden")
            check(!descBounds("Command").containsMatchIn(screen())) { "controls should be auto-hidden" }
            tapAt(width / 2, height / 4)
            center("Command", timeoutMs = 5_000)

            // The reveal tap's click is still in flight: take it before revoking.
            session.drain(1_500)
            session.send("{\"type\":\"allowInputState\",\"allowed\":false,\"state\":\"off\"}")
            Thread.sleep(500)
            tapAt(width / 2, height / 2)
            assertEquals("revoked: nothing more", emptyList<JsonObject>(), session.drain(1_500).input())
            shot("revoked-prompt")

            // 1c. Foldable: folding switches to the outer display (compact controls, a new panel for
            // the Mac); unfolding returns to the expanded layout. The session survives both.
            if (profile == "foldable") {
                session.send("{\"type\":\"allowInputState\",\"allowed\":true,\"state\":\"allowed\"}")
                adb("emu", "fold")
                val folded = session.expect("hello")
                Thread.sleep(2_000)
                shot("folded")
                assertCompactControls("folded")
                adb("emu", "unfold")
                val unfolded = session.expect("hello")
                assertTrue("unfolding announces the larger inner display", unfolded.int("pixelsWide") * unfolded.int("pixelsHigh") > folded.int("pixelsWide") * folded.int("pixelsHigh"))
                Thread.sleep(2_000)
                shot("unfolded")
                assertExpandedControls("unfolded")
            }

            // 2. Orientation: the session survives, hello announces the new panel, and the Mac's
            // rebuilt stream (new SPS) reconfigures the decoder on the same surface.
            adb("logcat", "-c")
            rotate(1)
            val turned = session.expect("hello")
            // A quarter turn swaps the panel, whichever way the device is natively held.
            assertEquals("turned hello: $turned", hello.int("pixelsWide") to hello.int("pixelsHigh"), turned.int("pixelsHigh") to turned.int("pixelsWide"))
            stream(session, accessUnits(resource("video/testsrc-180x320.h264"), hevc = false))
            waitForLog("output 180x320 (h264)")
            waitForLog("decoded 16 frames (h264)")
            rotate(0)
            val back = session.expect("hello")
            assertEquals("back hello: $back", hello.int("pixelsWide") to hello.int("pixelsHigh"), back.int("pixelsWide") to back.int("pixelsHigh"))
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
        val INPUT_TYPES = setOf("touch", "scroll", "gesture", "pencil", "proximity", "keyboard", "pointer", "nativeAppGesture", "smartTouchProbe")
        val START = byteArrayOf(0, 0, 0, 1)
    }
}

package com.raisecaterror.meowdisplay.core.clipboard

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put
import java.security.MessageDigest
import java.util.Base64

// Unified Clipboard (PROTOCOL.md 6.15) — the Kotlin twin of Shared/UnifiedClipboard.swift.
// Events are named by origin device + its own sequence number and carry their causal context;
// ordering never uses device clocks. Same rules, same vectors (fixtures/clipboard/vectors.json).
// Content is never logged.

object ClipboardWire {
    const val TYPE = "clip"
    const val FEATURE = "clipboard"
    const val INLINE_BYTES = 16_000
    const val PART_BYTES = 22_000
    const val READ_MAX = 262_144
    const val MAX_ITEMS = 16
    const val MAX_REPS = 6
    const val MAX_FILES = 2_000
    const val MAX_DEPTH = 32
    const val MAX_ORIGIN = 128
    /** Hard caps on declared sizes, so totals never overflow. */
    const val MAX_REP_BYTES = 200_000_000
    const val MAX_FILE_BYTES = 1L shl 40
    val SIZE_CHOICES = listOf(1_000_000, 10_000_000, 50_000_000, 200_000_000)
    const val DEFAULT_MAX_BYTES = 10_000_000
}

enum class ClipKind(val wire: String, val mime: String) {
    Text("text", "text/plain"), Url("url", "text/uri-list"), Html("html", "text/html"), Rtf("rtf", "text/rtf"),
    Png("png", "image/png"), Jpeg("jpeg", "image/jpeg");

    val isText: Boolean get() = this == Text || this == Url
    companion object { fun of(s: String?) = entries.firstOrNull { it.wire == s } }
}

enum class ClipTypes(val wire: String) { Text("text"), All("all");
    companion object { fun of(s: String?) = entries.firstOrNull { it.wire == s } }
}

enum class ClipDirection(val wire: String) {
    Both("both"), ToDevice("toDevice"), ToMac("toMac");
    val toDeviceAllowed: Boolean get() = this != ToMac
    val toMacAllowed: Boolean get() = this != ToDevice
    companion object { fun of(s: String?) = entries.firstOrNull { it.wire == s } }
}

data class ClipRep(val kind: ClipKind, val size: Int, val hash: String, val inline: ByteArray? = null, val blob: Int? = null) {
    override fun equals(other: Any?): Boolean = other is ClipRep && kind == other.kind && size == other.size && hash == other.hash &&
        blob == other.blob && (inline?.contentEquals(other.inline ?: return inline == null) ?: (other.inline == null))
    override fun hashCode(): Int = (kind.hashCode() * 31 + size) * 31 + hash.hashCode()
}

data class ClipItem(val reps: List<ClipRep>) { fun rep(kind: ClipKind) = reps.firstOrNull { it.kind == kind } }

data class ClipFile(val path: List<String>, val size: Long, val dir: Boolean, val blob: Int? = null) {
    val name: String get() = path.lastOrNull() ?: ""
}

data class ClipEventID(val origin: String, val seq: Long) {
    override fun toString() = "$origin:$seq"
}

data class ClipHeader(val id: ClipEventID, val lamport: Long, val context: Map<String, Long>, val contentHash: String) {
    fun follows(other: ClipHeader): Boolean = (context[other.id.origin] ?: 0) >= other.id.seq
    fun beats(other: ClipHeader): Boolean = if (lamport != other.lamport) lamport > other.lamport else id.origin > other.id.origin
}

data class ClipEvent(val header: ClipHeader, val at: Long, val items: List<ClipItem>, val files: List<ClipFile>) {
    val id: ClipEventID get() = header.id
    val totalBytes: Long get() = items.sumOf { i -> i.reps.sumOf { it.size.toLong() } } + files.sumOf { it.size }
    val hasFiles: Boolean get() = files.isNotEmpty()

    /** A short description for status lines (never the content itself). */
    val summary: String get() {
        if (hasFiles) { val n = files.count { it.path.size == 1 }; return if (n == 1) "1 item" else "$n items" }
        val kinds = items.flatMap { i -> i.reps.map { it.kind } }.toSet()
        if (ClipKind.Png in kinds || ClipKind.Jpeg in kinds) return "An image"
        if (ClipKind.Url in kinds && ClipKind.Html !in kinds) return "A link"
        return "Text"
    }

    fun wire(): JsonObject = buildJsonObject {
        put("type", ClipboardWire.TYPE); put("op", "event")
        put("o", header.id.origin); put("s", header.id.seq); put("lc", header.lamport)
        put("vv", buildJsonObject { header.context.forEach { (k, v) -> put(k, v) } })
        put("ch", header.contentHash); put("at", at)
        put("items", buildJsonArray {
            items.forEach { item ->
                add(buildJsonObject {
                    put("reps", buildJsonArray {
                        item.reps.forEach { r ->
                            add(buildJsonObject {
                                put("t", r.kind.wire); put("n", r.size); put("h", r.hash)
                                r.inline?.let { put("d", Base64.getEncoder().encodeToString(it)) }
                                r.blob?.let { put("b", it) }
                            })
                        }
                    })
                })
            }
        })
        if (files.isNotEmpty()) put("files", buildJsonArray {
            files.forEach { f ->
                add(buildJsonObject {
                    put("p", buildJsonArray { f.path.forEach { add(JsonPrimitive(it)) } }); put("n", f.size); put("dir", f.dir)
                    f.blob?.let { put("b", it) }
                })
            }
        })
    }

    companion object {
        fun contentHash(items: List<ClipItem>, files: List<ClipFile>): String {
            val md = MessageDigest.getInstance("SHA-256")
            for (item in items) {
                for (r in item.reps) md.update("${r.kind.wire}:${r.size}:${r.hash};".toByteArray())
                md.update("|".toByteArray())
            }
            for (f in files) md.update("${f.path.joinToString("/")}:${f.size}:${f.dir};".toByteArray())
            return ClipHash.hex16(md.digest())
        }

        /** Bounded, defensive: null for anything malformed (unsafe file names drop the event). */
        fun parse(o: JsonObject): ClipEvent? {
            val origin = o.str("o")?.takeIf { it.isNotEmpty() && it.length <= ClipboardWire.MAX_ORIGIN } ?: return null
            val seq = o.long("s")?.takeIf { it > 0 } ?: return null
            val lc = o.long("lc")?.takeIf { it > 0 } ?: return null
            val ch = o.str("ch")?.takeIf { it.length <= 64 } ?: return null
            val context = mutableMapOf<String, Long>()
            (o["vv"] as? JsonObject)?.entries?.take(64)?.forEach { (k, v) ->
                val n = (v as? JsonPrimitive)?.takeIf { !it.isString }?.longOrNull ?: return null
                if (k.length > ClipboardWire.MAX_ORIGIN || n < 0) return null
                context[k] = n
            }
            context[origin] = maxOf(context[origin] ?: 0, seq)
            val items = mutableListOf<ClipItem>()
            for (raw in (o["items"] as? JsonArray).orEmpty().take(ClipboardWire.MAX_ITEMS)) {
                val reps = mutableListOf<ClipRep>()
                for (r in ((raw as? JsonObject)?.get("reps") as? JsonArray).orEmpty().take(ClipboardWire.MAX_REPS)) {
                    val ro = r as? JsonObject ?: continue
                    val kind = ClipKind.of(ro.str("t")) ?: continue
                    val n = ro.long("n")?.takeIf { it >= 0 && it <= ClipboardWire.MAX_REP_BYTES }?.toInt() ?: return null
                    val h = ro.str("h")?.takeIf { it.length == 16 } ?: return null
                    val inline = ro.str("d")?.takeIf { it.length <= ClipboardWire.INLINE_BYTES * 4 / 3 + 8 }
                        ?.let { runCatching { Base64.getDecoder().decode(it) }.getOrNull() }
                    if (inline != null && inline.size != n) return null
                    val blob = ro.long("b")?.takeIf { it >= 0 }?.toInt()
                    if (inline == null && blob == null && n > 0) return null
                    reps.add(ClipRep(kind, n, h, inline, blob))
                }
                if (reps.isNotEmpty()) items.add(ClipItem(reps))
            }
            val files = mutableListOf<ClipFile>()
            for (raw in (o["files"] as? JsonArray).orEmpty().take(ClipboardWire.MAX_FILES)) {
                val fo = raw as? JsonObject ?: return null
                val path = (fo["p"] as? JsonArray)?.map { (it as? JsonPrimitive)?.takeIf { p -> p.isString }?.content ?: return null } ?: return null
                if (path.isEmpty() || path.size > ClipboardWire.MAX_DEPTH || !path.all(ClipFiles::isSafeName)) return null
                val n = fo.long("n")?.takeIf { it >= 0 && it <= ClipboardWire.MAX_FILE_BYTES } ?: return null
                files.add(ClipFile(path, n, fo.bool("dir") == true, fo.long("b")?.takeIf { it >= 0 }?.toInt()))
            }
            if (items.isEmpty() && files.isEmpty()) return null
            return ClipEvent(ClipHeader(ClipEventID(origin, seq), lc, context, ch), o.long("at") ?: 0, items, files)
        }
    }
}

object ClipHash {
    fun hex16(digest: ByteArray): String = digest.take(8).joinToString("") { "%02x".format(it) }
    fun of(bytes: ByteArray): String = hex16(MessageDigest.getInstance("SHA-256").digest(bytes))
}

object ClipFiles {
    fun isSafeName(s: String): Boolean = s.isNotEmpty() && s != "." && s != ".." && '/' !in s && '\u0000' !in s && '\\' !in s &&
        s.toByteArray().size <= 255
}

/** The ordering rules, with no I/O (same as ClipboardSync in Swift). */
class ClipboardSync(val origin: String, seq: Long = 0, lamport: Long = 0) {
    enum class Decision(val wire: String) { Apply("apply"), Alternative("alternative"), Duplicate("duplicate"), Echo("echo"), Older("older") }

    var seq: Long = seq; private set
    var lamport: Long = lamport; private set
    private val seenMap = mutableMapOf<String, Long>().apply { if (seq > 0) put(origin, seq) }
    val seen: Map<String, Long> get() = seenMap
    var current: ClipHeader? = null; private set
    var alternative: ClipHeader? = null; private set

    /** A genuine copy here; null when the shared clipboard already holds it. */
    fun localCopy(contentHash: String): ClipHeader? {
        if (current?.contentHash == contentHash) return null
        seq += 1; lamport += 1
        seenMap[origin] = seq
        val h = ClipHeader(ClipEventID(origin, seq), lamport, seenMap.toMap(), contentHash)
        current = h; alternative = null
        return h
    }

    fun receive(h: ClipHeader): Decision {
        if (h.id.origin == origin) return Decision.Echo
        if ((seenMap[h.id.origin] ?: 0) >= h.id.seq) return Decision.Duplicate
        seenMap[h.id.origin] = h.id.seq
        for ((o, s) in h.context) if (o != origin && o != h.id.origin && (seenMap[o] ?: 0) < s) seenMap[o] = s
        lamport = maxOf(lamport, h.lamport)
        val cur = current ?: run { current = h; return Decision.Apply }
        if (h.follows(cur)) { current = h; alternative = null; return Decision.Apply }
        if (cur.follows(h)) return Decision.Older
        if (h.beats(cur)) { alternative = cur; current = h; return Decision.Apply }
        alternative = h
        return Decision.Alternative
    }

    /** What the other side has seen (a connection starting): marked seen, nothing applied. */
    fun merge(other: Map<String, Long>) { for ((o, s) in other) if (o != origin) seenMap[o] = maxOf(seenMap[o] ?: 0, s) }

    fun isCurrent(id: ClipEventID) = current?.id == id
    fun dropAlternative() { alternative = null }
}

object ClipBlobWire {
    fun read(req: Int, id: ClipEventID, blob: Int, offset: Long, count: Int): JsonObject = buildJsonObject {
        put("type", ClipboardWire.TYPE); put("op", "read"); put("req", req); put("o", id.origin); put("s", id.seq)
        put("b", blob); put("off", offset); put("n", count)
    }

    /** The answer to one `read`: parts, then `readEnd` with the range digest; or an error. */
    fun answer(req: Int, offset: Long, bytes: ByteArray?, error: String? = null): List<JsonObject> {
        if (bytes == null) return listOf(buildJsonObject { put("type", ClipboardWire.TYPE); put("op", "readEnd"); put("req", req); put("error", error ?: "gone") })
        val out = mutableListOf<JsonObject>()
        var i = 0
        while (i < bytes.size) {
            val part = bytes.copyOfRange(i, minOf(bytes.size, i + ClipboardWire.PART_BYTES))
            val off = offset + i
            out.add(buildJsonObject { put("type", ClipboardWire.TYPE); put("op", "data"); put("req", req); put("off", off); put("d", Base64.getEncoder().encodeToString(part)) })
            i += ClipboardWire.PART_BYTES
        }
        out.add(buildJsonObject {
            put("type", ClipboardWire.TYPE); put("op", "readEnd"); put("req", req); put("off", offset); put("n", bytes.size); put("sha", ClipHash.of(bytes))
        })
        return out
    }
}

/** One blob fetched by ranged reads; every range and (when known) the whole is checked. */
class ClipBlobFetch(val req: Int, val id: ClipEventID, val blob: Int, val size: Long, private val expectedHash: String?) {
    sealed interface Step { data object More : Step; class RangeDone(val bytes: ByteArray) : Step; data class Failed(val code: String) : Step }

    var received = 0L; private set
    private val range = java.io.ByteArrayOutputStream()
    private val whole = MessageDigest.getInstance("SHA-256")
    /** Bytes the outstanding `read` asked for: a peer can't push more than that into memory. */
    private var asked = 0
    val done: Boolean get() = received >= size
    fun nextRead(): JsonObject? {
        if (done) return null
        asked = minOf(ClipboardWire.READ_MAX.toLong(), size - received).toInt()
        return ClipBlobWire.read(req, id, blob, received, asked)
    }

    fun handle(m: JsonObject): Step = when (m.str("op")) {
        "data" -> {
            val off = m.long("off")
            val d = m.str("d")?.let { runCatching { Base64.getDecoder().decode(it) }.getOrNull() }
            if (off != received + range.size() || d == null || d.size > ClipboardWire.PART_BYTES || range.size() + d.size > asked ||
                received + range.size() + d.size > size) Step.Failed("badRange")
            else { range.write(d); Step.More }
        }
        "readEnd" -> {
            val err = m.str("error")
            if (err != null) Step.Failed(err.take(32))
            else {
                val bytes = range.toByteArray()
                if (m.long("off") != received || m.long("n") != bytes.size.toLong() || (bytes.isEmpty() && size != 0L) || m.str("sha") != ClipHash.of(bytes)) Step.Failed("digest")
                else {
                    whole.update(bytes); received += bytes.size; range.reset()
                    if (done && expectedHash != null && ClipHash.hex16(whole.digest()) != expectedHash) Step.Failed("digest") else Step.RangeDone(bytes)
                }
            }
        }
        else -> Step.Failed("badRange")
    }
}

private fun JsonObject.str(k: String): String? = (this[k] as? JsonPrimitive)?.takeIf { it.isString }?.content
private fun JsonObject.long(k: String): Long? = (this[k] as? JsonPrimitive)?.takeIf { !it.isString }?.longOrNull
private fun JsonObject.bool(k: String): Boolean? = (this[k] as? JsonPrimitive)?.takeIf { !it.isString }?.booleanOrNull

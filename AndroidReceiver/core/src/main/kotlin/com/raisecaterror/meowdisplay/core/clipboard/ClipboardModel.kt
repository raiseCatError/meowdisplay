package com.raisecaterror.meowdisplay.core.clipboard

import com.raisecaterror.meowdisplay.core.workspace.RemoteFilesExport
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put
import java.io.File
import java.io.RandomAccessFile
import java.util.UUID

// The receiver's side of the Unified Clipboard (PROTOCOL.md 6.15) — the Kotlin twin of
// Shared/ClipboardClient.swift. Off until turned on here; the Mac's grant decides the rest.
// Content is never logged or kept after it is replaced.

data class ClipLocalFile(val name: String, val file: File)
data class ClipLocalContent(val items: List<List<Pair<ClipKind, ByteArray>>>, val files: List<ClipLocalFile>)

/** This device's clipboard (ClipboardManager in the app; a fake in tests). */
interface ClipboardPlatform {
    /** Changes whenever something is copied; null when it can't be told now (no focus). */
    fun changeToken(): Long?
    /** A copy from another device, for this device only. Returns the token it caused. */
    fun write(items: List<List<Pair<ClipKind, ByteArray>>>): Long?
    /** What is copied now; null when nothing usable (or marked sensitive). */
    fun read(textOnly: Boolean, maxBytes: Int, done: (ClipLocalContent?) -> Unit)
}

interface ClipboardSettingsStore { fun get(key: String): String?; fun set(key: String, value: String?) }

enum class MacClipState(val wire: String) { Unavailable("unavailable"), Off("off"), Idle("idle"), Asking("asking"), Denied("denied"), Ready("ready"), Paused("paused"), Revoked("revoked");
    companion object { fun of(s: String?) = entries.firstOrNull { it.wire == s } ?: Off }
}

data class ClipTransferNote(val atMs: Long, val fromMac: Boolean, val summary: String, val failure: String? = null)

data class ClipboardUi(
    val enabled: Boolean = false,
    val direction: ClipDirection = ClipDirection.Both,
    val types: ClipTypes = ClipTypes.All,
    val syncFiles: Boolean = true,
    val autoSend: Boolean = true,
    val maxBytes: Int = ClipboardWire.DEFAULT_MAX_BYTES,
    val macState: MacClipState = MacClipState.Unavailable,
    val toDevice: Boolean = false,
    val toMac: Boolean = false,
    val always: Boolean = false,
    val lastTransfer: ClipTransferNote? = null,
    val progress: Pair<Long, Long>? = null,
    val macFiles: ClipEvent? = null,
    val alternativeWaiting: Boolean = false,
    val localChangePending: Boolean = false,
    val export: RemoteFilesExport? = null,
    val notice: String? = null,
) {
    val ready: Boolean get() = enabled && macState == MacClipState.Ready
    val canSendToMac: Boolean get() = ready && toMac && direction.toMacAllowed
}

class ClipboardModel(
    origin: String,
    private val settings: ClipboardSettingsStore,
    private val send: (JsonObject) -> Boolean,
    private val scheduler: (Long, () -> Unit) -> (() -> Unit),
    private val tempRoot: File,
    private val now: () -> Long = System::currentTimeMillis,
) {
    private val _ui = MutableStateFlow(ClipboardUi(
        enabled = settings.get(K_ENABLED) == "1",
        direction = ClipDirection.of(settings.get(K_DIRECTION)) ?: ClipDirection.Both,
        types = ClipTypes.of(settings.get(K_TYPES)) ?: ClipTypes.All,
        syncFiles = settings.get(K_FILES) != "0",
        autoSend = settings.get(K_AUTO) != "0",
        maxBytes = settings.get(K_MAX)?.toIntOrNull()?.takeIf { it in ClipboardWire.SIZE_CHOICES } ?: ClipboardWire.DEFAULT_MAX_BYTES,
    ))
    val ui: StateFlow<ClipboardUi> = _ui.asStateFlow()
    var platform: ClipboardPlatform? = null

    private val sync = ClipboardSync(origin, settings.get(K_SEQ)?.toLongOrNull() ?: 0, settings.get(K_LAMPORT)?.toLongOrNull() ?: 0)
    private var available = false
    private var joined = false
    private var macMax = ClipboardWire.DEFAULT_MAX_BYTES
    private var macTypes = ClipTypes.All
    private var macFilesAllowed = false
    private var lastToken: Long? = null
    private var ownToken: Long? = null
    private val served = LinkedHashMap<ClipEventID, Map<Int, Any>>()   // ByteArray or File
    private var alternative: ClipEvent? = null
    private var job: Job? = null
    private var nextReq = 1

    init { tempRoot.deleteRecursively() }

    private class Job(val event: ClipEvent, val purpose: Purpose, val queue: ArrayDeque<Item>) {
        sealed interface Purpose { data object Apply : Purpose; data class Save(val mode: RemoteFilesExport.Mode) : Purpose; data object Alternative : Purpose }
        data class Item(val blob: Int, val size: Long, val hash: String?, val file: List<String>?)
        var fetch: ClipBlobFetch? = null
        val reps = HashMap<Int, java.io.ByteArrayOutputStream>()
        var dir: File? = null
        var out: java.io.FileOutputStream? = null
        val total = queue.sumOf { it.size }
        var done = 0L
        var lastActivity = 0L
        var cancelTimer: (() -> Unit)? = null
    }

    private val typesNow: ClipTypes get() = if (_ui.value.types == ClipTypes.Text || macTypes == ClipTypes.Text) ClipTypes.Text else ClipTypes.All
    private val maxNow: Int get() = minOf(_ui.value.maxBytes, macMax)
    private val filesAllowed: Boolean get() = _ui.value.syncFiles && macFilesAllowed && typesNow == ClipTypes.All
    private val canReceive: Boolean get() = available && _ui.value.ready && _ui.value.toDevice && _ui.value.direction.toDeviceAllowed

    // MARK: Settings

    fun setEnabled(on: Boolean) { settings.set(K_ENABLED, if (on) "1" else "0"); _ui.update { it.copy(enabled = on) }; settingsChanged() }
    fun setDirection(d: ClipDirection) { settings.set(K_DIRECTION, d.wire); _ui.update { it.copy(direction = d) }; settingsChanged() }
    fun setTypes(t: ClipTypes) { settings.set(K_TYPES, t.wire); _ui.update { it.copy(types = t) }; settingsChanged() }
    fun setSyncFiles(on: Boolean) { settings.set(K_FILES, if (on) "1" else "0"); _ui.update { it.copy(syncFiles = on) }; settingsChanged() }
    fun setAutoSend(on: Boolean) { settings.set(K_AUTO, if (on) "1" else "0"); _ui.update { it.copy(autoSend = on) } }
    fun setMaxBytes(n: Int) { settings.set(K_MAX, n.toString()); _ui.update { it.copy(maxBytes = n) }; settingsChanged() }

    private fun settingsChanged() {
        if (!_ui.value.enabled) { cancelJob(); _ui.update { it.copy(macFiles = null, localChangePending = false) } }
        sendJoin()
    }

    // MARK: Connection

    fun setAvailable(on: Boolean) {
        available = on
        joined = false
        if (on) {
            lastToken = platform?.changeToken()   // what is copied now is not a new copy
            sendJoin()
        } else {
            cancelJob()
            served.clear(); alternative = null
            tempRoot.deleteRecursively()
            _ui.update { it.copy(macState = MacClipState.Unavailable, toDevice = false, toMac = false, macFiles = null, alternativeWaiting = false, localChangePending = false) }
        }
    }

    private fun sendJoin() {
        if (!available) return
        val u = _ui.value
        if (!u.enabled) {
            if (joined) send(buildJsonObject { put("type", ClipboardWire.TYPE); put("op", "leave") })
            joined = false
            _ui.update { it.copy(macState = MacClipState.Idle) }
            return
        }
        joined = send(buildJsonObject {
            put("type", ClipboardWire.TYPE); put("op", "join"); put("on", true); put("dir", u.direction.wire); put("types", u.types.wire)
            put("files", u.syncFiles); put("max", u.maxBytes)
            put("seen", buildJsonObject { sync.seen.forEach { (k, v) -> put(k, v) } })
        })
    }

    // MARK: Messages from the Mac

    fun handle(m: JsonObject) {
        when (m.str("op")) {
            "state" -> applyState(m)
            "event" -> ClipEvent.parse(m)?.let(::receive)
            "read" -> serveRead(m)
            "data", "readEnd" -> jobMessage(m)
        }
    }

    private fun applyState(m: JsonObject) {
        val state = MacClipState.of(m.str("state"))
        val r = state == MacClipState.Ready
        macTypes = ClipTypes.of(m.str("types")) ?: ClipTypes.All
        macFilesAllowed = r && m.bool("files") == true
        macMax = (m.long("max") ?: ClipboardWire.DEFAULT_MAX_BYTES.toLong()).coerceIn(0, ClipboardWire.SIZE_CHOICES.last().toLong()).toInt()
        (m["seen"] as? JsonObject)?.let { seen ->
            sync.merge(seen.mapNotNull { (k, v) -> (v as? JsonPrimitive)?.longOrNull?.let { k to it.coerceAtLeast(0) } }.toMap())   // a reconnect is never a copy
            persist()
        }
        _ui.update { it.copy(macState = state, toDevice = r && m.bool("toDevice") == true, toMac = r && m.bool("toMac") == true,
            always = m.str("duration") == "always") }
        if (!r) cancelJob() else checkLocal(automatic = true)
    }

    private fun receive(e: ClipEvent) {
        if (!canReceive) return
        when (sync.receive(e.header)) {
            ClipboardSync.Decision.Apply -> { persist(); alternative = null; _ui.update { it.copy(alternativeWaiting = false) }; apply(e) }
            ClipboardSync.Decision.Alternative -> { persist(); alternative = e; _ui.update { it.copy(alternativeWaiting = true) } }
            else -> Unit
        }
    }

    private fun apply(e: ClipEvent) {
        val textOnly = typesNow == ClipTypes.Text
        val items = e.items.mapNotNull { item ->
            item.reps.filter { (!textOnly || it.kind.isText) && (it.inline != null || it.size <= maxNow) }.takeIf { it.isNotEmpty() }?.let(::ClipItem)
        }
        val files = if (filesAllowed && e.files.isNotEmpty()) e else null
        _ui.update { it.copy(macFiles = files) }
        if (items.isEmpty()) {
            note(true, e.summary, if (files == null) "Too large or not a type this device syncs" else null)
            return
        }
        val q = ArrayDeque<Job.Item>()
        items.forEach { i -> i.reps.forEach { r -> if (r.inline == null && r.blob != null) q.add(Job.Item(r.blob, r.size.toLong(), r.hash, null)) } }
        start(Job(e.copy(items = items, files = emptyList()), Job.Purpose.Apply, q))
    }

    // MARK: Fetching

    private fun start(j: Job) {
        cancelJob()
        job = j
        _ui.update { it.copy(progress = if (j.total > 0) 0L to j.total else null) }
        advance()
    }

    private fun cancelJob() {
        val j = job ?: return
        runCatching { j.out?.close() }
        j.cancelTimer?.invoke()
        j.dir?.deleteRecursively()
        job = null
        _ui.update { it.copy(progress = null) }
    }

    private fun advance() {
        val j = job ?: return
        j.fetch?.let { f -> f.nextRead()?.let { return sendRead(it, j) } }
        runCatching { j.out?.close() }; j.out = null
        val next = j.queue.removeFirstOrNull() ?: return finish(j, null)
        if (next.file != null) {
            val dir = j.dir ?: return finish(j, "noSpace")
            val f = next.file.fold(dir) { acc, n -> File(acc, n) }
            f.parentFile?.mkdirs()
            j.out = runCatching { java.io.FileOutputStream(f) }.getOrNull() ?: return finish(j, "noSpace")
        }
        if (next.size == 0L) { j.fetch = null; return advance() }
        val f = ClipBlobFetch(nextReq++, j.event.id, next.blob, next.size, next.hash)
        j.fetch = f
        sendRead(f.nextRead()!!, j)
    }

    private fun sendRead(read: JsonObject, j: Job) {
        j.lastActivity = now()
        if (!send(read)) return finish(j, "gone")
        j.cancelTimer?.invoke()
        j.cancelTimer = scheduler(16_000) { if (job === j && now() - j.lastActivity >= 15_000) finish(j, "timeout") }
    }

    private fun jobMessage(m: JsonObject) {
        val j = job ?: return
        val f = j.fetch ?: return
        if (m.long("req")?.toInt() != f.req) return
        j.lastActivity = now()
        when (val s = f.handle(m)) {
            is ClipBlobFetch.Step.More -> Unit
            is ClipBlobFetch.Step.RangeDone -> {
                if (f.done) j.fetch = null
                j.done += s.bytes.size
                val out = j.out
                if (out != null) out.write(s.bytes) else j.reps.getOrPut(f.blob) { java.io.ByteArrayOutputStream() }.write(s.bytes)
                _ui.update { it.copy(progress = j.done to j.total) }
                advance()
            }
            is ClipBlobFetch.Step.Failed -> finish(j, s.code)
        }
    }

    private fun finish(j: Job, failure: String?) {
        if (job !== j) return
        runCatching { j.out?.close() }; j.out = null
        j.cancelTimer?.invoke()
        job = null
        _ui.update { it.copy(progress = null) }
        if (failure != null) {
            j.dir?.deleteRecursively()
            note(true, j.event.summary, failureText(failure))
            return
        }
        when (val p = j.purpose) {
            Job.Purpose.Apply -> {
                if (!sync.isCurrent(j.event.id)) return   // a newer copy happened meanwhile
                writeToDevice(j.event, j.reps, own = true)
                note(true, j.event.summary, null)
            }
            Job.Purpose.Alternative -> sendLocal(ClipLocalContent(writeToDevice(j.event, j.reps, own = false), emptyList()))
            is Job.Purpose.Save -> {
                val dir = j.dir ?: return
                val tops = j.event.files.filter { it.path.size == 1 }.map { File(dir, it.path[0]) }
                _ui.update { it.copy(export = RemoteFilesExport(UUID.randomUUID().toString(), p.mode, tops, dir, 0)) }
            }
        }
    }

    private fun writeToDevice(e: ClipEvent, reps: Map<Int, java.io.ByteArrayOutputStream>, own: Boolean): List<List<Pair<ClipKind, ByteArray>>> {
        val items = e.items.map { item -> item.reps.mapNotNull { r -> (r.inline ?: r.blob?.let { reps[it]?.toByteArray() })?.let { r.kind to it } } }.filter { it.isNotEmpty() }
        val p = platform ?: return items
        if (items.isEmpty()) return items
        val token = p.write(items)
        if (own) { ownToken = token; lastToken = token }
        return items
    }

    // MARK: This device's copies

    /** The app got focus (or the Mac said ready): was something copied meanwhile? */
    fun checkLocal(automatic: Boolean) {
        val u = _ui.value
        if (!available || !u.canSendToMac) return
        val p = platform ?: return
        val token = p.changeToken() ?: return
        if (token == lastToken) return
        if (token == ownToken) { lastToken = token; return }
        if (automatic && !u.autoSend) { _ui.update { it.copy(localChangePending = true) }; return }
        lastToken = token
        _ui.update { it.copy(localChangePending = false) }
        p.read(typesNow == ClipTypes.Text, maxNow) { c -> if (c != null) sendLocal(c) }
    }

    fun sendLocal(content: ClipLocalContent) {
        if (!available || !_ui.value.canSendToMac) return
        _ui.update { it.copy(localChangePending = false) }
        lastToken = platform?.changeToken() ?: lastToken
        val sources = HashMap<Int, Any>()
        var blob = 0
        var inlineLeft = ClipboardWire.INLINE_BYTES
        val textOnly = typesNow == ClipTypes.Text
        val items = content.items.take(ClipboardWire.MAX_ITEMS).mapNotNull { reps ->
            reps.take(ClipboardWire.MAX_REPS).mapNotNull { (kind, data) ->
                if ((textOnly && !kind.isText) || data.size > maxNow) null
                else if (data.size <= inlineLeft) { inlineLeft -= data.size; ClipRep(kind, data.size, ClipHash.of(data), inline = data) }
                else { sources[blob] = data; ClipRep(kind, data.size, ClipHash.of(data), blob = blob++) }
            }.takeIf { it.isNotEmpty() }?.let(::ClipItem)
        }
        val files = if (!filesAllowed) emptyList() else content.files.take(64).filter { ClipFiles.isSafeName(it.name) }.map { f ->
            sources[blob] = f.file
            ClipFile(listOf(f.name), f.file.length(), false, blob++)
        }
        if (items.isEmpty() && files.isEmpty()) { note(false, "Copy", "Too large or not a type that syncs"); return }
        val h = sync.localCopy(ClipEvent.contentHash(items, files)) ?: return
        persist()
        alternative = null
        _ui.update { it.copy(alternativeWaiting = false) }
        val e = ClipEvent(h, now(), items, files)
        served[e.id] = sources
        while (served.size > 2) served.remove(served.keys.first())
        send(e.wire())
        note(false, e.summary, null)
    }

    private fun serveRead(m: JsonObject) {
        val req = m.long("req")?.toInt() ?: return
        val o = m.str("o") ?: return
        val s = m.long("s")?.takeIf { it > 0 } ?: return
        val b = m.long("b")?.toInt() ?: return
        val off = m.long("off")?.takeIf { it >= 0 } ?: return
        val n = m.long("n")?.toInt()?.takeIf { it in 1..ClipboardWire.READ_MAX } ?: return
        val source = served[ClipEventID(o, s)]?.get(b)
        if (!_ui.value.canSendToMac || source == null) { ClipBlobWire.answer(req, off, null, "gone").forEach { send(it) }; return }
        val frames = when (source) {
            is ByteArray -> if (off <= source.size) ClipBlobWire.answer(req, off, source.copyOfRange(off.toInt(), minOf(source.size, off.toInt() + n)))
                            else ClipBlobWire.answer(req, off, null, "badRange")
            is File -> runCatching {
                RandomAccessFile(source, "r").use { f ->
                    f.seek(off)
                    val buf = ByteArray(minOf(n.toLong(), (f.length() - off).coerceAtLeast(0)).toInt())
                    f.readFully(buf)
                    ClipBlobWire.answer(req, off, buf)
                }
            }.getOrElse { ClipBlobWire.answer(req, off, null, "gone") }
            else -> ClipBlobWire.answer(req, off, null, "gone")
        }
        frames.forEach { send(it) }
    }

    // MARK: Actions

    fun getMacFiles(mode: RemoteFilesExport.Mode) {
        val e = _ui.value.macFiles ?: return
        if (!canReceive) return
        val dir = File(tempRoot, UUID.randomUUID().toString()).apply { mkdirs() }
        e.files.filter { it.dir }.forEach { f -> f.path.fold(dir) { acc, n -> File(acc, n) }.mkdirs() }
        val q = ArrayDeque(e.files.filter { !it.dir && it.blob != null }.map { Job.Item(it.blob!!, it.size, null, it.path) })
        start(Job(e, Job.Purpose.Save(mode), q).also { it.dir = dir })
    }

    fun useAlternative() {
        val e = alternative ?: return
        if (!canReceive) return
        alternative = null
        sync.dropAlternative()
        _ui.update { it.copy(alternativeWaiting = false) }
        val q = ArrayDeque<Job.Item>()
        e.items.forEach { i -> i.reps.forEach { r -> if (r.inline == null && r.blob != null && r.size <= maxNow) q.add(Job.Item(r.blob, r.size.toLong(), r.hash, null)) } }
        start(Job(e.copy(files = emptyList()), Job.Purpose.Alternative, q))
    }

    fun exportFinished(e: RemoteFilesExport, completed: Boolean, keepForMs: Long = 0) {
        if (keepForMs > 0) scheduler(keepForMs) { e.directory.deleteRecursively() } else e.directory.deleteRecursively()
        _ui.update { it.copy(export = if (it.export?.id == e.id) null else it.export, notice = if (completed && e.mode == RemoteFilesExport.Mode.Save) "Saved to this device." else it.notice) }
    }

    fun dismissMacFiles() = _ui.update { it.copy(macFiles = null) }
    fun dismissNotice() = _ui.update { it.copy(notice = null) }
    fun cancelTransfer() = cancelJob()

    private fun note(fromMac: Boolean, summary: String, failure: String?) =
        _ui.update { it.copy(lastTransfer = ClipTransferNote(now(), fromMac, summary, failure)) }

    private fun persist() { settings.set(K_SEQ, sync.seq.toString()); settings.set(K_LAMPORT, sync.lamport.toString()) }

    companion object {
        private const val K_ENABLED = "clipboard.enabled"
        private const val K_DIRECTION = "clipboard.direction"
        private const val K_TYPES = "clipboard.types"
        private const val K_FILES = "clipboard.files"
        private const val K_AUTO = "clipboard.autoSend"
        private const val K_MAX = "clipboard.maxBytes"
        private const val K_SEQ = "clipboard.sync.seq"
        private const val K_LAMPORT = "clipboard.sync.lamport"

        fun failureText(code: String): String = when (code) {
            "timeout" -> "The Mac stopped answering"
            "changed" -> "The file changed on the Mac"
            "gone" -> "No longer available on the Mac"
            "denied" -> "The Mac doesn't allow this"
            "digest" -> "The data arrived damaged"
            "noSpace" -> "Not enough space on this device"
            else -> "Transfer failed"
        }
    }
}

private fun JsonObject.str(k: String): String? = (this[k] as? JsonPrimitive)?.takeIf { it.isString }?.content
private fun JsonObject.long(k: String): Long? = (this[k] as? JsonPrimitive)?.takeIf { !it.isString }?.longOrNull
private fun JsonObject.bool(k: String): Boolean? = (this[k] as? JsonPrimitive)?.takeIf { !it.isString }?.booleanOrNull

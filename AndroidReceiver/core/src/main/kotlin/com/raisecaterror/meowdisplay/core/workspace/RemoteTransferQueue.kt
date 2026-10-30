package com.raisecaterror.meowdisplay.core.workspace

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.put
import java.io.File
import java.io.InputStream
import java.io.RandomAccessFile
import java.security.MessageDigest
import java.util.Base64
import java.util.UUID

// Remote Finder transfers on the receiver (PROTOCOL.md 6.12): downloads into the app's private
// cache (to view in the app, save or share) and uploads from files the user picked. Bounded: a
// few transfers at a time, at most ~1 MiB in flight each, digests checked per range, a stall
// fails after a timeout with Retry, cancel removes partial files. The Mac checks every request.
// Mirrors iOS Shared/RemoteTransferQueue.swift. Main thread only.

enum class RemoteTransferPurpose(val wire: String) { View("view"), Save("save") }

/** How a name conflict on the Mac is answered. */
enum class RemoteFileConflictChoice(val wire: String) { Ask("ask"), Replace("replace"), KeepBoth("rename"), Skip("skip") }

/** A file picked on this device to upload: opened again on Retry. */
interface RemoteUploadSource {
    val name: String
    val size: Long
    /** Unix seconds, if known. */
    val modified: Long?
    fun open(): InputStream?
}

class RemoteLocalFileSource(private val file: File) : RemoteUploadSource {
    override val name: String get() = file.name
    override val size: Long get() = file.length()
    override val modified: Long? get() = file.lastModified().takeIf { it > 0 }?.div(1000)
    override fun open(): InputStream? = runCatching { file.inputStream() }.getOrNull()
}

data class RemoteTransferItem(
    val id: String,
    /** Null: an upload. */
    val purpose: RemoteTransferPurpose?,
    val name: String,
    val size: Long,
    val transferred: Long = 0,
    val state: State = State.Waiting,
    val bytesPerSecond: Double = 0.0,
    /** Download: the finished local copy. */
    val localFile: File? = null,
    /** Upload: the name it got on the Mac. */
    val resultName: String? = null,
    /** One user action (several files, a folder): conflicts can be answered for all of it. */
    val batch: String,
    val root: String,
    /** Download: the file. Upload: the destination folder. */
    val path: List<String>,
) {
    sealed interface State {
        data object Waiting : State
        data object Running : State
        /** An item with that name exists on the Mac: Replace, Keep Both or Skip. */
        data class Conflict(val suggest: String?) : State
        data object Done : State
        data object Skipped : State
        data class Failed(val code: String) : State
        data object Cancelled : State
    }

    val isUpload: Boolean get() = purpose == null
    val isFinished: Boolean get() = state == State.Done || state == State.Skipped || state == State.Cancelled || state is State.Failed
    val fraction: Double get() = if (size > 0) minOf(1.0, transferred.toDouble() / size) else if (state == State.Done) 1.0 else 0.0
}

class RemoteTransferQueue(
    private val send: (JsonObject) -> Boolean,
    /** Request ids come from the Finder model so they never collide with its own. */
    private val nextReq: () -> Int,
    private val scheduler: RemoteFilesScheduler,
    /** The app's private cache folder for copies from the Mac. */
    val cacheDir: File,
    private val now: () -> Long = { System.nanoTime() / 1_000_000 },
) {
    private val state = MutableStateFlow<List<RemoteTransferItem>>(emptyList())
    val items: StateFlow<List<RemoteTransferItem>> = state.asStateFlow()

    /** Called when an item finished in any way (a finished download carries `localFile`). */
    var onSettled: ((RemoteTransferItem) -> Unit)? = null
    /** An upload changed a folder on the Mac. */
    var onRemoteChange: ((root: String, path: List<String>) -> Unit)? = null

    companion object {
        const val RANGE_BYTES = 512 * 1024
        const val RANGES_IN_FLIGHT = 2
        /** Each `uploadData` stays under the 32 KB control-message limit once in base64. */
        const val UPLOAD_PART = 22_000
        const val UPLOAD_WINDOW = 16
        const val MAX_RUNNING = 2
        const val STALL_TIMEOUT_MS = 20_000L

        fun hex(bytes: ByteArray, count: Int = bytes.size) = bytes.take(count).joinToString("") { "%02x".format(it) }

        /** Reads up to [len] bytes (fewer only at the end); InputStream.readNBytes needs API 33. */
        fun readFully(src: InputStream, buf: ByteArray, len: Int): Int {
            var got = 0
            while (got < len) {
                val n = src.read(buf, got, len - got)
                if (n < 0) break
                got += n
            }
            return got
        }
    }

    private class Range(val o: Long, val n: Int) { val digest: MessageDigest = MessageDigest.getInstance("SHA-256") }

    private class Job {
        var x: Int? = null
        var req: Int? = null
        var file: RandomAccessFile? = null
        var source: InputStream? = null
        var upload: RemoteUploadSource? = null
        var nextRead = 0L
        /** Download: bytes from the start whose ranges matched their digests (Retry resumes here). */
        var verified = 0L
        val rangesOut = ArrayDeque<Range>()
        var rangeWritten = 0
        var acked = 0L
        var sent = 0L
        var digest: MessageDigest = MessageDigest.getInstance("SHA-256")
        var lastActivity = 0L
        var started = 0L
        var conflict = RemoteFileConflictChoice.Ask
        var version: Pair<Long, Long?>? = null
    }

    private val jobs = HashMap<String, Job>()
    private val batchConflict = HashMap<String, RemoteFileConflictChoice>()
    private var ticking = false

    val activeCount: Int get() = state.value.count { !it.isFinished }
    val firstConflict: RemoteTransferItem? get() = state.value.firstOrNull { it.state is RemoteTransferItem.State.Conflict }

    /** Copies left by an earlier run are never reused. */
    fun removeStaleCache() { cacheDir.deleteRecursively() }

    private fun item(id: String) = state.value.firstOrNull { it.id == id }
    private fun edit(id: String, f: (RemoteTransferItem) -> RemoteTransferItem) {
        state.value = state.value.map { if (it.id == id) f(it) else it }
    }

    // MARK: Adding

    fun download(root: String, path: List<String>, name: String, size: Long?, purpose: RemoteTransferPurpose, batch: String = UUID.randomUUID().toString()): String {
        if (purpose == RemoteTransferPurpose.View) {
            state.value.firstOrNull { it.purpose == purpose && it.root == root && it.path == path && !it.isFinished }?.let { return it.id }
        }
        val item = RemoteTransferItem(UUID.randomUUID().toString(), purpose, name, size ?: 0, batch = batch, root = root, path = path)
        state.value = state.value + item
        jobs[item.id] = Job()
        pump()
        return item.id
    }

    /** Uploads [source] into the folder [path] on the Mac. */
    fun upload(source: RemoteUploadSource, root: String, path: List<String>, batch: String = UUID.randomUUID().toString(), name: String = source.name): String {
        val item = RemoteTransferItem(UUID.randomUUID().toString(), null, name, source.size, batch = batch, root = root, path = path)
        state.value = state.value + item
        jobs[item.id] = Job().also { it.upload = source }
        pump()
        return item.id
    }

    fun cancel(id: String) {
        val i = item(id) ?: return
        if (!i.isFinished) finish(id, RemoteTransferItem.State.Cancelled)
    }

    fun retry(id: String) {
        val i = item(id) ?: return
        if (i.state !is RemoteTransferItem.State.Failed) return
        val old = jobs[id]
        val job = Job().also { it.upload = old?.upload; it.version = old?.version }
        // A download resumes after its last verified range when the Mac's file is the same version.
        val from = if (!i.isUpload && partialFile(id)?.exists() == true) old?.verified ?: 0 else 0
        job.nextRead = from
        job.verified = from
        edit(id) { it.copy(state = RemoteTransferItem.State.Waiting, bytesPerSecond = 0.0, transferred = from) }
        jobs[id] = job
        pump()
    }

    /** The user's answer to a name conflict (for this item, or every one in its batch). */
    fun resolveConflict(id: String, choice: RemoteFileConflictChoice, forAll: Boolean) {
        val i = item(id) ?: return
        if (i.state !is RemoteTransferItem.State.Conflict) return
        if (forAll) batchConflict[i.batch] = choice
        state.value = state.value.map { it ->
            if ((it.id == id || (forAll && it.batch == i.batch)) && it.state is RemoteTransferItem.State.Conflict) {
                jobs[it.id]?.conflict = choice
                it.copy(state = RemoteTransferItem.State.Waiting)
            } else it
        }
        pump()
    }

    fun clearFinished() {
        val gone = state.value.filter { it.isFinished && it.purpose != RemoteTransferPurpose.View }
        gone.forEach { jobs.remove(it.id) }
        state.value = state.value - gone.toSet()
    }

    /** Access ended or the connection went: unfinished transfers fail with [code]. */
    fun failRunning(code: String) {
        state.value.filter { !it.isFinished }.forEach { fail(it.id, code) }
    }

    /** Copies for viewing go when the browser closes or the session ends. */
    fun purgeViewCache() {
        state.value.filter { it.purpose == RemoteTransferPurpose.View }.forEach { v ->
            if (!v.isFinished) cancel(v.id)
            File(cacheDir, v.id).deleteRecursively()
            jobs.remove(v.id)
        }
        state.value = state.value.filter { it.purpose != RemoteTransferPurpose.View }
    }

    // MARK: Scheduling

    private fun pump() {
        var slots = MAX_RUNNING - state.value.count { it.state == RemoteTransferItem.State.Running }
        for (i in state.value) {
            if (slots <= 0) break
            if (i.state == RemoteTransferItem.State.Waiting) { start(i.id); slots-- }
        }
        tick()
    }

    private fun tick() {
        if (ticking || state.value.none { it.state == RemoteTransferItem.State.Running }) return
        ticking = true
        scheduler.after(1_000) {
            ticking = false
            val t = now()
            state.value.filter { it.state == RemoteTransferItem.State.Running }.forEach { i ->
                val job = jobs[i.id] ?: return@forEach
                if (t - job.lastActivity > STALL_TIMEOUT_MS) fail(i.id, "timeout")
            }
            tick()
        }
    }

    private fun start(id: String) {
        val job = jobs[id] ?: return
        edit(id) { it.copy(state = RemoteTransferItem.State.Running) }
        val i = item(id) ?: return
        job.started = now(); job.lastActivity = now()
        val r = nextReq()
        job.req = r
        if (!i.isUpload) {
            send(RemoteFilesWire.request("download", r) {
                put("root", i.root); put("path", RemoteFilesWire.names(i.path)); put("purpose", i.purpose!!.wire)
            })
        } else {
            if (job.conflict == RemoteFileConflictChoice.Ask) batchConflict[i.batch]?.let { job.conflict = it }
            val src = job.upload?.open() ?: return fail(id, "unreadable")
            job.source = src
            send(RemoteFilesWire.request("uploadBegin", r) {
                put("root", i.root); put("path", RemoteFilesWire.names(i.path)); put("name", i.name); put("size", i.size)
                put("conflict", job.conflict.wire)
                job.upload?.modified?.let { put("mod", it) }
            })
        }
    }

    private fun finish(id: String, end: RemoteTransferItem.State) {
        val i = item(id) ?: return
        val job = jobs[id]
        job?.x?.let { x ->
            if (!i.isUpload) send(RemoteFilesWire.request("close", nextReq()) { put("x", x) })
            else if (end != RemoteTransferItem.State.Done) send(RemoteFilesWire.request("uploadCancel", nextReq()) { put("x", x) })
        }
        runCatching { job?.file?.close() }
        runCatching { job?.source?.close() }
        job?.file = null; job?.source = null; job?.x = null; job?.rangesOut?.clear(); job?.rangeWritten = 0
        var local = i.localFile
        // A failed download keeps its part for Retry to resume; anything else unfinished goes.
        if (!i.isUpload && end != RemoteTransferItem.State.Done && end !is RemoteTransferItem.State.Failed) {
            File(cacheDir, id).deleteRecursively(); local = null
        }
        edit(id) { it.copy(state = end, localFile = local) }
        val settled = item(id)!!
        pump()
        onSettled?.invoke(settled)
    }

    private fun fail(id: String, code: String) {
        val i = item(id) ?: return
        if (i.isFinished) return
        finish(id, RemoteTransferItem.State.Failed(code))
    }

    private fun partialFile(id: String): File? {
        val i = item(id) ?: return null
        val safe = i.name.replace('/', '_').replace(':', '_').replace('\u0000', '_').takeIf { it.isNotEmpty() && it != "." && it != ".." } ?: "file"
        return File(File(cacheDir, id), safe)
    }

    private fun touch(id: String, bytes: Long) {
        val job = jobs[id] ?: return
        job.lastActivity = now()
        edit(id) {
            val t = it.transferred + bytes
            it.copy(transferred = t, bytesPerSecond = t / (maxOf(now() - job.started, 250L) / 1000.0))
        }
    }

    // MARK: Replies

    /** A Files reply that belongs to a transfer: true when it was one. */
    fun apply(r: RemoteFilesReply): Boolean = when (r.op) {
        "download" -> onDownloadOpened(r)
        "data" -> onData(r)
        "read" -> onRangeDone(r)
        "uploadBegin" -> onUploadBegun(r)
        "uploadAck" -> onUploadAck(r)
        "uploadEnd" -> onUploadEnded(r)
        else -> false
    }

    private fun byReq(req: Int?) = req?.let { q -> jobs.entries.firstOrNull { it.value.req == q } }
    private fun byX(x: Int?) = x?.let { v -> jobs.entries.firstOrNull { it.value.x == v } }

    private fun onDownloadOpened(r: RemoteFilesReply): Boolean {
        val (id, job) = byReq(r.req) ?: return false
        val i = item(id) ?: return true
        if (i.state != RemoteTransferItem.State.Running || i.isUpload) return true
        val x = r.x; val size = r.size
        if (!r.ok || x == null || size == null) { fail(id, r.error ?: "failed"); return true }
        job.version?.let { v -> if (v.first != size || v.second != r.mod) { job.nextRead = 0; job.verified = 0; edit(id) { it.copy(transferred = 0) } } }
        job.version = size to r.mod
        job.x = x
        val file = partialFile(id) ?: run { fail(id, "failed"); return true }
        try {
            file.parentFile?.mkdirs()
            if (job.nextRead == 0L || !file.exists()) { job.nextRead = 0; job.verified = 0; edit(id) { it.copy(transferred = 0) }; file.delete(); file.createNewFile() }
            val raf = RandomAccessFile(file, "rw")
            raf.setLength(job.nextRead)
            raf.seek(job.nextRead)
            job.file = raf
        } catch (e: Exception) { fail(id, "storage"); return true }
        edit(id) { it.copy(size = size, localFile = file) }
        if (size == 0L) finishDownload(id) else requestRanges(id)
        return true
    }

    private fun requestRanges(id: String) {
        val job = jobs[id] ?: return
        val x = job.x ?: return
        val size = item(id)?.size ?: return
        while (job.rangesOut.size < RANGES_IN_FLIGHT && job.nextRead < size) {
            val n = minOf(RANGE_BYTES.toLong(), size - job.nextRead).toInt()
            job.rangesOut.addLast(Range(job.nextRead, n))
            val o = job.nextRead
            send(RemoteFilesWire.request("read", nextReq()) { put("x", x); put("o", o); put("n", n) })
            job.nextRead += n
        }
    }

    private fun onData(r: RemoteFilesReply): Boolean {
        val (id, job) = byX(r.x) ?: return false
        if (item(id)?.isUpload != false) return false
        val range = job.rangesOut.firstOrNull()
        val data = r.dataBase64?.let { runCatching { Base64.getDecoder().decode(it) }.getOrNull() }
        if (range == null || data == null || r.offset != range.o + job.rangeWritten || job.rangeWritten + data.size > range.n) {
            fail(id, "badData"); return true
        }
        try { job.file?.write(data) } catch (e: Exception) { fail(id, "storage"); return true }
        range.digest.update(data)
        job.rangeWritten += data.size
        touch(id, data.size.toLong())
        return true
    }

    private fun onRangeDone(r: RemoteFilesReply): Boolean {
        val (id, job) = byX(r.x) ?: return false
        if (item(id)?.isUpload != false) return false
        if (!r.ok) { fail(id, r.error ?: "failed"); return true }
        val range = job.rangesOut.firstOrNull()
        if (range == null || r.offset != range.o || job.rangeWritten != range.n) { fail(id, "badData"); return true }
        if (hex(range.digest.digest(), 8) != r.sha) { fail(id, "digest"); return true }
        job.rangesOut.removeFirst()
        job.rangeWritten = 0
        job.verified = range.o + range.n
        val i = item(id) ?: return true
        if (i.transferred >= i.size && job.rangesOut.isEmpty()) finishDownload(id) else requestRanges(id)
        return true
    }

    private fun finishDownload(id: String) {
        runCatching { jobs[id]?.file?.fd?.sync() }
        finish(id, RemoteTransferItem.State.Done)
    }

    private fun onUploadBegun(r: RemoteFilesReply): Boolean {
        val (id, job) = byReq(r.req) ?: return false
        val i = item(id) ?: return true
        if (i.state != RemoteTransferItem.State.Running) return true
        if (r.skipped) { edit(id) { it.copy(resultName = r.name) }; finish(id, RemoteTransferItem.State.Skipped); return true }
        val x = r.x
        if (!r.ok || x == null) {
            if (r.error == "exists") {
                runCatching { job.source?.close() }; job.source = null
                edit(id) { it.copy(state = RemoteTransferItem.State.Conflict(r.suggest)) }
                pump()
            } else fail(id, r.error ?: "failed")
            return true
        }
        job.x = x
        edit(id) { it.copy(resultName = r.name) }
        sendParts(id)
        return true
    }

    private fun sendParts(id: String) {
        val job = jobs[id] ?: return
        val x = job.x ?: return
        val src = job.source ?: return
        val size = item(id)?.size ?: return
        val buf = ByteArray(UPLOAD_PART)
        while (job.sent < size && job.sent - job.acked < UPLOAD_PART.toLong() * UPLOAD_WINDOW) {
            val n = try { readFully(src, buf, minOf(UPLOAD_PART.toLong(), size - job.sent).toInt()) } catch (e: Exception) { -1 }
            if (n <= 0) return fail(id, "unreadable")
            job.digest.update(buf, 0, n)
            val o = job.sent
            val d = Base64.getEncoder().encodeToString(buf.copyOf(n))
            send(RemoteFilesWire.request("uploadData", nextReq()) { put("x", x); put("o", o); put("d", d) })
            job.sent += n
        }
        if (size == 0L || (job.sent >= size && job.acked >= size)) {
            val sha = hex(job.digest.digest())
            val r = nextReq()
            job.req = r
            send(RemoteFilesWire.request("uploadEnd", r) { put("x", x); put("sha", sha) })
        }
    }

    private fun onUploadAck(r: RemoteFilesReply): Boolean {
        val (id, job) = byX(r.x) ?: return false
        if (item(id)?.isUpload != true) return false
        val o = r.offset
        if (!r.ok || o == null) { fail(id, r.error ?: "failed"); return true }
        val delta = o - job.acked
        job.acked = o
        touch(id, maxOf(0, delta))
        sendParts(id)
        return true
    }

    private fun onUploadEnded(r: RemoteFilesReply): Boolean {
        val (id, _) = byReq(r.req) ?: return false
        val i = item(id) ?: return true
        if (!r.ok) { fail(id, r.error ?: "failed"); return true }
        edit(id) { it.copy(resultName = r.name ?: it.resultName) }
        finish(id, RemoteTransferItem.State.Done)
        onRemoteChange?.invoke(i.root, i.path)
        return true
    }
}

/**
 * Random-access reads of one open Mac file (`download` with purpose `view`) for a player that
 * asks for byte ranges as it plays and seeks. The Mac answers reads in order, so parts match
 * first in, first out; each range is digest-checked; a stalled read fails. Main thread only.
 */
class RemoteFileStream(
    val x: Int,
    val size: Long,
    val mime: String?,
    private val send: (JsonObject) -> Boolean,
    private val nextReq: () -> Int,
    private val scheduler: RemoteFilesScheduler,
    private val now: () -> Long = { System.nanoTime() / 1_000_000 },
) {
    private class Read(val o: Long, val n: Int, val asked: Long, val done: (ByteArray?) -> Unit) {
        val data = java.io.ByteArrayOutputStream(n)
        val digest: MessageDigest = MessageDigest.getInstance("SHA-256")
    }

    private val reads = ArrayDeque<Read>()
    var failed: String? = null
        private set
    private var watching = false

    companion object {
        const val READ_BYTES = 256 * 1024
        const val MAX_IN_FLIGHT = 6
        const val TIMEOUT_MS = 20_000L
    }

    val canRead: Boolean get() = failed == null && reads.size < MAX_IN_FLIGHT

    /** Reads [n] bytes at [o] (clamped to the file); [done] gets null when it failed. */
    fun read(o: Long, n: Int, done: (ByteArray?) -> Unit) {
        if (failed != null) return done(null)
        if (o >= size) return done(ByteArray(0))
        if (o < 0 || n <= 0) return done(null)
        val len = minOf(minOf(n, 1 shl 20).toLong(), size - o).toInt()
        reads.addLast(Read(o, len, now(), done))
        if (!send(RemoteFilesWire.request("read", nextReq()) { put("x", x); put("o", o); put("n", len) })) return fail("disconnected")
        watch()
    }

    fun apply(r: RemoteFilesReply) {
        if (failed != null) return
        val first = reads.firstOrNull() ?: return
        when (r.op) {
            "data" -> {
                val d = r.dataBase64?.let { runCatching { Base64.getDecoder().decode(it) }.getOrNull() }
                if (d == null || r.offset != first.o + first.data.size() || first.data.size() + d.size > first.n) return fail("badData")
                first.data.write(d); first.digest.update(d)
            }
            "read" -> {
                if (!r.ok) return fail(r.error ?: "failed")
                if (r.offset != first.o || first.data.size() != first.n || RemoteTransferQueue.hex(first.digest.digest(), 8) != r.sha) return fail("digest")
                reads.removeFirst()
                first.done(first.data.toByteArray())
            }
        }
    }

    fun fail(code: String) {
        if (failed != null) return
        failed = code
        val pending = reads.toList()
        reads.clear()
        pending.forEach { it.done(null) }
    }

    fun close() {
        fail("closed")
        send(RemoteFilesWire.request("close", nextReq()) { put("x", x) })
    }

    private fun watch() {
        if (watching) return
        watching = true
        scheduler.after(2_000) {
            watching = false
            val first = reads.firstOrNull() ?: return@after
            if (now() - first.asked > TIMEOUT_MS) fail("timeout") else watch()
        }
    }
}

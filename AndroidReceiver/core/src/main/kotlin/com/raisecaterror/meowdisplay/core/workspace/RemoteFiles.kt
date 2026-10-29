package com.raisecaterror.meowdisplay.core.workspace

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonObjectBuilder
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put
import java.io.File

// Remote Finder on the receiver (PROTOCOL.md 6.12): a Finder-like browser of what the Mac's
// owner allowed this device to reach. Everything is read and checked on the Mac; this side asks,
// draws, caches a bounded number of previews and moves files through RemoteTransferQueue. What it
// may change follows the Mac's grant (`state.grant`); the Mac refuses anything else. Mirrors iOS
// Shared/RemoteFiles.swift and Shared/RemoteFilesActions.swift.

object RemoteFilesWire {
    const val WELCOME_FEATURE = "files"
    const val REQUEST = "filesRequest"
    const val REPLY = "files"
    /** A 1600-sided JPEG preview. */
    const val MAX_BASE64 = 3_000_000

    fun request(op: String, req: Int, body: JsonObjectBuilder.() -> Unit = {}) = buildJsonObject {
        put("type", REQUEST); put("op", op); put("req", req); body()
    }

    internal fun names(list: List<String>) = buildJsonArray { list.forEach { add(JsonPrimitive(it)) } }
}

enum class RemoteFileKind(val wire: String) {
    Folder("folder"), App("app"), Image("image"), Video("video"), Audio("audio"), Pdf("pdf"),
    Archive("archive"), Text("text"), Document("document"), File("file");

    /** Quick Look can draw a useful still of it. */
    val hasThumbnail get() = this == Image || this == Video || this == Pdf || this == Document

    companion object { fun of(s: String?) = entries.firstOrNull { it.wire == s } }
}

data class RemoteFileEntry(
    val name: String,
    val isDirectory: Boolean,
    val kind: RemoteFileKind,
    val size: Long? = null,
    /** Unix seconds. */
    val modified: Long? = null,
    /** Search results: the folder it is in, below [root]. */
    val location: List<String>? = null,
    val root: String? = null,
    val created: Long? = null,
    val hidden: Boolean = false,
    /** The Mac can't write it. */
    val readOnly: Boolean = false,
) {
    val id: String get() = (root ?: "") + "/" + (location ?: emptyList()).joinToString("/") + "/" + name
}

data class RemoteFileRoot(val id: String, val name: String)

/** What this device may do on the Mac's files (`state.grant`), for the indicator and the menus. */
data class RemoteFilesGrant(
    val always: Boolean = false,
    val allFiles: Boolean = false,
    val capabilities: Set<String> = setOf("browse", "download"),
    val hidden: Boolean = false,
) {
    val canDownload get() = "download" in capabilities
    val canUpload get() = "upload" in capabilities
    val canModify get() = "modify" in capabilities
    val canDelete get() = "delete" in capabilities
    val readOnly get() = !canUpload && !canModify && !canDelete

    companion object {
        fun parse(o: JsonObject) = RemoteFilesGrant(
            always = o.s("duration") == "always",
            allFiles = o.s("scope") == "allAccessible",
            capabilities = (o["caps"] as? JsonArray).orEmpty().take(8).mapNotNull { (it as? JsonPrimitive)?.content?.take(16) }.toSet(),
            hidden = o.b("hidden") == true,
        )
    }
}

data class RemoteFileInfo(
    val name: String, val kind: String, val owner: String, val permissions: String,
    val size: Long?, val items: Int?, val complete: Boolean,
    val created: Long?, val modified: Long?, val opened: Long?,
    val writable: Boolean, val locked: Boolean, val cloud: String?,
) {
    companion object {
        fun parse(o: JsonObject) = RemoteFileInfo(
            (o.s("name") ?: "").take(255), (o.s("kind") ?: "").take(100), (o.s("owner") ?: "").take(64), (o.s("perm") ?: "").take(8),
            o.l("size"), o.i("items"), o.b("complete") != false, o.l("made"), o.l("mod"), o.l("used"),
            o.b("writable") == true, o.b("locked") == true, o.s("cloud")?.take(16),
        )
    }
}

data class RemoteOpenWithApp(val bundleID: String, val name: String, val isDefault: Boolean)

/** One `files` message from the Mac, parsed defensively and bounded. */
data class RemoteFilesReply(
    val op: String,
    val req: Int? = null,
    val ok: Boolean = true,
    val error: String? = null,
    val state: String? = null,
    val roots: List<RemoteFileRoot> = emptyList(),
    val root: String? = null,
    val path: List<String> = emptyList(),
    val entries: List<RemoteFileEntry> = emptyList(),
    val truncated: Boolean = false,
    val complete: Boolean = true,
    val query: String? = null,
    val text: String? = null,
    val jpegBase64: String? = null,
    val name: String? = null,
    /** Transfers (6.12): the Mac's transfer id, an offset, a size, a part (base64), a range digest. */
    val x: Int? = null,
    val offset: Long? = null,
    val length: Int? = null,
    val size: Long? = null,
    val dataBase64: String? = null,
    val sha: String? = null,
    val mod: Long? = null,
    val mime: String? = null,
    val uti: String? = null,
    val skipped: Boolean = false,
    val suggest: String? = null,
    val need: String? = null,
    val token: String? = null,
    val grant: RemoteFilesGrant? = null,
    val info: RemoteFileInfo? = null,
    val apps: List<RemoteOpenWithApp> = emptyList(),
) {
    companion object {
        /** A reply made here: the request failed before the Mac answered. */
        fun failure(op: String, code: String) = RemoteFilesReply(op, ok = false, error = code)

        fun parse(obj: JsonObject): RemoteFilesReply? {
            val op = obj.s("op")?.takeIf { it.length <= 16 } ?: return null
            val root = obj.s("root")?.take(64)
            fun names(k: String, o: JsonObject = obj) = (o[k] as? JsonArray).orEmpty().take(64).mapNotNull { (it as? JsonPrimitive)?.takeIf { p -> p.isString }?.content?.take(255) }
            return RemoteFilesReply(
                op = op,
                req = obj.i("req"),
                ok = obj.b("ok") ?: (obj["error"] == null),
                error = obj.s("error")?.take(32),
                state = obj.s("state")?.take(16),
                roots = (obj["roots"] as? JsonArray).orEmpty().take(32).mapNotNull { (it as? JsonObject) }.mapNotNull { o ->
                    val id = o.s("id")?.takeIf { it.isNotEmpty() } ?: return@mapNotNull null
                    RemoteFileRoot(id.take(64), (o.s("name") ?: id).take(120))
                },
                root = root,
                path = names("path"),
                entries = (obj["entries"] as? JsonArray).orEmpty().take(2000).mapNotNull { it as? JsonObject }.mapNotNull { e ->
                    val name = e.s("name")?.takeIf { it.isNotEmpty() } ?: return@mapNotNull null
                    val dir = e.b("dir") == true
                    val inFolder = if (e["in"] != null) names("in", e) else null
                    RemoteFileEntry(name.take(255), dir, RemoteFileKind.of(e.s("kind")) ?: if (dir) RemoteFileKind.Folder else RemoteFileKind.File,
                        e.l("size"), e.l("mod"), inFolder, if (inFolder != null) root else null,
                        created = e.l("made"), hidden = e.b("hidden") == true, readOnly = e.b("ro") == true)
                },
                truncated = obj.b("truncated") == true,
                complete = obj.b("complete") != false,
                query = obj.s("q")?.take(100),
                text = obj.s("text")?.take(40_000),
                jpegBase64 = obj.s("jpeg")?.takeIf { it.length <= RemoteFilesWire.MAX_BASE64 },
                name = obj.s("name")?.take(255),
                x = obj.i("x"),
                offset = obj.l("o"),
                length = obj.i("n"),
                size = obj.l("size"),
                dataBase64 = obj.s("d")?.takeIf { it.length <= 40_000 },
                sha = obj.s("sha")?.take(64),
                mod = obj.l("mod"),
                mime = obj.s("mime")?.take(100),
                uti = obj.s("uti")?.take(200),
                skipped = obj.b("skipped") == true,
                suggest = obj.s("suggest")?.take(255),
                need = obj.s("need")?.take(16),
                token = obj.s("token")?.take(64),
                grant = (obj["grant"] as? JsonObject)?.let(RemoteFilesGrant::parse),
                info = (obj["info"] as? JsonObject)?.let(RemoteFileInfo::parse),
                apps = (obj["apps"] as? JsonArray).orEmpty().take(24).mapNotNull { it as? JsonObject }.mapNotNull { a ->
                    val b = a.s("bundle") ?: return@mapNotNull null
                    RemoteOpenWithApp(b.take(255), (a.s("name") ?: return@mapNotNull null).take(100), a.b("default") == true)
                },
            )
        }
    }
}

/** What the browser shows: the approved folders, one folder, or the Mac's apps. */
sealed interface RemoteFilesLocation {
    data object Locations : RemoteFilesLocation
    data object Applications : RemoteFilesLocation
    data class Folder(val root: String, val path: List<String>) : RemoteFilesLocation
}

enum class RemoteFilesAccess { Unknown, Off, Asking, Denied, NoFolders, Ready, Revoked }
enum class RemoteFilesStyle { List, Grid }
enum class RemoteFilesSort { Name, Date, Size, Kind }

enum class RemoteFileKindFilter {
    All, Folders, Images, Movies, Audio, Documents, Archives;

    fun matches(e: RemoteFileEntry) = when (this) {
        All -> true
        Folders -> e.isDirectory && e.kind != RemoteFileKind.App
        Images -> e.kind == RemoteFileKind.Image
        Movies -> e.kind == RemoteFileKind.Video
        Audio -> e.kind == RemoteFileKind.Audio
        Documents -> e.kind == RemoteFileKind.Pdf || e.kind == RemoteFileKind.Text || e.kind == RemoteFileKind.Document
        Archives -> e.kind == RemoteFileKind.Archive
    }
}

object RemoteFilesSorting {
    private val numbers = Regex("\\d+|\\D+")

    /** Finder's name order: numbers by value, case ignored. */
    fun compareNames(a: String, b: String): Int {
        val x = numbers.findAll(a.lowercase()).map { it.value }.toList()
        val y = numbers.findAll(b.lowercase()).map { it.value }.toList()
        for (i in 0 until minOf(x.size, y.size)) {
            val p = x[i]; val q = y[i]
            val c = if (p[0].isDigit() && q[0].isDigit()) (p.toBigInteger().compareTo(q.toBigInteger())).takeIf { it != 0 } ?: p.length.compareTo(q.length)
                    else p.compareTo(q)
            if (c != 0) return c
        }
        return x.size.compareTo(y.size)
    }

    fun sorted(entries: List<RemoteFileEntry>, by: RemoteFilesSort, ascending: Boolean): List<RemoteFileEntry> {
        val byName = Comparator<RemoteFileEntry> { a, b -> compareNames(a.name, b.name) }
        val c: Comparator<RemoteFileEntry> = when (by) {
            RemoteFilesSort.Name -> byName
            RemoteFilesSort.Date -> compareBy<RemoteFileEntry> { it.modified ?: Long.MIN_VALUE }.then(byName)
            // Folders have no size: they come before files.
            RemoteFilesSort.Size -> compareBy<RemoteFileEntry> { if (it.isDirectory) -1L else it.size ?: 0L }.then(byName)
            RemoteFilesSort.Kind -> compareBy<RemoteFileEntry> { RemoteFilesFormat.kindName(it.kind) }.then(byName)
        }
        val list = entries.sortedWith(c)
        return if (ascending) list else list.reversed()
    }
}

object RemoteFilesFormat {
    fun kindName(kind: RemoteFileKind) = when (kind) {
        RemoteFileKind.Folder -> "Folder"; RemoteFileKind.App -> "Application"; RemoteFileKind.Image -> "Image"; RemoteFileKind.Video -> "Movie"
        RemoteFileKind.Audio -> "Audio"; RemoteFileKind.Pdf -> "PDF Document"; RemoteFileKind.Archive -> "Archive"; RemoteFileKind.Text -> "Text"
        RemoteFileKind.Document -> "Document"; RemoteFileKind.File -> "File"
    }

    fun capabilityName(need: String) = when (need) {
        "download" -> "saving and sharing copies"
        "upload" -> "uploading and new folders"
        "modify" -> "renaming, moving and copying"
        "delete" -> "moving to the Trash"
        else -> "browsing"
    }

    fun errorText(code: String?) = when (code) {
        "exists" -> "An item with that name already exists."
        "noSpace" -> "There isn't enough space."
        "tooLarge" -> "That file is too large."
        "permission" -> "macOS didn't allow MeowDisplay to do that on the Mac."
        "notFound" -> "It isn't there any more."
        "readOnly" -> "That location can't be changed."
        "intoItself" -> "A folder can't go inside itself."
        "busy" -> "The Mac is busy with other transfers. Try again shortly."
        "changed" -> "The file changed on the Mac while it was copied."
        "digest", "badData", "short" -> "The copy didn't arrive intact. Try again."
        "timeout" -> "The Mac didn't answer."
        "disconnected" -> "The Mac disconnected."
        "revoked", "denied", "off" -> "Files access on the Mac ended."
        "storage" -> "This device couldn't store the copy."
        "unreadable" -> "This device couldn't read that file."
        "unsupported", "noPreview" -> "That isn't supported for this item."
        "control" -> "Ask for control of the Mac first."
        else -> "The Mac couldn't do that."
    }

    /** Names a person typed: trimmed, no separators, not hidden by accident. */
    fun cleanName(raw: String): String? {
        val name = raw.trim().replace('/', '-').replace(':', '-')
        if (name.isEmpty() || name == "." || name == ".." || name.startsWith(".") || name.length > 255) return null
        return name
    }
}

sealed interface RemotePreviewContent {
    data object Loading : RemotePreviewContent
    data class Image(val jpegBase64: String) : RemotePreviewContent
    data class Text(val text: String, val truncated: Boolean) : RemotePreviewContent
    data object Unavailable : RemotePreviewContent
    data class Failed(val code: String) : RemotePreviewContent
}

data class RemotePreview(val entry: RemoteFileEntry, val root: String, val path: List<String>, val content: RemotePreviewContent) {
    val key: String get() = root + "/" + path.joinToString("/")
}

/** A file shown inside this app: streamed for playback, or a private copy (PDF pages, full-size image). */
data class RemoteFileViewer(val previewKey: String, val entry: RemoteFileEntry, val content: Content, val transferID: String? = null) {
    sealed interface Content {
        data object Loading : Content
        data class Stream(val x: Int, val size: Long, val mime: String?) : Content
        data class Local(val file: File) : Content
        data class Failed(val code: String) : Content
    }
}

/** Files copied to this device, ready to save (system picker) or share (share sheet). */
data class RemoteFilesExport(val id: String, val mode: Mode, val files: List<File>, val directory: File, val failed: Int) {
    enum class Mode { Save, Share }
}

/** Items copied or cut here, to paste into another folder on the Mac. */
data class RemoteFilesClipboard(val move: Boolean, val root: String, val folder: List<String>, val names: List<String>)

data class RemoteFavorite(val root: String, val path: List<String>, val name: String) {
    val id: String get() = root + "/" + path.joinToString("/")
}

/** A folder picked on this device to upload: its subfolders and files, relative to it. */
data class RemoteUploadFolder(val name: String, val folders: List<List<String>>, val files: List<Pair<RemoteUploadSource, List<String>>>)

enum class RemoteFolderConflictChoice { Merge, KeepBoth, Skip }

sealed interface RemoteFilesNotice {
    data class Opened(val name: String) : RemoteFilesNotice
    data object NeedsControl : RemoteFilesNotice
    data object OpenFailed : RemoteFilesNotice
    /** Something finished or failed (already worded). */
    data class Text(val text: String) : RemoteFilesNotice
    /** Moved to the Trash, with Put Back tokens for Undo. */
    data class Trashed(val count: Int, val tokens: List<String>) : RemoteFilesNotice
    /** The Mac's grant doesn't include this capability: offer to ask for it. */
    data class Needs(val capability: String) : RemoteFilesNotice
}

data class RemoteFileInfoSheet(val entry: RemoteFileEntry, val info: RemoteFileInfo)

data class RemoteFilesUi(
    /** The connected Mac offers Remote Finder (welcome feature `files`). */
    val available: Boolean = false,
    val isOpen: Boolean = false,
    val access: RemoteFilesAccess = RemoteFilesAccess.Unknown,
    val roots: List<RemoteFileRoot> = emptyList(),
    val location: RemoteFilesLocation = RemoteFilesLocation.Locations,
    val canGoBack: Boolean = false,
    val entries: List<RemoteFileEntry> = emptyList(),
    val loading: Boolean = false,
    /** `notFound`, `permission` or another error code from the Mac, for the current folder. */
    val folderError: String? = null,
    val truncated: Boolean = false,
    val query: String = "",
    val results: List<RemoteFileEntry> = emptyList(),
    val searching: Boolean = false,
    val searchComplete: Boolean = true,
    val preview: RemotePreview? = null,
    /** Grid stills by [RemoteFilesModel.thumbnailKey], as JPEG base64 (decoded by the UI). */
    val thumbnails: Map<String, String> = emptyMap(),
    val notice: RemoteFilesNotice? = null,
    /** The entry to point out after "Show in Folder". */
    val highlighted: String? = null,
    val style: RemoteFilesStyle = RemoteFilesStyle.List,
    /** What this device may do on the Mac; null until browsing is allowed. */
    val grant: RemoteFilesGrant? = null,
    val sort: RemoteFilesSort = RemoteFilesSort.Name,
    val ascending: Boolean = true,
    /** Hidden files the Mac lists (only when its owner allows it) are shown. */
    val showHidden: Boolean = false,
    val kindFilter: RemoteFileKindFilter = RemoteFileKindFilter.All,
    val selecting: Boolean = false,
    /** Selected entries of the current folder, by [RemoteFileEntry.id]. */
    val selection: Set<String> = emptySet(),
    val clipboard: RemoteFilesClipboard? = null,
    val info: RemoteFileInfoSheet? = null,
    val viewer: RemoteFileViewer? = null,
    val export: RemoteFilesExport? = null,
    /** An uploaded folder's name that exists on the Mac: Merge, Keep Both or Skip. */
    val folderConflict: String? = null,
    val favorites: List<RemoteFavorite> = emptyList(),
    /** Files opened this session (never stored). */
    val recents: List<RemoteFileEntry> = emptyList(),
    /** A file operation is waiting for the Mac. */
    val busy: Boolean = false,
) {
    val currentRoot: RemoteFileRoot? get() = (location as? RemoteFilesLocation.Folder)?.let { f -> roots.firstOrNull { it.id == f.root } }

    /** The current folder as shown: hidden files, kind filter and order applied. */
    val visibleEntries: List<RemoteFileEntry> by lazy {
        RemoteFilesSorting.sorted(entries.filter { (showHidden || !it.hidden) && kindFilter.matches(it) }, sort, ascending)
    }

    val selectedEntries: List<RemoteFileEntry> get() = visibleEntries.filter { it.id in selection }

    val canPaste: Boolean
        get() {
            val c = clipboard ?: return false
            val l = location as? RemoteFilesLocation.Folder ?: return false
            return !(c.move && c.root == l.root && c.folder == l.path)
        }

    /** Locations › Folder › Sub › Sub. */
    val breadcrumbs: List<Pair<String, RemoteFilesLocation>>
        get() {
            val crumbs = mutableListOf<Pair<String, RemoteFilesLocation>>("Locations" to RemoteFilesLocation.Locations)
            when (val l = location) {
                RemoteFilesLocation.Locations -> Unit
                RemoteFilesLocation.Applications -> crumbs += "Applications" to RemoteFilesLocation.Applications
                is RemoteFilesLocation.Folder -> {
                    crumbs += (roots.firstOrNull { it.id == l.root }?.name ?: l.root) to RemoteFilesLocation.Folder(l.root, emptyList())
                    l.path.indices.forEach { i -> crumbs += l.path[i] to RemoteFilesLocation.Folder(l.root, l.path.take(i + 1)) }
                }
            }
            return crumbs
        }
}

/** Delays for debouncing; the app uses a main-thread Handler, tests run them by hand. */
fun interface RemoteFilesScheduler {
    /** Runs [block] after [ms] on the model's thread; the returned function cancels it. */
    fun after(ms: Long, block: () -> Unit): () -> Unit
}

/** Small persistent settings (order, favorites); the app keeps them in SharedPreferences. */
interface RemoteFilesSettings {
    fun get(key: String): String?
    fun set(key: String, value: String?)

    class Memory : RemoteFilesSettings {
        private val map = HashMap<String, String>()
        override fun get(key: String) = map[key]
        override fun set(key: String, value: String?) { if (value == null) map.remove(key) else map[key] = value }
    }
}

/** Remote Finder's state. Main thread only. */
class RemoteFilesModel(
    private val send: (JsonObject) -> Boolean,
    private val inputAllowed: () -> Boolean,
    private val scheduler: RemoteFilesScheduler,
    style: RemoteFilesStyle = RemoteFilesStyle.List,
    /** The view style changed (the app keeps it). */
    private val onStyle: (RemoteFilesStyle) -> Unit = {},
    /** The app's private cache folder for copies from the Mac. */
    cacheDir: File = File(System.getProperty("java.io.tmpdir"), "RemoteFinder"),
    private val settings: RemoteFilesSettings = RemoteFilesSettings.Memory(),
    /** The connected Mac's paired identity, for favorites. */
    private val macKey: () -> String? = { null },
) {
    private val state = MutableStateFlow(RemoteFilesUi(
        style = style,
        sort = runCatching { RemoteFilesSort.valueOf(settings.get(SORT_KEY) ?: "") }.getOrDefault(RemoteFilesSort.Name),
        ascending = settings.get(ASCENDING_KEY) != "false",
    ))
    val ui: StateFlow<RemoteFilesUi> = state.asStateFlow()

    val transfers = RemoteTransferQueue({ send(it) }, { nextReq() }, scheduler, cacheDir)

    private var back = ArrayDeque<RemoteFilesLocation>()
    private var req = 0
    private var listReq: Int? = null
    private var searchReq: Int? = null
    private var previewReq: Int? = null
    private var cancelSearch: (() -> Unit)? = null
    private var cancelThumbs: (() -> Unit)? = null
    private var cancelNotice: (() -> Unit)? = null
    private var cancelRefresh: (() -> Unit)? = null
    private var pendingSearchRoots = ArrayDeque<String>()
    private val wantedThumbs = sortedSetOf<String>()
    private val thumbOrder = ArrayDeque<String>()
    private val unthumbable = HashSet<String>()
    private val previewCache = LinkedHashMap<String, RemotePreviewContent>()
    private var pendingOpenName = ""
    private val waiters = HashMap<Int, Pair<(RemoteFilesReply) -> Unit, () -> Unit>>()
    private val streams = HashMap<Int, RemoteFileStream>()
    private val exportBatches = HashMap<String, ExportBatch>()
    private var folderConflictAnswer: ((RemoteFolderConflictChoice?) -> Unit)? = null

    private class ExportBatch(val mode: RemoteFilesExport.Mode) {
        /** Transfer id → path inside the export (folders, then the file name). */
        val paths = LinkedHashMap<String, List<String>>()
        val folders = mutableListOf<List<String>>()
        val tops = mutableListOf<String>()
        val pending = HashSet<String>()
        var walking = 0
        var failed = 0
        var truncated = false
    }

    companion object {
        const val MAX_THUMBNAILS = 240
        const val MAX_CACHED_PREVIEWS = 12
        const val PREVIEW_SIDE = 1600
        const val SEARCH_DEBOUNCE_MS = 350L
        const val THUMB_DEBOUNCE_MS = 150L
        const val LIST_TIMEOUT_MS = 20_000L
        const val PREVIEW_TIMEOUT_MS = 25_000L
        const val MAX_EXPORT_FILES = 5000
        const val MAX_VIEW_COPY = 200L shl 20
        const val MAX_IMAGE_COPY = 60L shl 20
        private const val SORT_KEY = "files.sort"
        private const val ASCENDING_KEY = "files.ascending"
    }

    init {
        transfers.onSettled = ::transferSettled
        transfers.onRemoteChange = { root, path -> remoteChanged(root, path) }
        transfers.removeStaleCache()
    }

    private val location get() = state.value.location
    private val currentRootID get() = (location as? RemoteFilesLocation.Folder)?.root
    private val currentPath get() = (location as? RemoteFilesLocation.Folder)?.path ?: emptyList()
    private val grant get() = state.value.grant

    // MARK: Session

    fun setAvailable(value: Boolean) {
        state.update { it.copy(available = value) }
        if (!value) reset()
    }

    /** The session ended: nothing from the old Mac is kept. */
    fun reset() {
        cancelSearch?.invoke(); cancelThumbs?.invoke(); cancelNotice?.invoke(); cancelRefresh?.invoke()
        back.clear(); pendingSearchRoots.clear(); wantedThumbs.clear(); thumbOrder.clear(); unthumbable.clear(); previewCache.clear()
        listReq = null; searchReq = null; previewReq = null
        failWaiters("disconnected")
        stopStreams()
        folderConflictAnswer?.invoke(null)
        folderConflictAnswer = null
        transfers.failRunning("disconnected")
        transfers.purgeViewCache()
        state.update { RemoteFilesUi(available = it.available, style = it.style, sort = it.sort, ascending = it.ascending, export = it.export) }
    }

    /** Opens the browser. The first time in a session this asks the Mac, which asks its owner. */
    fun open(query: String? = null) {
        if (!state.value.available) return
        state.update { it.copy(isOpen = true) }
        if (query != null) setQuery(query)
        if (state.value.access == RemoteFilesAccess.Ready) {
            refresh()
        } else {
            state.update { it.copy(access = if (it.access == RemoteFilesAccess.Denied) RemoteFilesAccess.Denied else RemoteFilesAccess.Asking) }
            send(RemoteFilesWire.request("state", nextReq()))
        }
    }

    fun close() {
        cancelThumbs?.invoke()
        wantedThumbs.clear()
        previewReq = null
        stopStreams()
        transfers.purgeViewCache()
        state.update { it.copy(isOpen = false, preview = null, viewer = null, selecting = false, selection = emptySet()) }
    }

    /** Ask again (the owner may have turned it on, added a folder, or revoked access). */
    fun retry() { send(RemoteFilesWire.request("state", nextReq())) }

    fun setStyle(style: RemoteFilesStyle) {
        state.update { it.copy(style = style) }
        onStyle(style)
    }

    fun setSort(sort: RemoteFilesSort) { state.update { it.copy(sort = sort) }; settings.set(SORT_KEY, sort.name) }
    fun setAscending(value: Boolean) { state.update { it.copy(ascending = value) }; settings.set(ASCENDING_KEY, value.toString()) }
    fun setShowHidden(value: Boolean) { state.update { it.copy(showHidden = value && it.grant?.hidden == true) } }
    fun setKindFilter(f: RemoteFileKindFilter) { state.update { it.copy(kindFilter = f) } }

    fun setSelecting(value: Boolean) { state.update { it.copy(selecting = value, selection = emptySet()) } }
    fun toggleSelection(e: RemoteFileEntry) { state.update { it.copy(selection = if (e.id in it.selection) it.selection - e.id else it.selection + e.id) } }
    fun selectAll(all: Boolean) { state.update { s -> s.copy(selection = if (all) s.visibleEntries.map { it.id }.toSet() else emptySet()) } }
    fun clearClipboard() { state.update { it.copy(clipboard = null) } }
    fun dismissInfo() { state.update { it.copy(info = null) } }

    // MARK: Navigation

    fun go(to: RemoteFilesLocation, remember: Boolean = true) {
        if (to == location) return refresh()
        if (remember) { back.addLast(location); if (back.size > 64) back.removeFirst() }
        state.update { it.copy(location = to, highlighted = null, canGoBack = back.isNotEmpty(), selection = emptySet()) }
        if (state.value.query.isNotEmpty()) setQuery("")
        refresh()
    }

    fun goBack() {
        val previous = back.removeLastOrNull() ?: return
        state.update { it.copy(location = previous, highlighted = null, canGoBack = back.isNotEmpty(), selection = emptySet()) }
        refresh()
    }

    fun openEntry(entry: RemoteFileEntry) {
        if (entry.isDirectory) {
            val root = entry.root ?: currentRootID ?: return
            go(RemoteFilesLocation.Folder(root, (entry.location ?: currentPath) + entry.name))
        } else {
            showPreview(entry)
        }
    }

    /** In Select, a tap selects; otherwise it opens. */
    fun tap(entry: RemoteFileEntry) {
        if (state.value.selecting && entry.location == null) toggleSelection(entry) else openEntry(entry)
    }

    /** A search result: go to the folder it is in and point it out. */
    fun showInFolder(entry: RemoteFileEntry) {
        val root = entry.root ?: currentRootID ?: return
        closePreview()
        go(RemoteFilesLocation.Folder(root, entry.location ?: currentPath))
        state.update { it.copy(highlighted = entry.name) }
    }

    fun refresh() {
        if (state.value.access != RemoteFilesAccess.Ready) return
        val l = location as? RemoteFilesLocation.Folder
        if (l == null) {
            state.update { it.copy(entries = emptyList(), loading = false, folderError = null, truncated = false) }
            return
        }
        state.update { it.copy(loading = true, folderError = null) }
        val r = nextReq()
        listReq = r
        if (!send(RemoteFilesWire.request("list", r) { put("root", l.root); put("path", RemoteFilesWire.names(l.path)) })) {
            state.update { it.copy(loading = false, folderError = "disconnected") }
            return
        }
        // No endless spinner: a folder the Mac doesn't answer for says so, with Try Again.
        scheduler.after(LIST_TIMEOUT_MS) {
            if (listReq != r || !state.value.loading) return@after
            listReq = null
            if (state.value.entries.isEmpty()) state.update { it.copy(loading = false, folderError = "timeout") }
            else { state.update { it.copy(loading = false) }; show(RemoteFilesNotice.Text("The Mac didn't answer. Tap Refresh to try again.")) }
        }
    }

    private fun refreshSoon() {
        cancelRefresh?.invoke()
        cancelRefresh = scheduler.after(400) { refresh() }
    }

    // MARK: Search

    fun setQuery(q: String) {
        if (q == state.value.query) return
        state.update { it.copy(query = q) }
        cancelSearch?.invoke()
        val trimmed = q.trim()
        if (trimmed.isEmpty()) {
            searchReq = null; pendingSearchRoots.clear()
            state.update { it.copy(results = emptyList(), searching = false, searchComplete = true) }
            return
        }
        state.update { it.copy(searching = true) }
        cancelSearch = scheduler.after(SEARCH_DEBOUNCE_MS) { startSearch(trimmed.take(100)) }
    }

    private fun startSearch(q: String) {
        if (state.value.access != RemoteFilesAccess.Ready) { state.update { it.copy(searching = false) }; return }
        state.update { it.copy(results = emptyList(), searchComplete = true) }
        // In a folder: below it. At Locations: every approved folder, one after another.
        val l = location
        if (l is RemoteFilesLocation.Folder) {
            pendingSearchRoots.clear()
            sendSearch(q, l.root, l.path)
        } else {
            pendingSearchRoots = ArrayDeque(state.value.roots.map { it.id })
            val first = pendingSearchRoots.removeFirstOrNull() ?: run { state.update { it.copy(searching = false) }; return }
            sendSearch(q, first, emptyList())
        }
    }

    private fun sendSearch(q: String, root: String, path: List<String>) {
        val r = nextReq()
        searchReq = r
        send(RemoteFilesWire.request("search", r) { put("root", root); put("path", RemoteFilesWire.names(path)); put("q", q) })
    }

    // MARK: Preview and thumbnails

    fun showPreview(entry: RemoteFileEntry) {
        val root = entry.root ?: currentRootID ?: return
        val path = (entry.location ?: currentPath) + entry.name
        val key = root + "/" + path.joinToString("/")
        noteRecent(entry, root)
        previewCache[key]?.let { cached ->
            state.update { it.copy(preview = RemotePreview(entry, root, path, cached)) }
            startViewer(entry, root, path)
            return
        }
        state.update { it.copy(preview = RemotePreview(entry, root, path, RemotePreviewContent.Loading)) }
        val r = nextReq()
        previewReq = r
        if (!send(RemoteFilesWire.request("preview", r) { put("root", root); put("path", RemoteFilesWire.names(path)); put("max", PREVIEW_SIDE) })) {
            setPreviewContent(RemotePreviewContent.Failed("disconnected")); return
        }
        scheduler.after(PREVIEW_TIMEOUT_MS) {
            if (previewReq == r && state.value.preview?.content == RemotePreviewContent.Loading) setPreviewContent(RemotePreviewContent.Failed("timeout"))
        }
        startViewer(entry, root, path)
    }

    private fun setPreviewContent(c: RemotePreviewContent) { state.update { s -> s.copy(preview = s.preview?.copy(content = c)) } }

    /** Asks for the preview again (after a timeout or a failure). */
    fun retryPreview() {
        val p = state.value.preview ?: return
        previewCache.remove(p.key)
        showPreview(p.entry)
    }

    fun closePreview() {
        previewReq = null
        closeViewer()
        state.update { it.copy(preview = null) }
    }

    fun thumbnailKey(entry: RemoteFileEntry): String? {
        if (!entry.kind.hasThumbnail) return null
        val root = entry.root ?: currentRootID ?: return null
        return root + "/" + (entry.location ?: currentPath).joinToString("/") + "/" + entry.name
    }

    /** A row or tile came on screen: ask for its still soon (batched, current folder only). */
    fun wantThumbnail(entry: RemoteFileEntry) {
        if (entry.location != null) return
        val key = thumbnailKey(entry) ?: return
        if (state.value.thumbnails.containsKey(key) || key in unthumbable) return
        if (wantedThumbs.add(entry.name)) scheduleThumbs()
    }

    fun dropThumbnail(entry: RemoteFileEntry) { wantedThumbs.remove(entry.name) }

    private fun scheduleThumbs() {
        cancelThumbs?.invoke()
        cancelThumbs = scheduler.after(THUMB_DEBOUNCE_MS) {
            val l = location as? RemoteFilesLocation.Folder ?: return@after
            val names = wantedThumbs.take(48)
            if (names.isEmpty()) return@after
            send(RemoteFilesWire.request("thumbs", nextReq()) {
                put("root", l.root); put("path", RemoteFilesWire.names(l.path)); put("names", RemoteFilesWire.names(names)); put("max", 240)
            })
        }
    }

    // MARK: Open on the Mac

    /** Opens on the Mac (explicit action, needs control); [app] is an app to open it in. */
    fun openOnMac(entry: RemoteFileEntry, app: String? = null) {
        val root = entry.root ?: currentRootID ?: return
        if (!inputAllowed()) return show(RemoteFilesNotice.NeedsControl)
        pendingOpenName = entry.name
        send(RemoteFilesWire.request("open", nextReq()) {
            put("root", root); put("path", RemoteFilesWire.names((entry.location ?: currentPath) + entry.name))
            app?.let { put("with", it) }
        })
    }

    fun show(n: RemoteFilesNotice) {
        state.update { it.copy(notice = n) }
        cancelNotice?.invoke()
        val ms = when (n) { is RemoteFilesNotice.Trashed, is RemoteFilesNotice.Needs -> 6_000L; is RemoteFilesNotice.Text -> 4_000L; else -> 2_600L }
        cancelNotice = scheduler.after(ms) { state.update { it.copy(notice = null) } }
    }

    // MARK: Requests

    /** Sends a request and calls [done] with its answer (or a failure after [timeoutMs], or when the session ends). */
    fun request(op: String, timeoutMs: Long = 30_000, body: JsonObjectBuilder.() -> Unit = {}, done: (RemoteFilesReply) -> Unit) {
        val r = nextReq()
        if (!send(RemoteFilesWire.request(op, r, body))) return done(RemoteFilesReply.failure(op, "disconnected"))
        val cancel = scheduler.after(timeoutMs) { waiters.remove(r)?.first?.invoke(RemoteFilesReply.failure(op, "timeout")) }
        waiters[r] = done to cancel
    }

    private fun failWaiters(code: String) {
        val all = waiters.values.toList()
        waiters.clear()
        all.forEach { (done, cancel) -> cancel(); done(RemoteFilesReply.failure("", code)) }
    }

    /** Words a failed reply; true when it was a success. */
    private fun report(r: RemoteFilesReply, done: String? = null): Boolean {
        if (r.ok) { done?.let { show(RemoteFilesNotice.Text(it)) }; return true }
        show(if (r.error == "notAllowed") RemoteFilesNotice.Needs(r.need ?: "") else RemoteFilesNotice.Text(RemoteFilesFormat.errorText(r.error)))
        return false
    }

    /** The grant allows it, else the notice offers to ask the Mac. */
    private fun allowed(capability: String): Boolean {
        val g = grant ?: return false
        if (capability in g.capabilities) return true
        show(RemoteFilesNotice.Needs(capability))
        return false
    }

    private fun place(e: RemoteFileEntry): Pair<String, List<String>>? {
        val root = e.root ?: currentRootID ?: return null
        return root to (e.location ?: currentPath) + e.name
    }

    private fun busy(on: Boolean) = state.update { it.copy(busy = on) }

    /** Runs [step] on each item in order, stopping at the first failure; [finished] gets how many worked. */
    private fun <T> each(items: List<T>, step: (T, (Boolean) -> Unit) -> Unit, finished: (Int) -> Unit) {
        fun go(i: Int, done: Int) {
            if (i >= items.size) return finished(done)
            step(items[i]) { ok -> if (ok) go(i + 1, done + 1) else finished(done) }
        }
        go(0, 0)
    }

    // MARK: Folder operations

    fun newFolder(raw: String) {
        val l = location as? RemoteFilesLocation.Folder ?: return
        if (!allowed("upload")) return
        val name = RemoteFilesFormat.cleanName(raw) ?: "untitled folder"
        busy(true)
        request("mkdir", body = { put("root", l.root); put("path", RemoteFilesWire.names(l.path)); put("name", name); put("conflict", "rename") }) { r ->
            busy(false)
            if (report(r)) { refresh(); state.update { it.copy(highlighted = r.name ?: name) } }
        }
    }

    fun rename(entry: RemoteFileEntry, raw: String) {
        if (!allowed("modify")) return
        val (root, path) = place(entry) ?: return
        val name = RemoteFilesFormat.cleanName(raw)?.takeIf { it != entry.name } ?: return
        busy(true)
        request("rename", body = { put("root", root); put("path", RemoteFilesWire.names(path)); put("name", name) }) { r ->
            busy(false)
            if (report(r)) { refresh(); state.update { it.copy(highlighted = r.name ?: name) } }
        }
    }

    fun duplicate(entries: List<RemoteFileEntry>) {
        if (!allowed("modify")) return
        busy(true)
        var last: String? = null
        each(entries, { e, next ->
            val (root, path) = place(e) ?: return@each next(true)
            request("duplicate", 600_000, { put("root", root); put("path", RemoteFilesWire.names(path)) }) { r -> last = r.name; next(report(r)) }
        }) {
            busy(false); refresh()
            state.update { it.copy(highlighted = last, selecting = false, selection = emptySet()) }
        }
    }

    fun trash(entries: List<RemoteFileEntry>) {
        if (!allowed("delete")) return
        busy(true)
        val tokens = mutableListOf<String>()
        each(entries, { e, next ->
            val (root, path) = place(e) ?: return@each next(true)
            request("trash", 120_000, { put("root", root); put("path", RemoteFilesWire.names(path)) }) { r ->
                r.token?.let(tokens::add); next(report(r))
            }
        }) { moved ->
            busy(false); refresh()
            state.update { it.copy(selecting = false, selection = emptySet()) }
            if (moved > 0) show(RemoteFilesNotice.Trashed(moved, tokens))
        }
    }

    /** Undo of Move to Trash: Put Back, in this session. */
    fun putBack(tokens: List<String>) {
        if (!allowed("modify")) return
        busy(true)
        each(tokens, { t, next -> request("putBack", 120_000, { put("token", t) }) { r -> next(report(r)) } }) { busy(false); refresh() }
    }

    fun copyItems(entries: List<RemoteFileEntry>, move: Boolean) {
        val l = location as? RemoteFilesLocation.Folder ?: return
        if (entries.isEmpty() || !allowed("modify")) return
        state.update { it.copy(clipboard = RemoteFilesClipboard(move, l.root, l.path, entries.map { e -> e.name }), selecting = false, selection = emptySet()) }
        show(RemoteFilesNotice.Text(if (move) "Open the destination folder, then Move Here." else "Open the destination folder, then Paste."))
    }

    fun paste() {
        val c = state.value.clipboard ?: return
        val l = location as? RemoteFilesLocation.Folder ?: return
        if (!state.value.canPaste || !allowed("modify")) return
        busy(true)
        var last: String? = null
        each(c.names, { name, next ->
            request(if (c.move) "move" else "copy", 900_000, {
                put("root", c.root); put("path", RemoteFilesWire.names(c.folder + name))
                put("toRoot", l.root); put("toPath", RemoteFilesWire.names(l.path)); put("conflict", "rename")
            }) { r -> last = r.name; next(report(r)) }
        }) {
            busy(false)
            if (c.move) state.update { it.copy(clipboard = null) }
            refresh()
            state.update { it.copy(highlighted = last) }
        }
    }

    fun compress(entries: List<RemoteFileEntry>) {
        val l = location as? RemoteFilesLocation.Folder ?: return
        if (entries.isEmpty() || !allowed("modify")) return
        busy(true)
        request("zip", 900_000, { put("root", l.root); put("path", RemoteFilesWire.names(l.path)); put("names", RemoteFilesWire.names(entries.map { it.name })) }) { r ->
            busy(false)
            if (report(r)) { refresh(); state.update { it.copy(highlighted = r.name) } }
            state.update { it.copy(selecting = false, selection = emptySet()) }
        }
    }

    fun expand(entry: RemoteFileEntry) {
        if (!allowed("modify")) return
        val (root, path) = place(entry) ?: return
        busy(true)
        request("unzip", 900_000, { put("root", root); put("path", RemoteFilesWire.names(path)) }) { r ->
            busy(false)
            if (report(r)) { refresh(); state.update { it.copy(highlighted = r.name) } }
        }
    }

    fun getInfo(entry: RemoteFileEntry) {
        val (root, path) = place(entry) ?: return
        request("info", 60_000, { put("root", root); put("path", RemoteFilesWire.names(path)) }) { r ->
            if (report(r)) r.info?.let { i -> state.update { it.copy(info = RemoteFileInfoSheet(entry, i)) } }
        }
    }

    fun openWithApps(entry: RemoteFileEntry, done: (List<RemoteOpenWithApp>) -> Unit) {
        val (root, path) = place(entry) ?: return done(emptyList())
        request("openWithApps", body = { put("root", root); put("path", RemoteFilesWire.names(path)) }) { r -> done(if (r.ok) r.apps else emptyList()) }
    }

    /** Asks the Mac's owner for more (they see a prompt on the Mac). */
    fun requestAccess(caps: List<String>) {
        if (caps.isEmpty()) return
        show(RemoteFilesNotice.Text("Asked the Mac. Its owner decides there."))
        request("requestAccess", 300_000, { put("caps", RemoteFilesWire.names(caps)) }) { r ->
            when {
                r.ok -> show(RemoteFilesNotice.Text("The Mac allowed it."))
                r.error == "denied" -> show(RemoteFilesNotice.Text("The Mac said Not Now."))
                else -> report(r)
            }
        }
    }

    // MARK: Favorites and recents

    private fun favoritesKey() = macKey()?.let { "files.favorites.$it" }

    private fun loadFavorites() {
        val raw = favoritesKey()?.let(settings::get)
        val list = raw?.lineSequence()?.filter { it.isNotEmpty() }?.mapNotNull { line ->
            val parts = line.split('\u001F')
            if (parts.size < 2) null else RemoteFavorite(parts[0], parts.drop(2), parts[1])
        }?.take(40)?.toList().orEmpty()
        state.update { it.copy(favorites = list) }
    }

    private fun saveFavorites(list: List<RemoteFavorite>) {
        state.update { it.copy(favorites = list) }
        val key = favoritesKey() ?: return
        settings.set(key, list.joinToString("\n") { f -> (listOf(f.root, f.name) + f.path).joinToString("\u001F") })
    }

    fun isFavorite(entry: RemoteFileEntry): Boolean {
        val (root, path) = place(entry) ?: return false
        return state.value.favorites.any { it.root == root && it.path == path }
    }

    fun toggleFavorite(entry: RemoteFileEntry) {
        if (!entry.isDirectory) return
        val (root, path) = place(entry) ?: return
        val list = state.value.favorites
        saveFavorites(if (list.any { it.root == root && it.path == path }) list.filterNot { it.root == root && it.path == path }
                      else list + RemoteFavorite(root, path, entry.name))
    }

    fun removeFavorite(f: RemoteFavorite) = saveFavorites(state.value.favorites - f)

    private fun noteRecent(entry: RemoteFileEntry, root: String) {
        val e = entry.copy(root = root, location = entry.location ?: currentPath)
        state.update { s -> s.copy(recents = (listOf(e) + s.recents.filter { it.id != e.id }).take(12)) }
    }

    // MARK: Viewers

    /** Movies and audio stream with seeking; PDFs and images come as a private copy (pages, full size). */
    private fun startViewer(entry: RemoteFileEntry, root: String, path: List<String>) {
        closeViewer()
        val key = root + "/" + path.joinToString("/")
        when (entry.kind) {
            RemoteFileKind.Video, RemoteFileKind.Audio -> {
                state.update { it.copy(viewer = RemoteFileViewer(key, entry, RemoteFileViewer.Content.Loading)) }
                request("download", body = { put("root", root); put("path", RemoteFilesWire.names(path)); put("purpose", "view") }) { r ->
                    val x = r.x; val size = r.size
                    if (state.value.viewer?.previewKey != key) {
                        if (x != null) send(RemoteFilesWire.request("close", nextReq()) { put("x", x) })
                        return@request
                    }
                    if (!r.ok || x == null || size == null) return@request setViewer(RemoteFileViewer.Content.Failed(r.error ?: "failed"))
                    streams[x] = RemoteFileStream(x, size, r.mime, { send(it) }, { nextReq() }, scheduler)
                    setViewer(RemoteFileViewer.Content.Stream(x, size, r.mime))
                }
            }
            RemoteFileKind.Pdf, RemoteFileKind.Image -> {
                val limit = if (entry.kind == RemoteFileKind.Pdf) MAX_VIEW_COPY else MAX_IMAGE_COPY
                if ((entry.size ?: 0) > limit) return
                val t = transfers.download(root, path, entry.name, entry.size, RemoteTransferPurpose.View)
                state.update { it.copy(viewer = RemoteFileViewer(key, entry, RemoteFileViewer.Content.Loading, t)) }
            }
            else -> Unit
        }
    }

    private fun setViewer(c: RemoteFileViewer.Content) { state.update { s -> s.copy(viewer = s.viewer?.copy(content = c)) } }

    /** Other documents: a private copy to open in another app on this device, so it needs download. */
    fun openCopyHere(entry: RemoteFileEntry) {
        if (!allowed("download")) return
        val p = state.value.preview ?: return
        val (root, path) = place(entry) ?: return
        val t = transfers.download(root, path, entry.name, entry.size, RemoteTransferPurpose.Save)
        state.update { it.copy(viewer = RemoteFileViewer(p.key, entry, RemoteFileViewer.Content.Loading, t)) }
    }

    fun retryViewer() {
        val p = state.value.preview ?: return
        startViewer(p.entry, p.root, p.path)
    }

    fun viewerFailed(code: String) = setViewer(RemoteFileViewer.Content.Failed(code))

    private fun closeViewer() {
        state.value.viewer?.transferID?.let(transfers::cancel)
        stopStreams()
        state.update { it.copy(viewer = null) }
    }

    private fun stopStreams() {
        val all = streams.values.toList()
        streams.clear()
        all.forEach { it.close() }
    }

    fun stream(x: Int): RemoteFileStream? = streams[x]

    // MARK: Save, share, upload

    fun save(entries: List<RemoteFileEntry>) = startExport(entries, RemoteFilesExport.Mode.Save)
    fun share(entries: List<RemoteFileEntry>) = startExport(entries, RemoteFilesExport.Mode.Share)

    private fun startExport(entries: List<RemoteFileEntry>, mode: RemoteFilesExport.Mode) {
        if (entries.isEmpty() || !allowed("download")) return
        val id = java.util.UUID.randomUUID().toString()
        val b = ExportBatch(mode)
        exportBatches[id] = b
        for (e in entries) {
            val (root, path) = place(e) ?: continue
            b.tops += e.name
            if (e.isDirectory) {
                b.walking++
                walk(root, path, listOf(e.name), id, 0) { b.walking--; checkBatch(id) }
            } else enqueueSave(root, path, listOf(e.name), e.size, id)
        }
        state.update { it.copy(selecting = false, selection = emptySet()) }
        show(RemoteFilesNotice.Text(if (mode == RemoteFilesExport.Mode.Save) "Copying to this device…" else "Preparing to share…"))
        checkBatch(id)
    }

    private fun enqueueSave(root: String, path: List<String>, rel: List<String>, size: Long?, batch: String) {
        val b = exportBatches[batch] ?: return
        if (b.paths.size >= MAX_EXPORT_FILES) { b.truncated = true; return }
        val t = transfers.download(root, path, rel.last(), size, RemoteTransferPurpose.Save, batch)
        b.paths[t] = rel
        b.pending += t
    }

    /** Lists a folder on the Mac and queues every file in it (bounded depth and count). */
    private fun walk(root: String, path: List<String>, rel: List<String>, batch: String, depth: Int, done: () -> Unit) {
        val b = exportBatches[batch]
        if (b == null || depth >= 32) return done()
        b.folders += rel
        request("list", 60_000, { put("root", root); put("path", RemoteFilesWire.names(path)) }) { r ->
            if (!r.ok) { b.failed++; return@request done() }
            if (r.truncated) b.truncated = true
            val shown = r.entries.filter { !it.hidden || state.value.showHidden }
            shown.filter { !it.isDirectory }.forEach { enqueueSave(root, path + it.name, rel + it.name, it.size, batch) }
            each(shown.filter { it.isDirectory && it.kind != RemoteFileKind.App }, { d, next ->
                walk(root, path + d.name, rel + d.name, batch, depth + 1) { next(true) }
            }) { done() }
        }
    }

    private fun transferSettled(item: RemoteTransferItem) {
        val v = state.value.viewer
        val forViewer = v != null && v.transferID == item.id
        if (forViewer) {
            when (val s = item.state) {
                RemoteTransferItem.State.Done -> item.localFile?.let { setViewer(RemoteFileViewer.Content.Local(it)) }
                is RemoteTransferItem.State.Failed -> setViewer(RemoteFileViewer.Content.Failed(s.code))
                else -> Unit
            }
        }
        val s = item.state
        if (s is RemoteTransferItem.State.Failed && s.code == "notAllowed") show(RemoteFilesNotice.Needs(if (item.isUpload) "upload" else "download"))
        if (item.purpose != RemoteTransferPurpose.Save || forViewer) return
        val b = exportBatches[item.batch]
        if (b != null && item.id in b.pending) {
            b.pending -= item.id
            if (item.state != RemoteTransferItem.State.Done) b.failed++
            checkBatch(item.batch)
        } else if (item.state == RemoteTransferItem.State.Done) {
            // A retried file of a batch that was already handed on.
            item.localFile?.let { f -> state.update { it.copy(export = RemoteFilesExport(item.id, RemoteFilesExport.Mode.Save, listOf(f), f.parentFile ?: f, 0)) } }
        }
    }

    private fun checkBatch(id: String) {
        val b = exportBatches[id] ?: return
        if (b.pending.isNotEmpty() || b.walking > 0) return
        exportBatches.remove(id)
        val dir = File(transfers.cacheDir, "export-$id")
        dir.mkdirs()
        b.folders.forEach { File(dir, it.joinToString(File.separator)).mkdirs() }
        var moved = 0
        for ((t, rel) in b.paths) {
            val item = transfers.items.value.firstOrNull { it.id == t } ?: continue
            val src = item.localFile ?: continue
            if (item.state != RemoteTransferItem.State.Done) continue
            val dest = File(dir, rel.joinToString(File.separator))
            dest.parentFile?.mkdirs()
            if (src.renameTo(dest)) { moved++; src.parentFile?.deleteRecursively() }
        }
        val files = b.tops.distinct().map { File(dir, it) }.filter { it.exists() }
        if (files.isEmpty() || (moved == 0 && b.folders.isEmpty())) {
            dir.deleteRecursively()
            if (b.failed > 0) show(RemoteFilesNotice.Text("Nothing could be copied from the Mac."))
            return
        }
        if (b.truncated) show(RemoteFilesNotice.Text("Only the first $MAX_EXPORT_FILES files are included."))
        state.update { it.copy(export = RemoteFilesExport(id, b.mode, files, dir, b.failed)) }
    }

    /** The save picker or share sheet is done: the copies on this device go (shares a little later). */
    fun exportFinished(e: RemoteFilesExport, completed: Boolean, keepForMs: Long = 0) {
        if (state.value.export?.id == e.id) state.update { it.copy(export = null) }
        if (keepForMs > 0) scheduler.after(keepForMs) { e.directory.deleteRecursively() } else e.directory.deleteRecursively()
        if (completed && e.mode == RemoteFilesExport.Mode.Save) {
            show(RemoteFilesNotice.Text(if (e.failed > 0) "Saved. ${e.failed} couldn't be copied." else "Saved to this device."))
        }
    }

    /** Uploads picked files and folders into the current folder. */
    fun upload(files: List<RemoteUploadSource>, folders: List<RemoteUploadFolder> = emptyList()) {
        val l = location as? RemoteFilesLocation.Folder ?: return
        if ((files.isEmpty() && folders.isEmpty()) || !allowed("upload")) return
        val batch = java.util.UUID.randomUUID().toString()
        files.forEach { transfers.upload(it, l.root, l.path, batch) }
        each(folders, { f, next -> uploadFolder(f, l.root, l.path, batch) { next(true) } }) {}
        show(RemoteFilesNotice.Text("Uploading to the Mac…"))
    }

    fun answerFolderConflict(choice: RemoteFolderConflictChoice?) {
        val a = folderConflictAnswer ?: return
        folderConflictAnswer = null
        state.update { it.copy(folderConflict = null) }
        a(choice)
    }

    private fun uploadFolder(f: RemoteUploadFolder, root: String, path: List<String>, batch: String, done: () -> Unit) {
        val clean = RemoteFilesFormat.cleanName(f.name) ?: return done()
        fun mkdir(conflict: String, then: (RemoteFilesReply) -> Unit) =
            request("mkdir", body = { put("root", root); put("path", RemoteFilesWire.names(path)); put("name", clean); put("conflict", conflict) }, done = then)
        fun proceed(r: RemoteFilesReply) {
            if (!report(r)) return done()
            val top = path + (r.name ?: clean)
            refreshSoon()
            val folders = f.folders.filter { rel -> rel.isNotEmpty() && rel.all { RemoteFilesFormat.cleanName(it) == it } }.sortedBy { it.size }
            each(folders, { rel, next ->
                request("mkdir", body = {
                    put("root", root); put("path", RemoteFilesWire.names(top + rel.dropLast(1))); put("name", rel.last()); put("conflict", "skip")
                }) { m -> next(report(m)) }
            }) { made ->
                if (made < folders.size) return@each done()
                f.files.filter { (_, rel) -> rel.isNotEmpty() && rel.all { RemoteFilesFormat.cleanName(it) == it } }.take(MAX_EXPORT_FILES).forEach { (src, rel) ->
                    transfers.upload(src, root, top + rel.dropLast(1), batch, rel.last())
                }
                done()
            }
        }
        mkdir("ask") { r ->
            if (r.ok || r.error != "exists") return@mkdir proceed(r)
            folderConflictAnswer = { choice ->
                when (choice) {
                    RemoteFolderConflictChoice.Merge -> mkdir("skip", ::proceed)
                    RemoteFolderConflictChoice.KeepBoth -> mkdir("rename", ::proceed)
                    else -> done()
                }
            }
            state.update { it.copy(folderConflict = clean) }
        }
    }

    private fun remoteChanged(root: String, path: List<String>) {
        val l = location as? RemoteFilesLocation.Folder ?: return
        if (l.root == root && l.path == path) refreshSoon()
    }

    // MARK: Replies

    fun apply(r: RemoteFilesReply) {
        val accessError = r.error?.takeIf { it == "off" || it == "asking" || it == "denied" || it == "revoked" }
        if (accessError != null) {
            val a = when (accessError) { "off" -> RemoteFilesAccess.Off; "denied" -> RemoteFilesAccess.Denied; "revoked" -> RemoteFilesAccess.Revoked; else -> RemoteFilesAccess.Asking }
            state.update { it.copy(access = a, loading = false, searching = false) }
            if (accessError != "asking") { state.update { it.copy(grant = null) }; transfers.failRunning(accessError) }
        }
        // Transfers, streams and awaited operations take their own replies.
        if ((r.op == "data" || r.op == "read") && r.x != null) streams[r.x]?.let { it.apply(r); return }
        if (transfers.apply(r)) return
        r.req?.let { q -> waiters.remove(q)?.let { (done, cancel) -> cancel(); done(r); return } }
        if (accessError != null) {
            if (state.value.preview?.content == RemotePreviewContent.Loading) setPreviewContent(RemotePreviewContent.Failed(accessError))
            return
        }
        when (r.op) {
            "state" -> {
                if (r.state != "ready") state.update { it.copy(grant = null) }
                when (r.state) {
                    "off" -> state.update { it.copy(access = RemoteFilesAccess.Off) }
                    "denied" -> state.update { it.copy(access = RemoteFilesAccess.Denied) }
                    "revoked" -> {
                        transfers.failRunning("revoked")
                        stopStreams()
                        state.update { it.copy(access = RemoteFilesAccess.Revoked, selecting = false, selection = emptySet()) }
                    }
                    "noFolders" -> state.update { it.copy(access = RemoteFilesAccess.NoFolders, roots = emptyList()) }
                    "ready" -> {
                        val wasReady = state.value.access == RemoteFilesAccess.Ready
                        var l = location
                        if (l is RemoteFilesLocation.Folder && r.roots.none { it.id == l.root }) { l = RemoteFilesLocation.Locations; back.clear() }
                        if (l == RemoteFilesLocation.Locations && r.roots.size == 1 && back.isEmpty() && !wasReady) l = RemoteFilesLocation.Folder(r.roots[0].id, emptyList())
                        val g = r.grant ?: RemoteFilesGrant()
                        state.update { it.copy(access = RemoteFilesAccess.Ready, roots = r.roots, location = l, canGoBack = back.isNotEmpty(), grant = g,
                            showHidden = it.showHidden && g.hidden) }
                        loadFavorites()
                        if (state.value.isOpen) {
                            refresh()
                            val q = state.value.query.trim()
                            if (q.isNotEmpty()) { state.update { it.copy(searching = true) }; cancelSearch?.invoke(); cancelSearch = scheduler.after(SEARCH_DEBOUNCE_MS) { startSearch(q.take(100)) } }
                        }
                    }
                    else -> state.update { it.copy(access = RemoteFilesAccess.Asking) }
                }
            }
            "list" -> {
                if (r.req != null && r.req != listReq) return
                state.update { it.copy(loading = false) }
                val l = location as? RemoteFilesLocation.Folder ?: return
                if (r.root != null && r.root != l.root) return
                if (r.ok) {
                    if (r.path == l.path) state.update { s ->
                        val ids = r.entries.map { it.id }.toSet()
                        s.copy(entries = r.entries, truncated = r.truncated, folderError = null, selection = s.selection.intersect(ids))
                    }
                } else {
                    state.update { it.copy(entries = emptyList(), folderError = r.error ?: "notFound") }
                }
            }
            "search" -> {
                if (r.req != searchReq) return
                if (r.ok) state.update { s ->
                    s.copy(results = s.results + r.entries.take((400 - s.results.size).coerceAtLeast(0)),
                        searchComplete = s.searchComplete && r.complete)
                }
                val q = state.value.query.trim()
                val next = if (q.isNotEmpty()) pendingSearchRoots.removeFirstOrNull() else null
                if (next != null) sendSearch(q.take(100), next, emptyList()) else state.update { it.copy(searching = false) }
            }
            "preview" -> {
                if (r.req != previewReq) return
                val p = state.value.preview ?: return
                val content = when {
                    r.text != null -> RemotePreviewContent.Text(r.text, r.truncated)
                    r.jpegBase64 != null -> RemotePreviewContent.Image(r.jpegBase64)
                    r.error != null && r.error != "noPreview" && r.error != "unsupported" -> RemotePreviewContent.Failed(r.error)
                    else -> RemotePreviewContent.Unavailable
                }
                state.update { it.copy(preview = p.copy(content = content)) }
                if (content !is RemotePreviewContent.Failed) {
                    previewCache.remove(p.key)
                    previewCache[p.key] = content
                    while (previewCache.size > MAX_CACHED_PREVIEWS) previewCache.remove(previewCache.keys.first())
                }
            }
            "thumb" -> {
                val name = r.name ?: return
                val l = location as? RemoteFilesLocation.Folder ?: return
                if (r.root != l.root || r.path != l.path) return
                val key = l.root + "/" + l.path.joinToString("/") + "/" + name
                wantedThumbs.remove(name)
                val jpeg = r.jpegBase64
                if (!r.ok || jpeg == null) { unthumbable += key; return }
                thumbOrder.addLast(key)
                state.update { s ->
                    var map = s.thumbnails + (key to jpeg)
                    while (thumbOrder.size > MAX_THUMBNAILS) map = map - thumbOrder.removeFirst()
                    s.copy(thumbnails = map)
                }
            }
            "open" -> show(if (r.ok) RemoteFilesNotice.Opened(pendingOpenName) else if (r.error == "control") RemoteFilesNotice.NeedsControl else RemoteFilesNotice.OpenFailed)
            else -> Unit
        }
    }

    /** The UI decoded a still the Mac sent and found it unusable. */
    fun thumbnailUnusable(key: String) {
        unthumbable += key
        state.update { it.copy(thumbnails = it.thumbnails - key) }
    }

    fun nextReq(): Int { req = if (req >= 1_000_000_000) 1 else req + 1; return req }
}

private fun JsonObject.s(k: String): String? = (this[k] as? JsonPrimitive)?.takeIf { it.isString }?.content
private fun JsonObject.i(k: String): Int? = (this[k] as? JsonPrimitive)?.takeIf { !it.isString }?.intOrNull
private fun JsonObject.l(k: String): Long? = (this[k] as? JsonPrimitive)?.takeIf { !it.isString }?.longOrNull
private fun JsonObject.b(k: String): Boolean? = (this[k] as? JsonPrimitive)?.takeIf { !it.isString }?.booleanOrNull

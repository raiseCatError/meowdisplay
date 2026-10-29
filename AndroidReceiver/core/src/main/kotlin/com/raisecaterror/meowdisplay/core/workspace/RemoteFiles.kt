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

// Remote Finder on the receiver (PROTOCOL.md 6.12): a temporary, read-only, Finder-like
// browser of the folders the Mac's owner approved. Everything is read on the Mac; this side
// only asks, draws and caches a bounded number of previews. Mirrors iOS Shared/RemoteFiles.swift.

object RemoteFilesWire {
    const val WELCOME_FEATURE = "files"
    const val REQUEST = "filesRequest"
    const val REPLY = "files"
    const val MAX_BASE64 = 1_600_000

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
) {
    val id: String get() = (root ?: "") + "/" + (location ?: emptyList()).joinToString("/") + "/" + name
}

data class RemoteFileRoot(val id: String, val name: String)

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
) {
    companion object {
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
                        e.l("size"), e.l("mod"), inFolder, if (inFolder != null) root else null)
                },
                truncated = obj.b("truncated") == true,
                complete = obj.b("complete") != false,
                query = obj.s("q")?.take(100),
                text = obj.s("text")?.take(40_000),
                jpegBase64 = obj.s("jpeg")?.takeIf { it.length <= RemoteFilesWire.MAX_BASE64 },
                name = obj.s("name")?.take(255),
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

enum class RemoteFilesAccess { Unknown, Off, Asking, Denied, NoFolders, Ready }
enum class RemoteFilesStyle { List, Grid }

sealed interface RemotePreviewContent {
    data object Loading : RemotePreviewContent
    data class Image(val jpegBase64: String) : RemotePreviewContent
    data class Text(val text: String, val truncated: Boolean) : RemotePreviewContent
    data object Unavailable : RemotePreviewContent
}

data class RemotePreview(val entry: RemoteFileEntry, val root: String, val path: List<String>, val content: RemotePreviewContent) {
    val key: String get() = root + "/" + path.joinToString("/")
}

sealed interface RemoteFilesNotice {
    data class Opened(val name: String) : RemoteFilesNotice
    data object NeedsControl : RemoteFilesNotice
    data object OpenFailed : RemoteFilesNotice
}

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
) {
    val currentRoot: RemoteFileRoot? get() = (location as? RemoteFilesLocation.Folder)?.let { f -> roots.firstOrNull { it.id == f.root } }

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

/** Remote Finder's state. Main thread only. */
class RemoteFilesModel(
    private val send: (JsonObject) -> Boolean,
    private val inputAllowed: () -> Boolean,
    private val scheduler: RemoteFilesScheduler,
    style: RemoteFilesStyle = RemoteFilesStyle.List,
    /** The view style changed (the app keeps it). */
    private val onStyle: (RemoteFilesStyle) -> Unit = {},
) {
    private val state = MutableStateFlow(RemoteFilesUi(style = style))
    val ui: StateFlow<RemoteFilesUi> = state.asStateFlow()

    private var back = ArrayDeque<RemoteFilesLocation>()
    private var req = 0
    private var listReq: Int? = null
    private var searchReq: Int? = null
    private var previewReq: Int? = null
    private var cancelSearch: (() -> Unit)? = null
    private var cancelThumbs: (() -> Unit)? = null
    private var cancelNotice: (() -> Unit)? = null
    private var pendingSearchRoots = ArrayDeque<String>()
    private val wantedThumbs = sortedSetOf<String>()
    private val thumbOrder = ArrayDeque<String>()
    private val unthumbable = HashSet<String>()
    private val previewCache = LinkedHashMap<String, RemotePreviewContent>()
    private var pendingOpenName = ""

    companion object {
        const val MAX_THUMBNAILS = 240
        const val MAX_CACHED_PREVIEWS = 12
        const val PREVIEW_SIDE = 1024
        const val SEARCH_DEBOUNCE_MS = 350L
        const val THUMB_DEBOUNCE_MS = 150L
    }

    private val location get() = state.value.location
    private val currentRootID get() = (location as? RemoteFilesLocation.Folder)?.root
    private val currentPath get() = (location as? RemoteFilesLocation.Folder)?.path ?: emptyList()

    // MARK: Session

    fun setAvailable(value: Boolean) {
        state.update { it.copy(available = value) }
        if (!value) reset()
    }

    /** The session ended: nothing from the old Mac is kept. */
    fun reset() {
        cancelSearch?.invoke(); cancelThumbs?.invoke(); cancelNotice?.invoke()
        back.clear(); pendingSearchRoots.clear(); wantedThumbs.clear(); thumbOrder.clear(); unthumbable.clear(); previewCache.clear()
        listReq = null; searchReq = null; previewReq = null
        state.update { RemoteFilesUi(available = it.available, style = it.style) }
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
        state.update { it.copy(isOpen = false, preview = null) }
    }

    /** Ask again (the owner may have turned it on or added a folder). */
    fun retry() { send(RemoteFilesWire.request("state", nextReq())) }

    fun setStyle(style: RemoteFilesStyle) {
        state.update { it.copy(style = style) }
        onStyle(style)
    }

    // MARK: Navigation

    fun go(to: RemoteFilesLocation, remember: Boolean = true) {
        if (to == location) return refresh()
        if (remember) { back.addLast(location); if (back.size > 64) back.removeFirst() }
        state.update { it.copy(location = to, highlighted = null, canGoBack = back.isNotEmpty()) }
        if (state.value.query.isNotEmpty()) setQuery("")
        refresh()
    }

    fun goBack() {
        val previous = back.removeLastOrNull() ?: return
        state.update { it.copy(location = previous, highlighted = null, canGoBack = back.isNotEmpty()) }
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

    /** A search result: go to the folder it is in and point it out. */
    fun showInFolder(entry: RemoteFileEntry) {
        val root = entry.root ?: currentRootID ?: return
        state.update { it.copy(preview = null) }
        go(RemoteFilesLocation.Folder(root, entry.location ?: currentPath))
        state.update { it.copy(highlighted = entry.name) }
    }

    private fun refresh() {
        if (state.value.access != RemoteFilesAccess.Ready) return
        val l = location as? RemoteFilesLocation.Folder
        if (l == null) {
            state.update { it.copy(entries = emptyList(), loading = false, folderError = null, truncated = false) }
            return
        }
        state.update { it.copy(loading = true, folderError = null) }
        val r = nextReq()
        listReq = r
        send(RemoteFilesWire.request("list", r) { put("root", l.root); put("path", RemoteFilesWire.names(l.path)) })
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
        previewCache[key]?.let { cached ->
            state.update { it.copy(preview = RemotePreview(entry, root, path, cached)) }
            return
        }
        state.update { it.copy(preview = RemotePreview(entry, root, path, RemotePreviewContent.Loading)) }
        val r = nextReq()
        previewReq = r
        send(RemoteFilesWire.request("preview", r) { put("root", root); put("path", RemoteFilesWire.names(path)); put("max", PREVIEW_SIDE) })
    }

    fun closePreview() { previewReq = null; state.update { it.copy(preview = null) } }

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

    /** Opens on the Mac (explicit action, needs control); [app] is a pane's app to open it in. */
    fun openOnMac(entry: RemoteFileEntry, app: String? = null) {
        val root = entry.root ?: currentRootID ?: return
        if (!inputAllowed()) return show(RemoteFilesNotice.NeedsControl)
        pendingOpenName = entry.name
        send(RemoteFilesWire.request("open", nextReq()) {
            put("root", root); put("path", RemoteFilesWire.names((entry.location ?: currentPath) + entry.name))
            app?.let { put("with", it) }
        })
    }

    private fun show(n: RemoteFilesNotice) {
        state.update { it.copy(notice = n) }
        cancelNotice?.invoke()
        cancelNotice = scheduler.after(2_600) { state.update { it.copy(notice = null) } }
    }

    // MARK: Replies

    fun apply(r: RemoteFilesReply) {
        if (r.error == "off" || r.error == "asking" || r.error == "denied") {
            val a = when (r.error) { "off" -> RemoteFilesAccess.Off; "denied" -> RemoteFilesAccess.Denied; else -> RemoteFilesAccess.Asking }
            state.update { it.copy(access = a, loading = false, searching = false) }
            return
        }
        when (r.op) {
            "state" -> when (r.state) {
                "off" -> state.update { it.copy(access = RemoteFilesAccess.Off) }
                "denied" -> state.update { it.copy(access = RemoteFilesAccess.Denied) }
                "noFolders" -> state.update { it.copy(access = RemoteFilesAccess.NoFolders, roots = emptyList()) }
                "ready" -> {
                    val wasReady = state.value.access == RemoteFilesAccess.Ready
                    var l = location
                    if (l is RemoteFilesLocation.Folder && r.roots.none { it.id == l.root }) { l = RemoteFilesLocation.Locations; back.clear() }
                    if (l == RemoteFilesLocation.Locations && r.roots.size == 1 && back.isEmpty() && !wasReady) l = RemoteFilesLocation.Folder(r.roots[0].id, emptyList())
                    state.update { it.copy(access = RemoteFilesAccess.Ready, roots = r.roots, location = l, canGoBack = back.isNotEmpty()) }
                    if (state.value.isOpen) {
                        refresh()
                        val q = state.value.query.trim()
                        if (q.isNotEmpty()) { state.update { it.copy(searching = true) }; cancelSearch?.invoke(); cancelSearch = scheduler.after(SEARCH_DEBOUNCE_MS) { startSearch(q.take(100)) } }
                    }
                }
                else -> state.update { it.copy(access = RemoteFilesAccess.Asking) }
            }
            "list" -> {
                if (r.req != null && r.req != listReq) return
                state.update { it.copy(loading = false) }
                val l = location as? RemoteFilesLocation.Folder ?: return
                if (r.root != null && r.root != l.root) return
                if (r.ok) {
                    if (r.path == l.path) state.update { it.copy(entries = r.entries, truncated = r.truncated, folderError = null) }
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
                    else -> RemotePreviewContent.Unavailable
                }
                state.update { it.copy(preview = p.copy(content = content)) }
                previewCache.remove(p.key)
                previewCache[p.key] = content
                while (previewCache.size > MAX_CACHED_PREVIEWS) previewCache.remove(previewCache.keys.first())
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

    private fun nextReq(): Int { req = if (req >= 1_000_000_000) 1 else req + 1; return req }
}

private fun JsonObject.s(k: String): String? = (this[k] as? JsonPrimitive)?.takeIf { it.isString }?.content
private fun JsonObject.i(k: String): Int? = (this[k] as? JsonPrimitive)?.takeIf { !it.isString }?.intOrNull
private fun JsonObject.l(k: String): Long? = (this[k] as? JsonPrimitive)?.takeIf { !it.isString }?.longOrNull
private fun JsonObject.b(k: String): Boolean? = (this[k] as? JsonPrimitive)?.takeIf { !it.isString }?.booleanOrNull

package com.raisecaterror.meowdisplay.android.receiver.workspace

import android.content.ClipData
import android.content.ContentResolver
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.ImageDecoder
import android.graphics.SurfaceTexture
import android.graphics.pdf.PdfRenderer
import android.media.MediaDataSource
import android.media.MediaPlayer
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import android.view.Surface
import android.view.TextureView
import android.webkit.MimeTypeMap
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContract
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.detectTransformGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Slider
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.FileProvider
import com.raisecaterror.meowdisplay.core.workspace.RemoteFileConflictChoice
import com.raisecaterror.meowdisplay.core.workspace.RemoteFileInfoSheet
import com.raisecaterror.meowdisplay.core.workspace.RemoteFilesExport
import com.raisecaterror.meowdisplay.core.workspace.RemoteFilesFormat
import com.raisecaterror.meowdisplay.core.workspace.RemoteFilesModel
import com.raisecaterror.meowdisplay.core.workspace.RemoteFolderConflictChoice
import com.raisecaterror.meowdisplay.core.workspace.RemoteTransferItem
import com.raisecaterror.meowdisplay.core.workspace.RemoteTransferPurpose
import com.raisecaterror.meowdisplay.core.workspace.RemoteTransferQueue
import com.raisecaterror.meowdisplay.core.workspace.RemoteUploadFolder
import com.raisecaterror.meowdisplay.core.workspace.RemoteUploadSource
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.text.DateFormat
import java.util.Date
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

// Remote Finder on Android, the system side: Save to Device through the system's document picker
// (Storage Access Framework), Share through the share sheet with read-only content URIs from our
// own FileProvider, uploads from picked documents and folder trees, and in-app viewers (movies
// and audio streamed with seeking, PDF pages, full-size images). Mirrors iOS RemoteFileViewers.

private const val SHARE_KEEP_MS = 30 * 60_000L

/** A picked document to upload: read through the ContentResolver (opened again on Retry). */
class ContentUriSource(
    private val resolver: ContentResolver,
    private val uri: Uri,
    override val name: String,
    override val size: Long,
    override val modified: Long?,
) : RemoteUploadSource {
    override fun open(): InputStream? = runCatching { resolver.openInputStream(uri) }.getOrNull()
}

private fun mimeOf(name: String): String =
    MimeTypeMap.getSingleton().getMimeTypeFromExtension(name.substringAfterLast('.', "").lowercase()) ?: "application/octet-stream"

/** "Create document" with the file's own type, so the picker keeps its name. */
private class CreateTypedDocument : ActivityResultContract<Pair<String, String>, Uri?>() {
    override fun createIntent(context: Context, input: Pair<String, String>) = Intent(Intent.ACTION_CREATE_DOCUMENT)
        .addCategory(Intent.CATEGORY_OPENABLE).setType(input.second).putExtra(Intent.EXTRA_TITLE, input.first)
    override fun parseResult(resultCode: Int, intent: Intent?): Uri? = intent?.data
}

/**
 * The system pickers and sheets Remote Finder uses. [requestUploadFiles] / [requestUploadFolder]
 * are filled in so the overlay's menus can open them.
 */
@Composable
fun RemoteFinderSystem(files: RemoteFilesModel, requests: RemoteFinderRequests) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val ui by files.ui.collectAsState()
    val resolver = context.contentResolver

    val pickFiles = rememberLauncherForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { uris ->
        if (uris.isEmpty()) return@rememberLauncherForActivityResult
        scope.launch {
            val sources = withContext(Dispatchers.IO) { uris.mapNotNull { documentSource(resolver, it) } }
            files.upload(sources)
        }
    }
    val pickFolder = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocumentTree()) { tree ->
        if (tree == null) return@rememberLauncherForActivityResult
        scope.launch {
            val folder = withContext(Dispatchers.IO) { folderTree(resolver, tree) }
            if (folder != null) files.upload(emptyList(), listOf(folder))
        }
    }
    requests.uploadFiles = { pickFiles.launch(arrayOf("*/*")) }
    requests.uploadFolder = { pickFolder.launch(null) }

    // Save: one file → "create document"; several or folders → a folder to save into.
    var saving by remember { mutableStateOf<RemoteFilesExport?>(null) }
    val createDoc = rememberLauncherForActivityResult(CreateTypedDocument()) { uri ->
        val e = saving ?: return@rememberLauncherForActivityResult
        saving = null
        if (uri == null) return@rememberLauncherForActivityResult files.exportFinished(e, false)
        scope.launch {
            val ok = withContext(Dispatchers.IO) { runCatching { copyFile(resolver, e.files.single(), uri) }.isSuccess }
            files.exportFinished(e, ok)
        }
    }
    val pickDest = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocumentTree()) { tree ->
        val e = saving ?: return@rememberLauncherForActivityResult
        saving = null
        if (tree == null) return@rememberLauncherForActivityResult files.exportFinished(e, false)
        scope.launch {
            val ok = withContext(Dispatchers.IO) {
                runCatching {
                    val parent = DocumentsContract.buildDocumentUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree))
                    e.files.forEach { copyInto(resolver, it, parent) }
                }.isSuccess
            }
            files.exportFinished(e, ok)
        }
    }
    LaunchedEffect(ui.export?.id) {
        val e = ui.export ?: return@LaunchedEffect
        when (e.mode) {
            RemoteFilesExport.Mode.Save -> {
                saving = e
                val single = e.files.singleOrNull()?.takeIf { it.isFile }
                if (single != null) createDoc.launch(single.name to mimeOf(single.name)) else pickDest.launch(null)
            }
            RemoteFilesExport.Mode.Share -> {
                share(context, e)
                // The receiving app reads the copies when it likes; they go a while later (and when the app starts).
                files.exportFinished(e, completed = false, keepForMs = SHARE_KEEP_MS)
            }
        }
    }
}

/** Filled in by [RemoteFinderSystem]; the overlay calls them from its menus. */
class RemoteFinderRequests {
    var uploadFiles: () -> Unit = {}
    var uploadFolder: () -> Unit = {}
}

private fun documentSource(resolver: ContentResolver, uri: Uri): RemoteUploadSource? {
    var name: String? = null
    var size = -1L
    var modified: Long? = null
    runCatching {
        resolver.query(uri, null, null, null, null)?.use { c ->
            if (c.moveToFirst()) {
                c.getColumnIndex(OpenableColumns.DISPLAY_NAME).takeIf { it >= 0 }?.let { name = c.getString(it) }
                c.getColumnIndex(OpenableColumns.SIZE).takeIf { it >= 0 && !c.isNull(it) }?.let { size = c.getLong(it) }
                c.getColumnIndex(DocumentsContract.Document.COLUMN_LAST_MODIFIED).takeIf { it >= 0 && !c.isNull(it) }?.let { modified = c.getLong(it) / 1000 }
            }
        }
    }
    val n = name?.takeIf { it.isNotEmpty() } ?: return null
    if (size < 0) return null   // the Mac needs the size up front
    return ContentUriSource(resolver, uri, n, size, modified)
}

/** A picked folder, walked without following links; hidden files stay on this device. */
private fun folderTree(resolver: ContentResolver, tree: Uri): RemoteUploadFolder? {
    val rootID = DocumentsContract.getTreeDocumentId(tree)
    val rootName = runCatching {
        resolver.query(DocumentsContract.buildDocumentUriUsingTree(tree, rootID), arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME), null, null, null)
            ?.use { c -> if (c.moveToFirst()) c.getString(0) else null }
    }.getOrNull() ?: return null
    val folders = mutableListOf<List<String>>()
    val files = mutableListOf<Pair<RemoteUploadSource, List<String>>>()
    val cols = arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID, DocumentsContract.Document.COLUMN_DISPLAY_NAME,
        DocumentsContract.Document.COLUMN_MIME_TYPE, DocumentsContract.Document.COLUMN_SIZE, DocumentsContract.Document.COLUMN_LAST_MODIFIED)
    fun walk(docID: String, rel: List<String>, depth: Int) {
        if (depth > 32 || folders.size + files.size >= RemoteFilesModel.MAX_EXPORT_FILES) return
        val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, docID)
        resolver.query(children, cols, null, null, null)?.use { c ->
            while (c.moveToNext()) {
                val id = c.getString(0) ?: continue
                val name = c.getString(1) ?: continue
                if (name.startsWith(".")) continue
                if (c.getString(2) == DocumentsContract.Document.MIME_TYPE_DIR) {
                    folders += rel + name
                    walk(id, rel + name, depth + 1)
                } else {
                    val size = if (c.isNull(3)) continue else c.getLong(3)
                    val mod = if (c.isNull(4)) null else c.getLong(4) / 1000
                    files += ContentUriSource(resolver, DocumentsContract.buildDocumentUriUsingTree(tree, id), name, size, mod) to (rel + name)
                }
            }
        }
    }
    runCatching { walk(rootID, emptyList(), 0) }
    return RemoteUploadFolder(rootName, folders, files)
}

private fun copyFile(resolver: ContentResolver, src: File, dest: Uri) {
    resolver.openOutputStream(dest, "w")?.use { out -> src.inputStream().use { it.copyTo(out, 256 * 1024) } } ?: throw IOException("no output")
}

private fun copyInto(resolver: ContentResolver, src: File, parent: Uri) {
    if (src.isDirectory) {
        val dir = DocumentsContract.createDocument(resolver, parent, DocumentsContract.Document.MIME_TYPE_DIR, src.name) ?: throw IOException("mkdir")
        src.listFiles()?.sortedBy { it.name }?.forEach { copyInto(resolver, it, dir) }
    } else {
        val doc = DocumentsContract.createDocument(resolver, parent, mimeOf(src.name), src.name) ?: throw IOException("create")
        copyFile(resolver, src, doc)
    }
}

private fun contentUri(context: Context, f: File): Uri = FileProvider.getUriForFile(context, context.packageName + ".remotefiles", f)

/** The share sheet with read-only content URIs (folders are shared as the files inside them). */
private fun share(context: Context, e: RemoteFilesExport) {
    val all = e.files.flatMap { f -> if (f.isDirectory) f.walkTopDown().filter { it.isFile }.toList() else listOf(f) }.take(100)
    if (all.isEmpty()) return
    val uris = all.map { contentUri(context, it) }
    val type = all.map { mimeOf(it.name) }.distinct().singleOrNull() ?: "*/*"
    val intent = if (uris.size == 1) Intent(Intent.ACTION_SEND).putExtra(Intent.EXTRA_STREAM, uris[0])
                 else Intent(Intent.ACTION_SEND_MULTIPLE).putParcelableArrayListExtra(Intent.EXTRA_STREAM, ArrayList(uris))
    intent.type = type
    intent.clipData = ClipData.newRawUri(null, uris[0]).also { c -> uris.drop(1).forEach { c.addItem(ClipData.Item(it)) } }
    intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
    context.startActivity(Intent.createChooser(intent, null).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION))
}

/** A private copy opened in another app on this device (needs the download capability). */
fun openElsewhere(context: Context, f: File) {
    val uri = contentUri(context, f)
    val intent = Intent(Intent.ACTION_VIEW).setDataAndType(uri, mimeOf(f.name)).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
    runCatching { context.startActivity(Intent.createChooser(intent, null).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)) }
}

// MARK: Streaming playback

/**
 * Byte ranges for MediaPlayer, read from the Mac through [RemoteFilesModel.stream] in 256 KiB
 * blocks with a little read-ahead. MediaPlayer calls from its own thread; the model lives on the
 * main thread, so each block is asked for there and waited for here (bounded).
 */
private class RemoteMediaDataSource(private val files: RemoteFilesModel, private val x: Int, private val total: Long) : MediaDataSource() {
    private val main = Handler(Looper.getMainLooper())
    private val block = com.raisecaterror.meowdisplay.core.workspace.RemoteFileStream.READ_BYTES
    private val cache = object : LinkedHashMap<Long, ByteArray>(32, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<Long, ByteArray>?) = size > 24
    }
    private val pending = HashMap<Long, CountDownLatch>()
    @Volatile private var closed = false

    override fun getSize(): Long = total

    override fun readAt(position: Long, buffer: ByteArray, offset: Int, size: Int): Int {
        if (closed) throw IOException("closed")
        if (position >= total) return -1
        if (size == 0) return 0
        val b = position / block
        val data = blockData(b)
        prefetch(b + 1); prefetch(b + 2)
        val start = (position - b * block).toInt()
        val n = minOf(size, data.size - start)
        if (n <= 0) return -1
        System.arraycopy(data, start, buffer, offset, n)
        return n
    }

    private fun blockData(b: Long): ByteArray {
        synchronized(cache) { cache[b] }?.let { return it }
        val latch = request(b)
        if (!latch.await(25, TimeUnit.SECONDS)) throw IOException("timeout")
        return synchronized(cache) { cache[b] } ?: throw IOException("read failed")
    }

    private fun request(b: Long): CountDownLatch = synchronized(pending) {
        pending[b] ?: CountDownLatch(1).also { latch ->
            pending[b] = latch
            main.post {
                val s = files.stream(x)
                if (s == null || closed) done(b, null) else s.read(b * block, block) { done(b, it) }
            }
        }
    }

    private fun done(b: Long, data: ByteArray?) {
        if (data != null) synchronized(cache) { cache[b] = data }
        synchronized(pending) { pending.remove(b) }?.countDown()
    }

    private fun prefetch(b: Long) {
        if (b * block >= total || closed) return
        if (synchronized(cache) { cache.containsKey(b) }) return
        request(b)
    }

    override fun close() { closed = true }
}

/** A movie or a song from the Mac, streamed: play, pause and scrub. */
@Composable
fun RemoteMediaPlayer(files: RemoteFilesModel, x: Int, size: Long, video: Boolean, onFailed: (String) -> Unit) {
    val player = remember(x) { MediaPlayer() }
    var prepared by remember(x) { mutableStateOf(false) }
    var playing by remember(x) { mutableStateOf(false) }
    var duration by remember(x) { mutableIntStateOf(0) }
    var position by remember(x) { mutableIntStateOf(0) }
    var aspect by remember(x) { mutableFloatStateOf(16f / 9f) }
    var scrubbing by remember(x) { mutableStateOf<Float?>(null) }
    DisposableEffect(x) {
        runCatching {
            player.setDataSource(RemoteMediaDataSource(files, x, size))
            player.setOnPreparedListener { prepared = true; duration = it.duration; it.start(); playing = true }
            player.setOnVideoSizeChangedListener { _, w, h -> if (w > 0 && h > 0) aspect = w.toFloat() / h }
            player.setOnCompletionListener { playing = false }
            player.setOnErrorListener { _, _, _ -> onFailed("unsupported"); true }
            player.prepareAsync()
        }.onFailure { onFailed("unsupported") }
        onDispose { runCatching { player.reset() }; player.release() }
    }
    LaunchedEffect(x) { while (true) { delay(250); if (prepared && scrubbing == null) position = runCatching { player.currentPosition }.getOrDefault(position) } }
    Column(Modifier.fillMaxSize(), verticalArrangement = Arrangement.Center, horizontalAlignment = Alignment.CenterHorizontally) {
        Box(Modifier.weight(1f).fillMaxWidth(), contentAlignment = Alignment.Center) {
            if (video) {
                AndroidView(
                    factory = { ctx ->
                        TextureView(ctx).apply {
                            surfaceTextureListener = object : TextureView.SurfaceTextureListener {
                                override fun onSurfaceTextureAvailable(st: SurfaceTexture, w: Int, h: Int) { runCatching { player.setSurface(Surface(st)) } }
                                override fun onSurfaceTextureSizeChanged(st: SurfaceTexture, w: Int, h: Int) {}
                                override fun onSurfaceTextureDestroyed(st: SurfaceTexture): Boolean { runCatching { player.setSurface(null) }; return true }
                                override fun onSurfaceTextureUpdated(st: SurfaceTexture) {}
                            }
                        }
                    },
                    modifier = Modifier.fillMaxWidth().aspectRatio(aspect, matchHeightConstraintsFirst = false).semantics { contentDescription = "Movie" },
                )
            } else Text("♫", color = Color.White.copy(alpha = 0.6f), fontSize = 64.sp)
            if (!prepared) CircularProgressIndicator(color = Color(0xFF5499FF), modifier = Modifier.size(30.dp), strokeWidth = 2.5.dp)
        }
        Row(Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 6.dp), verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            Text(if (playing) "❚❚" else "▶", color = Color.White, fontSize = 18.sp,
                modifier = Modifier.clip(CircleShape).clickable(enabled = prepared) {
                    if (playing) { player.pause(); playing = false } else { player.start(); playing = true }
                }.padding(10.dp).semantics { contentDescription = if (playing) "Pause" else "Play" })
            Text(clock(scrubbing?.toInt() ?: position), color = Color.White.copy(alpha = 0.7f), fontSize = 12.sp)
            Slider(
                value = (scrubbing ?: position.toFloat()).coerceIn(0f, maxOf(1, duration).toFloat()),
                onValueChange = { scrubbing = it },
                onValueChangeFinished = { scrubbing?.let { runCatching { player.seekTo(it.toInt()) }; position = it.toInt() }; scrubbing = null },
                valueRange = 0f..maxOf(1, duration).toFloat(), enabled = prepared && duration > 0,
                modifier = Modifier.weight(1f).semantics { contentDescription = "Position" },
            )
            Text(clock(duration), color = Color.White.copy(alpha = 0.7f), fontSize = 12.sp)
        }
    }
}

private fun clock(ms: Int): String {
    val s = ms / 1000
    return if (s >= 3600) "%d:%02d:%02d".format(s / 3600, s / 60 % 60, s % 60) else "%d:%02d".format(s / 60, s % 60)
}

// MARK: PDF and images

/** A PDF's pages, rendered at the view's width as they come on screen. */
@Composable
fun RemotePdfViewer(file: File) {
    val renderer = remember(file) { runCatching { PdfRenderer(ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)) }.getOrNull() }
    DisposableEffect(renderer) { onDispose { runCatching { renderer?.close() } } }
    if (renderer == null) return Text("This PDF can't be shown here.", color = Color.White.copy(alpha = 0.7f))
    val lock = remember(renderer) { Mutex() }
    val list = rememberLazyListState()
    BoxWithConstraints(Modifier.fillMaxSize()) {
        val widthPx = with(LocalDensity.current) { maxWidth.toPx() }.toInt().coerceIn(200, 2000)
        LazyColumn(state = list, modifier = Modifier.fillMaxSize(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            items((0 until renderer.pageCount).toList()) { i ->
                var page by remember(i) { mutableStateOf<ImageBitmap?>(null) }
                var ratio by remember(i) { mutableFloatStateOf(1.414f) }
                LaunchedEffect(i, widthPx) {
                    page = withContext(Dispatchers.IO) {
                        lock.withLock {
                            runCatching {
                                renderer.openPage(i).use { p ->
                                    ratio = p.height.toFloat() / p.width
                                    val bmp = Bitmap.createBitmap(widthPx, (widthPx * ratio).toInt().coerceAtLeast(1), Bitmap.Config.ARGB_8888)
                                    bmp.eraseColor(android.graphics.Color.WHITE)
                                    p.render(bmp, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                                    bmp.asImageBitmap()
                                }
                            }.getOrNull()
                        }
                    }
                }
                Box(Modifier.fillMaxWidth().aspectRatio(1f / ratio).background(Color.White), contentAlignment = Alignment.Center) {
                    page?.let { Image(it, "Page ${i + 1}", Modifier.fillMaxSize(), contentScale = ContentScale.FillWidth) }
                        ?: CircularProgressIndicator(Modifier.size(24.dp))
                }
            }
        }
        if (renderer.pageCount > 1) {
            Text("${list.firstVisibleItemIndex + 1} of ${renderer.pageCount}", color = Color.White, fontSize = 12.sp, fontWeight = FontWeight.Medium,
                modifier = Modifier.align(Alignment.BottomCenter).padding(10.dp).background(Color(0xE0333338), CircleShape).padding(horizontal = 12.dp, vertical = 6.dp))
        }
    }
}

/** An image file from the Mac at full resolution (up to 4096 px), with pinch and double-tap zoom. */
@Composable
fun RemoteFullImage(file: File, placeholder: ImageBitmap?) {
    var image by remember(file) { mutableStateOf<ImageBitmap?>(null) }
    LaunchedEffect(file) {
        image = withContext(Dispatchers.IO) {
            runCatching {
                ImageDecoder.decodeBitmap(ImageDecoder.createSource(file)) { d, info, _ ->
                    val side = maxOf(info.size.width, info.size.height)
                    if (side > 4096) { val s = 4096f / side; d.setTargetSize((info.size.width * s).toInt(), (info.size.height * s).toInt()) }
                    d.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
                }.asImageBitmap()
            }.getOrNull()
        }
    }
    val shown = image ?: placeholder
    if (shown == null) return CircularProgressIndicator(color = Color(0xFF5499FF), modifier = Modifier.size(30.dp), strokeWidth = 2.5.dp)
    var zoom by remember { mutableFloatStateOf(1f) }
    var panX by remember { mutableFloatStateOf(0f) }
    var panY by remember { mutableFloatStateOf(0f) }
    Image(shown, null, contentScale = ContentScale.Fit,
        modifier = Modifier.fillMaxSize().padding(10.dp)
            .pointerInput(Unit) {
                detectTransformGestures { _, pan, z, _ ->
                    zoom = (zoom * z).coerceIn(1f, 6f)
                    if (zoom > 1f) { panX += pan.x; panY += pan.y } else { panX = 0f; panY = 0f }
                }
            }
            .pointerInput(Unit) { detectTapGestures(onDoubleTap = { zoom = if (zoom > 1f) 1f else 2.5f; panX = 0f; panY = 0f }) }
            .graphicsLayer { scaleX = zoom; scaleY = zoom; translationX = panX; translationY = panY })
}

// MARK: Dialogs

@Composable
fun RemoteTransfersDialog(transfers: RemoteTransferQueue, onDismiss: () -> Unit) {
    val items by transfers.items.collectAsState()
    val shown = items.filter { it.purpose != RemoteTransferPurpose.View }.asReversed()
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Transfers") },
        text = {
            if (shown.isEmpty()) Text("Nothing is being copied.")
            else LazyColumn(Modifier.height(360.dp)) {
                items(shown, key = { it.id }) { item -> TransferRow(transfers, item) }
            }
        },
        confirmButton = { TextButton(onClick = onDismiss) { Text("Done") } },
        dismissButton = { if (shown.any { it.isFinished }) TextButton(onClick = { transfers.clearFinished() }) { Text("Clear Finished") } },
    )
}

@Composable
private fun TransferRow(transfers: RemoteTransferQueue, item: RemoteTransferItem) {
    Row(Modifier.fillMaxWidth().padding(vertical = 6.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        Text(if (item.isUpload) "↑" else "↓", fontSize = 18.sp, color = if (item.isUpload) Color(0xFFFF9F0A) else Color(0xFF5499FF))
        Column(Modifier.weight(1f)) {
            Text(item.resultName ?: item.name, maxLines = 1, overflow = TextOverflow.Ellipsis)
            if (item.state == RemoteTransferItem.State.Running || item.state == RemoteTransferItem.State.Waiting) {
                LinearProgressIndicator(progress = { item.fraction.toFloat() }, modifier = Modifier.fillMaxWidth().padding(vertical = 3.dp))
            }
            Text(transferStatus(item), fontSize = 12.sp, maxLines = 2)
        }
        when (item.state) {
            RemoteTransferItem.State.Running, RemoteTransferItem.State.Waiting, is RemoteTransferItem.State.Conflict ->
                TextButton(onClick = { transfers.cancel(item.id) }) { Text("Cancel") }
            is RemoteTransferItem.State.Failed -> TextButton(onClick = { transfers.retry(item.id) }) { Text("Retry") }
            else -> Unit
        }
    }
}

private fun bytes(n: Long): String {
    if (n < 1000) return "$n bytes"
    val units = listOf("KB", "MB", "GB", "TB")
    var v = n / 1000.0
    var i = 0
    while (v >= 1000 && i < units.size - 1) { v /= 1000; i++ }
    return if (v >= 10) "${v.toInt()} ${units[i]}" else "%.1f %s".format(v, units[i])
}

private fun transferStatus(i: RemoteTransferItem): String = when (val s = i.state) {
    RemoteTransferItem.State.Waiting -> "Waiting"
    RemoteTransferItem.State.Running -> "${bytes(i.transferred)} of ${bytes(i.size)}" + if (i.bytesPerSecond > 0) " · ${bytes(i.bytesPerSecond.toLong())}/s" else ""
    is RemoteTransferItem.State.Conflict -> "Already on the Mac: choose what to do"
    RemoteTransferItem.State.Done -> if (i.isUpload) "Uploaded" else "Copied"
    RemoteTransferItem.State.Skipped -> "Skipped"
    RemoteTransferItem.State.Cancelled -> "Cancelled"
    is RemoteTransferItem.State.Failed -> RemoteFilesFormat.errorText(s.code)
}

/** Asks what to do when an uploaded file's name exists on the Mac. */
@Composable
fun RemoteUploadConflictDialog(transfers: RemoteTransferQueue, canReplace: Boolean) {
    val items by transfers.items.collectAsState()
    val item = items.firstOrNull { it.state is RemoteTransferItem.State.Conflict } ?: return
    val several = items.count { it.batch == item.batch && !it.isFinished } > 1
    var forAll by remember(item.batch) { mutableStateOf(false) }
    AlertDialog(
        onDismissRequest = {},
        title = { Text("“${item.name}” already exists on the Mac") },
        text = {
            Column {
                Text("Replace moves the item on the Mac to its Trash.")
                if (several) Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.clickable { forAll = !forAll }) {
                    Checkbox(checked = forAll, onCheckedChange = { forAll = it }); Text("Do this for the rest")
                }
                Row(horizontalArrangement = Arrangement.spacedBy(4.dp), modifier = Modifier.padding(top = 8.dp)) {
                    TextButton(onClick = { transfers.resolveConflict(item.id, RemoteFileConflictChoice.KeepBoth, forAll) }) { Text("Keep Both") }
                    if (canReplace) TextButton(onClick = { transfers.resolveConflict(item.id, RemoteFileConflictChoice.Replace, forAll) }) { Text("Replace") }
                    TextButton(onClick = { transfers.resolveConflict(item.id, RemoteFileConflictChoice.Skip, forAll) }) { Text("Skip") }
                }
            }
        },
        confirmButton = {},
        dismissButton = { TextButton(onClick = { transfers.cancel(item.id) }) { Text("Stop Upload") } },
    )
}

@Composable
fun RemoteFolderConflictDialog(name: String, answer: (RemoteFolderConflictChoice?) -> Unit) {
    AlertDialog(
        onDismissRequest = { answer(null) },
        title = { Text("“$name” already exists on the Mac") },
        text = {
            Column {
                Text("Merge adds what you upload to the folder on the Mac; files with the same name ask again.")
                Row(horizontalArrangement = Arrangement.spacedBy(4.dp), modifier = Modifier.padding(top = 8.dp)) {
                    TextButton(onClick = { answer(RemoteFolderConflictChoice.Merge) }) { Text("Merge") }
                    TextButton(onClick = { answer(RemoteFolderConflictChoice.KeepBoth) }) { Text("Keep Both") }
                    TextButton(onClick = { answer(RemoteFolderConflictChoice.Skip) }) { Text("Skip") }
                }
            }
        },
        confirmButton = {},
        dismissButton = { TextButton(onClick = { answer(null) }) { Text("Cancel") } },
    )
}

@Composable
fun RemoteNameDialog(title: String, initial: String, action: String, message: String? = null, onDone: (String?) -> Unit) {
    var text by remember { mutableStateOf(initial) }
    AlertDialog(
        onDismissRequest = { onDone(null) },
        title = { Text(title) },
        text = {
            Column {
                message?.let { Text(it, modifier = Modifier.padding(bottom = 8.dp)) }
                OutlinedTextField(text, { text = it }, singleLine = true, label = { Text("Name") })
            }
        },
        confirmButton = { TextButton(onClick = { onDone(text) }, enabled = RemoteFilesFormat.cleanName(text) != null) { Text(action) } },
        dismissButton = { TextButton(onClick = { onDone(null) }) { Text("Cancel") } },
    )
}

@Composable
fun RemoteInfoDialog(sheet: RemoteFileInfoSheet, onDismiss: () -> Unit) {
    val i = sheet.info
    fun date(s: Long?) = s?.let { DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT).format(Date(it * 1000)) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(i.name.ifEmpty { sheet.entry.name }, maxLines = 2, overflow = TextOverflow.Ellipsis) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                listOfNotNull(
                    "Kind" to i.kind.ifEmpty { RemoteFilesFormat.kindName(sheet.entry.kind) },
                    i.size?.let { "Size" to bytes(it) + if (i.complete) "" else "+" },
                    i.items?.let { "Items" to "$it" },
                    date(i.created)?.let { "Created" to it },
                    date(i.modified)?.let { "Modified" to it },
                    date(i.opened)?.let { "Last opened" to it },
                    i.cloud?.let { "iCloud" to it },
                    i.owner.takeIf { it.isNotEmpty() }?.let { "Owner" to it },
                    i.permissions.takeIf { it.isNotEmpty() }?.let { "Permissions" to it },
                    "Can be changed" to if (i.writable && !i.locked) "Yes" else "No",
                ).forEach { (k, v) ->
                    Row { Text(k, modifier = Modifier.width(120.dp), color = Color.Gray); Text(v) }
                }
            }
        },
        confirmButton = { TextButton(onClick = onDismiss) { Text("Done") } },
    )
}

/** What a file grant allows, in a few words. */
fun grantSummary(g: com.raisecaterror.meowdisplay.core.workspace.RemoteFilesGrant): String {
    val what = if (g.readOnly) (if (g.canDownload) "View & Save" else "View Only") else "Can Edit"
    return what + " · " + (if (g.always) "Always" else "This Session")
}

fun grantDescription(g: com.raisecaterror.meowdisplay.core.workspace.RemoteFilesGrant): String {
    val caps = listOf("download", "upload", "modify", "delete").filter { it in g.capabilities }.map(RemoteFilesFormat::capabilityName)
    return listOf(
        if (g.always) "Always allowed for this device" else "Allowed for this session",
        if (g.allFiles) "all files the Mac lets MeowDisplay read" else "approved folders",
        if (caps.isEmpty()) "viewing only" else "viewing, " + caps.joinToString(", "),
    ).joinToString(" · ")
}


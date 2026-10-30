package com.raisecaterror.meowdisplay.android.receiver.workspace

import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Context
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.os.PersistableBundle
import android.provider.OpenableColumns
import android.text.Html
import android.text.format.Formatter
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalWindowInfo
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.core.content.FileProvider
import com.raisecaterror.meowdisplay.android.receiver.Caption
import com.raisecaterror.meowdisplay.android.receiver.Choice
import com.raisecaterror.meowdisplay.android.receiver.Section
import com.raisecaterror.meowdisplay.android.receiver.Toggle
import com.raisecaterror.meowdisplay.core.clipboard.ClipDirection
import com.raisecaterror.meowdisplay.core.clipboard.ClipFiles
import com.raisecaterror.meowdisplay.core.clipboard.ClipKind
import com.raisecaterror.meowdisplay.core.clipboard.ClipLocalContent
import com.raisecaterror.meowdisplay.core.clipboard.ClipLocalFile
import com.raisecaterror.meowdisplay.core.clipboard.ClipTypes
import com.raisecaterror.meowdisplay.core.clipboard.ClipboardModel
import com.raisecaterror.meowdisplay.core.clipboard.ClipboardPlatform
import com.raisecaterror.meowdisplay.core.clipboard.ClipboardUi
import com.raisecaterror.meowdisplay.core.clipboard.ClipboardWire
import com.raisecaterror.meowdisplay.core.clipboard.MacClipState
import com.raisecaterror.meowdisplay.core.controls.CGRect
import com.raisecaterror.meowdisplay.core.workspace.RemoteFilesExport
import java.io.File
import java.text.DateFormat
import java.util.Date
import java.util.UUID
import java.util.concurrent.Executors

// Unified Clipboard on Android: the system clipboard (read only while MeowDisplay is in front,
// as Android requires), Settings ▸ Clipboard, and the small prompts over the picture.
// Content is never logged or shown in notifications.

/**
 * The system clipboard. Copies from the Mac are marked as ours and as from another device;
 * images go on the clipboard as read-only content URIs from our FileProvider. Copies an app
 * marked sensitive (ClipDescription.EXTRA_IS_SENSITIVE) are never read for sending.
 */
class AndroidClipboardPlatform(private val context: Context, tag: String) : ClipboardPlatform {
    private val cm = context.getSystemService(ClipboardManager::class.java)
    private val main = Handler(Looper.getMainLooper())
    private val io = Executors.newSingleThreadExecutor { r -> Thread(r, "clipboard-read").apply { isDaemon = true } }
    private val root = File(context.cacheDir, "RemoteFinder")
    private val inDir = File(root, "clipboard-in")
    private val outDir = File(File(root, "clipboard-out"), tag)
    private val sentBatches = ArrayDeque<File>()

    // Copies sent by an earlier run are not needed any more. (Images from the Mac stay until
    // replaced: they are what the system clipboard holds.)
    init { io.execute { outDir.deleteRecursively() } }

    override fun changeToken(): Long? {
        val d = runCatching { cm.primaryClipDescription }.getOrNull() ?: return null
        if (d.extras?.getBoolean(MARK) == true) return OWN
        return d.timestamp
    }

    override fun write(items: List<List<Pair<ClipKind, ByteArray>>>): Long? {
        inDir.deleteRecursively()
        val clipItems = mutableListOf<ClipData.Item>()
        val mimes = LinkedHashSet<String>()
        for (reps in items) {
            val m = reps.toMap()
            val html = m[ClipKind.Html]?.let { String(it, Charsets.UTF_8) }
            val text = (m[ClipKind.Text] ?: m[ClipKind.Url])?.let { String(it, Charsets.UTF_8) }
                ?: html?.let { Html.fromHtml(it, Html.FROM_HTML_MODE_COMPACT).toString() }
            val image = m[ClipKind.Png]?.let { Triple(it, "png", "image/png") } ?: m[ClipKind.Jpeg]?.let { Triple(it, "jpg", "image/jpeg") }
            val uri = image?.let { (bytes, ext, mime) ->
                runCatching {
                    inDir.mkdirs()
                    val f = File(inDir, "Copied Image ${clipItems.size + 1}.$ext").apply { writeBytes(bytes) }
                    FileProvider.getUriForFile(context, context.packageName + ".remotefiles", f)
                }.getOrNull()?.also { mimes += mime }
            }
            if (text == null && uri == null) continue
            if (text != null) mimes += ClipDescription.MIMETYPE_TEXT_PLAIN
            if (html != null) mimes += ClipDescription.MIMETYPE_TEXT_HTML
            clipItems += ClipData.Item(text, html, null, uri)
        }
        if (clipItems.isEmpty()) return null
        val desc = ClipDescription("MeowDisplay", mimes.toTypedArray()).apply {
            extras = PersistableBundle().apply { putBoolean(MARK, true); putBoolean(EXTRA_IS_REMOTE_DEVICE, true) }
        }
        val clip = ClipData(desc, clipItems.first()).apply { clipItems.drop(1).forEach(::addItem) }
        return if (runCatching { cm.setPrimaryClip(clip) }.isSuccess) OWN else null
    }

    override fun read(textOnly: Boolean, maxBytes: Int, done: (ClipLocalContent?) -> Unit) {
        val clip = runCatching { cm.primaryClip }.getOrNull()
        val d = clip?.description
        if (clip == null || d == null || d.extras?.getBoolean(EXTRA_IS_SENSITIVE) == true || d.extras?.getBoolean(MARK) == true) {
            done(null); return
        }
        io.execute {
            val c = runCatching { content(clip, textOnly, maxBytes) }.getOrNull()
            main.post { done(c) }
        }
    }

    /** Removes the private copies of files sent to the Mac (on disconnect; the app also clears its cache at start). */
    fun forgetSent() = io.execute { synchronized(sentBatches) { sentBatches.clear() }; outDir.deleteRecursively() }

    private fun content(clip: ClipData, textOnly: Boolean, maxBytes: Int): ClipLocalContent? {
        val resolver = context.contentResolver
        val items = mutableListOf<List<Pair<ClipKind, ByteArray>>>()
        val files = mutableListOf<ClipLocalFile>()
        var batch: File? = null
        for (i in 0 until minOf(clip.itemCount, ClipboardWire.MAX_ITEMS)) {
            val item = clip.getItemAt(i)
            val reps = mutableListOf<Pair<ClipKind, ByteArray>>()
            val html = item.htmlText
            val text = item.text?.toString() ?: html?.let { Html.fromHtml(it, Html.FROM_HTML_MODE_COMPACT).toString() }
            text?.let { reps += ClipKind.Text to it.toByteArray() }
            if (!textOnly && html != null) reps += ClipKind.Html to html.toByteArray()
            val uri: Uri? = item.uri
            when {
                uri == null -> {}
                uri.scheme == "http" || uri.scheme == "https" -> if (text == null) reps += ClipKind.Url to uri.toString().toByteArray()
                uri.scheme == "content" && !textOnly -> run {
                    // Too large or unreadable: the item's text (if any) still goes. The reported
                    // size is only a hint; what is actually read is capped at the limit.
                    if ((sizeOf(uri) ?: 0) > maxBytes) return@run
                    val type = resolver.getType(uri)
                    if (type == "image/png" || type == "image/jpeg") {
                        val buf = java.io.ByteArrayOutputStream()
                        val ok = runCatching { resolver.openInputStream(uri)?.use { copyCapped(it, buf, maxBytes.toLong()) } }.getOrNull() == true
                        if (!ok) return@run
                        reps += (if (type == "image/png") ClipKind.Png else ClipKind.Jpeg) to buf.toByteArray()
                    } else {
                        val dir = batch ?: File(outDir, UUID.randomUUID().toString()).apply { mkdirs() }.also { batch = it }
                        val name = nameOf(uri)?.takeIf { ClipFiles.isSafeName(it) && files.none { f -> f.name == it } } ?: "Copied File ${files.size + 1}"
                        val f = File(dir, name)
                        val ok = runCatching { resolver.openInputStream(uri)?.use { input -> f.outputStream().use { copyCapped(input, it, maxBytes.toLong()) } } }.getOrNull() == true
                        if (!ok) { f.delete(); return@run }
                        files += ClipLocalFile(name, f)
                    }
                }
            }
            if (reps.isNotEmpty()) items += reps
        }
        batch?.let { b ->
            // Keep the last two copies the Mac may still fetch.
            synchronized(sentBatches) {
                sentBatches.addLast(b)
                while (sentBatches.size > 2) sentBatches.removeFirst().deleteRecursively()
            }
        }
        return if (items.isEmpty() && files.isEmpty()) null else ClipLocalContent(items, files)
    }

    /** Copies at most [limit] bytes; false (stop) when the source has more. */
    private fun copyCapped(input: java.io.InputStream, out: java.io.OutputStream, limit: Long): Boolean {
        val buf = ByteArray(256 * 1024)
        var total = 0L
        while (true) {
            val n = input.read(buf)
            if (n < 0) return true
            total += n
            if (total > limit) return false
            out.write(buf, 0, n)
        }
    }

    private fun nameOf(uri: Uri): String? = runCatching {
        context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
            if (c.moveToFirst() && !c.isNull(0)) c.getString(0) else null
        }
    }.getOrNull()

    private fun sizeOf(uri: Uri): Long? = runCatching {
        context.contentResolver.query(uri, arrayOf(OpenableColumns.SIZE), null, null, null)?.use { c ->
            if (c.moveToFirst() && !c.isNull(0)) c.getLong(0) else null
        } ?: context.contentResolver.openAssetFileDescriptor(uri, "r")?.use { it.length.takeIf { n -> n >= 0 } }
    }.getOrNull()

    companion object {
        private const val MARK = "app.meowdisplay.clip"
        private const val OWN = -1L
        // ClipDescription.EXTRA_IS_SENSITIVE / EXTRA_IS_REMOTE_DEVICE (API 33); plain keys work on every level.
        private const val EXTRA_IS_SENSITIVE = "android.content.extra.IS_SENSITIVE"
        private const val EXTRA_IS_REMOTE_DEVICE = "android.content.extra.IS_REMOTE_DEVICE"
    }
}

/** Settings ▸ Clipboard. */
@Composable
internal fun ClipboardSettingsPage(clipboard: ClipboardModel?, demo: Boolean) {
    Section("Unified Clipboard")
    if (clipboard == null || demo) {
        Caption("Copy on your Mac and paste here, and the other way round, once you connect to a Mac and turn it on here. It isn't available in the demo.")
        return
    }
    val context = LocalContext.current
    val ui by clipboard.ui.collectAsState()
    Toggle("Unified Clipboard", ui.enabled) { clipboard.setEnabled(it) }
    Caption("Copy on your Mac and paste here, and the other way round. The Mac asks the first time (or follows its own setting for this device). Copies can contain passwords or private messages, so turn this on only for Macs you trust. Nothing is kept after it is replaced.")
    if (!ui.enabled) return
    Section("What Syncs")
    Choice("Direction", ClipDirection.entries, ui.direction, {
        when (it) { ClipDirection.Both -> "Both Ways"; ClipDirection.ToDevice -> "Mac to This Device Only"; ClipDirection.ToMac -> "This Device to Mac Only" }
    }) { clipboard.setDirection(it) }
    Choice("Types", ClipTypes.entries, ui.types, { if (it == ClipTypes.Text) "Text and Links Only" else "All Supported Types" }) { clipboard.setTypes(it) }
    Toggle("Copied Files", ui.syncFiles, enabled = ui.types == ClipTypes.All) { clipboard.setSyncFiles(it) }
    Choice("Transfer Automatically Up To", ClipboardWire.SIZE_CHOICES, ui.maxBytes, { Formatter.formatShortFileSize(context, it.toLong()) }) { clipboard.setMaxBytes(it) }
    Toggle("Send Copies Automatically", ui.autoSend) { clipboard.setAutoSend(it) }
    Caption("When on, what you copy in other apps goes to the Mac when you return to MeowDisplay: Android lets an app read the clipboard only while it is in front, and shows a notice when it does. When off, use the Send to Mac button that appears after you copy. Copies an app marks as sensitive (many password managers do) are never sent, but not every app marks them. Copies from the Mac arrive while MeowDisplay is open.")
    Section("Status")
    Text("Mac: ${clipboardStateText(ui)}", style = MaterialTheme.typography.bodyMedium)
    ui.lastTransfer?.let { t ->
        val time = DateFormat.getTimeInstance(DateFormat.SHORT).format(Date(t.atMs))
        Text((if (t.fromMac) "Last from the Mac: " else "Last sent to the Mac: ") + (t.failure?.let { "${t.summary}: $it" } ?: "${t.summary}, $time"),
            style = MaterialTheme.typography.bodyMedium)
    }
    if (ui.progress != null) OutlinedButton(onClick = { clipboard.cancelTransfer() }) { Text("Cancel Transfer") }
}

private fun clipboardStateText(ui: ClipboardUi): String = when (ui.macState) {
    MacClipState.Unavailable -> "Not connected, or the Mac doesn't support it"
    MacClipState.Off -> "Off on the Mac (Settings ▸ Clipboard)"
    MacClipState.Idle -> "Off on this device"
    MacClipState.Asking -> "Waiting for the Mac to allow it"
    MacClipState.Denied -> "Not allowed by the Mac"
    MacClipState.Paused -> "Paused on the Mac"
    MacClipState.Revoked -> "Revoked on the Mac"
    MacClipState.Ready -> {
        val way = if (ui.toDevice && ui.toMac) "both ways" else if (ui.toDevice) "from the Mac only" else "to the Mac only"
        if (ui.always) "On, $way (always allowed)" else "On, $way (this session)"
    }
}

/**
 * Small, transient prompts over the picture: send a copy made elsewhere, files the Mac copied,
 * a same-moment copy to choose. Never shows the content itself. Also checks for a new copy each
 * time MeowDisplay comes to the front, and runs Save/Share for the Mac's files.
 */
@Composable
internal fun ClipboardBanner(clipboard: ClipboardModel, modifier: Modifier = Modifier, onFrame: (CGRect?) -> Unit) {
    val ui by clipboard.ui.collectAsState()
    val focused = LocalWindowInfo.current.isWindowFocused
    LaunchedEffect(focused, ui.ready) {
        if (!focused || !ui.ready) return@LaunchedEffect
        kotlinx.coroutines.delay(250)   // the clipboard service sees the focus a moment later
        clipboard.checkLocal(automatic = true)
    }
    ExportLauncher(ui.export) { e, ok, keep -> clipboard.exportFinished(e, ok, keep) }
    val pending = ui.localChangePending && ui.canSendToMac
    if (!ui.enabled || !(pending || ui.macFiles != null || ui.alternativeWaiting || ui.progress != null || ui.notice != null)) return
    val density = LocalDensity.current.density.toDouble()
    DisposableEffect(Unit) { onDispose { onFrame(null) } }
    Column(
        modifier.onGloballyPositioned { c -> val b = c.boundsInRoot(); onFrame(CGRect(b.left / density, b.top / density, b.width / density, b.height / density)) },
        verticalArrangement = Arrangement.spacedBy(8.dp), horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        val light = ButtonDefaults.textButtonColors(contentColor = Color.White)
        if (pending) Pill {
            Text("You copied something", fontWeight = FontWeight.SemiBold, style = MaterialTheme.typography.bodySmall)
            Button(onClick = { clipboard.checkLocal(automatic = false) }, modifier = Modifier.semantics { contentDescription = "Send to Mac. Sends it to the Mac's clipboard" }) { Text("Send to Mac") }
        }
        ui.macFiles?.let { e ->
            Pill {
                Text("The Mac copied ${e.summary}", fontWeight = FontWeight.SemiBold, style = MaterialTheme.typography.bodySmall)
                Button(onClick = { clipboard.getMacFiles(RemoteFilesExport.Mode.Save) }) { Text("Save") }
                TextButton(onClick = { clipboard.getMacFiles(RemoteFilesExport.Mode.Share) }, colors = light) { Text("Share") }
                TextButton(onClick = { clipboard.dismissMacFiles() }, colors = light) { Text("✕", Modifier.semantics { contentDescription = "Dismiss" }) }
            }
        }
        if (ui.alternativeWaiting) Pill {
            Text("The Mac copied something at the same moment", fontWeight = FontWeight.SemiBold, style = MaterialTheme.typography.bodySmall)
            TextButton(onClick = { clipboard.useAlternative() }, colors = light) { Text("Use the Mac's Copy") }
        }
        ui.progress?.let { (done, total) ->
            Pill {
                LinearProgressIndicator(progress = { done.toFloat() / maxOf(total, 1L) }, modifier = Modifier.width(120.dp))
                TextButton(onClick = { clipboard.cancelTransfer() }, colors = light) { Text("Cancel") }
            }
        }
        ui.notice?.let { n ->
            Pill { Text(n, style = MaterialTheme.typography.bodySmall) }
            LaunchedEffect(n) { kotlinx.coroutines.delay(2_500); clipboard.dismissNotice() }
        }
    }
}

@Composable
private fun Pill(content: @Composable () -> Unit) {
    Surface(color = Color(0xEE1F1F1F), contentColor = Color.White, shape = RoundedCornerShape(percent = 50)) {
        Row(Modifier.padding(horizontal = 14.dp, vertical = 6.dp), horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
            content()
        }
    }
}

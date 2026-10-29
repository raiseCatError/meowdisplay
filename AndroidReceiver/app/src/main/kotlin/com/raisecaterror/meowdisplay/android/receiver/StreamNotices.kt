package com.raisecaterror.meowdisplay.android.receiver

import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import com.raisecaterror.meowdisplay.android.session.SessionHost
import com.raisecaterror.meowdisplay.core.session.DisplayMode

/**
 * The Mac has no physical display to mirror (closed lid, headless): offer Extend instead (pv 17
 * `mirrorUnavailable`). Switching goes through the ordinary Mac-confirmed mode request.
 */
@Composable
fun MirrorUnavailableOffer(media: SessionHost) {
    val stream by media.session.streamSettings.collectAsState()
    val ui by media.ui.collectAsState()
    var dismissedFor by remember { mutableStateOf<String?>(null) }
    if (!stream.mirrorUnavailable || !ui.admitted || dismissedFor == ui.peerID) return
    AlertDialog(
        onDismissRequest = { dismissedFor = ui.peerID },
        title = { Text("No display to mirror") },
        text = { Text("Your Mac has no screen MeowDisplay can mirror right now, for example when its lid is closed. Extend gives it a separate display on this device instead.") },
        confirmButton = { TextButton(onClick = { media.session.requestDisplayMode(DisplayMode.Extend) }) { Text("Switch to Extend") } },
        dismissButton = { TextButton(onClick = { dismissedFor = ui.peerID }) { Text("Not Now") } },
    )
}

/**
 * The Mac said this app is too old to work with it (`updateRequired`, iOS `UpdateRequiredView`):
 * a full-screen notice whose main action gets the update. Unlike iOS it can be put aside, because
 * another Mac may still work with this version; Home keeps the notice until a new connection.
 */
@Composable
fun UpdateRequiredNotice(media: SessionHost) {
    val ui by media.ui.collectAsState()
    // A new notice (another Mac, or the same one again) shows again.
    var dismissed by remember(ui.peerID, ui.receiverUpdateRequired) { mutableStateOf(false) }
    if (!ui.receiverUpdateRequired || dismissed) return
    val context = LocalContext.current
    val link = ui.updateLink
    val onGooglePlay = link?.let { runCatching { Uri.parse(it).host }.getOrNull() } == "play.google.com"
    Dialog(onDismissRequest = { dismissed = true }, properties = DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false)) {
        BackHandler { dismissed = true }
        Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.surface) {
            Column(
                Modifier.safeDrawingPadding().padding(32.dp),
                verticalArrangement = Arrangement.spacedBy(20.dp, Alignment.CenterVertically),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Text("⬆", style = MaterialTheme.typography.displayMedium, color = MaterialTheme.colorScheme.primary)
                Text("Update required", style = MaterialTheme.typography.headlineSmall, modifier = Modifier.semantics { heading() })
                Text(
                    ui.updateMessage ?: "Update MeowDisplay to keep using your second display.",
                    style = MaterialTheme.typography.bodyLarge, color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = TextAlign.Center,
                )
                if (link != null) {
                    Button(onClick = {
                        try {
                            context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(link)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                        } catch (_: ActivityNotFoundException) {
                        }
                    }, modifier = Modifier.fillMaxWidth()) { Text(if (onGooglePlay) "Update on Google Play" else "Get the Latest Version") }
                }
                TextButton(onClick = { dismissed = true }) { Text("Not Now") }
            }
        }
    }
}

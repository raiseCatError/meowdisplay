package com.raisecaterror.meowdisplay.android.ui

import androidx.compose.foundation.Image
import androidx.compose.ui.res.painterResource
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import com.raisecaterror.meowdisplay.android.R
import android.content.ClipData
import android.content.ClipboardManager
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.raisecaterror.meowdisplay.android.discovery.Bonjour
import com.raisecaterror.meowdisplay.android.identity.DeviceIdentity
import com.raisecaterror.meowdisplay.android.pairing.PairingController
import com.raisecaterror.meowdisplay.android.session.MediaController
import com.raisecaterror.meowdisplay.android.session.MediaUiState
import com.raisecaterror.meowdisplay.android.trust.PinStore
import com.raisecaterror.meowdisplay.core.pairing.PairingClassification
import com.raisecaterror.meowdisplay.core.session.DisplayMode
import com.raisecaterror.meowdisplay.core.session.InputWireState
import com.raisecaterror.meowdisplay.core.session.ReceiverApprovalDecision
import com.raisecaterror.meowdisplay.core.session.SessionPhase

/**
 * Home: what's connected (and the way back to it), your Macs, Macs to pair,
 * how to connect, and this device's details. While a session is live this is
 * shown over the running picture, so returning to it is instant.
 */
@Composable
fun ReceiverHome(
    identity: DeviceIdentity,
    pins: PinStore,
    bonjour: Bonjour,
    pairing: PairingController,
    media: MediaController,
    onReturnToDisplay: (() -> Unit)? = null,
    onOpenSettings: (() -> Unit)? = null,
) {
    val ui by pairing.ui.collectAsState()
    val mediaUi by media.ui.collectAsState()
    val nearby by bonjour.nearbyMacs.collectAsState()
    val paired by pins.paired.collectAsState()
    val autoRequestFlow = remember(media) { media.inputAutoRequest?.enabledPeers ?: kotlinx.coroutines.flow.MutableStateFlow(emptySet<String>()) }
    val autoRequestPeers by autoRequestFlow.collectAsState()
    val macName = { peerID: String? -> paired.firstOrNull { it.peerID == peerID }?.name ?: "your Mac" }
    var showDetails by remember { mutableStateOf(false) }
    var showSteps by rememberSaveable { mutableStateOf(paired.isEmpty()) }
    val pairedNames = paired.map { it.name }.toSet()
    // Bonjour names only: a nearby Mac with a paired Mac's name is shown once, under Your Macs.
    val toPair = nearby.filter { it.serviceName !in pairedNames }

    Surface(color = MaterialTheme.colorScheme.background, modifier = Modifier.fillMaxSize()) {
        LazyColumn(
            modifier = Modifier.fillMaxSize().safeDrawingPadding().padding(horizontal = 20.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            item {
                Column(Modifier.widthIn(max = 640.dp).fillMaxWidth().padding(top = 24.dp)) {
                    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                        Image(painterResource(R.drawable.meow_logo), contentDescription = null, modifier = Modifier.size(56.dp))
                        Spacer(Modifier.width(12.dp))
                        Text("MeowDisplay", style = MaterialTheme.typography.headlineLarge, color = MaterialTheme.colorScheme.onBackground,
                            modifier = Modifier.weight(1f).semantics { heading() })
                        onOpenSettings?.let { open -> TextButton(onClick = open) { Text("Settings") } }
                    }
                    Text("A second screen for your Mac.", style = MaterialTheme.typography.bodyLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
            if (onReturnToDisplay != null && mediaUi.admitted) {
                item { ConnectedCard(macName(mediaUi.peerID), mediaUi, onReturnToDisplay, onOpenSettings) { media.session.disconnect() } }
            } else {
                item { Hint(sessionStatus(mediaUi, macName(mediaUi.peerID))) }
            }
            mediaUi.updateMessage?.let { message -> item { Hint(listOfNotNull(message, mediaUi.updateLink).joinToString("\n")) } }
            ui.message?.let { message -> item { Notice(message, onDismiss = pairing::dismissMessage) } }
            mediaUi.connectFailedFor?.let { peer ->
                item {
                    Notice("${macName(peer)} didn't connect. Check that MeowDisplay is open on it and that both are on the same Wi-Fi, then try again.",
                        onDismiss = media::dismissConnectFailure)
                }
            }

            item { SectionTitle("Your Macs") }
            if (paired.isEmpty()) item { Hint("None yet. Pair a Mac below; after that, Connect is one tap.") }
            items(paired, key = { "paired-" + it.peerID }) { mac ->
                val live = mediaUi.peerID == mac.peerID && mediaUi.admitted
                val connecting = mediaUi.connectingTo == mac.peerID
                MacRow(
                    title = mac.name,
                    subtitle = when {
                        live -> "Connected"
                        connecting -> "Asking it to connect…"
                        else -> null
                    },
                    primary = when {
                        live && onReturnToDisplay != null -> "Show" to onReturnToDisplay
                        live -> null
                        connecting -> "Cancel" to media::cancelConnect
                        else -> "Connect" to { media.requestConnect(mac.peerID) }
                    },
                    enabled = mediaUi.listening || live,
                    menu = buildList {
                        if (!live && !connecting) {
                            add("Connect with Extend" to { media.requestConnect(mac.peerID, DisplayMode.Extend) })
                            add("Connect with Mirror" to { media.requestConnect(mac.peerID, DisplayMode.Mirror) })
                        }
                        media.inputAutoRequest?.let { auto ->
                            val on = mac.peerID in autoRequestPeers
                            add((if (on) "Request Input Automatically: On" else "Request Input Automatically: Off") to { auto.setEnabled(mac.peerID, !on) })
                        }
                        add("Forget This Mac" to { media.forget(mac.peerID) })
                    },
                )
            }

            item { SectionTitle("Pair a Mac") }
            if (toPair.isEmpty()) item { Hint(if (mediaUi.listening) "Looking for Macs with MeowDisplay open on this Wi-Fi…" else "Open MeowDisplay to look for Macs.") }
            items(toPair, key = { "nearby-" + it.serviceName }) { mac ->
                MacRow(
                    title = mac.serviceName, subtitle = null,
                    primary = (if (ui.pairingWith == mac.serviceName) "Pairing…" else "Pair") to { pairing.pair(mac) },
                    enabled = ui.pairingWith == null, menu = emptyList(),
                )
            }

            item {
                Column(Modifier.widthIn(max = 640.dp).fillMaxWidth()) {
                    TextButton(onClick = { showSteps = !showSteps }) { Text(if (showSteps) "Hide connection steps" else "How to connect") }
                    if (showSteps) Steps()
                }
            }
            item {
                Row(Modifier.widthIn(max = 640.dp).fillMaxWidth().padding(bottom = 24.dp), verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text("This device", style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        Text(DeviceIdentity.displayName(LocalContext.current), style = MaterialTheme.typography.bodyLarge)
                    }
                    TextButton(onClick = { showDetails = true }) { Text("Device Details") }
                }
            }
        }
    }

    if (showDetails) DeviceDetails(identity.fingerprint) { showDetails = false }

    mediaUi.approval?.let { approval ->
        AlertDialog(
            onDismissRequest = {},
            title = { Text("Show ${macName(approval.peerID)} here?") },
            text = {
                Text(
                    "It wants to " + when (approval.mode) {
                        DisplayMode.Mirror -> "mirror its screen"
                        DisplayMode.Window -> "show its windows"
                        else -> "extend its desktop"
                    } + " on this device. It can't control anything here, and it can't use your input unless you ask."
                )
            },
            confirmButton = { TextButton(onClick = { media.answer(approval.id, ReceiverApprovalDecision.Allow) }) { Text("Allow") } },
            dismissButton = { TextButton(onClick = { media.answer(approval.id, ReceiverApprovalDecision.RejectForSession) }) { Text("Not Now") } },
        )
    }

    ui.prompt?.let { prompt ->
        AlertDialog(
            onDismissRequest = {},
            title = {
                Text(
                    when (prompt.classification) {
                        PairingClassification.NewPeer -> "Pair with ${prompt.peerName}?"
                        PairingClassification.RePairSameKey -> "Pair again with ${prompt.peerName}?"
                        PairingClassification.IdentityChanged -> "${prompt.peerName} has a new identity"
                    },
                )
            },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Text("Make sure ${prompt.peerName} shows the same code:")
                    Text(
                        prompt.sas, fontSize = 40.sp, fontWeight = FontWeight.SemiBold, fontFamily = FontFamily.Monospace,
                        color = MaterialTheme.colorScheme.primary,
                        modifier = Modifier.semantics { contentDescription = "Pairing code " + prompt.sas.toCharArray().joinToString(" ") },
                    )
                    if (prompt.classification == PairingClassification.IdentityChanged) {
                        Text("Only continue if you reinstalled MeowDisplay on that Mac or reset it. Otherwise, cancel.", style = MaterialTheme.typography.bodySmall)
                    }
                }
            },
            confirmButton = { TextButton(onClick = { pairing.answer(true) }) { Text("Codes Match") } },
            dismissButton = { TextButton(onClick = { pairing.cancel() }) { Text("Cancel") } },
        )
    }
}

@Composable
private fun ConnectedCard(mac: String, ui: MediaUiState, onReturn: () -> Unit, onSettings: (() -> Unit)?, onDisconnect: () -> Unit) {
    var confirm by remember { mutableStateOf(false) }
    Card(
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.primaryContainer),
        modifier = Modifier.widthIn(max = 640.dp).fillMaxWidth(),
    ) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text("Connected to $mac", style = MaterialTheme.typography.titleMedium, color = MaterialTheme.colorScheme.onPrimaryContainer)
            val source = when (ui.source) {
                "mirror" -> "Mirroring a display"
                "extend" -> "Extended desktop"
                "window" -> "Showing Mac windows"
                else -> "Showing the Mac"
            }
            val control = if (ui.input == InputWireState.Allowed) "you can control the Mac" else "view only"
            Text("$source · $control", style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onPrimaryContainer)
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Button(onClick = onReturn) { Text("Return to Display") }
                onSettings?.let { OutlinedButton(onClick = it) { Text("Settings") } }
            }
            TextButton(onClick = { confirm = true }) { Text("Disconnect") }
        }
    }
    if (confirm) {
        AlertDialog(
            onDismissRequest = { confirm = false },
            title = { Text("Disconnect from $mac?") },
            text = { Text("The picture closes on this device. Connect again from here any time.") },
            confirmButton = { TextButton(onClick = { confirm = false; onDisconnect() }) { Text("Disconnect") } },
            dismissButton = { TextButton(onClick = { confirm = false }) { Text("Cancel") } },
        )
    }
}

@Composable
private fun Steps() {
    val steps = listOf(
        "Install MeowDisplay on your Mac and open it.",
        "Keep this device and the Mac on the same Wi-Fi. MeowDisplay finds the Mac by itself.",
        "Pair once: tap Pair, then check that both screens show the same code.",
        "Next time, tap Connect, or choose this device in MeowDisplay on the Mac.",
        "To control the Mac, tap the picture and choose Request Input. The Mac decides.",
    )
    Column(verticalArrangement = Arrangement.spacedBy(6.dp), modifier = Modifier.padding(horizontal = 12.dp)) {
        steps.forEachIndexed { i, s -> Text("${i + 1}. $s", style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant) }
        Text("Can't find the Mac? Check that MeowDisplay is open there and that the Wi-Fi isn't a guest network that keeps devices apart.",
            style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

/** This device's identity. The key fingerprint isn't secret, but it stays hidden until asked for (C4 F-03). */
@Composable
private fun DeviceDetails(fingerprint: String, onDismiss: () -> Unit) {
    val context = LocalContext.current
    var revealed by remember { mutableStateOf(false) }
    var copied by remember { mutableStateOf(false) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Device Details") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Text("Name: ${DeviceIdentity.displayName(context)}")
                Text("Security key", style = MaterialTheme.typography.labelLarge)
                Text(
                    if (revealed) fingerprint.chunked(4).joinToString(" ") else "Hidden",
                    fontFamily = FontFamily.Monospace,
                    modifier = Modifier.semantics { contentDescription = if (revealed) "Security key fingerprint $fingerprint" else "Security key hidden" },
                )
                Text("Macs pin this key when you pair. You only need it to check a pairing by hand.", style = MaterialTheme.typography.bodySmall)
                if (copied) Text("Copied.", style = MaterialTheme.typography.bodySmall)
            }
        },
        confirmButton = {
            Row {
                TextButton(onClick = { revealed = !revealed }) { Text(if (revealed) "Hide" else "Reveal") }
                if (revealed) TextButton(onClick = {
                    context.getSystemService(ClipboardManager::class.java)?.setPrimaryClip(ClipData.newPlainText("MeowDisplay key", fingerprint))
                    copied = true
                }) { Text("Copy") }
                TextButton(onClick = onDismiss) { Text("Done") }
            }
        },
    )
}

internal fun sessionStatus(ui: MediaUiState, mac: String): String = when (ui.phase) {
    SessionPhase.Connected -> if (ui.admitted) "Showing $mac." else "Connecting to $mac…"
    SessionPhase.Connecting -> "Connecting to $mac…"
    SessionPhase.Paused -> "$mac paused the picture."
    SessionPhase.Reconnecting -> "Reconnecting to $mac…"
    SessionPhase.ReconnectFailed -> "Lost the connection to $mac. It reconnects when the Mac is back, or tap Connect."
    SessionPhase.Unrecoverable -> "$mac needs a newer MeowDisplay (or this device does) to work together."
    SessionPhase.PeerDisconnected -> "$mac ended the session."
    SessionPhase.Disconnected -> ui.listenerError ?: if (ui.listening) "Ready. Tap Connect, or choose this device in MeowDisplay on your Mac." else "Not available while MeowDisplay is in the background."
}

@Composable
private fun SectionTitle(text: String) {
    Text(
        text, style = MaterialTheme.typography.titleMedium, color = MaterialTheme.colorScheme.secondary,
        modifier = Modifier.widthIn(max = 640.dp).fillMaxWidth().padding(top = 12.dp).semantics { heading() },
    )
}

@Composable
private fun Hint(text: String) {
    Text(text, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.widthIn(max = 640.dp).fillMaxWidth())
}

@Composable
private fun Notice(text: String, onDismiss: () -> Unit) {
    Card(colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceVariant), modifier = Modifier.widthIn(max = 640.dp).fillMaxWidth()) {
        Row(Modifier.padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
            Text(text, Modifier.weight(1f), color = MaterialTheme.colorScheme.onSurface)
            TextButton(onClick = onDismiss) { Text("OK") }
        }
    }
}

@Composable
private fun MacRow(title: String, subtitle: String?, primary: Pair<String, () -> Unit>?, enabled: Boolean, menu: List<Pair<String, () -> Unit>>) {
    var open by remember { mutableStateOf(false) }
    Card(colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface), modifier = Modifier.widthIn(max = 640.dp).fillMaxWidth()) {
        Row(Modifier.padding(horizontal = 16.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text(title, style = MaterialTheme.typography.bodyLarge)
                subtitle?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant) }
            }
            Spacer(Modifier.padding(4.dp))
            primary?.let { (label, action) -> TextButton(onClick = action, enabled = enabled) { Text(label) } }
            if (menu.isNotEmpty()) {
                androidx.compose.foundation.layout.Box {
                    TextButton(onClick = { open = true }, modifier = Modifier.semantics { contentDescription = "More for $title" }) { Text("•••") }
                    DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
                        menu.forEach { (label, action) -> DropdownMenuItem(text = { Text(label) }, onClick = { open = false; action() }) }
                    }
                }
            }
        }
    }
}


package com.raisecaterror.meowdisplay.android.ui

import androidx.compose.foundation.Image
import androidx.compose.foundation.clickable
import androidx.compose.material3.OutlinedTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.ui.res.painterResource
import com.raisecaterror.meowdisplay.android.receiver.overlay.GlyphIcon
import com.raisecaterror.meowdisplay.android.receiver.overlay.OverlayGlyph
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import com.raisecaterror.meowdisplay.android.R
import android.content.ClipData
import android.content.ClipboardManager
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
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
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalWindowInfo
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.raisecaterror.meowdisplay.android.discovery.Bonjour
import com.raisecaterror.meowdisplay.android.identity.DeviceIdentity
import com.raisecaterror.meowdisplay.android.pairing.PairingController
import com.raisecaterror.meowdisplay.android.remote.RemoteAccess
import com.raisecaterror.meowdisplay.core.remote.HomeRows
import com.raisecaterror.meowdisplay.core.remote.MacFacts
import com.raisecaterror.meowdisplay.core.remote.MacStatus
import com.raisecaterror.meowdisplay.core.remote.MacStatusReducer
import com.raisecaterror.meowdisplay.core.remote.RowAction
import com.raisecaterror.meowdisplay.android.session.MediaController
import com.raisecaterror.meowdisplay.android.session.MediaUiState
import com.raisecaterror.meowdisplay.android.trust.PinStore
import com.raisecaterror.meowdisplay.core.pairing.PairingClassification
import com.raisecaterror.meowdisplay.core.session.DisplayMode
import com.raisecaterror.meowdisplay.core.session.InputWireState
import com.raisecaterror.meowdisplay.core.session.ReceiverApprovalDecision
import com.raisecaterror.meowdisplay.core.session.SessionPhase

/**
 * Home: the name and one short status line, one card of Macs (paired ones with Connect, nearby
 * ones with Pair), a quiet row of links (How to Connect, This Device) and Settings & Help. While
 * a session is live this is shown over the running picture, so returning to it is instant.
 */
@Composable
fun ReceiverHome(
    identity: DeviceIdentity,
    pins: PinStore,
    bonjour: Bonjour,
    pairing: PairingController,
    media: MediaController,
    remote: RemoteAccess,
    onReturnToDisplay: (() -> Unit)? = null,
    onOpenSettings: (() -> Unit)? = null,
    /** Explore Demo; null while a real session is up. */
    onTryDemo: (() -> Unit)? = null,
) {
    val ui by pairing.ui.collectAsState()
    val mediaUi by media.ui.collectAsState()
    val nearby by bonjour.nearbyMacs.collectAsState()
    val paired by pins.paired.collectAsState()
    val autoRequestFlow = remember(media) { media.inputAutoRequest?.enabledPeers ?: kotlinx.coroutines.flow.MutableStateFlow(emptySet<String>()) }
    val autoRequestPeers by autoRequestFlow.collectAsState()
    val remoteMacs by remote.store.macs.collectAsState()
    val attempts by remote.coordinator.attempts.collectAsState()
    val macName = { peerID: String? -> paired.firstOrNull { it.peerID == peerID }?.name ?: "your Mac" }
    var showDetails by remember { mutableStateOf(false) }
    var showAddRemote by rememberSaveable { mutableStateOf(false) }
    var editAddressFor by rememberSaveable { mutableStateOf<String?>(null) }
    var policyFor by rememberSaveable { mutableStateOf<String?>(null) }
    var forgetFor by rememberSaveable { mutableStateOf<String?>(null) }
    var securityFor by rememberSaveable { mutableStateOf<String?>(null) }
    var showSteps by rememberSaveable { mutableStateOf(false) }
    // Short phones (landscape) keep the links in the scrolling list so the Macs keep their room.
    val windowHeight = with(LocalDensity.current) { LocalWindowInfo.current.containerSize.height.toDp() }
    val compactHeight = windowHeight < 500.dp
    // One row per Mac, however it was found: a paired Mac that is nearby, saved remotely or both is a single
    // row in the Macs card. Bonjour names only: a nearby Mac with a paired Mac's name is not offered to pair again.
    val rows = HomeRows.buildFromNearby(paired.map { HomeRows.Paired(it.peerID, it.name) }, nearby.map { HomeRows.Nearby(it.serviceName, it.advert) })
    val toPair = nearby.filter { it.serviceName in rows.toPair }

    Surface(color = MaterialTheme.colorScheme.background, modifier = Modifier.fillMaxSize()) {
      // Same arrangement as the iPhone: centred logo, name and one status line on top, the Macs
      // card, then the links and Settings & Help at the bottom centre, always in reach.
      Column(Modifier.fillMaxSize().safeDrawingPadding(), horizontalAlignment = Alignment.CenterHorizontally) {
        LazyColumn(
            modifier = Modifier.weight(1f).fillMaxWidth().padding(horizontal = 20.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            item {
                Column(Modifier.widthIn(max = 640.dp).fillMaxWidth().padding(top = 20.dp, bottom = 4.dp),
                    horizontalAlignment = Alignment.CenterHorizontally) {
                    Image(painterResource(R.drawable.meow_logo), contentDescription = null, modifier = Modifier.size(72.dp))
                    Spacer(Modifier.height(8.dp))
                    Text("MeowDisplay", style = MaterialTheme.typography.headlineMedium, color = MaterialTheme.colorScheme.onBackground,
                        modifier = Modifier.semantics { heading() })
                }
            }
            if (onReturnToDisplay != null && mediaUi.admitted && !mediaUi.awaitingMacApproval) {
                item { ConnectedCard(macName(mediaUi.peerID), mediaUi, onReturnToDisplay, onOpenSettings) { media.session.disconnect() } }
            } else {
                item { Hint(sessionStatus(mediaUi, macName(mediaUi.peerID)), centered = true) }   // under the name, as on iPhone
            }
            mediaUi.updateMessage?.let { message -> item { Hint(message) } }
            ui.message?.let { message -> item { Notice(message, onDismiss = pairing::dismissMessage) } }
            mediaUi.connectFailedFor?.let { peer ->
                item {
                    Notice("${macName(peer)} didn't connect. Open MeowDisplay on it and check that both are on the same Wi-Fi.",
                        onDismiss = media::dismissConnectFailure)
                }
            }

            item {
                MacsCard {
                    if (paired.isEmpty() && toPair.isEmpty()) {
                        Row(Modifier.fillMaxWidth().padding(vertical = 12.dp), verticalAlignment = Alignment.CenterVertically) {
                            if (mediaUi.listening) {
                                CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp)
                                Spacer(Modifier.width(10.dp))
                            }
                            Text(
                                if (mediaUi.listening) "Looking for Macs on this Wi-Fi…" else "Open MeowDisplay to look for Macs.",
                                style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }
                    }
                    paired.forEach { mac ->
                        val awaiting = mediaUi.peerID == mac.peerID && mediaUi.awaitingMacApproval
                        val live = mediaUi.peerID == mac.peerID && mediaUi.admitted && !awaiting
                        val isNearby = remote.nearby(mac.peerID)
                        val saved = remoteMacs[mac.peerID]?.endpoint
                        val status = MacStatusReducer.reduce(
                            MacFacts(
                                peerID = mac.peerID, name = mac.name, nearby = isNearby, remote = saved, connected = live,
                                route = mediaUi.route.takeIf { live }, awaitingMacApproval = awaiting,
                                localConnectPending = mediaUi.connectingTo == mac.peerID, attempt = attempts[mac.peerID],
                                switchedOut = isNearby && remote.switchedOut(mac.peerID),
                            ),
                        ) { id -> paired.firstOrNull { it.peerID == id }?.name }
                        val busy = status is MacStatus.Connecting || status is MacStatus.NeedsMacApproval
                        HorizontalDivider(color = MaterialTheme.colorScheme.outline.copy(alpha = 0.5f))
                        MacRow(
                            title = mac.name,
                            subtitle = status.text,
                            detail = status.hint,
                            primary = when (status.action) {
                                RowAction.Show -> onReturnToDisplay?.let { "Show" to it }
                                RowAction.Cancel -> "Cancel" to { remote.cancel(mac.peerID) }
                                RowAction.Retry -> "Retry" to { remote.connect(mac.peerID) }
                                RowAction.Connect -> "Connect" to { remote.connect(mac.peerID) }
                                RowAction.None -> null
                            },
                            enabled = mediaUi.listening || live || busy,
                            menu = buildList {
                                // Kept even when the Mac advertises Switched Out: that TXT claim is unauthenticated.
                                if (!live && !busy) {
                                    add("Connect with Mirror" to { remote.connect(mac.peerID, DisplayMode.Mirror) })
                                    add("Connect with Extend" to { remote.connect(mac.peerID, DisplayMode.Extend) })
                                    if (isNearby && saved != null) add("Connect over Remote" to { remote.connectRemotely(mac.peerID) })
                                }
                                media.inputAutoRequest?.let { auto ->
                                    val on = mac.peerID in autoRequestPeers
                                    add((if (on) "Request Control Automatically: On" else "Request Control Automatically: Off") to { auto.setEnabled(mac.peerID, !on) })
                                }
                                add((if (saved != null) "Edit Address" else "Add Address") to { editAddressFor = mac.peerID })
                                if (saved != null) add("Remove Address" to { remote.store.remove(mac.peerID); remote.coordinator.cancel(mac.peerID) })
                                add("Connection Requests…" to { policyFor = mac.peerID })
                                add("Security Details" to { securityFor = mac.peerID })
                                add("Forget This Mac…" to { forgetFor = mac.peerID })
                            },
                        )
                    }
                    toPair.forEach { mac ->
                        HorizontalDivider(color = MaterialTheme.colorScheme.outline.copy(alpha = 0.5f))
                        // Switched out: that session can't share, so there is nothing to pair with yet (iOS).
                        val switchedOut = mac.advert?.switchedOut == true
                        MacRow(
                            title = mac.advert?.sessionTitle ?: mac.serviceName, subtitle = if (switchedOut) "Switched Out" else "Not paired",
                            primary = if (switchedOut) null else (if (ui.pairingWith == mac.serviceName) "Pairing…" else "Pair") to { pairing.pair(mac) },
                            enabled = ui.pairingWith == null, menu = emptyList(),
                        )
                    }
                    if (onTryDemo != null && paired.isEmpty()) {
                        HorizontalDivider(color = MaterialTheme.colorScheme.outline.copy(alpha = 0.5f))
                        OutlinedButton(
                            onClick = onTryDemo,
                            modifier = Modifier.fillMaxWidth().padding(vertical = 10.dp)
                                .semantics { contentDescription = "Try the Demo. Opens a sample session. Nothing connects to another device." },
                        ) { Text("Try the Demo") }
                    }
                    HorizontalDivider(color = MaterialTheme.colorScheme.outline.copy(alpha = 0.5f))
                    TextButton(
                        onClick = { showAddRemote = true },
                        modifier = Modifier.semantics { contentDescription = "Add Remote Mac" },
                    ) { Text("+ Add Remote Mac") }
                }
            }

            val footerDemo = onTryDemo.takeIf { paired.isNotEmpty() }
            if (compactHeight) item { FooterLinks(onSteps = { showSteps = true }, onDevice = { showDetails = true }, onDemo = footerDemo) }
        }
        if (!compactHeight) FooterLinks(onSteps = { showSteps = true }, onDevice = { showDetails = true }, onDemo = onTryDemo.takeIf { paired.isNotEmpty() },
            modifier = Modifier.padding(horizontal = 20.dp))
        onOpenSettings?.let { open ->
            OutlinedButton(onClick = open, modifier = Modifier.padding(top = 4.dp, bottom = 16.dp)) {
                GlyphIcon(OverlayGlyph.Gear, 18.dp, MaterialTheme.colorScheme.primary)
                Spacer(Modifier.width(8.dp))
                Text("Settings & Help")
            }
        }
      }
    }

    if (showSteps) {
        AlertDialog(
            onDismissRequest = { showSteps = false },
            title = { Text("How to Connect") },
            text = { Column(Modifier.verticalScroll(rememberScrollState())) { Steps() } },
            confirmButton = { TextButton(onClick = { showSteps = false }) { Text("Done") } },
        )
    }

    if (showDetails) DeviceDetails(identity.fingerprint) { showDetails = false }

    if (showAddRemote) AddRemoteMacDialog(pairing, ui, paired, remote) { showAddRemote = false }

    editAddressFor?.let { peerID ->
        val mac = paired.firstOrNull { it.peerID == peerID }
        if (mac == null) editAddressFor = null else EditAddressDialog(
            macName = mac.name, current = remoteMacs[peerID]?.endpoint,
            sharedWith = { endpoint ->
                remoteMacs.values.filter { it.peerID != peerID && it.endpoint.host.equals(endpoint.host, ignoreCase = true) && it.endpoint.port == endpoint.port }
                    .mapNotNull { other -> paired.firstOrNull { it.peerID == other.peerID }?.name }
            },
            onSave = { endpoint -> remote.store.save(peerID, endpoint).also { saved -> if (saved) remote.coordinator.cancel(peerID) } },
            onDismiss = { editAddressFor = null },
        )
    }

    policyFor?.let { peerID ->
        val changes by media.connectionPolicyChanges.collectAsState()
        ConnectionPolicyDialog(media.macName(peerID), media.connectionPolicy(peerID).also { changes }, media.automaticallyAllowConnections,
            onChoose = { media.setConnectionPolicy(peerID, it); policyFor = null }, onDismiss = { policyFor = null })
    }
    forgetFor?.let { peerID ->
        AlertDialog(
            onDismissRequest = { forgetFor = null },
            title = { Text("Forget \u201C${media.macName(peerID)}\u201D?") },
            text = { Text("This removes the pairing and its saved address. To use this Mac again, pair it again.") },
            confirmButton = { TextButton(onClick = { remote.forget(peerID); forgetFor = null }) { Text("Forget", color = MaterialTheme.colorScheme.error) } },
            dismissButton = { TextButton(onClick = { forgetFor = null }) { Text("Cancel") } },
        )
    }
    securityFor?.let { peerID ->
        val mac = paired.firstOrNull { it.peerID == peerID }
        if (mac == null) securityFor = null else SecurityDetailsDialog(
            mac, remoteMacs[peerID]?.endpoint,
            remote.store.sharedWith(peerID).mapNotNull { other -> paired.firstOrNull { it.peerID == other }?.name },
        ) { securityFor = null }
    }

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
                    } + " on this device. It can't control anything here, and this device can't control it unless you ask."
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
                "mirror" -> "Mirror"
                "extend" -> "Extend"
                "window" -> "Windows"
                else -> "Showing the Mac"
            }
            val control = if (ui.input == InputWireState.Allowed) "Controlling" else "View Only"
            Text(
                listOfNotNull(source, control, ui.route?.sessionLabel).joinToString(" · "),
                style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onPrimaryContainer,
            )
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
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        com.raisecaterror.meowdisplay.android.receiver.connectionHelp.forEach { (title, body) ->
            Column {
                Text(title, style = MaterialTheme.typography.titleSmall)
                Text(body, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
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
        title = { Text("This Device") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                var name by remember { mutableStateOf(DeviceIdentity.customName(context) ?: "") }
                OutlinedTextField(
                    name, { name = it.take(40) }, label = { Text("Device Name") }, singleLine = true,
                    placeholder = { Text(DeviceIdentity.systemName(context)) },
                    supportingText = { Text("Shown on your Mac. Macs see a new name the next time they find this device.") },
                    keyboardActions = KeyboardActions(onDone = { DeviceIdentity.setCustomName(context, name) }),
                    modifier = Modifier.fillMaxWidth(),
                )
                if ((DeviceIdentity.customName(context) ?: "") != name.trim()) {
                    TextButton(onClick = { DeviceIdentity.setCustomName(context, name) }) { Text("Save Name") }
                }
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

/** One short line for the home screen and Settings. What to do about a state is in How to Connect. */
internal fun sessionStatus(ui: MediaUiState, mac: String): String = when (ui.phase) {
    SessionPhase.Connected -> when {
        ui.awaitingMacApproval -> "Waiting for $mac to accept"
        ui.admitted -> "Connected to $mac"
        else -> "Connecting to $mac…"
    }
    SessionPhase.Connecting -> "Connecting to $mac…"
    SessionPhase.Paused -> "Paused by $mac"
    SessionPhase.Reconnecting -> "Reconnecting to $mac…"
    SessionPhase.ReconnectFailed -> "Connection to $mac lost"
    SessionPhase.Unrecoverable -> "Update MeowDisplay to use $mac"
    SessionPhase.PeerDisconnected -> "$mac ended the session"
    SessionPhase.Disconnected -> ui.listenerError ?: if (ui.listening) "Ready to connect" else "Not available in the background"
}

/** The one card the home screen's Macs live in: a heading, then a row per Mac. */
@Composable
private fun MacsCard(content: @Composable ColumnScope.() -> Unit) {
    Card(colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface), modifier = Modifier.widthIn(max = 640.dp).fillMaxWidth()) {
        Column(Modifier.padding(horizontal = 16.dp, vertical = 12.dp)) {
            Text(
                "Macs", style = MaterialTheme.typography.titleMedium, color = MaterialTheme.colorScheme.secondary,
                modifier = Modifier.padding(bottom = 4.dp).semantics { heading() },
            )
            content()
        }
    }
}

/** How to Connect · This Device: quiet text links under the card. */
@Composable
private fun FooterLinks(onSteps: () -> Unit, onDevice: () -> Unit, onDemo: (() -> Unit)? = null, modifier: Modifier = Modifier) {
    Row(
        modifier.widthIn(max = 640.dp).fillMaxWidth(),
        horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.CenterVertically,
    ) {
        TextButton(onClick = onSteps, modifier = Modifier.weight(1f, fill = false)) { Text("How to Connect", textAlign = TextAlign.Center) }
        Text("·", color = MaterialTheme.colorScheme.outline, modifier = Modifier.clearAndSetSemantics {})
        if (onDemo != null) {
            TextButton(onClick = onDemo, modifier = Modifier.weight(1f, fill = false)) { Text("Try the Demo", textAlign = TextAlign.Center) }
            Text("·", color = MaterialTheme.colorScheme.outline, modifier = Modifier.clearAndSetSemantics {})
        }
        TextButton(onClick = onDevice, modifier = Modifier.weight(1f, fill = false)) { Text("This Device", textAlign = TextAlign.Center) }
    }
}

@Composable
private fun Hint(text: String, centered: Boolean = false) {
    Text(text, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.widthIn(max = 640.dp).fillMaxWidth(),
        textAlign = if (centered) androidx.compose.ui.text.style.TextAlign.Center else null)
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

/** One Mac in the card: name and one-word subtitle, a prominent action, and a ••• menu for the rest. */
@Composable
private fun MacRow(
    title: String, subtitle: String?, primary: Pair<String, () -> Unit>?, enabled: Boolean, menu: List<Pair<String, () -> Unit>>,
    detail: String? = null,
) {
    var open by remember { mutableStateOf(false) }
    // Large font scales stack the buttons under the name instead of squeezing the name.
    val stacked = LocalDensity.current.fontScale >= 1.5f
    val name: @Composable (Modifier) -> Unit = { modifier ->
        Column(modifier.semantics(mergeDescendants = true) {}) {
            Text(title, style = MaterialTheme.typography.bodyLarge)
            subtitle?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant) }
            detail?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant) }
        }
    }
    val actions: @Composable () -> Unit = {
        primary?.let { (label, action) ->
            Button(onClick = action, enabled = enabled, modifier = Modifier.semantics { contentDescription = "$label, $title" }) { Text(label) }
        }
        if (menu.isNotEmpty()) {
            Box {
                TextButton(onClick = { open = true }, modifier = Modifier.semantics { contentDescription = "More for $title" }) { Text("•••") }
                DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
                    menu.forEach { (label, action) -> DropdownMenuItem(text = { Text(label) }, onClick = { open = false; action() }) }
                }
            }
        }
    }
    if (stacked) {
        Column(Modifier.fillMaxWidth().padding(vertical = 8.dp)) {
            name(Modifier.fillMaxWidth())
            Row(verticalAlignment = Alignment.CenterVertically) { actions() }
        }
    } else {
        Row(Modifier.fillMaxWidth().padding(vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
            name(Modifier.weight(1f))
            Spacer(Modifier.width(8.dp))
            actions()
        }
    }
}


/** iOS per-Mac "Connection Requests": Default follows Automatically Allow Connections. */
@Composable
private fun ConnectionPolicyDialog(
    mac: String, current: com.raisecaterror.meowdisplay.core.session.PeerSessionPolicy?, automaticallyAllow: Boolean,
    onChoose: (com.raisecaterror.meowdisplay.core.session.PeerSessionPolicy?) -> Unit, onDismiss: () -> Unit,
) {
    val options = listOf(
        null to (if (automaticallyAllow) "Default (Allow)" else "Default (Ask)"),
        com.raisecaterror.meowdisplay.core.session.PeerSessionPolicy.AlwaysAllow to "Always Allow",
        com.raisecaterror.meowdisplay.core.session.PeerSessionPolicy.Blocked to "Blocked",
    )
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Connection Requests") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text("When $mac asks to start a session on this device.", style = MaterialTheme.typography.bodyMedium)
                options.forEach { (policy, label) ->
                    Row(Modifier.fillMaxWidth().clickable { onChoose(policy) }.padding(vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                        androidx.compose.material3.RadioButton(selected = current == policy, onClick = { onChoose(policy) })
                        Text(label)
                    }
                }
                Text("Blocked ends any session with this Mac now and declines its requests until you change this.", style = MaterialTheme.typography.bodySmall)
            }
        },
        confirmButton = { TextButton(onClick = onDismiss) { Text("Done") } },
    )
}

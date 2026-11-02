package com.raisecaterror.meowdisplay.android.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.foundation.layout.heightIn
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import com.raisecaterror.meowdisplay.android.pairing.PairingController
import com.raisecaterror.meowdisplay.android.pairing.PairingUiState
import com.raisecaterror.meowdisplay.android.pairing.RemotePairingState
import com.raisecaterror.meowdisplay.android.remote.RemoteAccess
import com.raisecaterror.meowdisplay.android.trust.PairedMac
import com.raisecaterror.meowdisplay.core.remote.EndpointError
import com.raisecaterror.meowdisplay.core.remote.EndpointParse
import com.raisecaterror.meowdisplay.core.remote.RemoteEndpoint
import com.raisecaterror.meowdisplay.core.remote.RemoteEndpoints
import com.raisecaterror.meowdisplay.core.remote.RemotePorts
import com.raisecaterror.meowdisplay.core.tls.PinnedTls

/** What a rejected address says (the iPhone's wording). */
internal fun addressProblem(error: EndpointError): String = when (error) {
    EndpointError.EmptyHost -> "Enter a host or IP address."
    EndpointError.InvalidHost -> "That doesn't look like a valid host or IP address."
    EndpointError.InvalidPort -> "Enter a port between 1 and 65535."
}

/**
 * The address a Mac is reached at for connect requests (port 9003 unless typed). Port 9004 is the
 * pairing listener, which doesn't speak TLS: knocking there would only look like a failed pairing.
 */
internal fun parseConnectAddress(text: String): Pair<RemoteEndpoint?, String?> =
    when (val parsed = RemoteEndpoints.parseAddress(text, RemotePorts.CONNECT_REQUEST)) {
        is EndpointParse.Invalid -> null to addressProblem(parsed.error)
        is EndpointParse.Valid ->
            if (parsed.endpoint.port == RemotePorts.PAIRING) null to "Port ${RemotePorts.PAIRING} is for pairing. Leave the port off to use ${RemotePorts.CONNECT_REQUEST}."
            else parsed.endpoint to null
    }

/**
 * Add Remote Mac: an address (a Tailscale IP, a MagicDNS name or any reachable host, optionally
 * with a port) and two honest actions. Pair New Mac runs the usual pairing, code on both devices,
 * to that address; Use for a Paired Mac only remembers where an already-paired Mac can be found,
 * and the first Connect checks it against that Mac's key.
 */
@Composable
internal fun AddRemoteMacDialog(
    pairing: PairingController,
    pairingUi: PairingUiState,
    paired: List<PairedMac>,
    remote: RemoteAccess,
    onDismiss: () -> Unit,
) {
    var address by rememberSaveable { mutableStateOf("") }
    var problem by rememberSaveable { mutableStateOf<String?>(null) }
    var choosing by rememberSaveable { mutableStateOf(false) }
    var chosen by rememberSaveable { mutableStateOf<String?>(null) }
    val state = pairingUi.remote
    val onPaired = { peerID: String, saved: RemoteEndpoint -> remote.store.save(peerID, saved); Unit }

    LaunchedEffect(state) {
        if (state is RemotePairingState.Done) {
            pairing.acknowledgeRemote()
            onDismiss()
        }
    }

    when (state) {
        is RemotePairingState.Connecting -> AlertDialog(
            onDismissRequest = {},
            title = { Text("Pairing…") },
            text = {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    CircularProgressIndicator(Modifier.size(20.dp).clearAndSetSemantics {}, strokeWidth = 2.dp)
                    Spacer(Modifier.width(12.dp))
                    Text("Make sure Pair over Remote is open on your Mac. When a code appears, check that both screens show the same one and confirm it on both.")
                }
            },
            confirmButton = { TextButton(onClick = pairing::cancelRemote) { Text("Cancel") } },
        )
        is RemotePairingState.Failed -> AlertDialog(
            onDismissRequest = { pairing.acknowledgeRemote() },
            title = { Text(state.kind.title) },
            text = { state.kind.detail?.let { Text(it) } },
            confirmButton = {
                if (state.kind.retryable) TextButton(onClick = { pairing.retryRemote(onPaired) }) { Text("Try Again") }
                else TextButton(onClick = { pairing.acknowledgeRemote(); onDismiss() }) { Text("Close") }
            },
            dismissButton = { TextButton(onClick = { pairing.acknowledgeRemote() }) { Text(if (state.kind.retryable) "Change Address" else "Back") } },
        )
        else -> AlertDialog(
            onDismissRequest = onDismiss,
            title = { Text("Add Remote Mac") },
            text = {
                Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Text(
                        "Reach a Mac on another network, over Tailscale or a VPN. The address only tells this device where to look. Trust comes from pairing.",
                        style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    val reach = remember { com.raisecaterror.meowdisplay.core.remote.TailscaleGuidance.reach(remote.routes.snapshot()) }
                    Text(
                        when (reach) {
                            com.raisecaterror.meowdisplay.core.remote.TailscaleReach.Connected -> "Tailscale is connected on this device. On your Mac, open Settings → Remote Access → Check Tailscale to see its name."
                            com.raisecaterror.meowdisplay.core.remote.TailscaleReach.OtherVpn -> "A VPN is on. To use Tailscale, open the Tailscale app and connect, then find your Mac's name in its Settings → Remote Access → Check Tailscale."
                            com.raisecaterror.meowdisplay.core.remote.TailscaleReach.Off -> "Tailscale doesn't look connected on this device. Open the Tailscale app and connect to the same tailnet as your Mac. Your Mac shows its Tailscale name in Settings → Remote Access → Check Tailscale."
                        },
                        style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    OutlinedTextField(
                        value = address, onValueChange = { address = it; problem = null },
                        label = { Text("Address") }, singleLine = true, isError = problem != null,
                        placeholder = { Text("mac.tailnet.ts.net or 100.101.102.103") },
                        supportingText = { Text(problem ?: "A name, an IPv4 or [IPv6] address. Add :port for another port.") },
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri),
                        modifier = Modifier.fillMaxWidth().semantics { contentDescription = "Remote Mac address" },
                    )
                    if (!choosing) {
                        Text("Pair New Mac", style = MaterialTheme.typography.titleSmall, modifier = Modifier.semantics { heading() })
                        Text(
                            "On your Mac: Settings → Devices → Open Pair over Remote, then confirm the code on both.",
                            style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                        Button(
                            onClick = {
                                when (val parsed = RemoteEndpoints.parseAddress(address, RemotePorts.PAIRING)) {
                                    is EndpointParse.Invalid -> problem = addressProblem(parsed.error)
                                    is EndpointParse.Valid -> pairing.pairRemote(parsed.endpoint, onPaired)
                                }
                            },
                            enabled = pairingUi.pairingWith == null,
                            modifier = Modifier.fillMaxWidth(),
                        ) { Text("Pair New Mac") }
                        OutlinedButton(
                            onClick = {
                                val (endpoint, bad) = parseConnectAddress(address)
                                problem = bad
                                if (endpoint != null) choosing = true
                            },
                            modifier = Modifier.fillMaxWidth(),
                        ) { Text("Use for a Paired Mac") }
                    } else {
                        Text("Which Mac is at this address?", style = MaterialTheme.typography.titleSmall, modifier = Modifier.semantics { heading() })
                        if (paired.isEmpty()) {
                            Text("No Macs are paired yet. Go back and use Pair New Mac.", style = MaterialTheme.typography.bodySmall)
                        }
                        paired.forEach { mac ->
                            Row(
                                Modifier.fillMaxWidth().selectable(selected = chosen == mac.peerID, role = Role.RadioButton, onClick = { chosen = mac.peerID })
                                    .heightIn(min = 48.dp).padding(vertical = 2.dp),
                                verticalAlignment = Alignment.CenterVertically,
                            ) {
                                RadioButton(selected = chosen == mac.peerID, onClick = null)
                                Spacer(Modifier.width(10.dp))
                                Text(mac.name, style = MaterialTheme.typography.bodyLarge)
                            }
                        }
                        Text(
                            "It's checked against that Mac's key the first time you connect.",
                            style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            Button(
                                enabled = chosen != null && paired.any { it.peerID == chosen },
                                onClick = {
                                    val (endpoint, bad) = parseConnectAddress(address)
                                    val peerID = chosen
                                    if (endpoint != null && peerID != null) {
                                        if (remote.store.save(peerID, endpoint)) onDismiss() else problem = "Couldn't save the address. Try again."
                                    } else {
                                        problem = bad
                                        choosing = false
                                    }
                                },
                            ) { Text("Save Address") }
                            TextButton(onClick = { choosing = false }) { Text("Back") }
                        }
                    }
                }
            },
            confirmButton = { TextButton(onClick = onDismiss) { Text("Done") } },
        )
    }
}

/** Edit (or add) the address one paired Mac is reached at. */
@Composable
internal fun EditAddressDialog(
    macName: String,
    current: RemoteEndpoint?,
    sharedWith: (RemoteEndpoint) -> List<String>,
    onSave: (RemoteEndpoint) -> Boolean,
    onDismiss: () -> Unit,
) {
    var address by rememberSaveable { mutableStateOf(current?.typed(RemotePorts.CONNECT_REQUEST).orEmpty()) }
    var problem by rememberSaveable { mutableStateOf<String?>(null) }
    val shared = remember(address) { parseConnectAddress(address).first?.let(sharedWith).orEmpty() }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(if (current == null) "Add Address for $macName" else "Edit Address for $macName") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedTextField(
                    value = address, onValueChange = { address = it; problem = null },
                    label = { Text("Address") }, singleLine = true, isError = problem != null,
                    placeholder = { Text("mac.tailnet.ts.net or 100.101.102.103") },
                    supportingText = { Text(problem ?: "A name, an IPv4 or [IPv6] address. Add :port for another port.") },
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri),
                    modifier = Modifier.fillMaxWidth().semantics { contentDescription = "Address for $macName" },
                )
                if (shared.isNotEmpty()) {
                    Text(
                        "The same address is saved for ${shared.joinToString(" and ")}. That's allowed: the key, not the address, decides which Mac answers.",
                        style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                Text(
                    "Only a hint for where to look. It's checked against $macName's key every time.",
                    style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        },
        confirmButton = {
            TextButton(onClick = {
                val (endpoint, bad) = parseConnectAddress(address)
                problem = bad
                if (endpoint != null) {
                    if (onSave(endpoint)) onDismiss() else problem = "Couldn't save the address. Try again."
                }
            }) { Text("Save") }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

/** What this device knows about a paired Mac: its key, a short ID, and the address it is reached at. */
@Composable
internal fun SecurityDetailsDialog(mac: PairedMac, address: RemoteEndpoint?, sharedWith: List<String>, onDismiss: () -> Unit) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Security Details") },
        text = {
            Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Detail("Mac", mac.name)
                Detail("Security key", PinnedTls.fingerprint(mac.spki), mono = true)
                Detail("Mac ID", mac.peerID.take(8) + "…", mono = true)
                Detail("Saved address", address?.display ?: "None")
                if (sharedWith.isNotEmpty()) Text("Also saved for ${sharedWith.joinToString(" and ")}.", style = MaterialTheme.typography.bodySmall)
                Spacer(Modifier.height(2.dp))
                Text(
                    "This device connects only to a Mac whose key matches the one above, which was set when you paired. " +
                        "The address just tells it where to look; being reachable, or on the same Tailscale network, never makes a Mac trusted.",
                    style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        },
        confirmButton = { TextButton(onClick = onDismiss) { Text("Done") } },
    )
}

@Composable
private fun Detail(label: String, value: String, mono: Boolean = false) {
    Column(Modifier.semantics(mergeDescendants = true) {}) {
        Text(label, style = MaterialTheme.typography.labelLarge)
        Text(value, fontFamily = if (mono) FontFamily.Monospace else null, style = MaterialTheme.typography.bodyMedium)
    }
}

package com.raisecaterror.meowdisplay.android.ui

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
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.raisecaterror.meowdisplay.android.discovery.Bonjour
import com.raisecaterror.meowdisplay.android.identity.DeviceIdentity
import com.raisecaterror.meowdisplay.android.pairing.PairingController
import com.raisecaterror.meowdisplay.android.trust.PinStore
import com.raisecaterror.meowdisplay.core.pairing.PairingClassification

/** The receiver's home: this device, Macs nearby to pair with, and paired Macs. */
@Composable
fun ReceiverHome(identity: DeviceIdentity, pins: PinStore, bonjour: Bonjour, pairing: PairingController) {
    val ui by pairing.ui.collectAsState()
    val nearby by bonjour.nearbyMacs.collectAsState()
    val paired by pins.paired.collectAsState()

    Surface(color = MaterialTheme.colorScheme.background, modifier = Modifier.fillMaxSize()) {
        LazyColumn(
            modifier = Modifier.fillMaxSize().safeDrawingPadding().padding(horizontal = 20.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            item {
                Column(Modifier.widthIn(max = 640.dp).fillMaxWidth().padding(top = 24.dp)) {
                    Text("MeowDisplay", style = MaterialTheme.typography.headlineLarge, color = MaterialTheme.colorScheme.primary)
                    Text(
                        "Use this device as a display for your Mac. Open MeowDisplay on the Mac, or pair from here.",
                        style = MaterialTheme.typography.bodyLarge,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
            ui.message?.let { message ->
                item { Notice(message, onDismiss = pairing::dismissMessage) }
            }
            item { SectionTitle("Macs nearby") }
            if (nearby.isEmpty()) {
                item { Hint("Looking for Macs running MeowDisplay on this network…") }
            }
            items(nearby, key = { "nearby-" + it.serviceName }) { mac ->
                ActionRow(mac.serviceName, if (ui.pairingWith == mac.serviceName) "Pairing…" else "Pair", enabled = ui.pairingWith == null) {
                    pairing.pair(mac)
                }
            }
            item { SectionTitle("Paired Macs") }
            if (paired.isEmpty()) {
                item { Hint("No paired Macs yet.") }
            }
            items(paired, key = { "paired-" + it.peerID }) { mac ->
                ActionRow(mac.name, "Forget", enabled = true) { pins.forget(mac.peerID) }
            }
            item {
                Column(Modifier.widthIn(max = 640.dp).fillMaxWidth().padding(vertical = 24.dp)) {
                    Text("This device's key", style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    Text(identity.fingerprint, fontFamily = FontFamily.Monospace, color = MaterialTheme.colorScheme.onSurface)
                }
            }
        }
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
                    Text("Check that ${prompt.peerName} shows the same code:")
                    Text(
                        prompt.sas,
                        fontSize = 40.sp,
                        fontWeight = FontWeight.SemiBold,
                        fontFamily = FontFamily.Monospace,
                        color = MaterialTheme.colorScheme.primary,
                        modifier = Modifier.semantics { contentDescription = "Pairing code " + prompt.sas.toCharArray().joinToString(" ") },
                    )
                }
            },
            confirmButton = { TextButton(onClick = { pairing.answer(true) }) { Text("Codes Match") } },
            dismissButton = { TextButton(onClick = { pairing.cancel() }) { Text("Cancel") } },
        )
    }
}

@Composable
private fun SectionTitle(text: String) {
    Text(
        text,
        style = MaterialTheme.typography.titleMedium,
        color = MaterialTheme.colorScheme.secondary,
        modifier = Modifier.widthIn(max = 640.dp).fillMaxWidth().padding(top = 12.dp),
    )
}

@Composable
private fun Hint(text: String) {
    Text(
        text,
        style = MaterialTheme.typography.bodyMedium,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = Modifier.widthIn(max = 640.dp).fillMaxWidth(),
    )
}

@Composable
private fun Notice(text: String, onDismiss: () -> Unit) {
    Card(
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceVariant),
        modifier = Modifier.widthIn(max = 640.dp).fillMaxWidth(),
    ) {
        Row(Modifier.padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
            Text(text, Modifier.weight(1f), color = MaterialTheme.colorScheme.onSurface)
            TextButton(onClick = onDismiss) { Text("OK") }
        }
    }
}

@Composable
private fun ActionRow(title: String, action: String, enabled: Boolean, onAction: () -> Unit) {
    Card(
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
        modifier = Modifier.widthIn(max = 640.dp).fillMaxWidth(),
    ) {
        Row(Modifier.padding(horizontal = 16.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
            Text(title, Modifier.weight(1f), style = MaterialTheme.typography.bodyLarge)
            Spacer(Modifier.padding(4.dp))
            TextButton(onClick = onAction, enabled = enabled) { Text(action) }
        }
    }
}

package com.raisecaterror.meowdisplay.android.receiver

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.Settings
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** Product links and the tagline. Same addresses as the Apple apps (Shared/ProjectLinks.swift). */
object ProjectLinks {
    const val TAGLINE = "Mac Everywhere, On Whatever Display"
    const val GITHUB = "https://github.com/raiseCatError/meowdisplay"
    const val PRIVACY = "https://meowdisplay.app/privacy"
    const val MAC_APP = "https://github.com/raiseCatError/meowdisplay/releases/latest/download/MeowDisplay.dmg"
}

/** How each way of connecting works on Android today, in the order people try them. */
internal val connectionHelp = listOf(
    "Same Wi-Fi" to "Open MeowDisplay on your Mac. Your Mac appears on this device's home screen, and this device appears in the Mac app.",
    "First time" to "Tap Pair, then check that both screens show the same code. After that, tap Connect.",
    "USB cable" to "Not available on Android yet. Use Wi-Fi.",
    "Another network" to "Not available on Android yet. Both devices need to be on the same Wi-Fi.",
    "Can't find the Mac?" to "Check that MeowDisplay is open on the Mac and that both are on the same Wi-Fi. Guest networks often keep devices apart.",
    "Connection lost" to "This device reconnects by itself when the Mac is back (Auto-Reconnect in Settings). Or tap Connect on the home screen.",
    "Needs an update" to "If a Mac needs a newer MeowDisplay, or this device does, update the older one so both match.",
)

@Composable
internal fun HelpPage() {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var sharing by remember { mutableStateOf(false) }
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Heading("How to Connect")
        connectionHelp.forEach { (title, body) ->
            Column {
                Text(title, style = MaterialTheme.typography.titleSmall)
                Text(body, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
        TextButton(onClick = { open(context, ProjectLinks.MAC_APP) }) { Text("Get the Mac app") }

        Heading("Troubleshooting")
        OutlinedButton(enabled = !sharing, onClick = {
            sharing = true
            scope.launch {
                val log = withContext(Dispatchers.IO) { ownLog() }
                sharing = false
                share(context, log)
            }
        }) { Text(if (sharing) "Preparing…" else "Share Connection Log") }
        Text(
            "What this device saw while connecting. No screen content, and nothing leaves the device unless you share it.",
            style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
        )

        Heading("About")
        Row(Modifier.fillMaxWidth()) {
            Text("Version", Modifier.weight(1f))
            Text(versionName(context), color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        TextButton(onClick = { open(context, ProjectLinks.GITHUB) }) { Text("MeowDisplay on GitHub") }
        TextButton(onClick = { open(context, ProjectLinks.PRIVACY) }) { Text("Privacy Policy") }
        TextButton(onClick = { openAppSettings(context) }) { Text("Android Settings for MeowDisplay") }
        Text(ProjectLinks.TAGLINE, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(top = 4.dp))
    }
}

@Composable
private fun Heading(text: String) = Text(
    text, style = MaterialTheme.typography.titleMedium, color = MaterialTheme.colorScheme.primary,
    modifier = Modifier.padding(top = 8.dp).semantics { heading() },
)

private fun versionName(context: Context): String = runCatching {
    context.packageManager.getPackageInfo(context.packageName, 0).versionName
}.getOrNull() ?: "dev"

private fun open(context: Context, url: String) {
    try {
        context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    } catch (_: ActivityNotFoundException) {
    }
}

private fun openAppSettings(context: Context) {
    try {
        context.startActivity(
            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", context.packageName, null))
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
        )
    } catch (_: ActivityNotFoundException) {
    }
}

/** This app's own recent log lines (Android only lets an app read its own), bounded for sharing. */
private fun ownLog(): String = runCatching {
    val process = ProcessBuilder("logcat", "-d", "-v", "time", "-t", "1500", "--pid=${android.os.Process.myPid()}")
        .redirectErrorStream(true).start()
    process.inputStream.bufferedReader().use { it.readText() }.takeLast(MAX_LOG_CHARS)
}.getOrElse { "Couldn't read the log: ${it.message}" }

private fun share(context: Context, log: String) {
    val send = Intent(Intent.ACTION_SEND).setType("text/plain")
        .putExtra(Intent.EXTRA_SUBJECT, "MeowDisplay connection log")
        .putExtra(Intent.EXTRA_TEXT, log)
    try {
        context.startActivity(Intent.createChooser(send, "Share Connection Log").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    } catch (_: ActivityNotFoundException) {
    }
}

/** Well under the binder limit for an intent extra. */
private const val MAX_LOG_CHARS = 200_000

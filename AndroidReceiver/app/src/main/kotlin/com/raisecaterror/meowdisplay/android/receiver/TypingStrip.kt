package com.raisecaterror.meowdisplay.android.receiver

import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import com.raisecaterror.meowdisplay.core.controls.TypedTextEcho
import kotlin.math.min

/** Height of [TypingStrip]; the picture treats the keyboard as this much taller (iOS `TypingStripView`). */
val TypingStripHeight = 44.dp

/** The system font scale stops growing the strip's text here: it sits between the picture and the keys. */
private const val MAX_FONT_SCALE = 1.3f

private const val MAX_ECHO_CHARACTERS = 80

/**
 * The slim strip pinned to the top of the soft keyboard: a one-line, right-aligned echo of this
 * keyboard session's typing as the Mac received it ([TypedTextEcho]), with Done at the trailing
 * edge. The word still being composed is underlined, like marked text. Empty, it reads "Typing to
 * <Mac name>". It is the iOS `TypingStripView`; placed above the input layer, it takes its own
 * touches, so nothing tapped here reaches the Mac.
 */
@Composable
fun TypingStrip(echo: TypedTextEcho, macName: String, onDone: () -> Unit, modifier: Modifier = Modifier) {
    val base = LocalDensity.current
    CompositionLocalProvider(LocalDensity provides Density(base.density, min(base.fontScale, MAX_FONT_SCALE))) {
        Surface(
            modifier = modifier
                .fillMaxWidth()
                .height(TypingStripHeight)
                // Every touch that lands on the strip stops here; the Done button inside handles its own.
                .pointerInput(Unit) {
                    awaitPointerEventScope {
                        while (true) {
                            val event = awaitPointerEvent(PointerEventPass.Main)
                            event.changes.forEach { it.consume() }
                        }
                    }
                },
            color = MaterialTheme.colorScheme.surfaceContainerHigh,
            tonalElevation = 3.dp,
        ) {
            Row(Modifier.fillMaxSize().padding(start = 16.dp, end = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                Text(
                    text = remember(echo, macName) { echoText(echo, macName) },
                    modifier = Modifier.weight(1f).padding(end = 8.dp),
                    style = MaterialTheme.typography.bodyLarge,
                    color = if (echo.isEmpty) MaterialTheme.colorScheme.onSurfaceVariant else MaterialTheme.colorScheme.onSurface,
                    textAlign = TextAlign.End,
                    maxLines = 1,
                    softWrap = false,
                    // Keep the end of the line: the part just typed.
                    overflow = TextOverflow.StartEllipsis,
                )
                TextButton(onClick = onDone) { Text("Done", fontWeight = FontWeight.SemiBold) }
            }
        }
    }
}

private fun echoText(echo: TypedTextEcho, macName: String) = buildAnnotatedString {
    if (echo.isEmpty) {
        append("Typing to $macName")
        return@buildAnnotatedString
    }
    val tail = echo.tail(MAX_ECHO_CHARACTERS)
    val composing = echo.composing.takeLast(minOf(echo.composing.length, tail.length))
    append(tail.dropLast(composing.length))
    withStyle(SpanStyle(textDecoration = TextDecoration.Underline)) { append(composing) }
}

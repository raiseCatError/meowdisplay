package com.raisecaterror.meowdisplay.android.receiver

import androidx.activity.ComponentActivity
import androidx.activity.compose.LocalActivity
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.ime
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.text.BasicTextField
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
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.Density
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import com.raisecaterror.meowdisplay.android.ui.MeowTheme
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

/**
 * The strip on the phone's own soft keyboard, placed as [ReceiverScreen] places it; whatever is typed
 * shows in it (as finished and composing text), without a Mac. On a phone with a debug build:
 * `adb shell am start -n com.raisecaterror.meowdisplay.android.debug/androidx.compose.ui.tooling.PreviewActivity
 * --es composable com.raisecaterror.meowdisplay.android.receiver.TypingStripKt.TypingStripOnKeyboardPreview`
 */
@Preview
@Composable
private fun TypingStripOnKeyboardPreview() {
    // Edge to edge with the bars hidden, as the receiver screen is, so the keyboard inset is measured the same way.
    val activity = LocalActivity.current as? ComponentActivity
    LaunchedEffect(activity) {
        val window = activity?.window ?: return@LaunchedEffect
        activity.enableEdgeToEdge()
        WindowCompat.getInsetsController(window, window.decorView).apply {
            systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            hide(WindowInsetsCompat.Type.systemBars())
        }
    }
    MeowTheme {
        val focus = remember { FocusRequester() }
        var field by remember { mutableStateOf(TextFieldValue()) }
        var echo by remember { mutableStateOf(TypedTextEcho.EMPTY) }
        Box(Modifier.fillMaxSize().background(Color(0xFF1C1C1E))) {
            BasicTextField(
                value = field,
                onValueChange = { value ->
                    field = value
                    val composing = value.composition
                    echo = if (composing == null) {
                        TypedTextEcho.EMPTY.apply(TypedTextEcho.Edit.Commit(value.text))
                    } else {
                        TypedTextEcho.EMPTY.apply(TypedTextEcho.Edit.Commit(value.text.substring(0, composing.min)))
                            .apply(TypedTextEcho.Edit.Composing(value.text.substring(composing.min, composing.max)))
                    }
                },
                modifier = Modifier.size(1.dp).focusRequester(focus),
            )
            TypingStrip(
                echo = echo,
                macName = "Review Mac",
                onDone = {},
                modifier = Modifier.align(Alignment.BottomCenter).windowInsetsPadding(WindowInsets.ime),
            )
        }
        LaunchedEffect(Unit) { focus.requestFocus() }
    }
}

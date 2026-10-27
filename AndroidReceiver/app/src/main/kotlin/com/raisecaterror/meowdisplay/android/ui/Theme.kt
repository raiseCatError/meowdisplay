package com.raisecaterror.meowdisplay.android.ui

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

/** MeowDisplay's own look: warm amber on deep violet, independent of the system palette. */
private val MeowColors = darkColorScheme(
    primary = Color(0xFFFFB86B),
    onPrimary = Color(0xFF2B1A00),
    secondary = Color(0xFFC7B8FF),
    onSecondary = Color(0xFF221A3D),
    background = Color(0xFF14121A),
    onBackground = Color(0xFFECE6F5),
    surface = Color(0xFF1E1A28),
    onSurface = Color(0xFFECE6F5),
    surfaceVariant = Color(0xFF2B2440),
    onSurfaceVariant = Color(0xFFC9C0DA),
    error = Color(0xFFFF8A80),
)

@Composable
fun MeowTheme(content: @Composable () -> Unit) {
    MaterialTheme(colorScheme = MeowColors, content = content)
}

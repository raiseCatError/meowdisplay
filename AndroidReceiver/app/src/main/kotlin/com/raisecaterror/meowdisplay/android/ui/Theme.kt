package com.raisecaterror.meowdisplay.android.ui

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

/**
 * MeowDisplay's look on Android: the same blue accent and grouped grays as the iPhone and iPad
 * app (Apple's system blue, light and dark), following the system appearance.
 */
private val Light = lightColorScheme(
    primary = Color(0xFF007AFF),
    onPrimary = Color.White,
    primaryContainer = Color(0xFFD6E8FF),
    onPrimaryContainer = Color(0xFF00295C),
    secondary = Color(0xFF6C6C70),
    onSecondary = Color.White,
    background = Color(0xFFF2F2F7),
    onBackground = Color.Black,
    surface = Color.White,
    onSurface = Color.Black,
    surfaceVariant = Color(0xFFE5E5EA),
    onSurfaceVariant = Color(0xFF6C6C70),
    outline = Color(0xFFC6C6C8),
    error = Color(0xFFFF3B30),
)

private val Dark = darkColorScheme(
    primary = Color(0xFF0A84FF),
    onPrimary = Color.White,
    primaryContainer = Color(0xFF0A3D7A),
    onPrimaryContainer = Color(0xFFD6E8FF),
    secondary = Color(0xFF98989F),
    onSecondary = Color.Black,
    background = Color.Black,
    onBackground = Color.White,
    surface = Color(0xFF1C1C1E),
    onSurface = Color.White,
    surfaceVariant = Color(0xFF2C2C2E),
    onSurfaceVariant = Color(0xFF98989F),
    outline = Color(0xFF48484A),
    error = Color(0xFFFF453A),
)

@Composable
fun MeowTheme(content: @Composable () -> Unit) {
    MaterialTheme(colorScheme = if (isSystemInDarkTheme()) Dark else Light, content = content)
}

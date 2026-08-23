package com.dbpprt.dieter.ui.theme

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Shapes
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.graphics.Color
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.dbpprt.dieter.R

// Arctic Console: cold shell blues on a deep terminal canvas.
val DieterAbyss = Color(0xFF0D1B24)
val DieterBackground = Color(0xFF081116)
val DieterSurface = Color(0xFF122834)
val DieterSurfaceHigh = Color(0xFF193A49)
val DieterOutline = Color(0xFF264554)
val DieterShellDeep = Color(0xFF3D6E85)
val DieterShell = Color(0xFF8DD8E8)
val DieterPane = Color(0xFFD7F2F5)
val DieterLive = Color(0xFF62B6CB)
val DieterEyes = Color(0xFFBCEAF1)
val DieterRunning = DieterLive
val DieterAmber = Color(0xFFE2BE6A)
val DieterCoral = Color(0xFFF1868E)
val DieterText = Color(0xFFF5FBFD)
val DieterMuted = Color(0xFFA8B5C3)
val DieterDivider = Color(0xFF182D39)
val DieterScrim = Color(0xB3081116)

// Cool tinted fills used for selected chips, icon tiles, and highlights.
val DieterShellTint = Color(0xFF193A49)
val DieterShellTintDeep = Color(0xFF10242E)
val DieterAmberTint = Color(0xFF2C2410)
val DieterEyesTint = Color(0xFF173640)

private val colors = darkColorScheme(
    primary = DieterShell,
    onPrimary = DieterAbyss,
    primaryContainer = DieterShellDeep,
    onPrimaryContainer = DieterText,
    secondary = DieterEyes,
    tertiary = DieterLive,
    background = DieterBackground,
    onBackground = DieterText,
    surface = DieterSurface,
    onSurface = DieterText,
    surfaceVariant = DieterSurfaceHigh,
    onSurfaceVariant = DieterMuted,
    surfaceContainerLowest = DieterBackground,
    surfaceContainerLow = Color(0xFF0E2029),
    surfaceContainer = DieterSurface,
    surfaceContainerHigh = DieterSurfaceHigh,
    surfaceContainerHighest = Color(0xFF234352),
    outline = DieterOutline,
    outlineVariant = DieterDivider,
    error = DieterCoral,
    onError = Color(0xFF33141B),
    errorContainer = Color(0xFF3C1B23),
    onErrorContainer = Color(0xFFFFD9DF),
    scrim = DieterScrim,
)

private val DieterDisplayFont = FontFamily(
    Font(R.font.sora_variable, FontWeight.Normal),
    Font(R.font.sora_variable, FontWeight.Medium),
    Font(R.font.sora_variable, FontWeight.SemiBold),
    Font(R.font.sora_variable, FontWeight.Bold),
)

private val boardTypography = Typography(
    headlineLarge = TextStyle(fontFamily = DieterDisplayFont, fontSize = 32.sp, lineHeight = 38.sp, fontWeight = FontWeight.SemiBold),
    headlineMedium = TextStyle(fontFamily = DieterDisplayFont, fontSize = 28.sp, lineHeight = 34.sp, fontWeight = FontWeight.SemiBold),
    headlineSmall = TextStyle(fontFamily = DieterDisplayFont, fontSize = 24.sp, lineHeight = 30.sp, fontWeight = FontWeight.SemiBold),
    titleLarge = TextStyle(fontFamily = DieterDisplayFont, fontSize = 22.sp, lineHeight = 28.sp, fontWeight = FontWeight.Medium),
    titleMedium = TextStyle(fontFamily = DieterDisplayFont, fontSize = 16.sp, lineHeight = 22.sp, fontWeight = FontWeight.Medium),
    titleSmall = TextStyle(fontFamily = DieterDisplayFont, fontSize = 14.sp, lineHeight = 20.sp, fontWeight = FontWeight.Medium),
    bodyLarge = TextStyle(fontSize = 16.sp, lineHeight = 24.sp),
    bodyMedium = TextStyle(fontSize = 14.sp, lineHeight = 20.sp),
    bodySmall = TextStyle(fontSize = 12.sp, lineHeight = 16.sp),
    labelLarge = TextStyle(fontSize = 14.sp, lineHeight = 20.sp, fontWeight = FontWeight.SemiBold),
    labelMedium = TextStyle(fontSize = 12.sp, lineHeight = 16.sp, fontWeight = FontWeight.Medium),
    labelSmall = TextStyle(fontSize = 11.sp, lineHeight = 14.sp, fontWeight = FontWeight.Medium),
)

private val boardShapes = Shapes(
    extraSmall = RoundedCornerShape(10.dp),
    small = RoundedCornerShape(14.dp),
    medium = RoundedCornerShape(16.dp),
    large = RoundedCornerShape(24.dp),
    extraLarge = RoundedCornerShape(32.dp),
)

@Composable
fun DieterTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = colors,
        typography = boardTypography,
        shapes = boardShapes,
        content = content,
    )
}

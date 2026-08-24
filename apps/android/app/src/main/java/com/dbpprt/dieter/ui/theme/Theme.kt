package com.dbpprt.dieter.ui.theme

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Shapes
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.lerp
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.dbpprt.dieter.R
import com.dbpprt.dieter.settings.DieterPalette

private var activePalette = DieterPalette.DEFAULT
private val activeTokens get() = activePalette.tokens

// Extended semantic colors stay source-compatible with the existing UI while
// resolving through the palette selected by the root DieterTheme.
val DieterAbyss get() = Color(activeTokens.darkBrand)
val DieterBackground get() = Color(activeTokens.darkBackground)
val DieterSurface get() = Color(activeTokens.darkSurface)
val DieterSurfaceHigh get() = Color(activeTokens.darkRaised)
val DieterOutline get() = lerp(DieterSurfaceHigh, DieterText, 0.12f)
val DieterShellDeep get() = Color(activeTokens.shellEnd)
val DieterShell get() = Color(activeTokens.shellStart)
val DieterPane get() = Color(activeTokens.paneStart)
val DieterLive get() = Color(activeTokens.paneEnd)
val DieterEyes get() = Color(activeTokens.eyes)
val DieterRunning get() = DieterLive
val DieterAmber = Color(0xFFE2BE6A)
val DieterCoral = Color(0xFFF1868E)
val DieterText get() = Color(activeTokens.light)
val DieterMuted get() = lerp(DieterText, DieterAbyss, 0.30f)
val DieterDivider get() = lerp(DieterSurface, DieterText, 0.06f)
val DieterScrim get() = DieterBackground.copy(alpha = 0.70f)

// Palette-tinted fills used for selected chips, icon tiles, and highlights.
val DieterShellTint get() = DieterSurfaceHigh
val DieterShellTintDeep get() = lerp(DieterBackground, DieterShellDeep, 0.18f)
val DieterAmberTint = Color(0xFF2C2410)
val DieterEyesTint get() = lerp(DieterBackground, DieterEyes, 0.16f)
val DieterGlassFadeSoft get() = DieterBackground.copy(alpha = 0.40f)
val DieterGlassFadeStrong get() = DieterBackground.copy(alpha = 0.82f)
val DieterGlassDockFill get() = DieterSurface.copy(alpha = 0.92f)
val DieterTerminalCanvas get() = DieterBackground
val DieterTerminalBar get() = lerp(DieterBackground, DieterSurface, 0.55f)

private fun paletteColorScheme() = darkColorScheme(
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
    surfaceContainerLow = lerp(DieterBackground, DieterSurface, 0.46f),
    surfaceContainer = DieterSurface,
    surfaceContainerHigh = DieterSurfaceHigh,
    surfaceContainerHighest = lerp(DieterSurfaceHigh, DieterPane, 0.14f),
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
fun DieterTheme(
    palette: DieterPalette = DieterPalette.DEFAULT,
    content: @Composable () -> Unit,
) {
    activePalette = palette
    MaterialTheme(
        colorScheme = paletteColorScheme(),
        typography = boardTypography,
        shapes = boardShapes,
        content = content,
    )
}

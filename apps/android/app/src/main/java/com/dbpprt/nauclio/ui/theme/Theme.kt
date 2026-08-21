package com.dbpprt.nauclio.ui.theme

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Shapes
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

// Near-black canvas with a slight violet cast, per the Android design reference.
val NauclioAbyss = Color(0xFF191634)
val NauclioBackground = Color(0xFF0D0C12)
val NauclioSurface = Color(0xFF16151D)
val NauclioSurfaceHigh = Color(0xFF1E1D28)
val NauclioOutline = Color(0xFF2C2A38)
val NauclioCobalt = Color(0xFF5B54D8)
val NauclioAegean = Color(0xFFB6ADF6)
val NauclioPrimary = Color(0xFFCDC4F9)
val NauclioSeafoam = Color(0xFF72D493)
val NauclioRunning = Color(0xFF6FAAF2)
val NauclioAmber = Color(0xFFE2BE6A)
val NauclioCoral = Color(0xFFF1868E)
val NauclioText = Color(0xFFF4F3F9)
val NauclioMuted = Color(0xFFA19EB4)
val NauclioDivider = Color(0xFF221F2E)
val NauclioScrim = Color(0xB30D0C12)

// Lavender-tinted fills used for selected chips, icon tiles, and highlights.
val NauclioLavenderTint = Color(0xFF2A2740)
val NauclioIndigoTintDeep = Color(0xFF221F3A)
val NauclioAmberTint = Color(0xFF2C2410)
val NauclioSeafoamTint = Color(0xFF15291D)

private val colors = darkColorScheme(
    primary = NauclioPrimary,
    onPrimary = NauclioAbyss,
    primaryContainer = NauclioCobalt,
    onPrimaryContainer = NauclioText,
    secondary = NauclioSeafoam,
    tertiary = NauclioAmber,
    background = NauclioBackground,
    onBackground = NauclioText,
    surface = NauclioSurface,
    onSurface = NauclioText,
    surfaceVariant = NauclioSurfaceHigh,
    onSurfaceVariant = NauclioMuted,
    surfaceContainerLowest = NauclioBackground,
    surfaceContainerLow = Color(0xFF121118),
    surfaceContainer = NauclioSurface,
    surfaceContainerHigh = NauclioSurfaceHigh,
    surfaceContainerHighest = Color(0xFF26242F),
    outline = NauclioOutline,
    outlineVariant = NauclioDivider,
    error = NauclioCoral,
    onError = Color(0xFF33141B),
    errorContainer = Color(0xFF3C1B23),
    onErrorContainer = Color(0xFFFFD9DF),
    scrim = NauclioScrim,
)

private val boardTypography = Typography(
    headlineLarge = TextStyle(fontSize = 32.sp, lineHeight = 38.sp, fontWeight = FontWeight.SemiBold),
    headlineMedium = TextStyle(fontSize = 28.sp, lineHeight = 34.sp, fontWeight = FontWeight.SemiBold),
    headlineSmall = TextStyle(fontSize = 24.sp, lineHeight = 30.sp, fontWeight = FontWeight.SemiBold),
    titleLarge = TextStyle(fontSize = 22.sp, lineHeight = 28.sp, fontWeight = FontWeight.Medium),
    titleMedium = TextStyle(fontSize = 16.sp, lineHeight = 22.sp, fontWeight = FontWeight.Medium),
    titleSmall = TextStyle(fontSize = 14.sp, lineHeight = 20.sp, fontWeight = FontWeight.Medium),
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
fun NauclioTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = colors,
        typography = boardTypography,
        shapes = boardShapes,
        content = content,
    )
}

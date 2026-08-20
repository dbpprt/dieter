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

val NauclioAbyss = Color(0xFF071426)
val NauclioBackground = Color(0xFF050B14)
val NauclioSurface = Color(0xFF0B1628)
val NauclioSurfaceHigh = Color(0xFF12243C)
val NauclioOutline = Color(0xFF20364F)
val NauclioCobalt = Color(0xFF2563EB)
val NauclioAegean = Color(0xFF22D3EE)
val NauclioPrimary = Color(0xFF56C7FF)
val NauclioSeafoam = Color(0xFF5EEAD4)
val NauclioAmber = Color(0xFFF59E0B)
val NauclioCoral = Color(0xFFFB7185)
val NauclioText = Color(0xFFF5FAFF)
val NauclioMuted = Color(0xFF9DB0C3)
val NauclioDivider = Color(0xFF172D45)
val NauclioScrim = Color(0xB3050B14)

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
    surfaceContainerLow = Color(0xFF091221),
    surfaceContainer = NauclioSurface,
    surfaceContainerHigh = NauclioSurfaceHigh,
    surfaceContainerHighest = Color(0xFF19314D),
    outline = NauclioOutline,
    outlineVariant = NauclioDivider,
    error = NauclioCoral,
    onError = NauclioAbyss,
    errorContainer = Color(0xFF4A1824),
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
    extraSmall = RoundedCornerShape(8.dp),
    small = RoundedCornerShape(14.dp),
    medium = RoundedCornerShape(14.dp),
    large = RoundedCornerShape(22.dp),
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

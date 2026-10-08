package com.dbpprt.dieter.mobile

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.compositeOver
import androidx.compose.ui.graphics.lerp
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.em
import androidx.compose.ui.unit.sp
import com.dbpprt.dieter.mobile.resources.Res
import com.dbpprt.dieter.mobile.resources.sora_variable
import com.dbpprt.dieter.settings.DieterPalette
import org.jetbrains.compose.resources.Font

/**
 * Semantic colors shared by every screen. Apple resolves them to the iOS system palette (grouped
 * backgrounds, labels, separators and system tints); Android resolves them to a Material 3 tonal
 * scheme derived from the selected Dieter palette or the device's dynamic colors.
 */
@Immutable
internal data class DieterColors(
    val dark: Boolean,
    /** Screen background: iOS systemGroupedBackground, Material surface. */
    val background: Color,
    /** Grouped rows and cards: iOS secondarySystemGroupedBackground, Material container. */
    val cell: Color,
    /** Second-level fill inside a cell, e.g. code blocks or nested cards. */
    val inset: Color,
    /** Search fields, chips and secondary buttons: iOS tertiarySystemFill. */
    val fill: Color,
    val label: Color,
    val secondaryLabel: Color,
    val tertiaryLabel: Color,
    val separator: Color,
    val accent: Color,
    val onAccent: Color,
    /** Tinted container for selected chips, user bubbles and badges. */
    val accentContainer: Color,
    val onAccentContainer: Color,
    val destructive: Color,
    val success: Color,
    val warning: Color,
    val info: Color,
    val purple: Color,
)

/** Semantic text styles; Apple uses the iOS Dynamic Type scale, Android the M3 type scale. */
@Immutable
internal data class DieterType(
    val largeTitle: TextStyle,
    val title1: TextStyle,
    val title2: TextStyle,
    val title3: TextStyle,
    val headline: TextStyle,
    val body: TextStyle,
    val bodyEmphasized: TextStyle,
    val callout: TextStyle,
    val subheadline: TextStyle,
    val footnote: TextStyle,
    val caption: TextStyle,
    val caption2: TextStyle,
    val mono: TextStyle,
    val monoSmall: TextStyle,
)

internal val LocalApplePresentation = staticCompositionLocalOf { false }
internal val LocalDieterColors = staticCompositionLocalOf { lightApple(DieterPalette.DEFAULT) }
internal val LocalDieterType = staticCompositionLocalOf { appleType() }

/** True when the iOS presentation is active. */
internal val apple: Boolean
    @Composable @ReadOnlyComposable get() = LocalApplePresentation.current

internal val palette: DieterColors
    @Composable @ReadOnlyComposable get() = LocalDieterColors.current

internal val type: DieterType
    @Composable @ReadOnlyComposable get() = LocalDieterType.current

internal val colors: ColorScheme
    @Composable @ReadOnlyComposable get() = MaterialTheme.colorScheme

/** Resolves the effective dark mode from the stored appearance preference. */
@Composable
internal fun MobileStore.isDark(): Boolean {
    val appearance by appearance.collectAsState()
    return when (appearance) {
        "dark" -> true
        "light" -> false
        else -> isSystemInDarkTheme()
    }
}

@Composable
internal fun MobileTheme(store: MobileStore, apple: Boolean, content: @Composable () -> Unit) {
    val selected by store.palette.collectAsState()
    val dynamic by store.dynamicColor.collectAsState()
    val dark = store.isDark()
    val dynamicScheme = if (!apple && dynamic) platformDynamicScheme(dark) else null
    val scheme = dynamicScheme ?: materialScheme(selected, dark)
    val semantic =
        if (apple) (if (dark) darkApple(selected) else lightApple(selected))
        else materialSemantic(scheme, dark)
    val display = if (apple) FontFamily.Default else FontFamily(Font(Res.font.sora_variable))
    val semanticType = if (apple) appleType(platformMonospace()) else materialType(display)
    val typography = if (apple) appleTypography(semanticType) else materialTypography(display)
    CompositionLocalProvider(
        LocalApplePresentation provides apple,
        LocalDieterColors provides semantic,
        LocalDieterType provides semanticType,
    ) {
        MaterialTheme(
            colorScheme = if (apple) appleMaterialBridge(scheme, semantic) else scheme,
            typography = typography,
            shapes =
                Shapes(
                    extraSmall = RoundedCornerShape(6.dp),
                    small = RoundedCornerShape(10.dp),
                    medium = RoundedCornerShape(if (apple) 14.dp else 16.dp),
                    large = RoundedCornerShape(if (apple) 22.dp else 24.dp),
                    extraLarge = RoundedCornerShape(if (apple) 30.dp else 28.dp),
                ),
            content = content,
        )
    }
}

/** The system's monospaced face: SF Mono on Apple platforms. */
internal expect fun platformMonospace(): FontFamily

/** Device colors on Android 12+, null elsewhere. */
@Composable internal expect fun platformDynamicScheme(dark: Boolean): ColorScheme?

internal expect val platformSupportsDynamicColor: Boolean

private fun DieterPalette.accent(dark: Boolean): Color =
    if (this == DieterPalette.MONOCHROME) (if (dark) Color.White else Color.Black)
    else Color(if (dark) tokens.shellStart else tokens.shellEnd)

private fun lightApple(selected: DieterPalette): DieterColors {
    val accent = selected.accent(false)
    val background = Color(0xFFF2F2F7)
    return DieterColors(
        dark = false,
        background = background,
        cell = Color.White,
        inset = Color(0xFFF2F2F7),
        fill = Color(0x1F767680),
        label = Color.Black,
        secondaryLabel = Color(0x993C3C43),
        tertiaryLabel = Color(0x4D3C3C43),
        separator = Color(0x4A3C3C43),
        accent = accent,
        onAccent = Color.White,
        accentContainer =
            if (selected == DieterPalette.MONOCHROME) Color(0xFFE9E9EE)
            else accent.copy(alpha = .14f).compositeOver(Color.White),
        onAccentContainer =
            if (selected == DieterPalette.MONOCHROME) Color.Black
            else lerp(accent, Color.Black, .35f),
        destructive = Color(0xFFFF3B30),
        success = Color(0xFF34C759),
        warning = Color(0xFFFF9500),
        info = Color(0xFF007AFF),
        purple = Color(0xFFAF52DE),
    )
}

private fun darkApple(selected: DieterPalette): DieterColors {
    val accent = selected.accent(true)
    return DieterColors(
        dark = true,
        background = Color.Black,
        cell = Color(0xFF1C1C1E),
        inset = Color(0xFF2C2C2E),
        fill = Color(0x3D767680),
        label = Color.White,
        secondaryLabel = Color(0x99EBEBF5),
        tertiaryLabel = Color(0x4DEBEBF5),
        separator = Color(0x99545458),
        accent = accent,
        onAccent = if (selected == DieterPalette.MONOCHROME) Color.Black else Color.White,
        accentContainer =
            if (selected == DieterPalette.MONOCHROME) Color(0xFF2C2C2E)
            else accent.copy(alpha = .24f).compositeOver(Color(0xFF1C1C1E)),
        onAccentContainer =
            if (selected == DieterPalette.MONOCHROME) Color.White
            else lerp(accent, Color.White, .45f),
        destructive = Color(0xFFFF453A),
        success = Color(0xFF30D158),
        warning = Color(0xFFFF9F0A),
        info = Color(0xFF0A84FF),
        purple = Color(0xFFBF5AF2),
    )
}

/** A Material 3 tonal scheme from a Dieter palette. Monochrome stays neutral. */
private fun materialScheme(selected: DieterPalette, dark: Boolean): ColorScheme {
    val tokens = selected.tokens
    val mono = selected == DieterPalette.MONOCHROME
    if (!dark) {
        val seed = Color(tokens.shellEnd)
        val primary = if (mono) Color(0xFF1B1B1F) else lerp(seed, Color.Black, .12f)
        val surface = if (mono) Color(0xFFFBFBFD) else lerp(Color(tokens.light), seed, .015f)
        fun tone(amount: Float) = lerp(surface, if (mono) Color(0xFF1B1B1F) else seed, amount)
        return lightColorScheme(
            primary = primary,
            onPrimary = Color.White,
            primaryContainer = if (mono) Color(0xFFE3E3E8) else lerp(Color.White, seed, .22f),
            onPrimaryContainer = if (mono) Color(0xFF1B1B1F) else lerp(seed, Color.Black, .55f),
            inversePrimary = lerp(seed, Color.White, .45f),
            secondary = if (mono) Color(0xFF5E5E66) else lerp(seed, Color(0xFF5E5E66), .55f),
            onSecondary = Color.White,
            secondaryContainer = if (mono) Color(0xFFE4E4EA) else lerp(Color.White, seed, .16f),
            onSecondaryContainer = if (mono) Color(0xFF1B1B1F) else lerp(seed, Color.Black, .6f),
            tertiary =
                Color(if (mono) 0xFF4F5B66 else tokens.paneEnd).let {
                    if (mono) it else lerp(it, Color.Black, .2f)
                },
            onTertiary = Color.White,
            tertiaryContainer = lerp(Color.White, Color(tokens.paneEnd), .2f),
            onTertiaryContainer = lerp(Color(tokens.paneEnd), Color.Black, .6f),
            background = surface,
            onBackground = Color(0xFF1B1B1F),
            surface = surface,
            onSurface = Color(0xFF1B1B1F),
            surfaceVariant = tone(.08f),
            onSurfaceVariant = Color(0xFF46464F),
            surfaceTint = primary,
            inverseSurface = Color(0xFF303034),
            inverseOnSurface = Color(0xFFF2F0F4),
            error = Color(0xFFBA1A1A),
            onError = Color.White,
            errorContainer = Color(0xFFFFDAD6),
            onErrorContainer = Color(0xFF410002),
            outline = Color(0xFF777680),
            outlineVariant = Color(0xFFC7C5D0),
            scrim = Color.Black,
            surfaceBright = surface,
            surfaceDim = tone(.1f),
            surfaceContainerLowest = Color.White,
            surfaceContainerLow = tone(.03f),
            surfaceContainer = tone(.05f),
            surfaceContainerHigh = tone(.075f),
            surfaceContainerHighest = tone(.1f),
        )
    }
    val seed = Color(tokens.shellStart)
    val primary = if (mono) Color(0xFFE6E6EB) else lerp(seed, Color.White, .2f)
    val surface = if (mono) Color(0xFF121214) else Color(tokens.darkBackground)
    fun tone(amount: Float) = lerp(surface, if (mono) Color(0xFFE6E6EB) else seed, amount)
    return darkColorScheme(
        primary = primary,
        onPrimary = if (mono) Color(0xFF1B1B1F) else Color(tokens.darkBrand),
        primaryContainer = if (mono) Color(0xFF3A3A40) else lerp(surface, seed, .32f),
        onPrimaryContainer = if (mono) Color(0xFFE6E6EB) else lerp(seed, Color.White, .6f),
        inversePrimary = lerp(seed, Color.Black, .3f),
        secondary = if (mono) Color(0xFFC6C6CE) else lerp(seed, Color(0xFFC6C6CE), .5f),
        onSecondary = Color(0xFF2F3036),
        secondaryContainer = if (mono) Color(0xFF34343A) else lerp(surface, seed, .22f),
        onSecondaryContainer = if (mono) Color(0xFFE4E4EA) else lerp(seed, Color.White, .65f),
        tertiary = lerp(Color(tokens.paneStart), Color.White, .1f),
        onTertiary = Color(tokens.darkBrand),
        tertiaryContainer = lerp(surface, Color(tokens.paneEnd), .3f),
        onTertiaryContainer = lerp(Color(tokens.paneStart), Color.White, .5f),
        background = surface,
        onBackground = Color(0xFFE4E2E6),
        surface = surface,
        onSurface = Color(0xFFE4E2E6),
        surfaceVariant = tone(.1f),
        onSurfaceVariant = Color(0xFFC7C5D0),
        surfaceTint = primary,
        inverseSurface = Color(0xFFE4E2E6),
        inverseOnSurface = Color(0xFF303034),
        error = Color(0xFFFFB4AB),
        onError = Color(0xFF690005),
        errorContainer = Color(0xFF93000A),
        onErrorContainer = Color(0xFFFFDAD6),
        outline = Color(0xFF91909A),
        outlineVariant = Color(0xFF46464F),
        scrim = Color.Black,
        surfaceBright = tone(.14f),
        surfaceDim = surface,
        surfaceContainerLowest = lerp(surface, Color.Black, .4f),
        surfaceContainerLow = tone(.04f),
        surfaceContainer = tone(.065f),
        surfaceContainerHigh = tone(.09f),
        surfaceContainerHighest = tone(.12f),
    )
}

private fun materialSemantic(scheme: ColorScheme, dark: Boolean) =
    DieterColors(
        dark = dark,
        background = scheme.surface,
        cell = scheme.surfaceContainerLow,
        inset = scheme.surfaceContainerHigh,
        fill = scheme.surfaceContainerHighest,
        label = scheme.onSurface,
        secondaryLabel = scheme.onSurfaceVariant,
        tertiaryLabel = scheme.onSurfaceVariant.copy(alpha = .62f),
        separator = scheme.outlineVariant,
        accent = scheme.primary,
        onAccent = scheme.onPrimary,
        accentContainer = scheme.secondaryContainer,
        onAccentContainer = scheme.onSecondaryContainer,
        destructive = scheme.error,
        success = if (dark) Color(0xFF7DDB98) else Color(0xFF1E7A3C),
        warning = if (dark) Color(0xFFF7BD66) else Color(0xFF9A5B00),
        info = if (dark) Color(0xFF9CCAFF) else Color(0xFF00629E),
        purple = if (dark) Color(0xFFD7BAFF) else Color(0xFF7440B6),
    )

/** Material components keep working on iOS while drawing with the system palette. */
private fun appleMaterialBridge(scheme: ColorScheme, semantic: DieterColors) =
    scheme.copy(
        primary = semantic.accent,
        onPrimary = semantic.onAccent,
        primaryContainer = semantic.accentContainer,
        onPrimaryContainer = semantic.onAccentContainer,
        secondary = semantic.accent,
        onSecondary = semantic.onAccent,
        secondaryContainer = semantic.accentContainer,
        onSecondaryContainer = semantic.onAccentContainer,
        background = semantic.background,
        onBackground = semantic.label,
        surface = semantic.background,
        onSurface = semantic.label,
        surfaceVariant = semantic.fill,
        onSurfaceVariant = semantic.secondaryLabel,
        surfaceTint = Color.Transparent,
        surfaceContainerLowest = semantic.cell,
        surfaceContainerLow = semantic.cell,
        surfaceContainer = semantic.cell,
        surfaceContainerHigh = semantic.cell,
        surfaceContainerHighest = semantic.inset,
        outline = semantic.separator,
        outlineVariant = semantic.separator,
        error = semantic.destructive,
    )

private fun ios(size: Int, line: Int, tracking: Float, weight: FontWeight = FontWeight.Normal) =
    TextStyle(
        fontSize = size.sp,
        lineHeight = line.sp,
        letterSpacing = (tracking / size).em,
        fontWeight = weight,
    )

/** iOS Dynamic Type at the default size, including the system tracking table. */
internal fun appleType(mono: FontFamily = FontFamily.Monospace) =
    DieterType(
        largeTitle = ios(34, 41, .4f, FontWeight.Bold),
        title1 = ios(28, 34, .38f, FontWeight.Bold),
        title2 = ios(22, 28, -.26f, FontWeight.Bold),
        title3 = ios(20, 25, -.45f, FontWeight.SemiBold),
        headline = ios(17, 22, -.43f, FontWeight.SemiBold),
        body = ios(17, 22, -.43f),
        bodyEmphasized = ios(17, 22, -.43f, FontWeight.SemiBold),
        callout = ios(16, 21, -.31f),
        subheadline = ios(15, 20, -.23f),
        footnote = ios(13, 18, -.08f),
        caption = ios(12, 16, 0f),
        caption2 = ios(11, 13, .06f),
        mono = TextStyle(fontFamily = mono, fontSize = 13.sp, lineHeight = 18.sp),
        monoSmall = TextStyle(fontFamily = mono, fontSize = 11.sp, lineHeight = 15.sp),
    )

private fun m3(
    size: Int,
    line: Int,
    weight: FontWeight = FontWeight.Normal,
    tracking: TextUnit = 0.sp,
    family: FontFamily = FontFamily.Default,
) =
    TextStyle(
        fontFamily = family,
        fontSize = size.sp,
        lineHeight = line.sp,
        fontWeight = weight,
        letterSpacing = tracking,
    )

internal fun materialType(display: FontFamily) =
    DieterType(
        largeTitle = m3(28, 36, FontWeight.SemiBold, family = display),
        title1 = m3(24, 32, FontWeight.SemiBold, family = display),
        title2 = m3(22, 28, FontWeight.Medium, family = display),
        title3 = m3(18, 24, FontWeight.Medium, family = display),
        headline = m3(16, 24, FontWeight.Medium, .15.sp),
        body = m3(16, 24, tracking = .5.sp),
        bodyEmphasized = m3(16, 24, FontWeight.Medium, .15.sp),
        callout = m3(15, 22, tracking = .25.sp),
        subheadline = m3(14, 20, tracking = .25.sp),
        footnote = m3(12, 16, tracking = .4.sp),
        caption = m3(12, 16, FontWeight.Medium, .5.sp),
        caption2 = m3(11, 16, FontWeight.Medium, .5.sp),
        mono = TextStyle(fontFamily = FontFamily.Monospace, fontSize = 13.sp, lineHeight = 18.sp),
        monoSmall =
            TextStyle(fontFamily = FontFamily.Monospace, fontSize = 11.sp, lineHeight = 15.sp),
    )

private fun materialTypography(display: FontFamily): Typography {
    val base = Typography()
    return base.copy(
        displaySmall = base.displaySmall.copy(fontFamily = display),
        headlineLarge =
            base.headlineLarge.copy(fontFamily = display, fontWeight = FontWeight.SemiBold),
        headlineMedium =
            base.headlineMedium.copy(fontFamily = display, fontWeight = FontWeight.SemiBold),
        headlineSmall =
            base.headlineSmall.copy(fontFamily = display, fontWeight = FontWeight.SemiBold),
        titleLarge = base.titleLarge.copy(fontFamily = display, fontWeight = FontWeight.Medium),
    )
}

private fun appleTypography(value: DieterType) =
    Typography(
        displayLarge = value.largeTitle,
        displayMedium = value.largeTitle,
        displaySmall = value.title1,
        headlineLarge = value.largeTitle,
        headlineMedium = value.title1,
        headlineSmall = value.title2,
        titleLarge = value.title3,
        titleMedium = value.headline,
        titleSmall = value.subheadline.copy(fontWeight = FontWeight.SemiBold),
        bodyLarge = value.body,
        bodyMedium = value.subheadline,
        bodySmall = value.footnote,
        labelLarge = value.subheadline.copy(fontWeight = FontWeight.SemiBold),
        labelMedium = value.footnote.copy(fontWeight = FontWeight.Medium),
        labelSmall = value.caption2,
    )

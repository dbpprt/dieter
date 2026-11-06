package com.getdieter.mobile.desktop

import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.getdieter.mobile.design.*
import com.getdieter.mobile.platform.platformMonospace
import com.getdieter.mobile.settings.DieterPalette

/**
 * The desktop shell's surfaces, as the Mac app draws them: a canvas, floating panels, tiles on them
 * and controls on those. Each comes from the selected palette the way the Mac derives it.
 */
@Immutable
internal class DesktopTokens(
    val dark: Boolean,
    /** L0: the window behind every panel. */
    val canvas: Color,
    /** L1: floating panels (sidebar, conversation, lists' detail). */
    val panel: Color,
    val panelRim: Color,
    /** L2: cards and rows on the canvas or a panel. */
    val tile: Color,
    val tileHover: Color,
    val tileSelected: Color,
    val tileRim: Color,
    val tileRimSelected: Color,
    /** A recessed well, e.g. the machines and quotas panel. */
    val inset: Color,
    val hairline: Color,
    val text: Color,
    val subtle: Color,
    val tertiary: Color,
    /** L3: capsule controls and segmented tracks. */
    val control: Color,
    val controlRim: Color,
    val segmentThumb: Color,
    val selection: Color,
    /** Primary buttons, unread mail and review, as systemBlue. */
    val action: Color,
    val running: Color,
    val attention: Color,
    val coral: Color,
    val decision: Color,
    val offline: Color,
) {
    companion object {
        fun of(palette: DieterPalette, dark: Boolean): DesktopTokens {
            val p = palette.tokens
            val white = 0xFFFFFFL
            fun rgb(value: Long, alpha: Float = 1f) =
                Color(0xFF000000L or (value and 0xFFFFFF)).copy(alpha = alpha)
            val lightSurface = mix(p.light, white, .72f)
            val darkSubtle = mix(p.light, p.darkBrand, .30f)
            val darkTertiary = mix(p.light, p.darkBrand, .48f)
            val lightSubtle = mix(p.darkBrand, p.light, .34f)
            val lightTertiary = mix(p.darkBrand, p.light, .43f)
            return DesktopTokens(
                dark = dark,
                canvas = rgb(if (dark) p.darkSurface else mix(p.light, p.darkBrand, .07f)),
                panel = rgb(if (dark) p.darkRaised else lightSurface),
                panelRim = if (dark) Color.White.copy(.11f) else Color.Black.copy(.08f),
                tile = if (dark) Color.White.copy(.05f) else Color.White.copy(.62f),
                tileHover = if (dark) Color.White.copy(.08f) else Color.White.copy(.82f),
                tileSelected = if (dark) Color.White.copy(.11f) else Color.White.copy(.96f),
                tileRim = if (dark) Color.White.copy(.08f) else Color.Black.copy(.07f),
                tileRimSelected = if (dark) Color.White.copy(.26f) else Color.Black.copy(.2f),
                inset = if (dark) Color.Black.copy(.24f) else Color.Black.copy(.045f),
                hairline = if (dark) Color.White.copy(.08f) else Color.Black.copy(.08f),
                text = rgb(if (dark) p.light else p.darkBrand),
                subtle = rgb(if (dark) darkSubtle else lightSubtle),
                tertiary = rgb(if (dark) darkTertiary else lightTertiary),
                control = if (dark) Color.White.copy(.1f) else Color.White,
                controlRim = if (dark) Color.White.copy(.1f) else Color.Black.copy(.07f),
                segmentThumb = if (dark) Color.White.copy(.15f) else Color.White,
                selection = rgb(if (dark) p.shellStart else p.shellEnd, if (dark) .2f else .13f),
                action = if (dark) Color(0xFF0A84FF) else Color(0xFF007AFF),
                running = if (dark) Color(0xFF32D74B) else Color(0xFF28CD41),
                attention = rgb(if (dark) 0xE8A33D else 0xA84C08),
                coral = rgb(if (dark) 0xF26D80 else 0xD52D4B),
                decision = if (dark) Color(0xFFBF5AF2) else Color(0xFFAF52DE),
                offline = if (dark) Color(0xFFFF453A) else Color(0xFFFF3B30),
            )
        }

        /** The Mac's channel mix: [amount] of the way from [first] to [second]. */
        internal fun mix(first: Long, second: Long, amount: Float): Long {
            fun channel(shift: Int): Long {
                val a = (first shr shift) and 0xFF
                val b = (second shr shift) and 0xFF
                return kotlin.math.round(a + (b - a) * amount.coerceIn(0f, 1f)).toLong()
            }
            return (channel(16) shl 16) or (channel(8) shl 8) or channel(0)
        }
    }
}

internal val LocalDesktopTokens = staticCompositionLocalOf<DesktopTokens?> { null }

/** True inside the desktop shell: dense controls, hover states, pointer and keyboard first. */
internal val desktop: Boolean
    @Composable @ReadOnlyComposable get() = LocalDesktopTokens.current != null

/** The desktop tokens; only valid inside [DesktopTheme]. */
internal val tokens: DesktopTokens
    @Composable
    @ReadOnlyComposable
    get() = LocalDesktopTokens.current ?: DesktopTokens.of(DieterPalette.DEFAULT, false)

/** Mac metrics the desktop shell shares. */
internal object DesktopMetrics {
    val windowInset = 10.dp
    val panelGap = 10.dp
    val panelRadius = 16.dp
    val sidebarRadius = 16.dp
    val tileRadius = 10.dp
    val rowRadius = 8.dp
    val rowHeight = 29.dp
    val titleBand = 52.dp
    val control = 30.dp
    val segment = 26.dp
}

/**
 * The semantic colors every reused screen reads, resolved for the desktop: screens draw on a panel,
 * grouped rows are tiles on it.
 */
private fun desktopColors(t: DesktopTokens, palette: DieterPalette): DieterColors {
    val mono = palette == DieterPalette.MONOCHROME
    val accent =
        if (mono) t.action
        else
            Color(
                0xFF000000L or
                    ((if (t.dark) palette.tokens.shellStart else palette.tokens.shellEnd) and
                        0xFFFFFF)
            )
    val cell =
        if (t.dark) Color.White.copy(.06f).compositeOverSafe(t.panel)
        else Color.Black.copy(.035f).compositeOverSafe(t.panel)
    return DieterColors(
        dark = t.dark,
        background = t.panel,
        cell = cell,
        inset = t.inset.compositeOverSafe(t.panel),
        fill = if (t.dark) Color.White.copy(.09f) else Color.Black.copy(.055f),
        label = t.text,
        secondaryLabel = t.subtle,
        tertiaryLabel = t.tertiary,
        separator = t.hairline.copy(alpha = if (t.dark) .14f else .12f),
        accent = accent,
        onAccent = Color.White,
        accentContainer =
            accent.copy(alpha = if (t.dark) .26f else .14f).compositeOverSafe(t.panel),
        onAccentContainer = if (t.dark) Color.White else t.text,
        destructive = t.offline,
        success = t.running,
        warning = t.attention,
        info = t.action,
        purple = t.decision,
    )
}

private fun Color.compositeOverSafe(background: Color): Color {
    val a = alpha
    return Color(
        red = red * a + background.red * (1 - a),
        green = green * a + background.green * (1 - a),
        blue = blue * a + background.blue * (1 - a),
        alpha = 1f,
    )
}

private fun dense(
    size: Float,
    line: Float,
    weight: FontWeight = FontWeight.Normal,
    family: FontFamily = FontFamily.Default,
) = TextStyle(fontFamily = family, fontSize = size.sp, lineHeight = line.sp, fontWeight = weight)

/** The Mac's type: 13 pt body, 11.5 pt captions, Sora for titles. */
internal fun desktopType(display: FontFamily, mono: FontFamily) =
    DieterType(
        largeTitle = dense(19f, 25f, FontWeight.SemiBold, display),
        title1 = dense(17f, 23f, FontWeight.SemiBold, display),
        title2 = dense(15f, 20f, FontWeight.SemiBold, display),
        title3 = dense(14f, 19f, FontWeight.SemiBold),
        headline = dense(13f, 17f, FontWeight.SemiBold),
        body = dense(13f, 18f),
        bodyEmphasized = dense(13f, 18f, FontWeight.SemiBold),
        callout = dense(12.5f, 17f),
        subheadline = dense(12f, 16f),
        footnote = dense(11f, 14f),
        caption = dense(11f, 14f, FontWeight.Medium),
        caption2 = dense(10f, 13f, FontWeight.Medium),
        mono = TextStyle(fontFamily = mono, fontSize = 12.sp, lineHeight = 17.sp),
        monoSmall = TextStyle(fontFamily = mono, fontSize = 10.5.sp, lineHeight = 14.sp),
    )

private fun desktopTypography(display: FontFamily) =
    Typography(
        displayLarge = dense(32f, 40f, FontWeight.SemiBold, display),
        displayMedium = dense(26f, 32f, FontWeight.SemiBold, display),
        displaySmall = dense(22f, 28f, FontWeight.SemiBold, display),
        headlineLarge = dense(20f, 26f, FontWeight.SemiBold, display),
        headlineMedium = dense(18f, 24f, FontWeight.SemiBold, display),
        headlineSmall = dense(16f, 22f, FontWeight.SemiBold, display),
        titleLarge = dense(14.5f, 20f, FontWeight.SemiBold),
        titleMedium = dense(13f, 18f, FontWeight.SemiBold),
        titleSmall = dense(12.5f, 17f, FontWeight.Medium),
        bodyLarge = dense(13f, 18f),
        bodyMedium = dense(12.5f, 17f),
        bodySmall = dense(11f, 15f),
        labelLarge = dense(12.5f, 16f, FontWeight.Medium),
        labelMedium = dense(11.5f, 15f, FontWeight.Medium),
        labelSmall = dense(10.5f, 14f, FontWeight.Medium),
    )

/**
 * Restyles everything below for the desktop: Mac colors and type, dense Material components and no
 * 48 dp touch-target padding (a pointer is precise).
 */
@Composable
internal fun DesktopTheme(
    palette: DieterPalette,
    dark: Boolean,
    display: FontFamily,
    content: @Composable () -> Unit,
) {
    val t = remember(palette, dark) { DesktopTokens.of(palette, dark) }
    val semantic = remember(t, palette) { desktopColors(t, palette) }
    val mono = platformMonospace()
    val semanticType = remember(display, mono) { desktopType(display, mono) }
    val base = MaterialTheme.colorScheme
    val scheme =
        base.copy(
            primary = semantic.accent,
            onPrimary = semantic.onAccent,
            primaryContainer = semantic.accentContainer,
            onPrimaryContainer = semantic.onAccentContainer,
            secondaryContainer = semantic.accentContainer,
            onSecondaryContainer = semantic.onAccentContainer,
            background = t.panel,
            onBackground = t.text,
            surface = t.panel,
            onSurface = t.text,
            onSurfaceVariant = t.subtle,
            surfaceTint = Color.Transparent,
            surfaceContainerLowest = t.panel,
            surfaceContainerLow = semantic.cell,
            surfaceContainer = t.panel,
            surfaceContainerHigh = semantic.cell,
            surfaceContainerHighest = semantic.inset,
            outline = t.tertiary,
            outlineVariant = semantic.separator,
        )
    CompositionLocalProvider(
        LocalDesktopTokens provides t,
        LocalDieterColors provides semantic,
        LocalDieterType provides semanticType,
        LocalMinimumInteractiveComponentSize provides 0.dp,
    ) {
        MaterialTheme(
            colorScheme = scheme,
            typography = desktopTypography(display),
            shapes =
                Shapes(
                    extraSmall = RoundedCornerShape(5.dp),
                    small = RoundedCornerShape(8.dp),
                    medium = RoundedCornerShape(10.dp),
                    large = RoundedCornerShape(14.dp),
                    extraLarge = RoundedCornerShape(18.dp),
                ),
            content = content,
        )
    }
}

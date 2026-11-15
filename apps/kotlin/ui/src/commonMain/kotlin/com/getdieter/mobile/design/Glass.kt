package com.getdieter.mobile.design

import androidx.compose.runtime.*
import androidx.compose.runtime.snapshots.Snapshot
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawWithCache
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.draw.dropShadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.*
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.clipPath
import androidx.compose.ui.graphics.drawscope.translate
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.layer.GraphicsLayer
import androidx.compose.ui.graphics.layer.drawLayer
import androidx.compose.ui.graphics.shadow.Shadow
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInRoot
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.DpOffset
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import com.getdieter.mobile.platform.GlassLens
import com.getdieter.mobile.platform.createGlassEffects
import kotlin.math.roundToInt

/**
 * Liquid glass, the Android shell's floating material. A [GlassBackdrop] records what lies beneath
 * ([glassSource]); every [glass] surface drawn above it shows its own region of that recording
 * through the platform's lens: blurred, saturated and bent at the rim where shaders run (Android
 * 13+, and Skia in UI tests), blurred only on Android 12, and as a solid tint on older devices.
 *
 * A surface must not sit inside its own backdrop's source: the shell records the page and floats
 * the navigation above it, a conversation records its transcript and floats the composer above.
 */
@Stable
internal class GlassBackdrop internal constructor(internal val layer: GraphicsLayer) {
    /** Where the recorded content sits in the root, so surfaces can find their region. */
    internal var origin by mutableStateOf(Offset.Zero)
    /** Advances with every recording, so surfaces redraw when what lies beneath them changes. */
    internal var version by mutableIntStateOf(0)
}

@Composable
internal fun rememberGlassBackdrop(): GlassBackdrop {
    val layer = androidx.compose.ui.graphics.rememberGraphicsLayer()
    return remember(layer) { GlassBackdrop(layer) }
}

/** Records this content for the glass surfaces above it; draws it unchanged. */
internal fun Modifier.glassSource(backdrop: GlassBackdrop?): Modifier =
    if (backdrop == null) this
    else
        onGloballyPositioned { backdrop.origin = it.positionInRoot() }
            // Its own layer: redrawing a parent must not record again, nor bump the version.
            .graphicsLayer()
            .drawWithContent {
                backdrop.layer.record { this@drawWithContent.drawContent() }
                drawLayer(backdrop.layer)
                // Written while drawing, but never read here: only the surfaces redraw.
                Snapshot.withoutReadObservation { backdrop.version++ }
            }

/** How one kind of glass looks; see [GlassStyles]. */
@Immutable
internal data class GlassStyle(
    /** Laid over the bent backdrop, so labels on the glass stay readable. */
    val tint: Color,
    /** The whole surface where the platform cannot filter (Android 11 and older). */
    val fallback: Color,
    /** A soft light falling on the upper half. */
    val sheen: Color,
    /** The rim's brightest point, top-left; the bottom-right catches a fainter reflection. */
    val highlight: Color,
    val blur: Dp,
    val saturation: Float,
    /** Width of the bent rim and how far it pulls the picture beneath. */
    val bezel: Dp,
    val refraction: Dp,
    val dispersion: Float,
    val rim: Dp,
    val shadow: Dp,
    val shadowColor: Color,
    /** Magnifies what lies beneath, 1 for none. */
    val zoom: Float = 1f,
)

/** The glass kinds of the Android shell, in light and dark. */
internal object GlassStyles {
    /** Floating navigation: clear, with a strong rim, so the page reads through it. */
    @Composable
    @ReadOnlyComposable
    fun chrome(): GlassStyle {
        val dark = palette.dark
        return GlassStyle(
            tint =
                if (dark) colors.surfaceContainer.copy(alpha = .52f)
                else Color.White.copy(alpha = .5f),
            fallback =
                if (dark) colors.surfaceContainerHigh.copy(alpha = .97f)
                else colors.surfaceContainerLowest.copy(alpha = .97f),
            sheen = Color.White.copy(alpha = if (dark) .06f else .32f),
            highlight = Color.White.copy(alpha = if (dark) .34f else .95f),
            blur = 9.dp,
            saturation = if (dark) 1.4f else 1.55f,
            bezel = 18.dp,
            refraction = 11.dp,
            dispersion = .35f,
            rim = 1.dp,
            shadow = 22.dp,
            shadowColor = Color.Black.copy(alpha = if (dark) .5f else .16f),
        )
    }

    /** The composer: denser, so what you type never competes with the transcript beneath. */
    @Composable
    @ReadOnlyComposable
    fun panel(): GlassStyle {
        val dark = palette.dark
        return chrome()
            .copy(
                tint =
                    if (dark) colors.surfaceContainerHigh.copy(alpha = .78f)
                    else Color.White.copy(alpha = .76f),
                blur = 16.dp,
                refraction = 9.dp,
                dispersion = .2f,
                shadow = 26.dp,
                shadowColor = Color.Black.copy(alpha = if (dark) .55f else .14f),
            )
    }

    /**
     * The lifted selection: a clear bead that magnifies the tabs beneath it, with a domed rim and
     * no blur, so it reads as a drop of water on the bar.
     */
    @Composable
    @ReadOnlyComposable
    fun bead(): GlassStyle {
        val dark = palette.dark
        return chrome()
            .copy(
                tint = Color.White.copy(alpha = if (dark) .05f else .1f),
                fallback = Color.White.copy(alpha = if (dark) .12f else .3f),
                sheen = Color.White.copy(alpha = if (dark) .1f else .3f),
                highlight = Color.White.copy(alpha = if (dark) .7f else 1f),
                blur = 0.dp,
                saturation = 1.2f,
                bezel = 16.dp,
                refraction = 7.dp,
                dispersion = .6f,
                rim = 1.25.dp,
                shadow = 12.dp,
                shadowColor = Color.Black.copy(alpha = if (dark) .45f else .16f),
                zoom = 1.3f,
            )
    }

    /** An accent-tinted drop, e.g. the compose button beside the navigation. */
    @Composable
    @ReadOnlyComposable
    fun tinted(color: Color): GlassStyle =
        chrome()
            .copy(
                tint = color.copy(alpha = .86f),
                fallback = color,
                sheen = Color.White.copy(alpha = .22f),
                highlight = Color.White.copy(alpha = .7f),
                shadowColor = color.copy(alpha = if (palette.dark) .45f else .38f),
            )
}

/**
 * Draws this element as glass of [style] over [backdrop], clipped to [shape], with a soft drop
 * shadow, a sheen and a lit rim. Without a backdrop (e.g. inside a sheet, its own window) the
 * surface uses the style's fallback tint.
 */
@Composable
internal fun Modifier.glass(
    backdrop: GlassBackdrop?,
    shape: Shape,
    style: GlassStyle,
    shadow: Boolean = true,
): Modifier {
    val layer = androidx.compose.ui.graphics.rememberGraphicsLayer()
    val effects = remember { createGlassEffects() }
    val position = remember { mutableStateOf(Offset.Zero) }
    return this.then(
            if (shadow && style.shadowColor.alpha > 0f)
                Modifier.dropShadow(
                    shape,
                    Shadow(
                        radius = style.shadow,
                        color = style.shadowColor,
                        offset = DpOffset(0.dp, style.shadow / 3),
                    ),
                )
            else Modifier
        )
        .onGloballyPositioned { position.value = it.positionInRoot() }
        // Its own layer, so following the backdrop redraws only this surface. Without it the
        // redraw reaches the nearest parent layer, which may hold the backdrop's source:
        // recording again would bump the version and redraw this surface, frame after frame.
        .graphicsLayer()
        .drawWithCache {
            val outline = shape.createOutline(size, layoutDirection, this)
            val clip = Path().apply { addOutline(outline) }
            val radius =
                (outline as? Outline.Rounded)?.roundRect?.topLeftCornerRadius?.x
                    ?: (if (outline is Outline.Generic) size.minDimension / 2f else 0f)
            // Margin around the surface, so blur and lens sample real content at the rim.
            val pad = (style.blur + style.refraction).toPx() * 1.5f + 2f
            val lens =
                if (style.refraction > 0.dp || style.zoom != 1f)
                    GlassLens(
                        pad,
                        pad,
                        size.width,
                        size.height,
                        radius,
                        style.bezel.toPx(),
                        style.refraction.toPx(),
                        style.dispersion,
                        style.zoom,
                    )
                else null
            val effect =
                if (backdrop != null) effects.effect(style.blur.toPx(), style.saturation, lens)
                else null
            layer.renderEffect = effect
            val recorded =
                IntSize(
                    (size.width + pad * 2).roundToInt().coerceAtLeast(1),
                    (size.height + pad * 2).roundToInt().coerceAtLeast(1),
                )
            val rimWidth = style.rim.toPx() * 2f
            val rim =
                Brush.linearGradient(
                    0f to style.highlight,
                    .3f to style.highlight.copy(alpha = style.highlight.alpha * .18f),
                    .7f to style.highlight.copy(alpha = style.highlight.alpha * .08f),
                    1f to style.highlight.copy(alpha = style.highlight.alpha * .55f),
                    start = Offset.Zero,
                    end = Offset(size.width, size.height),
                )
            val sheen = Brush.verticalGradient(0f to style.sheen, .6f to Color.Transparent)
            onDrawBehind {
                clipPath(clip) {
                    if (backdrop != null && effect != null) {
                        backdrop.version
                        val offset = position.value - backdrop.origin
                        layer.record(recorded) {
                            translate(pad - offset.x, pad - offset.y) {
                                drawLayer(backdrop.layer)
                            }
                        }
                        translate(-pad, -pad) { drawLayer(layer) }
                        drawRect(style.tint)
                    } else drawRect(style.fallback)
                    drawRect(sheen)
                    // Twice the rim's width, centred on the edge: the clip keeps the inner half.
                    drawOutline(outline, rim, style = Stroke(rimWidth))
                }
            }
        }
}

package com.getdieter.mobile.design

import androidx.compose.animation.*
import androidx.compose.animation.core.*
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawWithCache
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.drawOutline
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

// The shell's motion: one set of springs, the transitions between routes and panes, and a few
// small live effects (press scale, the working glow, text shimmer, typing dots). Everything here
// is presentation only.

/** The springs every animated surface shares, so motion feels like one material. */
internal object Motion {
    /** Pages and panes arriving: a little overshoot, settles fast. */
    fun <T> emphasized() = spring<T>(dampingRatio = .82f, stiffness = 380f)

    /** Controls reacting to a touch. */
    fun <T> quick() = spring<T>(dampingRatio = .7f, stiffness = 700f)

    /** A playful pop, e.g. a selected tab or a button that just became available. */
    fun <T> bouncy() = spring<T>(dampingRatio = .5f, stiffness = 600f)

    /** Layout that follows content, e.g. a disclosure opening. */
    fun <T> settle() = spring<T>(dampingRatio = .85f, stiffness = 320f)
}

/**
 * The shared-axis transition between two pages of one stack: the new page slides in from the
 * trailing edge (or the leading one on the way back) while it grows from 96 %, and the old one
 * slides a little further away and fades.
 */
internal fun pushTransition(forward: Boolean): ContentTransform {
    val sign = if (forward) 1 else -1
    return (slideInHorizontally(Motion.emphasized()) { sign * it / 5 } +
        fadeIn(tween(220, delayMillis = 30)) +
        scaleIn(Motion.emphasized(), initialScale = .96f)) togetherWith
        (slideOutHorizontally(tween(260, easing = FastOutSlowInEasing)) { -sign * it / 6 } +
            fadeOut(tween(150)) +
            scaleOut(tween(260), targetScale = .97f))
}

/** Switching tabs: the pages pass each other sideways in the order of the tabs, gently. */
internal fun tabTransition(forward: Boolean): ContentTransform {
    val sign = if (forward) 1 else -1
    return (slideInHorizontally(Motion.emphasized()) { sign * it / 14 } +
        fadeIn(tween(220, delayMillis = 40))) togetherWith
        (slideOutHorizontally(tween(200)) { -sign * it / 14 } + fadeOut(tween(110)))
}

/** A detail arriving beside its list: it lifts in from a few dp below, fading. */
internal fun detailTransition(): ContentTransform =
    (slideInVertically(Motion.emphasized()) { it / 24 } +
        fadeIn(tween(200, delayMillis = 40)) +
        scaleIn(Motion.emphasized(), initialScale = .985f)) togetherWith
        (fadeOut(tween(120)) + scaleOut(tween(160), targetScale = .99f))

/** A sheet-like page presented modally: rises from below and grows from 96 %. */
internal val modalEnter: EnterTransition =
    slideInVertically(Motion.emphasized()) { it / 6 } +
        fadeIn(tween(200)) +
        scaleIn(Motion.emphasized(), initialScale = .96f)

internal val modalExit: ExitTransition =
    slideOutVertically(tween(220, easing = FastOutLinearInEasing)) { it / 7 } +
        fadeOut(tween(160)) +
        scaleOut(tween(220), targetScale = .97f)

/** Something appearing in place, e.g. a floating pill: grows from 80 % and fades in. */
internal val popIn: EnterTransition =
    scaleIn(Motion.bouncy(), initialScale = .8f) + fadeIn(tween(160))

internal val popOut: ExitTransition = scaleOut(tween(140), targetScale = .85f) + fadeOut(tween(120))

/** Shrinks the element to [pressed] % while a finger rests on it; a spring brings it back. */
@Composable
internal fun Modifier.pressScale(
    interaction: MutableInteractionSource,
    enabled: Boolean = true,
    pressed: Float = .975f,
): Modifier {
    val isPressed by interaction.collectIsPressedAsState()
    val scale by
        animateFloatAsState(
            if (isPressed && enabled) pressed else 1f,
            Motion.quick(),
            label = "press-scale",
        )
    return graphicsLayer {
        scaleX = scale
        scaleY = scale
    }
}

/** A pop when [trigger] changes: the element dips to [from] and springs back to its size. */
@Composable
internal fun Modifier.popOnChange(trigger: Any?, from: Float = .82f): Modifier {
    val scale = remember { Animatable(1f) }
    var first by remember { mutableStateOf(true) }
    LaunchedEffect(trigger) {
        if (first) {
            first = false
            return@LaunchedEffect
        }
        scale.snapTo(from)
        scale.animateTo(1f, Motion.bouncy())
    }
    return graphicsLayer {
        scaleX = scale.value
        scaleY = scale.value
    }
}

/**
 * Color stops of a sweep whose bright [highlight] sits at [position] (0–1 around the circle) and
 * fades into [base] over [width] on either side, wrapped so the ring has no seam.
 */
internal fun sweepStops(
    position: Float,
    highlight: Color,
    base: Color,
    width: Float = .18f,
): Array<Pair<Float, Color>> {
    val center = ((position % 1f) + 1f) % 1f
    val points = mutableListOf(0f to base, 1f to base)
    fun add(at: Float, color: Color) {
        when {
            at < 0f -> {
                points.add(at + 1f to color)
                points.add(0f to lerpColor(base, highlight, 1f - (-at / width)))
            }
            at > 1f -> {
                points.add(at - 1f to color)
                points.add(1f to lerpColor(base, highlight, 1f - ((at - 1f) / width)))
            }
            else -> points.add(at to color)
        }
    }
    add(center - width, base)
    add(center, highlight)
    add(center + width, base)
    // Two stops at 0 or 1 keep the brighter one, so the seam is continuous.
    val merged =
        points
            .groupBy { (it.first * 10_000).toInt() }
            .map { (_, group) -> group.maxBy { it.second.alpha } }
            .sortedBy { it.first }
    return merged.toTypedArray()
}

private fun lerpColor(a: Color, b: Color, t: Float) =
    androidx.compose.ui.graphics.lerp(a, b, t.coerceIn(0f, 1f))

/**
 * A soft light travelling along the outline while [active]: the way the composer shows that the
 * agent is working on what was sent. Nothing is drawn when idle.
 */
@Composable
internal fun Modifier.workingGlow(
    active: Boolean,
    shape: Shape,
    color: Color,
    width: Dp = 2.dp,
): Modifier {
    val alpha by animateFloatAsState(if (active) 1f else 0f, tween(400), label = "glow-alpha")
    if (alpha <= 0f) return this
    val transition = rememberInfiniteTransition(label = "glow")
    val turn by
        transition.animateFloat(
            0f,
            1f,
            infiniteRepeatable(tween(2600, easing = LinearEasing)),
            label = "glow-turn",
        )
    return drawWithCache {
        val outline = shape.createOutline(size, layoutDirection, this)
        val stroke = Stroke(width.toPx())
        onDrawWithContent {
            drawContent()
            val stops =
                sweepStops(
                    turn,
                    color.copy(alpha = color.alpha * alpha),
                    color.copy(alpha = .08f * alpha),
                    width = .22f,
                )
            val second =
                sweepStops(
                    turn + .5f,
                    color.copy(alpha = color.alpha * .55f * alpha),
                    Color.Transparent,
                    width = .12f,
                )
            drawOutline(outline, Brush.sweepGradient(*stops, center = center), style = stroke)
            drawOutline(outline, Brush.sweepGradient(*second, center = center), style = stroke)
        }
    }
}

/** A text style whose glyphs carry a sweeping highlight, for live status lines. */
@Composable
internal fun TextStyle.shimmer(base: Color, highlight: Color): TextStyle {
    val transition = rememberInfiniteTransition(label = "shimmer")
    val phase by
        transition.animateFloat(
            -1f,
            2f,
            infiniteRepeatable(tween(1600, easing = LinearEasing)),
            label = "shimmer-phase",
        )
    val brush =
        remember(phase, base, highlight) {
            object : androidx.compose.ui.graphics.ShaderBrush() {
                override fun createShader(size: androidx.compose.ui.geometry.Size) =
                    androidx.compose.ui.graphics.LinearGradientShader(
                        from = Offset(size.width * (phase - .4f), 0f),
                        to = Offset(size.width * (phase + .4f), 0f),
                        colors = listOf(base, highlight, base),
                        colorStops = listOf(0f, .5f, 1f),
                        tileMode = androidx.compose.ui.graphics.TileMode.Clamp,
                    )
            }
        }
    return merge(TextStyle(brush = brush))
}

/** Three dots that rise in turn: the agent is busy. */
@Composable
internal fun TypingDots(color: Color, modifier: Modifier = Modifier, size: Dp = 6.dp) {
    val transition = rememberInfiniteTransition(label = "typing")
    val phase by
        transition.animateFloat(
            0f,
            1f,
            infiniteRepeatable(tween(1100, easing = LinearEasing)),
            label = "typing-phase",
        )
    Canvas(modifier.size(width = size * 5, height = size * 2.2f)) {
        val radius = size.toPx() / 2
        val gap = size.toPx() * 2
        val baseline = this.size.height - radius
        for (index in 0 until 3) {
            // Each dot's bounce, offset by a third of the cycle.
            val t = ((phase - index * .18f) % 1f + 1f) % 1f
            val lift = kotlin.math.sin((t.coerceIn(0f, .6f) / .6f) * kotlin.math.PI).toFloat()
            drawCircle(
                color.copy(alpha = color.alpha * (.45f + .55f * lift)),
                radius * (.85f + .25f * lift),
                Offset(radius + index * gap, baseline - lift * size.toPx() * .9f),
            )
        }
    }
}

/** A pulsing ring around content, e.g. a sparkle that marks a turn in progress. */
@Composable
internal fun Pulse(
    color: Color,
    size: Dp,
    modifier: Modifier = Modifier,
    content: @Composable () -> Unit,
) {
    val transition = rememberInfiniteTransition(label = "pulse")
    val t by
        transition.animateFloat(
            0f,
            1f,
            infiniteRepeatable(tween(1400, easing = FastOutSlowInEasing)),
            label = "pulse-t",
        )
    Box(modifier.size(size), contentAlignment = Alignment.Center) {
        Box(
            Modifier.size(size)
                .graphicsLayer {
                    val s = .7f + .5f * t
                    scaleX = s
                    scaleY = s
                    this.alpha = (1f - t) * .35f
                }
                .then(Modifier.drawWithCache { onDrawBehind { drawCircle(color) } })
        )
        content()
    }
}

/** [CircleShape] re-exported for callers of [workingGlow] that want a pill. */
internal val PillShape: Shape = CircleShape

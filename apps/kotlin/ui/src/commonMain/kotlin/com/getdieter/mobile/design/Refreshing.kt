package com.getdieter.mobile.design

import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.StartOffset
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.CompositingStrategy
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.rotate
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

/** One sweep of the refresh shimmer across a row. */
private const val SweepMillis = 1500

/** How far behind its predecessor each row in a list starts its sweep, so it travels downwards. */
private const val WaveStepMillis = 90

/** Rows after this many restart the wave, so a long list never waits seconds for its sweep. */
private const val WaveLength = 8

/**
 * A soft highlight sweeping across what this draws while [active]: what shows is a cached state
 * that is being brought up to date ([com.getdieter.client.v1.ActivityRow.refreshing]). Only the
 * drawn pixels (text, glyphs) catch the light. A row of a list passes its position as [wave], so
 * the sweep runs down the list. It fades in and out instead of snapping when refreshing ends.
 */
@Composable
internal fun Modifier.refreshShimmer(active: Boolean, highlight: Color, wave: Int = 0): Modifier {
    val strength by
        animateFloatAsState(
            if (active) 1f else 0f,
            tween(if (active) 240 else 520),
            label = "refresh-shimmer",
        )
    if (strength == 0f) return this
    val phase by
        rememberInfiniteTransition(label = "refresh-shimmer")
            .animateFloat(
                0f,
                1f,
                infiniteRepeatable(
                    tween(SweepMillis, easing = FastOutSlowInEasing),
                    initialStartOffset = StartOffset((wave % WaveLength) * WaveStepMillis),
                ),
                label = "refresh-shimmer-phase",
            )
    return shimmerBand(phase, strength, highlight)
}

/**
 * One frame of [refreshShimmer]: a band of [highlight] centred [phase] of the way across (0 enters
 * from the left, 1 leaves on the right), at [strength], tinting only the pixels this draws.
 */
internal fun Modifier.shimmerBand(phase: Float, strength: Float, highlight: Color): Modifier =
    graphicsLayer {
        compositingStrategy = CompositingStrategy.Offscreen
    }
    .drawWithContent {
        drawContent()
        val band = size.width * .28f
        val center = -band + (size.width + band * 2) * phase
        drawRect(
            Brush.horizontalGradient(
                0f to Color.Transparent,
                .5f to highlight.copy(alpha = highlight.alpha * strength),
                1f to Color.Transparent,
                startX = center - band,
                endX = center + band,
            ),
            blendMode = BlendMode.SrcAtop,
        )
    }

/**
 * A small arc chasing its own fading tail: this row's machine is being asked for its current state.
 * Sized to sit beside a row's time; says "Refreshing" to accessibility services.
 */
@Composable
internal fun RefreshingMark(tint: Color, modifier: Modifier = Modifier, size: Dp = 12.dp) {
    val turn by
        rememberInfiniteTransition(label = "refreshing-mark")
            .animateFloat(
                0f,
                360f,
                infiniteRepeatable(tween(900, easing = LinearEasing)),
                label = "refreshing-mark-turn",
            )
    val appear by animateFloatAsState(1f, tween(240), label = "refreshing-mark-appear")
    Canvas(modifier.size(size).alpha(appear).semantics { contentDescription = "Refreshing" }) {
        val width = 1.6.dp.toPx()
        val inset = width / 2
        val box = Size(this.size.width - width, this.size.height - width)
        drawArc(
            tint.copy(alpha = .18f),
            0f,
            360f,
            false,
            Offset(inset, inset),
            box,
            style = Stroke(width),
        )
        rotate(turn) {
            drawArc(
                Brush.sweepGradient(0f to Color.Transparent, .75f to tint, 1f to tint),
                0f,
                270f,
                false,
                Offset(inset, inset),
                box,
                style = Stroke(width, cap = StrokeCap.Round),
            )
        }
    }
}

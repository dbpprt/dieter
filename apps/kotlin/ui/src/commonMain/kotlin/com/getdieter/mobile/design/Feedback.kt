@file:OptIn(
    androidx.compose.material3.ExperimentalMaterial3Api::class,
    androidx.compose.foundation.ExperimentalFoundationApi::class,
    androidx.compose.foundation.layout.ExperimentalLayoutApi::class,
)

package com.getdieter.mobile.design

import androidx.compose.animation.*
import androidx.compose.animation.core.*
import androidx.compose.animation.core.tween
import androidx.compose.foundation.*
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.draw.scale
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.sin
import kotlin.time.Clock
import kotlin.time.Instant
import kotlinx.coroutines.delay

/** UIActivityIndicatorView-style spokes on iOS; a Material indeterminate indicator on Android. */
@Composable
internal fun Spinner(modifier: Modifier = Modifier.size(20.dp), color: Color = Color.Unspecified) {
    if (!apple) {
        CircularProgressIndicator(
            modifier,
            strokeWidth = 2.5.dp,
            color = if (color == Color.Unspecified) colors.primary else color,
        )
        return
    }
    val tint = if (color == Color.Unspecified) palette.secondaryLabel else color
    val transition = rememberInfiniteTransition()
    val step by
        transition.animateFloat(0f, 8f, infiniteRepeatable(tween(800, easing = LinearEasing)))
    Canvas(modifier) {
        val spokes = 8
        val radius = size.minDimension / 2
        val width = radius * .26f
        val head = step.toInt() % spokes
        for (index in 0 until spokes) {
            val angle = (index * 2 * PI / spokes) - PI / 2
            val age = (head - index + spokes) % spokes
            val alpha = 1f - age * .1f
            val start =
                Offset(
                    center.x + cos(angle).toFloat() * radius * .48f,
                    center.y + sin(angle).toFloat() * radius * .48f,
                )
            val end =
                Offset(
                    center.x + cos(angle).toFloat() * (radius - width / 2),
                    center.y + sin(angle).toFloat() * (radius - width / 2),
                )
            drawLine(
                tint.copy(alpha = tint.alpha * alpha.coerceIn(.2f, 1f)),
                start,
                end,
                width,
                androidx.compose.ui.graphics.StrokeCap.Round,
            )
        }
    }
}

/** A pulsing dot for live activity. */
@Composable
internal fun LiveDot(color: Color, modifier: Modifier = Modifier, size: Dp = 8.dp) {
    val transition = rememberInfiniteTransition()
    val pulse by
        transition.animateFloat(
            .35f,
            1f,
            infiniteRepeatable(tween(900, easing = FastOutSlowInEasing), RepeatMode.Reverse),
        )
    Box(modifier.size(size), contentAlignment = Alignment.Center) {
        Box(
            Modifier.size(size)
                .scale(.6f + pulse * .6f)
                .background(color.copy(alpha = .25f * pulse), CircleShape)
        )
        Box(Modifier.size(size * .75f).background(color, CircleShape))
    }
}

/** ContentUnavailableView on iOS; Material empty state on Android. */
@Composable
internal fun EmptyState(
    glyph: Glyph,
    title: String,
    message: String,
    modifier: Modifier = Modifier,
    action: (@Composable () -> Unit)? = null,
) {
    Column(
        modifier.fillMaxWidth().padding(horizontal = 32.dp, vertical = 40.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        if (apple)
            Icon(
                glyph,
                null,
                tint = palette.secondaryLabel,
                size = 46.dp,
                weight = GlyphWeight.REGULAR,
            )
        else
            Box(
                Modifier.size(72.dp).background(colors.secondaryContainer, CircleShape),
                contentAlignment = Alignment.Center,
            ) {
                Icon(glyph, null, tint = colors.onSecondaryContainer, size = 32.dp)
            }
        Spacer(Modifier.height(if (apple) 14.dp else 20.dp))
        Text(
            title,
            style = if (apple) type.title2 else type.title3,
            color = palette.label,
            textAlign = TextAlign.Center,
        )
        Spacer(Modifier.height(6.dp))
        Text(
            message,
            style = if (apple) type.body else type.subheadline,
            color = palette.secondaryLabel,
            textAlign = TextAlign.Center,
        )
        if (action != null) {
            Spacer(Modifier.height(18.dp))
            action()
        }
    }
}

internal enum class Tone {
    NEUTRAL,
    WARNING,
    DANGER,
    SUCCESS,
}

/** Inline notice for connection state, failures and recoverable errors. */
@Composable
internal fun Banner(
    title: String,
    message: String,
    modifier: Modifier = Modifier,
    tone: Tone = Tone.NEUTRAL,
    glyph: Glyph? = null,
    actionLabel: String? = null,
    onAction: (() -> Unit)? = null,
    onDismiss: (() -> Unit)? = null,
) {
    val accent =
        when (tone) {
            Tone.NEUTRAL -> palette.secondaryLabel
            Tone.WARNING -> palette.warning
            Tone.DANGER -> palette.destructive
            Tone.SUCCESS -> palette.success
        }
    val container =
        if (apple) palette.cell
        else
            when (tone) {
                Tone.DANGER -> colors.errorContainer
                Tone.WARNING -> colors.tertiaryContainer
                else -> colors.surfaceContainerHigh
            }
    Row(
        modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(if (apple) 18.dp else 16.dp))
            .background(container)
            .padding(start = 14.dp, end = 6.dp, top = 12.dp, bottom = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(
            glyph
                ?: when (tone) {
                    Tone.DANGER -> Glyph.ERROR
                    Tone.WARNING -> Glyph.WARNING
                    Tone.SUCCESS -> Glyph.TASK_DONE
                    Tone.NEUTRAL -> Glyph.INFO
                },
            null,
            tint = if (!apple && tone == Tone.DANGER) colors.onErrorContainer else accent,
            size = 22.dp,
        )
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            Text(
                title,
                style = type.subheadline.copy(fontWeight = FontWeight.SemiBold),
                color =
                    if (!apple && tone == Tone.DANGER) colors.onErrorContainer else palette.label,
            )
            if (message.isNotEmpty())
                Text(
                    message,
                    style = type.footnote,
                    color =
                        if (!apple && tone == Tone.DANGER) colors.onErrorContainer
                        else palette.secondaryLabel,
                    maxLines = 4,
                    overflow = TextOverflow.Ellipsis,
                )
        }
        if (actionLabel != null && onAction != null)
            DButton(actionLabel, onAction, kind = ButtonKind.PLAIN)
        if (onDismiss != null)
            Box(
                Modifier.size(36.dp)
                    .clickable(remember { MutableInteractionSource() }, null, onClick = onDismiss)
                    .semantics { contentDescription = "Dismiss" },
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    Glyph.CLOSE,
                    null,
                    tint = palette.secondaryLabel,
                    size = 16.dp,
                    weight = GlyphWeight.SEMIBOLD,
                )
            }
    }
}

/** Small capsule with an optional symbol, used for machines, branches and counts. */
@Composable
internal fun MetaPill(
    text: String,
    glyph: Glyph? = null,
    modifier: Modifier = Modifier,
    tint: Color = palette.secondaryLabel,
    container: Color = palette.fill.copy(alpha = palette.fill.alpha * .8f),
    accessibility: String = text,
) {
    Row(
        modifier
            .widthIn(max = 220.dp)
            .clip(RoundedCornerShape(if (apple) 7.dp else 8.dp))
            .background(container)
            .padding(horizontal = 7.dp, vertical = 3.dp)
            .semantics(mergeDescendants = true) { contentDescription = accessibility },
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        if (glyph != null) Icon(glyph, null, tint = tint, size = 12.dp, weight = GlyphWeight.MEDIUM)
        Text(
            text,
            style = type.caption,
            color = tint,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

/** A board label: colored dot and tinted capsule. */
@Composable
internal fun LabelPill(name: String, color: String, modifier: Modifier = Modifier) {
    val tint = labelColor(color)
    Row(
        modifier
            .clip(CircleShape)
            .background(tint.copy(alpha = if (palette.dark) .24f else .14f))
            .padding(horizontal = 8.dp, vertical = 3.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(Modifier.size(6.dp).background(tint, CircleShape))
        Spacer(Modifier.width(5.dp))
        Text(
            name,
            style = type.caption.copy(fontWeight = FontWeight.Medium),
            color = tint.readableOn(palette.cell),
            maxLines = 1,
        )
    }
}

@Composable
@ReadOnlyComposable
internal fun labelColor(value: String): Color = runCatching {
    Color(("FF" + value.removePrefix("#")).toLong(16))
}
    .getOrDefault(palette.accent)

/** Count badge for tabs, menus and rows. */
@Composable
internal fun CountBadge(
    count: Int,
    modifier: Modifier = Modifier,
    color: Color = palette.destructive,
) {
    if (count <= 0) return
    Box(
        modifier
            .heightIn(min = 20.dp)
            .widthIn(min = 20.dp)
            .background(color, CircleShape)
            .padding(horizontal = 6.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            if (count > 99) "99+" else "$count",
            style = type.caption2.copy(fontWeight = FontWeight.SemiBold),
            color = Color.White,
        )
    }
}

/** Rounded project avatar: the project's initial on a stable label color. */
@Composable
internal fun ProjectAvatar(id: String, name: String, size: Dp = 36.dp) {
    val tint = labelColor(com.getdieter.core.admin.Labels.stable(id))
    Box(
        Modifier.size(size).clip(RoundedCornerShape(size * .28f)).background(tint),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            name.trim().take(1).uppercase(),
            style =
                (if (apple) type.headline else type.headline).copy(fontWeight = FontWeight.Bold),
            color = Color.White,
        )
    }
}

/** A content card: grouped-cell surface on iOS, a filled Material card on Android. */
@Composable
internal fun ContentCard(
    modifier: Modifier = Modifier,
    selected: Boolean = false,
    onClick: (() -> Unit)? = null,
    onLongClick: (() -> Unit)? = null,
    contentPadding: PaddingValues = PaddingValues(horizontal = 16.dp, vertical = 14.dp),
    content: @Composable ColumnScope.() -> Unit,
) {
    val shape = RoundedCornerShape(if (apple) 22.dp else 20.dp)
    Column(
        modifier
            .fillMaxWidth()
            .then(
                if (apple && !palette.dark)
                    Modifier.shadow(
                        if (selected) 0.dp else .5.dp,
                        shape,
                        ambientColor = Color.Black.copy(.06f),
                        spotColor = Color.Black.copy(.1f),
                    )
                else Modifier
            )
            .clip(shape)
            .background(if (selected) palette.accentContainer else palette.cell)
            .then(
                if (selected && apple)
                    Modifier.border(1.5.dp, palette.accent.copy(alpha = .7f), shape)
                else Modifier
            )
            .then(
                if (onClick != null)
                    Modifier.pressable(
                        onClick = onClick,
                        onLongClick = onLongClick,
                        highlight = !apple,
                        scaleOnPress = apple,
                    )
                else Modifier
            )
            .padding(contentPadding),
        content = content,
    )
}

/** A thin rounded progress bar. */
@Composable
internal fun ProgressBar(
    fraction: Float,
    modifier: Modifier = Modifier,
    color: Color = palette.accent,
    track: Color = palette.fill,
) {
    Canvas(modifier.fillMaxWidth().height(6.dp)) {
        val radius = CornerRadius(size.height / 2, size.height / 2)
        drawRoundRect(track, cornerRadius = radius)
        drawRoundRect(
            color,
            size = Size(size.width * fraction.coerceIn(0f, 1f), size.height),
            cornerRadius = radius,
        )
    }
}

/** Divider matching the platform list separator. */
@Composable
internal fun Hairline(modifier: Modifier = Modifier, inset: Dp = 0.dp) {
    val height = with(LocalDensity.current) { 1f / density }.dp
    Box(
        modifier
            .fillMaxWidth()
            .padding(start = inset)
            .height(if (apple) height else 1.dp)
            .background(palette.separator)
    )
}

/** Rotating chevron for disclosure rows. */
@Composable
internal fun DisclosureChevron(expanded: Boolean, tint: Color = palette.secondaryLabel) {
    val angle by animateFloatAsState(if (expanded) 90f else 0f)
    Icon(
        Glyph.CHEVRON_RIGHT,
        if (expanded) "Collapse" else "Expand",
        Modifier.rotate(angle),
        tint = tint,
        size = 13.dp,
        weight = GlyphWeight.SEMIBOLD,
    )
}

@Composable
internal fun Placeholder(text: String) {
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        Text(
            text,
            style = type.body.copy(fontWeight = FontWeight.Medium),
            color = palette.secondaryLabel,
        )
    }
}

@Composable
internal fun rememberNow(): Instant {
    var now by remember { mutableStateOf(Clock.System.now()) }
    LaunchedEffect(Unit) {
        while (true) {
            delay(30_000)
            now = Clock.System.now()
        }
    }
    return now
}

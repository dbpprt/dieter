@file:OptIn(
    androidx.compose.material3.ExperimentalMaterial3Api::class,
    androidx.compose.foundation.ExperimentalFoundationApi::class,
    androidx.compose.foundation.layout.ExperimentalLayoutApi::class,
)

package com.getdieter.mobile.design

import androidx.compose.animation.core.*
import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

/** Where an item sits in a grouped section; decides corners, separators and Android gaps. */
internal enum class Position {
    SINGLE,
    FIRST,
    MIDDLE,
    LAST;

    val isFirst
        get() = this == SINGLE || this == FIRST

    val isLast
        get() = this == SINGLE || this == LAST

    companion object {
        fun of(index: Int, count: Int) =
            when {
                count <= 1 -> SINGLE
                index == 0 -> FIRST
                index == count - 1 -> LAST
                else -> MIDDLE
            }
    }
}

internal val ScreenMargin = 16.dp

@Composable
@ReadOnlyComposable
internal fun groupShape(position: Position): Shape {
    val outer = if (apple) 24.dp else 22.dp
    val inner = if (apple) 0.dp else 5.dp
    return RoundedCornerShape(
        topStart = if (position.isFirst) outer else inner,
        topEnd = if (position.isFirst) outer else inner,
        bottomStart = if (position.isLast) outer else inner,
        bottomEnd = if (position.isLast) outer else inner,
    )
}

/**
 * One segment of a grouped section. iOS draws an inset-grouped list with hairline separators;
 * Android draws the Material 3 segmented list used by system Settings, with small gaps.
 */
@Composable
internal fun GroupItem(
    position: Position,
    modifier: Modifier = Modifier,
    separatorInset: Dp = 16.dp,
    onClick: (() -> Unit)? = null,
    onLongClick: (() -> Unit)? = null,
    enabled: Boolean = true,
    selected: Boolean = false,
    content: @Composable () -> Unit,
) {
    val shape = groupShape(position)
    val separator = palette.separator
    val hairline = with(LocalDensity.current) { 1f / density }.dp
    val iOS = apple
    Box(
        modifier
            .fillMaxWidth()
            .padding(horizontal = ScreenMargin)
            .padding(top = if (!iOS && !position.isFirst) 2.dp else 0.dp)
            .clip(shape)
            .background(if (selected) palette.accentContainer else palette.cell)
            .then(
                if (onClick != null || onLongClick != null)
                    Modifier.pressable(
                        enabled = enabled,
                        onClick = onClick ?: {},
                        onLongClick = onLongClick,
                        highlight = true,
                    )
                else Modifier
            )
            .drawBehind {
                if (iOS && !position.isFirst)
                    drawRect(
                        separator,
                        topLeft = Offset(separatorInset.toPx(), 0f),
                        size = Size(size.width - separatorInset.toPx(), hairline.toPx()),
                    )
            }
    ) {
        content()
    }
}

/** A grouped section from a fixed list of rows. */
@Composable
internal fun <T> Group(
    items: List<T>,
    modifier: Modifier = Modifier,
    separatorInset: Dp = 16.dp,
    row: @Composable (item: T, position: Position) -> Unit,
) {
    Column(modifier) {
        items.forEachIndexed { index, item -> row(item, Position.of(index, items.size)) }
    }
}

/**
 * Section title. iOS uses uppercase footnote headers for forms and bold title headers for content;
 * Android uses the Material primary-colored label style.
 */
@Composable
internal fun SectionHeader(
    text: String,
    modifier: Modifier = Modifier,
    prominent: Boolean = false,
    trailing: (@Composable () -> Unit)? = null,
) {
    Row(
        modifier
            .fillMaxWidth()
            .padding(
                start = ScreenMargin + if (apple && !prominent) 16.dp else 4.dp,
                end = ScreenMargin + 4.dp,
                top = if (prominent) 20.dp else 18.dp,
                bottom = if (prominent) 8.dp else 7.dp,
            )
            .semantics(mergeDescendants = true) {},
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            when {
                apple && !prominent -> text.uppercase()
                else -> text
            },
            Modifier.weight(1f),
            style =
                when {
                    apple && prominent -> type.title3.copy(fontWeight = FontWeight.Bold)
                    apple -> type.footnote
                    prominent -> type.title3
                    else -> MaterialTheme.typography.labelLarge
                },
            color =
                when {
                    prominent -> palette.label
                    apple -> palette.secondaryLabel
                    else -> colors.primary
                },
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
        trailing?.invoke()
    }
}

@Composable
internal fun SectionFooter(text: String, modifier: Modifier = Modifier) {
    Text(
        text,
        modifier
            .fillMaxWidth()
            .padding(start = ScreenMargin + 16.dp, end = ScreenMargin + 16.dp, top = 7.dp),
        style = type.footnote,
        color = palette.secondaryLabel,
    )
}

internal enum class Accessory {
    NONE,
    CHEVRON,
    CHECK,
}

/** A standard list row inside a grouped section. */
@Composable
internal fun ListRow(
    title: String,
    modifier: Modifier = Modifier,
    position: Position = Position.SINGLE,
    subtitle: String? = null,
    value: String? = null,
    glyph: Glyph? = null,
    tile: Color? = null,
    glyphTint: Color? = null,
    accessory: Accessory = Accessory.NONE,
    destructive: Boolean = false,
    enabled: Boolean = true,
    selected: Boolean = false,
    titleMaxLines: Int = 1,
    subtitleMaxLines: Int = 2,
    onClick: (() -> Unit)? = null,
    onLongClick: (() -> Unit)? = null,
    leading: (@Composable () -> Unit)? = null,
    trailing: (@Composable () -> Unit)? = null,
) {
    val iOS = apple
    val leadingWidth =
        when {
            leading != null -> 40.dp
            tile != null -> 30.dp
            glyph != null -> if (iOS) 28.dp else 24.dp
            else -> 0.dp
        }
    val inset =
        if (leadingWidth > 0.dp) 16.dp + leadingWidth + (if (iOS) 14.dp else 16.dp) else 16.dp
    GroupItem(
        position,
        modifier,
        separatorInset = inset,
        onClick = onClick,
        onLongClick = onLongClick,
        enabled = enabled,
        selected = selected,
    ) {
        Row(
            Modifier.fillMaxWidth()
                .heightIn(
                    min =
                        if (iOS) (if (subtitle != null) 58.dp else 46.dp)
                        else (if (subtitle != null) 68.dp else 56.dp)
                )
                .padding(horizontal = 16.dp, vertical = if (iOS) 9.dp else 10.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            when {
                leading != null -> {
                    Box(Modifier.width(leadingWidth), contentAlignment = Alignment.Center) {
                        leading()
                    }
                    Spacer(Modifier.width(if (iOS) 14.dp else 16.dp))
                }
                tile != null && glyph != null -> {
                    IconTile(glyph, tile)
                    Spacer(Modifier.width(if (iOS) 14.dp else 16.dp))
                }
                glyph != null -> {
                    Icon(
                        glyph,
                        null,
                        Modifier.width(leadingWidth),
                        tint =
                            glyphTint
                                ?: if (destructive) palette.destructive
                                else if (iOS) palette.accent else palette.secondaryLabel,
                        size = if (iOS) 22.dp else 24.dp,
                    )
                    Spacer(Modifier.width(if (iOS) 14.dp else 16.dp))
                }
            }
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(1.dp)) {
                Text(
                    title,
                    style = type.body,
                    color =
                        when {
                            !enabled -> palette.tertiaryLabel
                            destructive -> palette.destructive
                            else -> palette.label
                        },
                    maxLines = titleMaxLines,
                    overflow = TextOverflow.Ellipsis,
                )
                if (!subtitle.isNullOrEmpty())
                    Text(
                        subtitle,
                        style = if (iOS) type.subheadline else type.subheadline,
                        color = palette.secondaryLabel,
                        maxLines = subtitleMaxLines,
                        overflow = TextOverflow.Ellipsis,
                    )
            }
            if (!value.isNullOrEmpty())
                Text(
                    value,
                    Modifier.padding(start = 10.dp).widthIn(max = 200.dp),
                    style = type.body,
                    color = palette.secondaryLabel,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            if (trailing != null) {
                Spacer(Modifier.width(10.dp))
                trailing()
            }
            when (accessory) {
                Accessory.CHEVRON ->
                    if (iOS)
                        Icon(
                            Glyph.CHEVRON_RIGHT,
                            null,
                            Modifier.padding(start = 8.dp),
                            tint = palette.tertiaryLabel,
                            size = 14.dp,
                            weight = GlyphWeight.SEMIBOLD,
                        )
                Accessory.CHECK ->
                    Icon(
                        Glyph.CHECK,
                        "Selected",
                        Modifier.padding(start = 8.dp),
                        tint = palette.accent,
                        size = if (iOS) 18.dp else 22.dp,
                        weight = GlyphWeight.SEMIBOLD,
                    )
                Accessory.NONE -> Unit
            }
        }
    }
}

/** Settings-style colored symbol tile on iOS; a tonal circle on Android. */
@Composable
internal fun IconTile(glyph: Glyph, color: Color, size: Dp = 30.dp) {
    if (apple)
        Box(
            Modifier.size(size).clip(RoundedCornerShape(size * .26f)).background(color),
            contentAlignment = Alignment.Center,
        ) {
            Icon(glyph, null, tint = Color.White, size = size * .62f, weight = GlyphWeight.MEDIUM)
        }
    else {
        val container =
            androidx.compose.ui.graphics.lerp(palette.cell, color, if (palette.dark) .3f else .16f)
        Box(
            Modifier.size(size + 10.dp).clip(CircleShape).background(container),
            contentAlignment = Alignment.Center,
        ) {
            Icon(glyph, null, tint = color.readableOn(container), size = 22.dp)
        }
    }
}

/** Darkens or lightens a hue until it is readable on [background]. */
internal fun Color.readableOn(background: Color): Color {
    val darkBackground = background.luminance() < .4f
    var value = this
    repeat(6) {
        val contrast =
            (maxOf(value.luminance(), background.luminance()) + .05f) /
                (minOf(value.luminance(), background.luminance()) + .05f)
        if (contrast >= 3.2f) return value
        value =
            androidx.compose.ui.graphics.lerp(
                value,
                if (darkBackground) Color.White else Color.Black,
                .2f,
            )
    }
    return value
}

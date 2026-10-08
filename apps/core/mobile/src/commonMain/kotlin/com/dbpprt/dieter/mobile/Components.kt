@file:OptIn(
    androidx.compose.material3.ExperimentalMaterial3Api::class,
    androidx.compose.foundation.ExperimentalFoundationApi::class,
    androidx.compose.foundation.layout.ExperimentalLayoutApi::class,
)

package com.dbpprt.dieter.mobile

import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.*
import androidx.compose.foundation.*
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.draw.scale
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.sin

// ---------------------------------------------------------------------------------------------
// Grouped sections
// ---------------------------------------------------------------------------------------------

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

// ---------------------------------------------------------------------------------------------
// Interaction
// ---------------------------------------------------------------------------------------------

/**
 * Platform press feedback: iOS highlights rows (or dims buttons) without ripples; Android uses the
 * Material ripple.
 */
@Composable
internal fun Modifier.pressable(
    enabled: Boolean = true,
    onClick: () -> Unit,
    onLongClick: (() -> Unit)? = null,
    highlight: Boolean = false,
    scaleOnPress: Boolean = false,
    role: Role? = Role.Button,
): Modifier {
    val interaction = remember { MutableInteractionSource() }
    if (!apple)
        return this.combinedClickable(
            interactionSource = interaction,
            indication = ripple(),
            enabled = enabled,
            role = role,
            onLongClick = onLongClick,
            onClick = onClick,
        )
    val pressed by interaction.collectIsPressedAsState()
    val fill = palette.label.copy(alpha = if (palette.dark) .14f else .08f)
    val scale by
        animateFloatAsState(if (pressed && scaleOnPress) .97f else 1f, spring(stiffness = 900f))
    return this.then(if (scaleOnPress) Modifier.scale(scale) else Modifier)
        .drawBehind { if (pressed && highlight) drawRect(fill) }
        .combinedClickable(
            interactionSource = interaction,
            indication = null,
            enabled = enabled,
            role = role,
            onLongClick = onLongClick,
            onClick = onClick,
        )
}

// ---------------------------------------------------------------------------------------------
// Buttons
// ---------------------------------------------------------------------------------------------

internal enum class ButtonKind {
    PROMINENT,
    TONAL,
    PLAIN,
    DESTRUCTIVE,
}

@Composable
internal fun DButton(
    text: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    kind: ButtonKind = ButtonKind.PROMINENT,
    glyph: Glyph? = null,
    enabled: Boolean = true,
    large: Boolean = false,
    loading: Boolean = false,
) {
    if (apple) {
        val interaction = remember { MutableInteractionSource() }
        val pressed by interaction.collectIsPressedAsState()
        val container =
            when (kind) {
                ButtonKind.PROMINENT -> palette.accent
                ButtonKind.TONAL -> palette.fill
                ButtonKind.PLAIN -> Color.Transparent
                ButtonKind.DESTRUCTIVE -> palette.destructive.copy(alpha = .14f)
            }
        val content =
            when (kind) {
                ButtonKind.PROMINENT -> palette.onAccent
                ButtonKind.TONAL -> palette.label
                ButtonKind.PLAIN -> palette.accent
                ButtonKind.DESTRUCTIVE -> palette.destructive
            }
        Row(
            modifier
                .clip(CircleShape)
                .background(
                    if (enabled) container else container.copy(alpha = container.alpha * .45f)
                )
                .graphicsAlpha(if (pressed) .7f else if (enabled) 1f else .5f)
                .clickable(
                    interactionSource = interaction,
                    indication = null,
                    enabled = enabled && !loading,
                    role = Role.Button,
                    onClick = onClick,
                )
                .heightIn(min = if (large) 50.dp else 36.dp)
                .padding(
                    horizontal = if (kind == ButtonKind.PLAIN) 8.dp else if (large) 22.dp else 15.dp
                ),
            horizontalArrangement = Arrangement.Center,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            if (loading) {
                Spinner(Modifier.size(18.dp), color = content)
                Spacer(Modifier.width(8.dp))
            } else if (glyph != null) {
                Icon(
                    glyph,
                    null,
                    tint = content,
                    size = if (large) 20.dp else 17.dp,
                    weight = GlyphWeight.SEMIBOLD,
                )
                Spacer(Modifier.width(6.dp))
            }
            Text(
                text,
                style =
                    if (large) type.headline
                    else type.subheadline.copy(fontWeight = FontWeight.SemiBold),
                color = content,
                maxLines = 1,
            )
        }
        return
    }
    val inner: @Composable RowScope.() -> Unit = {
        if (loading) {
            CircularProgressIndicator(
                Modifier.size(18.dp),
                strokeWidth = 2.dp,
                color = LocalContentColor.current,
            )
            Spacer(Modifier.width(8.dp))
        } else if (glyph != null) {
            Icon(glyph, null, size = 18.dp)
            Spacer(Modifier.width(8.dp))
        }
        Text(text, maxLines = 1)
    }
    val height = Modifier.heightIn(min = if (large) 56.dp else 40.dp)
    when (kind) {
        ButtonKind.PROMINENT ->
            Button(onClick, modifier.then(height), enabled = enabled && !loading, content = inner)
        ButtonKind.TONAL ->
            FilledTonalButton(
                onClick,
                modifier.then(height),
                enabled = enabled && !loading,
                content = inner,
            )
        ButtonKind.PLAIN ->
            TextButton(onClick, modifier, enabled = enabled && !loading, content = inner)
        ButtonKind.DESTRUCTIVE ->
            Button(
                onClick,
                modifier.then(height),
                enabled = enabled && !loading,
                colors =
                    ButtonDefaults.buttonColors(
                        containerColor = colors.errorContainer,
                        contentColor = colors.onErrorContainer,
                    ),
                content = inner,
            )
    }
}

internal fun Modifier.graphicsAlpha(alpha: Float) = this.graphicsLayer { this.alpha = alpha }

/** Round icon button: iOS glass-like fill, Android standard or tonal icon button. */
@Composable
internal fun CircleButton(
    glyph: Glyph,
    contentDescription: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    prominent: Boolean = false,
    enabled: Boolean = true,
    size: Dp = if (apple) 36.dp else 40.dp,
    tint: Color? = null,
) {
    if (apple) {
        val interaction = remember { MutableInteractionSource() }
        val pressed by interaction.collectIsPressedAsState()
        Box(
            modifier
                .size(size)
                .clip(CircleShape)
                .background(
                    when {
                        prominent && enabled -> palette.accent
                        prominent -> palette.fill
                        else -> palette.fill
                    }
                )
                .clickable(
                    interactionSource = interaction,
                    indication = null,
                    enabled = enabled,
                    role = Role.Button,
                    onClick = onClick,
                )
                .semantics { this.contentDescription = contentDescription }
                .graphicsAlpha(if (pressed) .6f else 1f),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                glyph,
                null,
                tint =
                    tint
                        ?: when {
                            prominent && enabled -> palette.onAccent
                            !enabled -> palette.tertiaryLabel
                            else -> palette.label
                        },
                size = size * .5f,
                weight = GlyphWeight.SEMIBOLD,
            )
        }
    } else if (prominent)
        FilledIconButton(onClick, modifier.size(size), enabled = enabled) {
            Icon(glyph, contentDescription, size = 22.dp)
        }
    else
        IconButton(onClick, modifier.size(size + 8.dp), enabled = enabled) {
            Icon(glyph, contentDescription, tint = tint ?: LocalContentColor.current, size = 24.dp)
        }
}

// ---------------------------------------------------------------------------------------------
// Controls
// ---------------------------------------------------------------------------------------------

@Composable
internal fun DSwitch(
    checked: Boolean,
    onCheckedChange: ((Boolean) -> Unit)?,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
) {
    if (!apple) {
        Switch(checked, onCheckedChange, modifier, enabled = enabled)
        return
    }
    val track by
        animateColorAsState(
            when {
                checked -> palette.success
                palette.dark -> Color(0xFF39393D)
                else -> Color(0xFFE9E9EA)
            },
            tween(220),
        )
    val offset by
        animateDpAsState(
            if (checked) 20.dp else 0.dp,
            spring(dampingRatio = .72f, stiffness = 700f),
        )
    Box(
        modifier
            .size(51.dp, 31.dp)
            .graphicsAlpha(if (enabled) 1f else .45f)
            .clip(CircleShape)
            .background(track)
            .then(
                if (onCheckedChange != null)
                    Modifier.clickable(
                        remember { MutableInteractionSource() },
                        null,
                        enabled = enabled,
                        role = Role.Switch,
                    ) {
                        onCheckedChange(!checked)
                    }
                else Modifier
            )
            .padding(2.dp)
    ) {
        Box(
            Modifier.offset(x = offset)
                .size(27.dp)
                .shadow(
                    3.dp,
                    CircleShape,
                    ambientColor = Color.Black.copy(.2f),
                    spotColor = Color.Black.copy(.2f),
                )
                .background(Color.White, CircleShape)
        )
    }
}

/** iOS segmented control or Material 3 segmented buttons. */
@Composable
internal fun Segmented(
    options: List<String>,
    selected: Int,
    onSelect: (Int) -> Unit,
    modifier: Modifier = Modifier,
    testTagPrefix: String = "segment",
) {
    if (!apple) {
        SingleChoiceSegmentedButtonRow(modifier.fillMaxWidth()) {
            options.forEachIndexed { index, label ->
                SegmentedButton(
                    selected = index == selected,
                    onClick = { onSelect(index) },
                    shape = SegmentedButtonDefaults.itemShape(index, options.size),
                    modifier = Modifier.testTag("$testTagPrefix-$index"),
                    icon = {},
                    label = { Text(label, maxLines = 1, overflow = TextOverflow.Ellipsis) },
                )
            }
        }
        return
    }
    BoxWithConstraints(
        modifier
            .fillMaxWidth()
            .height(36.dp)
            .clip(CircleShape)
            .background(palette.fill)
            .padding(2.dp)
    ) {
        val count = options.size.coerceAtLeast(1)
        val width = maxWidth / count
        val thumb by
            animateDpAsState(
                width * selected.coerceIn(0, count - 1),
                spring(stiffness = 600f, dampingRatio = .85f),
            )
        Box(
            Modifier.offset(x = thumb)
                .width(width)
                .fillMaxHeight()
                .shadow(
                    2.dp,
                    CircleShape,
                    ambientColor = Color.Black.copy(.12f),
                    spotColor = Color.Black.copy(.12f),
                )
                .background(if (palette.dark) Color(0xFF636366) else Color.White, CircleShape)
        )
        Row(Modifier.fillMaxSize()) {
            options.forEachIndexed { index, label ->
                Box(
                    Modifier.weight(1f)
                        .fillMaxHeight()
                        .clickable(remember { MutableInteractionSource() }, null, role = Role.Tab) {
                            onSelect(index)
                        }
                        .testTag("$testTagPrefix-$index")
                        .semantics { contentDescription = label },
                    contentAlignment = Alignment.Center,
                ) {
                    Text(
                        label,
                        style =
                            type.footnote.copy(
                                fontWeight =
                                    if (index == selected) FontWeight.SemiBold
                                    else FontWeight.Medium
                            ),
                        color = palette.label,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.padding(horizontal = 6.dp),
                    )
                }
            }
        }
    }
}

/** Horizontally scrolling filter capsules (iOS) or Material filter chips. */
@Composable
internal fun FilterPill(
    text: String,
    selected: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    dot: Color? = null,
    glyph: Glyph? = null,
    trailingChevron: Boolean = false,
) {
    if (!apple) {
        FilterChip(
            selected,
            onClick,
            label = { Text(text, maxLines = 1) },
            modifier = modifier,
            leadingIcon =
                when {
                    dot != null -> {
                        { Box(Modifier.size(8.dp).background(dot, CircleShape)) }
                    }
                    glyph != null -> {
                        { Icon(glyph, null, size = 18.dp) }
                    }
                    selected -> {
                        { Icon(Glyph.CHECK, null, size = 18.dp) }
                    }
                    else -> null
                },
            trailingIcon =
                if (trailingChevron) {
                    { Icon(Glyph.CHEVRON_DOWN, null, size = 18.dp) }
                } else null,
            shape = RoundedCornerShape(10.dp),
        )
        return
    }
    Row(
        modifier
            .height(34.dp)
            .clip(CircleShape)
            .background(if (selected) palette.label else palette.cell)
            .then(
                if (!selected)
                    Modifier.border(.5.dp, palette.separator.copy(alpha = .5f), CircleShape)
                else Modifier
            )
            .pressable(onClick = onClick)
            .padding(horizontal = 13.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        val content =
            if (selected) palette.background.let { if (palette.dark) Color.Black else Color.White }
            else palette.label
        if (dot != null) Box(Modifier.size(8.dp).background(dot, CircleShape))
        if (glyph != null)
            Icon(glyph, null, tint = content, size = 15.dp, weight = GlyphWeight.MEDIUM)
        Text(
            text,
            style = type.subheadline.copy(fontWeight = FontWeight.Medium),
            color = content,
            maxLines = 1,
        )
        if (trailingChevron)
            Icon(Glyph.CHEVRON_DOWN, null, tint = content, size = 11.dp, weight = GlyphWeight.BOLD)
    }
}

// ---------------------------------------------------------------------------------------------
// Text input
// ---------------------------------------------------------------------------------------------

@Composable
internal fun SearchField(
    value: String,
    onValueChange: (String) -> Unit,
    placeholder: String,
    modifier: Modifier = Modifier,
    testTag: String = "search-field",
) {
    if (!apple) {
        Row(
            modifier
                .fillMaxWidth()
                .height(52.dp)
                .clip(CircleShape)
                .background(colors.surfaceContainerHigh)
                .padding(horizontal = 16.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(Glyph.SEARCH, null, tint = colors.onSurfaceVariant, size = 24.dp)
            Spacer(Modifier.width(14.dp))
            Box(Modifier.weight(1f)) {
                if (value.isEmpty())
                    Text(
                        placeholder,
                        style = MaterialTheme.typography.bodyLarge,
                        color = colors.onSurfaceVariant,
                    )
                BasicTextField(
                    value,
                    onValueChange,
                    Modifier.fillMaxWidth().testTag(testTag),
                    singleLine = true,
                    textStyle = MaterialTheme.typography.bodyLarge.copy(color = colors.onSurface),
                    cursorBrush = SolidColor(colors.primary),
                    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
                )
            }
            if (value.isNotEmpty())
                IconButton({ onValueChange("") }, Modifier.size(36.dp)) {
                    Icon(Glyph.CLOSE, "Clear search", size = 20.dp)
                }
        }
        return
    }
    Row(
        modifier
            .fillMaxWidth()
            .height(40.dp)
            .clip(CircleShape)
            .background(palette.fill)
            .padding(start = 12.dp, end = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(
            Glyph.SEARCH,
            null,
            tint = palette.secondaryLabel,
            size = 17.dp,
            weight = GlyphWeight.MEDIUM,
        )
        Spacer(Modifier.width(7.dp))
        Box(Modifier.weight(1f)) {
            if (value.isEmpty())
                Text(placeholder, style = type.body, color = palette.secondaryLabel, maxLines = 1)
            BasicTextField(
                value,
                onValueChange,
                Modifier.fillMaxWidth().testTag(testTag),
                singleLine = true,
                textStyle = type.body.copy(color = palette.label),
                cursorBrush =
                    SolidColor(
                        palette.accent.takeUnless { it == Color.Black || it == Color.White }
                            ?: palette.info
                    ),
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
            )
        }
        if (value.isNotEmpty())
            Box(
                Modifier.size(28.dp)
                    .clickable(remember { MutableInteractionSource() }, null) { onValueChange("") }
                    .semantics { contentDescription = "Clear search" },
                contentAlignment = Alignment.Center,
            ) {
                Box(
                    Modifier.size(17.dp).background(palette.tertiaryLabel, CircleShape),
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(
                        Glyph.CLOSE,
                        null,
                        tint = palette.cell,
                        size = 9.dp,
                        weight = GlyphWeight.BOLD,
                    )
                }
            }
    }
}

/**
 * Text field with platform styling. iOS uses a filled rounded field (labels become the placeholder,
 * with an optional caption above); Android uses the outlined Material field.
 */
@Composable
internal fun MobileTextField(
    value: String,
    onValueChange: (String) -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    readOnly: Boolean = false,
    textStyle: TextStyle = LocalTextStyle.current,
    label: (@Composable () -> Unit)? = null,
    placeholder: (@Composable () -> Unit)? = null,
    leadingIcon: (@Composable () -> Unit)? = null,
    trailingIcon: (@Composable () -> Unit)? = null,
    supportingText: (@Composable () -> Unit)? = null,
    singleLine: Boolean = false,
    maxLines: Int = if (singleLine) 1 else Int.MAX_VALUE,
    minLines: Int = 1,
    shape: Shape = RoundedCornerShape(12.dp),
    keyboardOptions: KeyboardOptions = KeyboardOptions.Default,
    keyboardActions: KeyboardActions = KeyboardActions.Default,
) {
    if (!apple) {
        OutlinedTextField(
            value,
            onValueChange,
            modifier,
            enabled = enabled,
            readOnly = readOnly,
            textStyle = textStyle,
            label = label,
            placeholder = placeholder,
            leadingIcon = leadingIcon,
            trailingIcon = trailingIcon,
            supportingText = supportingText,
            singleLine = singleLine,
            maxLines = maxLines,
            minLines = minLines,
            shape = RoundedCornerShape(14.dp),
            keyboardOptions = keyboardOptions,
            keyboardActions = keyboardActions,
        )
        return
    }
    Column(modifier) {
        if (label != null && placeholder != null)
            CompositionLocalProvider(
                LocalTextStyle provides type.footnote,
                LocalContentColor provides palette.secondaryLabel,
            ) {
                Box(Modifier.padding(start = 4.dp, bottom = 6.dp)) { label() }
            }
        BasicTextField(
            value,
            onValueChange,
            Modifier.fillMaxWidth(),
            enabled = enabled,
            readOnly = readOnly,
            singleLine = singleLine,
            maxLines = maxLines,
            minLines = minLines,
            textStyle =
                type.body
                    .merge(textStyle.copy(color = palette.label))
                    .copy(color = if (enabled) palette.label else palette.secondaryLabel),
            cursorBrush = SolidColor(palette.info),
            keyboardOptions = keyboardOptions,
            keyboardActions = keyboardActions,
            decorationBox = { inner ->
                Row(
                    Modifier.fillMaxWidth()
                        .clip(RoundedCornerShape(12.dp))
                        .background(palette.fill)
                        .heightIn(min = 44.dp)
                        .padding(horizontal = 14.dp, vertical = 11.dp),
                    verticalAlignment =
                        if (singleLine) Alignment.CenterVertically else Alignment.Top,
                ) {
                    if (leadingIcon != null) {
                        CompositionLocalProvider(
                            LocalContentColor provides palette.secondaryLabel
                        ) {
                            leadingIcon()
                        }
                        Spacer(Modifier.width(8.dp))
                    }
                    Box(Modifier.weight(1f)) {
                        if (value.isEmpty())
                            CompositionLocalProvider(
                                LocalTextStyle provides type.body,
                                LocalContentColor provides palette.secondaryLabel,
                            ) {
                                (placeholder ?: label)?.invoke()
                            }
                        inner()
                    }
                    if (trailingIcon != null) {
                        Spacer(Modifier.width(8.dp))
                        CompositionLocalProvider(
                            LocalContentColor provides palette.secondaryLabel
                        ) {
                            trailingIcon()
                        }
                    }
                }
            },
        )
        if (supportingText != null)
            CompositionLocalProvider(
                LocalTextStyle provides type.footnote,
                LocalContentColor provides palette.secondaryLabel,
            ) {
                Box(Modifier.padding(start = 4.dp, top = 6.dp)) { supportingText() }
            }
    }
}

// ---------------------------------------------------------------------------------------------
// Status and feedback
// ---------------------------------------------------------------------------------------------

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
    val tint = labelColor(com.dbpprt.dieter.core.admin.Labels.stable(id))
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

@file:OptIn(
    androidx.compose.material3.ExperimentalMaterial3Api::class,
    androidx.compose.foundation.ExperimentalFoundationApi::class,
    androidx.compose.foundation.layout.ExperimentalLayoutApi::class,
)

package com.getdieter.mobile.design

import androidx.compose.animation.*
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.*
import androidx.compose.foundation.*
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.scale
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.getdieter.mobile.app.*

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

/** A row showing a value that opens a menu of choices (iOS pop-up button, Android dropdown). */
@Composable
internal fun PickerRow(
    title: String,
    value: String,
    options: List<Pair<String, String>>,
    selected: String,
    enabled: Boolean,
    position: Position,
    glyph: Glyph? = null,
    tag: String = "picker-${title.lowercase().replace(' ', '-')}",
    onSelect: (String) -> Unit,
) {
    val menu = rememberMenuState()
    val focus = LocalFocusManager.current
    var choosing by remember { mutableStateOf(false) }
    val nativeMenu = apple
    if (choosing && !nativeMenu) {
        AlertDialog(
            onDismissRequest = { choosing = false },
            title = { Text(title) },
            text = {
                LazyColumn(
                    Modifier.fillMaxWidth(),
                    state =
                        rememberLazyListState(
                            options.indexOfFirst { it.first == selected }.coerceAtLeast(0)
                        ),
                ) {
                    itemsIndexed(options, key = { _, option -> option.first }) { _, option ->
                        Row(
                            Modifier.fillMaxWidth()
                                .selectable(
                                    selected = option.first == selected,
                                    role = Role.RadioButton,
                                    onClick = {
                                        choosing = false
                                        onSelect(option.first)
                                    },
                                )
                                .padding(vertical = 12.dp)
                                .testTag("$tag-${option.first}"),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            RadioButton(selected = option.first == selected, onClick = null)
                            Text(option.second, Modifier.padding(start = 12.dp), style = type.body)
                        }
                    }
                }
            },
            confirmButton = { TextButton(onClick = { choosing = false }) { Text("Cancel") } },
        )
    }
    MenuAnchor(menu) {
        ListRow(
            title,
            Modifier.testTag(tag),
            position = position,
            glyph = glyph,
            enabled = enabled && options.isNotEmpty(),
            onClick = {
                if (!nativeMenu) choosing = true
                else {
                    // UIKit restores a focused Compose text field when its menu closes.
                    // End that focus before presenting so the keyboard cannot cover choices.
                    focus.clearFocus()
                    menu.show(
                        listOf(
                            MenuSection(
                                options.map { (key, label) ->
                                    ChromeAction(
                                        "$tag-$key",
                                        label,
                                        checked = key == selected,
                                    ) {
                                        onSelect(key)
                                    }
                                }
                            )
                        )
                    )
                }
            },
            trailing = {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        value.ifEmpty { "Choose" },
                        style = type.body,
                        color = palette.secondaryLabel,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.widthIn(max = 190.dp),
                    )
                    Spacer(Modifier.width(4.dp))
                    Icon(
                        if (apple) Glyph.CHEVRON_UP_DOWN else Glyph.CHEVRON_DOWN,
                        null,
                        tint = palette.secondaryLabel,
                        size = if (apple) 13.dp else 20.dp,
                        weight = GlyphWeight.SEMIBOLD,
                    )
                }
            },
        )
    }
}

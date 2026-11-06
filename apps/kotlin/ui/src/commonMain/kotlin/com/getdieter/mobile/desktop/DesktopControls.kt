@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)

package com.getdieter.mobile.desktop

import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.*
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsHoveredAsState
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.input.pointer.*
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.getdieter.mobile.design.*

/** A row or tile that shows hover and selection fills, without ripples, as the Mac does. */
@Composable
internal fun Modifier.desktopClickable(
    onClick: () -> Unit,
    shape: Shape = RoundedCornerShape(DesktopMetrics.rowRadius),
    selected: Boolean = false,
    rest: Color = Color.Transparent,
    hover: Color = tokens.tileHover,
    selectedFill: Color = tokens.tileSelected,
    enabled: Boolean = true,
    onSecondary: (() -> Unit)? = null,
    onDoubleClick: (() -> Unit)? = null,
    role: Role = Role.Button,
): Modifier {
    val interaction = remember { MutableInteractionSource() }
    val hovered by interaction.collectIsHoveredAsState()
    val fill by
        animateColorAsState(
            when {
                selected -> selectedFill
                hovered && enabled -> hover
                else -> rest
            },
            tween(120),
            label = "row-fill",
        )
    return this.clip(shape)
        .background(fill, shape)
        .then(if (onSecondary != null) Modifier.onSecondaryClick(onSecondary) else Modifier)
        .hoverable(interaction, enabled)
        .combinedClickable(
            interactionSource = interaction,
            indication = null,
            enabled = enabled,
            role = role,
            onDoubleClick = onDoubleClick,
            onClick = onClick,
        )
        .semantics { if (selected) this.selected = true }
}

/** Runs [action] on a secondary (right) mouse click, e.g. to open a context menu. */
internal fun Modifier.onSecondaryClick(action: () -> Unit): Modifier =
    pointerInput(action) {
        awaitEachGesture {
            val event = awaitPointerEvent(PointerEventPass.Initial)
            if (event.type == PointerEventType.Press && event.buttons.isSecondaryPressed) {
                event.changes.forEach { it.consume() }
                action()
            }
        }
    }

/** A hover tooltip for pointer users. */
@Composable
internal fun DesktopTooltip(text: String, content: @Composable () -> Unit) {
    if (text.isEmpty()) return content()
    TooltipBox(
        positionProvider = TooltipDefaults.rememberPlainTooltipPositionProvider(6.dp),
        tooltip = {
            PlainTooltip(
                containerColor = if (tokens.dark) Color(0xFF3A3A3C) else Color(0xFF2C2C2E),
                contentColor = Color.White,
            ) {
                Text(text, fontSize = 11.sp)
            }
        },
        state = rememberTooltipState(),
    ) {
        content()
    }
}

/** A 28 dp toolbar button; [active] tints it, as an applied filter does. */
@Composable
internal fun DesktopIconButton(
    glyph: Glyph,
    description: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    active: Boolean = false,
    enabled: Boolean = true,
    size: Dp = 28.dp,
    tint: Color = Color.Unspecified,
    tooltip: String = description,
) {
    DesktopTooltip(tooltip) {
        Box(
            modifier
                .size(size)
                .desktopClickable(
                    onClick,
                    RoundedCornerShape(7.dp),
                    selected = active,
                    hover = if (tokens.dark) Color.White.copy(.09f) else Color.Black.copy(.06f),
                    selectedFill = tokens.action.copy(alpha = .14f),
                    enabled = enabled,
                )
                .semantics { contentDescription = description },
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                glyph,
                null,
                tint =
                    when {
                        !enabled -> tokens.tertiary.copy(alpha = .5f)
                        active -> tokens.action
                        tint != Color.Unspecified -> tint
                        else -> tokens.subtle
                    },
                size = (size.value * .55f).dp,
                weight = GlyphWeight.MEDIUM,
            )
        }
    }
}

/** A capsule button: prominent ones fill with the action blue, as "New Task" on the Mac. */
@Composable
internal fun DesktopCapsule(
    text: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    glyph: Glyph? = null,
    prominent: Boolean = false,
    destructive: Boolean = false,
    enabled: Boolean = true,
    height: Dp = DesktopMetrics.control,
) {
    val shape = RoundedCornerShape(50)
    val content =
        when {
            prominent -> Color.White
            destructive -> tokens.offline
            else -> tokens.text
        }
    Row(
        modifier
            .height(height)
            .then(if (prominent) Modifier.shadow(if (enabled) 1.dp else 0.dp, shape) else Modifier)
            .border(1.dp, if (prominent) Color.White.copy(.18f) else tokens.controlRim, shape)
            .desktopClickable(
                onClick,
                shape,
                rest =
                    if (prominent) tokens.action.copy(alpha = if (enabled) 1f else .45f)
                    else tokens.control,
                hover = if (prominent) tokens.action.copy(alpha = .88f) else tokens.tileHover,
                enabled = enabled,
            )
            .padding(horizontal = if (height < 28.dp) 10.dp else 12.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        glyph?.let {
            Icon(
                it,
                null,
                tint = content.copy(alpha = if (enabled) 1f else .5f),
                size = 13.dp,
                weight = GlyphWeight.SEMIBOLD,
            )
        }
        Text(
            text,
            color = content.copy(alpha = if (enabled) 1f else .5f),
            fontSize = if (height < 28.dp) 11.sp else 12.5.sp,
            fontWeight = if (prominent) FontWeight.SemiBold else FontWeight.Medium,
            maxLines = 1,
        )
    }
}

/** A segmented track: the selected segment gets a raised thumb. */
@Composable
internal fun DesktopSegments(
    items: List<String>,
    selected: Int,
    onSelect: (Int) -> Unit,
    modifier: Modifier = Modifier,
    testTagPrefix: String = "segment",
    height: Dp = DesktopMetrics.segment,
) {
    Row(
        modifier
            .height(height + 6.dp)
            .clip(RoundedCornerShape(9.dp))
            .background(tokens.inset)
            .padding(3.dp),
        horizontalArrangement = Arrangement.spacedBy(2.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        items.forEachIndexed { index, item ->
            val on = index == selected
            Box(
                Modifier.fillMaxHeight()
                    .then(
                        if (on)
                            Modifier.shadow(
                                if (tokens.dark) 0.dp else 1.dp,
                                RoundedCornerShape(7.dp),
                            )
                        else Modifier
                    )
                    .desktopClickable(
                        { onSelect(index) },
                        RoundedCornerShape(7.dp),
                        selected = on,
                        hover = tokens.tileHover,
                        selectedFill = tokens.segmentThumb,
                        role = Role.Tab,
                    )
                    .padding(horizontal = 10.dp)
                    .testTag("$testTagPrefix-$index"),
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    item,
                    color = if (on) tokens.text else tokens.subtle,
                    fontSize = 12.sp,
                    fontWeight = if (on) FontWeight.SemiBold else FontWeight.Medium,
                    maxLines = 1,
                )
            }
        }
    }
}

/** A count capsule: tinted for attention, mail or channels, else quiet. */
@Composable
internal fun DesktopCount(
    count: Int,
    tint: Color? = null,
    label: String = "",
    modifier: Modifier = Modifier,
) {
    if (count <= 0 && label.isEmpty()) return
    val color = tint ?: tokens.subtle
    Box(
        modifier
            .heightIn(min = 17.dp)
            .widthIn(min = 18.dp)
            .background(
                color.copy(alpha = if (tint == null) .12f else .16f),
                RoundedCornerShape(50),
            )
            .padding(horizontal = 5.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            label.ifEmpty { count.toString() },
            color = if (tint == null) tokens.subtle else color,
            fontSize = 10.5.sp,
            fontWeight = FontWeight.SemiBold,
            maxLines = 1,
        )
    }
}

@Composable
internal fun StatusDot(color: Color, modifier: Modifier = Modifier, size: Dp = 7.dp) {
    Box(modifier.size(size).background(color, CircleShape))
}

/** A 28 dp search capsule. */
@Composable
internal fun DesktopSearchField(
    value: String,
    onValueChange: (String) -> Unit,
    placeholder: String,
    modifier: Modifier = Modifier,
    testTag: String = "desktop-search",
    focusRequester: FocusRequester? = null,
    height: Dp = 28.dp,
    onSubmit: () -> Unit = {},
) {
    val shape = RoundedCornerShape(50)
    BasicTextField(
        value,
        onValueChange,
        modifier
            .height(height)
            .then(if (focusRequester != null) Modifier.focusRequester(focusRequester) else Modifier)
            .testTag(testTag),
        singleLine = true,
        textStyle = TextStyle(color = tokens.text, fontSize = 12.5.sp),
        cursorBrush = SolidColor(tokens.action),
        keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
        keyboardActions =
            androidx.compose.foundation.text.KeyboardActions(onSearch = { onSubmit() }),
        decorationBox = { field ->
            Row(
                Modifier.fillMaxSize()
                    .background(tokens.inset, shape)
                    .border(1.dp, tokens.controlRim, shape)
                    .padding(horizontal = 10.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(
                    Glyph.SEARCH,
                    null,
                    tint = tokens.tertiary,
                    size = 13.dp,
                    weight = GlyphWeight.MEDIUM,
                )
                Spacer(Modifier.width(6.dp))
                Box(Modifier.weight(1f)) {
                    if (value.isEmpty())
                        Text(
                            placeholder,
                            color = tokens.tertiary,
                            fontSize = 12.5.sp,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                    field()
                }
                if (value.isNotEmpty())
                    Box(
                        Modifier.size(16.dp)
                            .clip(CircleShape)
                            .clickable { onValueChange("") }
                            .semantics { contentDescription = "Clear search" },
                        contentAlignment = Alignment.Center,
                    ) {
                        Icon(
                            Glyph.CLOSE,
                            null,
                            tint = tokens.tertiary,
                            size = 10.dp,
                            weight = GlyphWeight.BOLD,
                        )
                    }
            }
        },
    )
}

/** A floating L1 panel: radius 16, a 1 dp rim and a soft shadow. */
@Composable
internal fun DesktopPanel(
    modifier: Modifier = Modifier,
    radius: Dp = DesktopMetrics.panelRadius,
    content: @Composable BoxScope.() -> Unit,
) {
    val shape = RoundedCornerShape(radius)
    Box(
        modifier
            .shadow(
                if (tokens.dark) 6.dp else 4.dp,
                shape,
                ambientColor = Color.Black.copy(.2f),
                spotColor = Color.Black.copy(.22f),
            )
            .clip(shape)
            .background(tokens.panel)
            .border(1.dp, tokens.panelRim, shape),
        content = content,
    )
}

/** A sentence-case section heading, 11.5 semibold tertiary, with optional trailing content. */
@Composable
internal fun DesktopSectionHeader(
    title: String,
    modifier: Modifier = Modifier,
    trailing: @Composable RowScope.() -> Unit = {},
) {
    Row(
        modifier.fillMaxWidth().height(24.dp).padding(horizontal = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            title,
            Modifier.weight(1f),
            color = tokens.tertiary,
            fontSize = 11.5.sp,
            fontWeight = FontWeight.SemiBold,
            maxLines = 1,
        )
        trailing()
    }
}

/**
 * The gap between two panes, which drags the one before it: [onDrag] gets the change in dp, [onEnd]
 * runs when the drag ends.
 */
@Composable
internal fun ResizeHandle(
    onDrag: (Float) -> Unit,
    onEnd: () -> Unit,
    modifier: Modifier = Modifier,
    width: Dp = DesktopMetrics.panelGap,
    testTag: String = "resize-handle",
) {
    val density = LocalDensity.current
    val interaction = remember { MutableInteractionSource() }
    val hovered by interaction.collectIsHoveredAsState()
    var dragging by remember { mutableStateOf(false) }
    val drag by rememberUpdatedState(onDrag)
    val end by rememberUpdatedState(onEnd)
    Box(
        modifier
            .width(width)
            .fillMaxHeight()
            .hoverable(interaction)
            .pointerHoverIcon(com.getdieter.mobile.platform.horizontalResizePointer)
            .pointerInput(Unit) {
                detectDragGestures(
                    onDragStart = { dragging = true },
                    onDragEnd = {
                        dragging = false
                        end()
                    },
                    onDragCancel = {
                        dragging = false
                        end()
                    },
                ) { change, amount ->
                    change.consume()
                    drag(with(density) { amount.x.toDp().value })
                }
            }
            .testTag(testTag),
        contentAlignment = Alignment.Center,
    ) {
        if (hovered || dragging)
            Box(
                Modifier.width(3.dp)
                    .height(36.dp)
                    .background(
                        tokens.tertiary.copy(alpha = if (dragging) .6f else .35f),
                        RoundedCornerShape(50),
                    )
            )
    }
}

/** Monospace text for ages, ids and counts. */
internal val MonoSmall = TextStyle(fontFamily = FontFamily.Monospace, fontSize = 10.sp)

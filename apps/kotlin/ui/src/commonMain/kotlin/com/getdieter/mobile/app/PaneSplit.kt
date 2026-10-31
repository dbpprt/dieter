package com.getdieter.mobile.app

import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.snap
import androidx.compose.animation.core.spring
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.Orientation
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.draggable
import androidx.compose.foundation.gestures.rememberDraggableState
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsDraggedAsState
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.VerticalDivider
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.layout
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import com.getdieter.mobile.design.*
import com.getdieter.mobile.store.*
import kotlin.math.roundToInt

/**
 * A list beside its detail, divided by a handle. Dragging it resizes both; dragging a pane well
 * past its minimum width sends it away so the other fills the window, and the handle stays at the
 * edge to bring it back. A double tap restores both panes. The choice is kept per device, so a
 * foldable opens the way it was left. [detailOpen] says whether something is open beside the list:
 * without it, a list that was sent away shows beside the placeholder.
 */
@Composable
internal fun ListDetailSplit(
    store: MobileStore,
    detailOpen: Boolean,
    list: @Composable () -> Unit,
    detail: @Composable () -> Unit,
) {
    val fraction by store.layout.paneFraction.collectAsState()
    val saved by store.layout.paneCollapse.collectAsState()
    val collapse = saved.shown(detailOpen)
    BoxWithConstraints(Modifier.fillMaxSize()) {
        val total = maxWidth.value
        // The list's width while a finger moves the handle; settled once the drag ends.
        var dragged by remember { mutableStateOf<Float?>(null) }
        val width by
            animateFloatAsState(
                dragged ?: PaneSplit.shownWidth(total, fraction, collapse),
                if (dragged != null) snap() else spring(stiffness = Spring.StiffnessMediumLow),
                label = "split",
            )
        val showList = width > .5f
        val showDetail = total - width > .5f
        Row(Modifier.fillMaxSize()) {
            if (showList)
                Box(
                    Modifier.width(width.dp)
                        .fillMaxHeight()
                        .clipToBounds()
                        .atLeastWidth(PaneSplit.MIN_LIST_DP.dp, alignEnd = true)
                ) {
                    list()
                }
            if (showList && showDetail) VerticalDivider(color = colors.outlineVariant)
            if (showDetail)
                Box(
                    Modifier.weight(1f)
                        .fillMaxHeight()
                        .clipToBounds()
                        .atLeastWidth(PaneSplit.MIN_DETAIL_DP.dp, alignEnd = false)
                ) {
                    detail()
                }
        }
        SplitHandle(
            store,
            total = total,
            width = width,
            collapsed = dragged == null && (!showList || !showDetail),
            canHideList = detailOpen,
            onDrag = { delta -> dragged = ((dragged ?: width) + delta).coerceIn(0f, total) },
            onDragEnd = {
                dragged?.let { store.layout.settle(total, it) }
                dragged = null
            },
        )
    }
}

/** A list sent away only stays away while something is open beside it. */
internal fun PaneCollapse.shown(detailOpen: Boolean): PaneCollapse =
    if (this == PaneCollapse.LIST && !detailOpen) PaneCollapse.NONE else this

/**
 * Lays the content out at least [min] wide, so a pane narrower than that slides out of view instead
 * of squeezing its content; the parent clips what does not fit.
 */
private fun Modifier.atLeastWidth(min: Dp, alignEnd: Boolean) = layout { measurable, constraints ->
    val width = maxOf(constraints.maxWidth, min.roundToPx())
    val placeable = measurable.measure(constraints.copy(minWidth = width, maxWidth = width))
    layout(constraints.maxWidth, placeable.height) {
        placeable.place(if (alignEnd) constraints.maxWidth - width else 0, 0)
    }
}

@Composable
private fun BoxScope.SplitHandle(
    store: MobileStore,
    total: Float,
    width: Float,
    collapsed: Boolean,
    canHideList: Boolean,
    onDrag: (Float) -> Unit,
    onDragEnd: () -> Unit,
) {
    val density = LocalDensity.current
    val interaction = remember { MutableInteractionSource() }
    val dragging by interaction.collectIsDraggedAsState()
    val pill by animateDpAsState(if (dragging) 56.dp else 40.dp, label = "handle")
    val left = (width - 12f).coerceIn(0f, (total - 24f).coerceAtLeast(0f))
    val atEnd = width > total / 2
    // Only the handle takes touches, so rows and back buttons beside the divider keep theirs.
    Box(
        Modifier.offset { IntOffset((left * density.density).roundToInt(), 0) }
            .width(24.dp)
            .fillMaxHeight(),
        contentAlignment = Alignment.Center,
    ) {
        Box(
            Modifier.size(width = 24.dp, height = 72.dp)
                .draggable(
                    rememberDraggableState { delta -> onDrag(delta / density.density) },
                    Orientation.Horizontal,
                    interactionSource = interaction,
                    onDragStopped = { onDragEnd() },
                )
                .pointerInput(Unit) {
                    detectTapGestures(onDoubleTap = { store.layout.resetPanes() })
                }
                .semantics {
                    contentDescription = "Resize panes"
                    customActions =
                        listOfNotNull(
                            CustomAccessibilityAction("Show list and detail") {
                                store.layout.resetPanes()
                                true
                            },
                            if (canHideList)
                                CustomAccessibilityAction("Hide list") {
                                    store.layout.setPaneCollapse(PaneCollapse.LIST)
                                    true
                                }
                            else null,
                            CustomAccessibilityAction("Hide detail") {
                                store.layout.setPaneCollapse(PaneCollapse.DETAIL)
                                true
                            },
                        )
                }
                .testTag("pane-divider"),
            contentAlignment =
                if (!collapsed) Alignment.Center
                else if (atEnd) Alignment.CenterEnd else Alignment.CenterStart,
        ) {
            // At an edge the handle becomes a tab to pull the pane back.
            Box(
                Modifier.then(
                    if (collapsed)
                        Modifier.size(width = 14.dp, height = 64.dp)
                            .clip(
                                if (atEnd) RoundedCornerShape(topStart = 10.dp, bottomStart = 10.dp)
                                else RoundedCornerShape(topEnd = 10.dp, bottomEnd = 10.dp)
                            )
                            .background(colors.surfaceContainerHighest)
                    else Modifier
                ),
                contentAlignment = Alignment.Center,
            ) {
                Box(
                    Modifier.size(width = 4.dp, height = if (collapsed) 36.dp else pill)
                        .clip(CircleShape)
                        .background(if (dragging) colors.onSurface else colors.outline)
                )
            }
        }
    }
}

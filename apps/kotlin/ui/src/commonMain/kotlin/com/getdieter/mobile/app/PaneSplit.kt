package com.getdieter.mobile.app

import androidx.compose.animation.core.animateDpAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.Orientation
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.draggable
import androidx.compose.foundation.gestures.rememberDraggableState
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsDraggedAsState
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.VerticalDivider
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.ProgressBarRangeInfo
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.progressBarRangeInfo
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.setProgress
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import com.getdieter.mobile.design.*
import com.getdieter.mobile.store.*
import kotlin.math.roundToInt

/**
 * A list beside its detail, divided by a handle that drags the split and resets it on a double tap.
 * The split is kept per device, so a foldable opens the way it was left.
 */
@Composable
internal fun ListDetailSplit(
    store: MobileStore,
    list: @Composable () -> Unit,
    detail: @Composable () -> Unit,
) {
    val saved by store.layout.paneFraction.collectAsState()
    BoxWithConstraints(Modifier.fillMaxSize()) {
        val total = maxWidth.value
        // Follows the finger while dragging; saved once the drag ends.
        var dragged by remember { mutableStateOf<Float?>(null) }
        val width = PaneSplit.listWidth(total, dragged ?: saved)
        Row(Modifier.fillMaxSize()) {
            Box(Modifier.width(width.dp).fillMaxHeight()) { list() }
            VerticalDivider(color = colors.outlineVariant)
            Box(Modifier.weight(1f).fillMaxHeight()) { detail() }
        }
        val density = LocalDensity.current
        val interaction = remember { MutableInteractionSource() }
        val dragging by interaction.collectIsDraggedAsState()
        val handle by animateDpAsState(if (dragging) 56.dp else 40.dp, label = "handle")
        // Only the handle takes touches, so rows and back buttons beside the divider keep theirs.
        Box(
            Modifier.offset { IntOffset(((width - 12f) * density.density).roundToInt(), 0) }
                .width(24.dp)
                .fillMaxHeight(),
            contentAlignment = Alignment.Center,
        ) {
            Box(
                Modifier.size(width = 24.dp, height = 72.dp)
                    .draggable(
                        rememberDraggableState { delta ->
                            val current = PaneSplit.listWidth(total, dragged ?: saved)
                            dragged = PaneSplit.fraction(total, current + delta / density.density)
                        },
                        Orientation.Horizontal,
                        interactionSource = interaction,
                        onDragStopped = {
                            dragged?.let(store.layout::setPaneFraction)
                            dragged = null
                        },
                    )
                    .pointerInput(Unit) {
                        detectTapGestures(
                            onDoubleTap = {
                                store.layout.setPaneFraction(PaneSplit.DEFAULT_FRACTION)
                            }
                        )
                    }
                    .semantics {
                        contentDescription = "Resize panes"
                        progressBarRangeInfo =
                            ProgressBarRangeInfo(
                                PaneSplit.fraction(total, width),
                                PaneSplit.fraction(total, 0f)..PaneSplit.fraction(total, total),
                            )
                        setProgress { value ->
                            store.layout.setPaneFraction(PaneSplit.fraction(total, total * value))
                            true
                        }
                    }
                    .testTag("pane-divider"),
                contentAlignment = Alignment.Center,
            ) {
                Box(
                    Modifier.size(width = 4.dp, height = handle)
                        .clip(CircleShape)
                        .background(if (dragging) colors.onSurface else colors.outline)
                )
            }
        }
    }
}

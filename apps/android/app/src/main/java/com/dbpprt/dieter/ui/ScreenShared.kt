@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)

package com.dbpprt.dieter.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Cancel
import androidx.compose.material.icons.outlined.Folder
import androidx.compose.material.icons.outlined.Sync
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.ProgressBarRangeInfo
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.progressBarRangeInfo
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.setProgress
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.dbpprt.dieter.ui.theme.DieterShell
import com.dbpprt.dieter.ui.theme.DieterMuted
import com.dbpprt.dieter.ui.theme.DieterOutline
import com.dbpprt.dieter.v1.Harness
import java.time.Duration
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale
import com.dbpprt.dieter.ui.theme.DieterShellTint

internal const val PROJECT_CHAT_PREVIEW_COUNT = 5

internal fun conversationRefreshLabel(lastRefreshedAtMillis: Long?, syncing: Boolean, nowMillis: Long): String {
    if (lastRefreshedAtMillis == null) return if (syncing) "Refreshing…" else "Not refreshed yet"
    val ageMillis = (nowMillis - lastRefreshedAtMillis).coerceAtLeast(0L)
    val freshness = when {
        ageMillis < 60_000L -> "just now"
        ageMillis < 3_600_000L -> "${ageMillis / 60_000L}m ago"
        ageMillis < 86_400_000L -> "${ageMillis / 3_600_000L}h ago"
        else -> DateTimeFormatter.ofPattern("MMM d · HH:mm", Locale.getDefault())
            .format(Instant.ofEpochMilli(lastRefreshedAtMillis).atZone(ZoneId.systemDefault()))
    }
    return "Last refreshed $freshness" + if (syncing) " · Refreshing…" else ""
}

/** Dashed rounded outline used by the reference design for "add" affordances and empty states. */
internal fun Modifier.dashedBorder(
    color: Color,
    cornerRadius: androidx.compose.ui.unit.Dp = 20.dp,
    strokeWidth: androidx.compose.ui.unit.Dp = 1.dp,
): Modifier = drawBehind {
    val stroke = androidx.compose.ui.graphics.drawscope.Stroke(
        width = strokeWidth.toPx(),
        pathEffect = androidx.compose.ui.graphics.PathEffect.dashPathEffect(
            floatArrayOf(9.dp.toPx(), 7.dp.toPx()),
        ),
    )
    drawRoundRect(
        color = color,
        style = stroke,
        cornerRadius = androidx.compose.ui.geometry.CornerRadius(cornerRadius.toPx()),
    )
}

@Composable
internal fun ConnectionEmptyState(state: DieterUiState, model: DieterViewModel) {
    if (state.desiredConnected) return
    Column(
        Modifier.fillMaxSize().padding(32.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Icon(Icons.Outlined.Sync, null, Modifier.size(46.dp), tint = DieterShell)
        Spacer(Modifier.height(14.dp))
        Text("Connect to Dieter", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold)
        Spacer(Modifier.height(8.dp))
        Text("Start Dieter on an enrolled machine and connect through your configured gateway.", color = DieterMuted)
        Spacer(Modifier.height(16.dp))
        OutlinedButton(onClick = model::refresh) { Text(state.endpoint) }
        TextButton(onClick = model::refresh) { Text("Try again") }
    }
}

@Composable
internal fun LoadingState(modifier: Modifier = Modifier) {
    Box(modifier.fillMaxSize(), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
}

@Composable
internal fun EmptyList(title: String, body: String, icon: ImageVector, modifier: Modifier = Modifier) {
    Column(
        modifier.fillMaxSize().padding(28.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Surface(shape = RoundedCornerShape(18.dp), color = DieterShellTint, modifier = Modifier.size(64.dp)) {
            Box(contentAlignment = Alignment.Center) {
                Icon(icon, null, Modifier.size(28.dp), tint = DieterShell)
            }
        }
        Spacer(Modifier.height(16.dp))
        Text(title, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
        Spacer(Modifier.height(6.dp))
        Text(body, color = DieterMuted, fontSize = 13.sp, lineHeight = 19.sp, textAlign = TextAlign.Center)
    }
}

@Composable
internal fun EmptyDetail(title: String, body: String, icon: ImageVector, modifier: Modifier = Modifier) {
    EmptyList(title, body, icon, modifier)
}

internal fun clampedPaneLeadingWidth(
    requestedWidth: Float,
    totalWidth: Float,
    dividerWidth: Float,
    minimumLeadingWidth: Float,
    minimumTrailingWidth: Float,
): Float {
    val availableWidth = (totalWidth - dividerWidth).coerceAtLeast(0f)
    if (availableWidth == 0f) return 0f
    val minimumCombinedWidth = minimumLeadingWidth + minimumTrailingWidth
    if (minimumCombinedWidth > availableWidth && minimumCombinedWidth > 0f) {
        return availableWidth * (minimumLeadingWidth / minimumCombinedWidth)
    }
    return requestedWidth.coerceIn(
        minimumLeadingWidth.coerceAtMost(availableWidth),
        (availableWidth - minimumTrailingWidth).coerceAtLeast(0f),
    )
}

@Composable
internal fun ResizableHorizontalSplitPane(
    dividerTag: String,
    modifier: Modifier = Modifier,
    initialLeadingFraction: Float = 0.43f,
    minimumLeadingWidth: androidx.compose.ui.unit.Dp = 220.dp,
    minimumTrailingWidth: androidx.compose.ui.unit.Dp = 320.dp,
    leading: @Composable (Modifier) -> Unit,
    trailing: @Composable (Modifier) -> Unit,
) {
    val dividerWidth = 16.dp
    var requestedFraction by rememberSaveable(dividerTag) { mutableFloatStateOf(initialLeadingFraction) }
    var dragging by remember { mutableStateOf(false) }
    val density = LocalDensity.current

    BoxWithConstraints(modifier) {
        val totalWidthPx = with(density) { maxWidth.toPx() }
        val dividerWidthPx = with(density) { dividerWidth.toPx() }
        val availableWidthPx = (totalWidthPx - dividerWidthPx).coerceAtLeast(0f)
        val minimumLeadingWidthPx = with(density) { minimumLeadingWidth.toPx() }
        val minimumTrailingWidthPx = with(density) { minimumTrailingWidth.toPx() }
        val leadingWidthPx = clampedPaneLeadingWidth(
            requestedWidth = availableWidthPx * requestedFraction,
            totalWidth = totalWidthPx,
            dividerWidth = dividerWidthPx,
            minimumLeadingWidth = minimumLeadingWidthPx,
            minimumTrailingWidth = minimumTrailingWidthPx,
        )
        val leadingWidth = with(density) { leadingWidthPx.toDp() }
        val actualFraction = if (availableWidthPx > 0f) leadingWidthPx / availableWidthPx else 0.5f
        val currentLeadingWidthPx by rememberUpdatedState(leadingWidthPx)

        Row(Modifier.fillMaxSize()) {
            leading(Modifier.width(leadingWidth).fillMaxHeight())
            Box(
                Modifier.width(dividerWidth).fillMaxHeight()
                    .testTag(dividerTag)
                    .semantics {
                        contentDescription = "Resize list and detail panes"
                        stateDescription = "List pane ${(actualFraction * 100).toInt()} percent"
                        progressBarRangeInfo = ProgressBarRangeInfo(actualFraction, 0f..1f)
                        setProgress { targetFraction ->
                            requestedFraction = targetFraction.coerceIn(0f, 1f)
                            true
                        }
                    }
                    .pointerInput(availableWidthPx, minimumLeadingWidthPx, minimumTrailingWidthPx) {
                        var draggedWidthPx = leadingWidthPx
                        detectHorizontalDragGestures(
                            onDragStart = {
                                draggedWidthPx = currentLeadingWidthPx
                                dragging = true
                            },
                            onDragCancel = { dragging = false },
                            onDragEnd = { dragging = false },
                        ) { change, dragAmount ->
                            change.consume()
                            draggedWidthPx = clampedPaneLeadingWidth(
                                requestedWidth = draggedWidthPx + dragAmount,
                                totalWidth = totalWidthPx,
                                dividerWidth = dividerWidthPx,
                                minimumLeadingWidth = minimumLeadingWidthPx,
                                minimumTrailingWidth = minimumTrailingWidthPx,
                            )
                            if (availableWidthPx > 0f) requestedFraction = draggedWidthPx / availableWidthPx
                        }
                    },
                contentAlignment = Alignment.Center,
            ) {
                Box(Modifier.fillMaxHeight().width(1.dp).background(DieterOutline))
                Box(
                    Modifier.width(if (dragging) 5.dp else 3.dp).height(if (dragging) 58.dp else 42.dp)
                        .background(
                            if (dragging) DieterShell else DieterMuted.copy(alpha = 0.58f),
                            RoundedCornerShape(50),
                        ),
                )
            }
            trailing(Modifier.weight(1f).fillMaxHeight())
        }
    }
}

internal fun shortTimestamp(
    value: String,
    now: Instant = Instant.now(),
    zoneId: ZoneId = ZoneId.systemDefault(),
): String {
    if (value.isBlank()) return ""
    return runCatching {
        val timestamp = Instant.parse(value)
        if (timestamp.isAfter(now)) {
            val until = Duration.between(now, timestamp)
            return@runCatching when {
                until.toMinutes() < 1 -> "in <1m"
                until.toMinutes() < 60 -> "in ${until.toMinutes()}m"
                until.toHours() < 24 -> "in ${until.toHours()}h"
                else -> DateTimeFormatter.ofPattern("MMM d · HH:mm")
                    .format(timestamp.atZone(zoneId))
            }
        }
        val age = Duration.between(timestamp, now)
        when {
            age.toMinutes() < 1 -> "now"
            age.toMinutes() < 60 -> "${age.toMinutes()}m"
            age.toHours() < 24 -> "${age.toHours()}h"
            else -> DateTimeFormatter.ofPattern("MMM d")
                .format(timestamp.atZone(zoneId))
        }
    }.getOrElse { value.substringBefore('T').takeLast(5) }
}

@Composable
internal fun FileCreateDialog(currentPath: String, onDismiss: () -> Unit, onCreate: (String, Boolean) -> Unit) {
    var name by remember { mutableStateOf("") }
    var directory by remember { mutableStateOf(false) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Create in ${currentPath.ifBlank { "/" }}") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                OutlinedTextField(name, { name = it }, label = { Text("Name") }, singleLine = true)
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    FilterChip(selected = !directory, onClick = { directory = false }, label = { Text("File") })
                    FilterChip(selected = directory, onClick = { directory = true }, label = { Text("Folder") })
                }
            }
        },
        confirmButton = {
            Button(
                onClick = { onCreate(listOf(currentPath.trim('/'), name.trim('/')).filter { it.isNotBlank() }.joinToString("/"), directory) },
                enabled = name.isNotBlank(),
            ) { Text("Create") }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

@Composable
internal fun TextInputDialog(
    title: String,
    label: String,
    initial: String,
    onDismiss: () -> Unit,
    onConfirm: (String) -> Unit,
) {
    var value by remember(initial) { mutableStateOf(initial) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title) },
        text = { OutlinedTextField(value, { value = it }, label = { Text(label) }, modifier = Modifier.fillMaxWidth()) },
        confirmButton = { Button(onClick = { onConfirm(value.trim()) }, enabled = value.isNotBlank()) { Text("Save") } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

@Composable
internal fun ConfirmDialog(
    title: String,
    body: String,
    confirmLabel: String,
    onDismiss: () -> Unit,
    onConfirm: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title) },
        text = { Text(body) },
        confirmButton = { Button(onClick = onConfirm) { Text(confirmLabel) } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

@Composable
internal fun CardLabelsDialog(state: DieterUiState, onDismiss: () -> Unit, onSave: (List<String>) -> Unit) {
    val selected = remember(state.selectedCardId) { mutableStateListOf<String>().also { it += state.selectedCard?.labelIdsList.orEmpty() } }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Card labels") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                state.board?.labelsList.orEmpty().forEach { label ->
                    FilterChip(
                        selected = label.id in selected,
                        onClick = { if (label.id in selected) selected.remove(label.id) else selected += label.id },
                        label = { Text(label.name) },
                    )
                }
                if (state.board?.labelsCount == 0) Text("This board has no labels yet.", color = DieterMuted)
            }
        },
        confirmButton = { Button(onClick = { onSave(selected.toList()) }) { Text("Save") } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

internal fun Harness.effortOptionsFor(modelId: String) =
    modelsList.firstOrNull { it.id == modelId }?.effortsList.orEmpty().let { allowed ->
        effort.optionsList.filter { allowed.isEmpty() || it.id in allowed }
    }

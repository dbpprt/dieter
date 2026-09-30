@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)

package com.dbpprt.dieter.ui

import androidx.compose.runtime.staticCompositionLocalOf
import com.dbpprt.dieter.core.composition.Attachments
import com.dbpprt.dieter.core.presentation.ActivitySummary
import com.dbpprt.dieter.core.presentation.DetectedLinks
import com.dbpprt.dieter.core.presentation.Durations
import com.dbpprt.dieter.core.presentation.Markdown
import com.dbpprt.dieter.core.presentation.MarkdownBlock
import com.dbpprt.dieter.core.presentation.Parts
import com.dbpprt.dieter.core.presentation.StepKind
import com.dbpprt.dieter.core.presentation.SubagentPresentation
import android.graphics.BitmapFactory
import androidx.compose.animation.animateContentSize
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.Image
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.outlined.Cancel
import androidx.compose.material.icons.outlined.CheckCircle
import androidx.compose.material.icons.outlined.ChevronRight
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.Description
import androidx.compose.material.icons.outlined.Schedule
import androidx.compose.material.icons.outlined.Terminal
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.key
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.LinkAnnotation
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextLinkStyles
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.withLink
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.dbpprt.dieter.core.presentation.TableAlignment
import com.dbpprt.dieter.core.presentation.TaskPlans
import com.dbpprt.dieter.core.presentation.TimelineBuilder
import com.dbpprt.dieter.core.presentation.TimelineItem
import com.dbpprt.dieter.core.presentation.TimelineStep
import com.dbpprt.dieter.core.presentation.ToolStatus
import com.dbpprt.dieter.core.presentation.Tools
import com.dbpprt.dieter.core.presentation.WorkspaceImages
import com.dbpprt.dieter.ui.theme.DieterEyes
import com.dbpprt.dieter.ui.theme.DieterShell
import com.dbpprt.dieter.ui.theme.DieterMuted
import com.dbpprt.dieter.ui.theme.DieterOutline
import com.dbpprt.dieter.ui.theme.DieterShellTint
import com.dbpprt.dieter.ui.theme.DieterSurfaceHigh
import com.dbpprt.dieter.api.v1.MessagePart
import com.dbpprt.dieter.api.v1.Schedule
import com.dbpprt.dieter.api.v1.Subagent
import com.dbpprt.dieter.api.v1.TaskPlan
import com.dbpprt.dieter.api.v1.UiMessage
import com.dbpprt.dieter.api.v1.ToolOutput
import kotlin.time.Duration.Companion.milliseconds
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** The conversation's workspace root, for resolving image links an agent wrote as absolute paths. */
internal val LocalWorkspaceRoot = staticCompositionLocalOf<String?> { null }

@Composable
internal fun MessageParts(item: TimelineItem.Message, model: DieterViewModel, compact: Boolean = false) {
    var previewPath by remember(item.id) { mutableStateOf<String?>(null) }
    val groups = item.groups
    var retainedFrom by remember(item.id) { mutableStateOf<String?>(null) }
    val start = if (item.user) 0 else TimelineBuilder.visibleStart(groups, retainedFrom)
    LaunchedEffect(item.id, groups.isEmpty()) {
        // New streamed parts append to the mounted window; they never evict
        // already-visible prose or reset an expanded tool group.
        if (groups.isNotEmpty() && retainedFrom == null) retainedFrom = groups.getOrNull(start)?.id
    }
    item.plans.forEach { plan -> TaskPlanBlock(plan) }
    if (start > 0) {
        TextButton(
            onClick = { retainedFrom = groups[(start - TimelineBuilder.INITIAL_GROUPS).coerceAtLeast(0)].id },
            modifier = Modifier.testTag("message-earlier-${item.message.id}"),
        ) { Text("Show earlier in this message") }
    }
    groups.drop(start).forEach { group ->
        key(group.id) {
            if (group.activity) {
                ActivityGroup(group.id, ActivitySummary.of(group.steps).english(), group.steps, model)
            } else {
                group.steps.forEach { step ->
                    TimelineStepContent(step, item.subagents, model, compact) { previewPath = it }
                }
            }
        }
    }
    previewPath?.let { path ->
        ConversationImageLightbox(path = path, model = model, onDismiss = { previewPath = null })
    }
}

@Composable
private fun TimelineStepContent(
    step: TimelineStep,
    subagents: List<Subagent>,
    model: DieterViewModel,
    compact: Boolean,
    onImageLink: (String) -> Unit,
) {
    when (step.kind) {
        StepKind.TEXT -> SelectionContainer { MessageMarkdown(step.text, compact, onImageLink) }
        StepKind.REASONING -> ReasoningPart(step.text)
        StepKind.ATTACHMENT -> AttachmentPart(step.part)
        StepKind.TOOL -> ToolItem(step.messageId, step.part, model, attention = Parts.isApprovalTool(step.part))
        StepKind.SUBAGENTS -> SubagentBlock(subagents)
        StepKind.ATTENTION, StepKind.OTHER -> step.text.ifBlank { step.part.error_text }.takeIf(String::isNotBlank)?.let { text ->
            MessageMarkdown(text, compact, onImageLink)
        }
    }
}

@Composable
internal fun MessageMarkdown(value: String, compact: Boolean, onImageLink: ((String) -> Unit)? = null) {
    val blocks = remember(value) { Markdown.parse(value) }
    val workspaceRoot = LocalWorkspaceRoot.current
    Column(verticalArrangement = Arrangement.spacedBy(if (compact) 2.dp else 7.dp)) {
        blocks.forEach { block ->
            when (block) {
                is MarkdownBlock.Table -> MessageMarkdownTable(block)
                is MarkdownBlock.Code -> Surface(color = DieterSurfaceHigh, shape = RoundedCornerShape(9.dp), modifier = Modifier.fillMaxWidth()) {
                    Text(
                        block.text,
                        color = DieterMuted,
                        fontFamily = FontFamily.Monospace,
                        fontSize = 11.sp,
                        lineHeight = 17.sp,
                        modifier = Modifier.padding(horizontal = 11.dp, vertical = 9.dp),
                    )
                }
                is MarkdownBlock.Heading -> MarkdownText(block.text, compact, heading = true, workspaceRoot, onImageLink)
                is MarkdownBlock.Bullet -> MarkdownText("• " + block.text, compact, heading = false, workspaceRoot, onImageLink)
                is MarkdownBlock.Paragraph -> MarkdownText(block.text, compact, heading = false, workspaceRoot, onImageLink)
            }
        }
    }
}

@Composable
private fun MarkdownText(text: String, compact: Boolean, heading: Boolean, workspaceRoot: String?, onImageLink: ((String) -> Unit)?) {
    val inline = remember(text, workspaceRoot, onImageLink) { markdownInlineText(text, workspaceRoot, onImageLink) }
    Text(
        inline,
        fontSize = if (heading) 15.sp else 14.sp,
        fontWeight = if (heading) FontWeight.SemiBold else FontWeight.Normal,
        lineHeight = if (compact) 20.sp else 21.sp,
    )
}

@Composable
private fun MessageMarkdownTable(table: MarkdownBlock.Table) {
    val columnWidths = remember(table) {
        table.header.indices.map { column ->
            val longest = (listOf(table.header[column]) + table.rows.map { it.getOrElse(column) { "" } })
                .maxOf { it.length }
            (longest.coerceIn(8, 24) * 7 + 24).dp
        }
    }
    Surface(
        color = MaterialTheme.colorScheme.surface,
        shape = RoundedCornerShape(9.dp),
        modifier = Modifier.fillMaxWidth().testTag("markdown-table")
            .border(1.dp, DieterOutline, RoundedCornerShape(9.dp)),
    ) {
        Column(Modifier.horizontalScroll(rememberScrollState())) {
            MarkdownTableRow(table.header, table.alignments, columnWidths, header = true)
            table.rows.forEach { row ->
                MarkdownTableRow(row, table.alignments, columnWidths, header = false)
            }
        }
    }
}

@Composable
private fun MarkdownTableRow(
    values: List<String>,
    alignments: List<TableAlignment>,
    widths: List<androidx.compose.ui.unit.Dp>,
    header: Boolean,
) {
    Row(
        Modifier
            .background(if (header) DieterSurfaceHigh else MaterialTheme.colorScheme.surface)
            .drawBehind {
                drawLine(DieterOutline, Offset(0f, size.height), Offset(size.width, size.height), 1.dp.toPx())
            },
        verticalAlignment = Alignment.Top,
    ) {
        widths.indices.forEach { column ->
            val alignment = alignments.getOrElse(column) { TableAlignment.START }
            Text(
                markdownInlineText(values.getOrElse(column) { "" }),
                fontSize = 12.sp,
                lineHeight = 17.sp,
                fontWeight = if (header) FontWeight.SemiBold else FontWeight.Normal,
                textAlign = when (alignment) {
                    TableAlignment.START -> TextAlign.Start
                    TableAlignment.CENTER -> TextAlign.Center
                    TableAlignment.END -> TextAlign.End
                },
                modifier = Modifier.width(widths[column]).padding(horizontal = 10.dp, vertical = 8.dp),
            )
        }
    }
}

internal val inlineMarkdownPattern = Regex("(\\*\\*([^*]+)\\*\\*|`([^`]+)`|\\[([^]]+)]\\(([^)]+)\\))")

/**
 * Inline styling (bold, code, links) is the platform's; which links open an
 * image and which bare addresses become web links is the core's.
 */
internal fun markdownInlineText(value: String, workspaceRoot: String? = null, onImageLink: ((String) -> Unit)? = null): AnnotatedString = buildAnnotatedString {
    val linkStyle = SpanStyle(color = DieterShell, textDecoration = TextDecoration.Underline)
    fun plain(text: String) {
        var cursor = 0
        DetectedLinks.find(text).forEach { match ->
            append(text.substring(cursor, match.range.first))
            withLink(LinkAnnotation.Url(match.url, TextLinkStyles(style = linkStyle))) { append(text.substring(match.range)) }
            cursor = match.range.last + 1
        }
        append(text.substring(cursor))
    }
    var cursor = 0
    inlineMarkdownPattern.findAll(value).forEach { match ->
        plain(value.substring(cursor, match.range.first))
        when {
            match.groupValues[2].isNotEmpty() -> withStyle(SpanStyle(fontWeight = FontWeight.SemiBold)) {
                append(match.groupValues[2])
            }
            match.groupValues[3].isNotEmpty() -> withStyle(
                SpanStyle(color = DieterShell, background = DieterSurfaceHigh, fontFamily = FontFamily.Monospace),
            ) { append(match.groupValues[3]) }
            else -> {
                val label = match.groupValues[4]
                val image = WorkspaceImages.path(match.groupValues[5], workspaceRoot)
                if (image != null && onImageLink != null) {
                    withLink(
                        LinkAnnotation.Clickable(
                            tag = image,
                            styles = TextLinkStyles(style = linkStyle),
                            linkInteractionListener = { onImageLink(image) },
                        ),
                    ) { append(label) }
                } else {
                    withStyle(linkStyle) { append(label) }
                }
            }
        }
        cursor = match.range.last + 1
    }
    plain(value.substring(cursor))
}

@Composable
private fun ConversationImageLightbox(path: String, model: DieterViewModel, onDismiss: () -> Unit) {
    var document by remember(path) { mutableStateOf<com.dbpprt.dieter.api.v1.FileDocument?>(null) }
    var loaded by remember(path) { mutableStateOf(false) }
    var bitmap by remember(path) { mutableStateOf<ImageBitmap?>(null) }
    LaunchedEffect(path) {
        document = model.readConversationImage(path)
        bitmap = document?.let { value ->
            val bytes = if (value.binary) value.data_.toByteArray() else value.content.toByteArray()
            withContext(Dispatchers.Default) { decodeConversationImage(bytes) }?.asImageBitmap()
        }
        loaded = true
    }
    Dialog(
        onDismissRequest = onDismiss,
        properties = DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false),
    ) {
        val displayedBitmap = bitmap
        Box(
            Modifier.fillMaxSize().background(androidx.compose.ui.graphics.Color.Black)
                .testTag("conversation-image-lightbox"),
        ) {
            when {
                displayedBitmap != null -> Image(
                    bitmap = displayedBitmap,
                    contentDescription = document?.name ?: path.substringAfterLast('/'),
                    contentScale = ContentScale.Fit,
                    modifier = Modifier.fillMaxSize().padding(12.dp),
                )
                !loaded -> CircularProgressIndicator(
                    Modifier.align(Alignment.Center),
                    color = androidx.compose.ui.graphics.Color.White,
                )
                else -> Text(
                    "This image could not be displayed.",
                    color = androidx.compose.ui.graphics.Color.White,
                    modifier = Modifier.align(Alignment.Center),
                )
            }
            Text(
                document?.name ?: path.substringAfterLast('/'),
                color = androidx.compose.ui.graphics.Color.White,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.align(Alignment.TopStart).padding(20.dp),
            )
            IconButton(
                onClick = onDismiss,
                modifier = Modifier.align(Alignment.TopEnd).padding(8.dp).testTag("conversation-image-close"),
            ) {
                Icon(
                    Icons.Outlined.Close,
                    contentDescription = "Close image",
                    tint = androidx.compose.ui.graphics.Color.White,
                )
            }
        }
    }
}

private fun decodeConversationImage(bytes: ByteArray, maxDimension: Int = 2400): android.graphics.Bitmap? {
    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
    var sample = 1
    while (bounds.outWidth / sample > maxDimension * 2 || bounds.outHeight / sample > maxDimension * 2) {
        sample *= 2
    }
    return BitmapFactory.decodeByteArray(
        bytes,
        0,
        bytes.size,
        BitmapFactory.Options().apply { inSampleSize = sample },
    )
}

@Composable
internal fun TaskPlanBlock(plan: TaskPlan) {
    val progress = TaskPlans.progress(plan)
    val active = progress.active
    var expanded by remember(plan.id, plan.revision) { mutableStateOf(active) }
    Surface(
        shape = RoundedCornerShape(9.dp),
        color = DieterSurfaceHigh,
        modifier = Modifier.fillMaxWidth().padding(vertical = 3.dp)
            .border(1.dp, DieterOutline.copy(alpha = 0.55f), RoundedCornerShape(9.dp)),
    ) {
        Column {
            Row(
                Modifier.fillMaxWidth().clickable { expanded = !expanded }.padding(horizontal = 9.dp, vertical = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(Icons.Outlined.ChevronRight, null, tint = DieterMuted, modifier = Modifier.size(15.dp).rotate(if (expanded) 90f else 0f))
                Spacer(Modifier.width(6.dp))
                if (active) CircularProgressIndicator(Modifier.size(13.dp), strokeWidth = 1.5.dp, color = DieterShell)
                else Icon(Icons.Outlined.CheckCircle, null, tint = DieterEyes, modifier = Modifier.size(14.dp))
                Spacer(Modifier.width(7.dp))
                Text("Task progress", Modifier.weight(1f), fontSize = 11.sp, fontWeight = FontWeight.SemiBold)
                Text("${progress.completed}/${progress.total}", color = DieterMuted, fontSize = 10.sp)
            }
            if (expanded) {
                Column(Modifier.padding(start = 31.dp, end = 9.dp, bottom = 9.dp), verticalArrangement = Arrangement.spacedBy(5.dp)) {
                    if (plan.explanation.isNotBlank()) Text(plan.explanation, color = DieterMuted, fontSize = 10.sp, lineHeight = 14.sp)
                    plan.phases.forEach { phase ->
                        if (phase.name.isNotBlank()) Text(phase.name.uppercase(), color = DieterMuted, fontSize = 9.sp, fontWeight = FontWeight.SemiBold)
                        phase.tasks.forEach { task ->
                            Row(verticalAlignment = Alignment.Top) {
                                when (task.status) {
                                    "in_progress" -> CircularProgressIndicator(Modifier.size(12.dp), strokeWidth = 1.5.dp, color = DieterShell)
                                    "completed" -> Icon(Icons.Filled.Check, null, tint = DieterEyes, modifier = Modifier.size(13.dp))
                                    "blocked" -> Icon(Icons.Outlined.Cancel, null, tint = MaterialTheme.colorScheme.error, modifier = Modifier.size(13.dp))
                                    else -> Icon(Icons.Outlined.Schedule, null, tint = DieterMuted, modifier = Modifier.size(13.dp))
                                }
                                Spacer(Modifier.width(7.dp))
                                Column(Modifier.weight(1f)) {
                                    Text(
                                        TaskPlans.text(task),
                                        color = if (TaskPlans.finished(task)) DieterMuted else MaterialTheme.colorScheme.onSurface,
                                        fontSize = 10.sp,
                                        lineHeight = 14.sp,
                                    )
                                    if (task.blocker.isNotBlank()) Text(task.blocker, color = MaterialTheme.colorScheme.error, fontSize = 9.sp)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

@Composable
internal fun SubagentBlock(subagents: List<Subagent>) {
    val active = SubagentPresentation.active(subagents) > 0
    var expanded by remember(subagents.map { "${it.id}:${it.status}" }) { mutableStateOf(active) }
    Column(Modifier.fillMaxWidth().padding(vertical = 3.dp)) {
        Row(
            Modifier.clip(RoundedCornerShape(7.dp)).clickable { expanded = !expanded }.padding(horizontal = 4.dp, vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(Icons.Outlined.ChevronRight, null, tint = DieterMuted, modifier = Modifier.size(15.dp).rotate(if (expanded) 90f else 0f))
            Spacer(Modifier.width(5.dp))
            Text("${subagents.size} ${if (subagents.size == 1) "subagent" else "subagents"}", color = DieterMuted, fontSize = 11.sp, fontWeight = FontWeight.SemiBold)
            if (active) {
                Spacer(Modifier.width(7.dp))
                CircularProgressIndicator(Modifier.size(11.dp), strokeWidth = 1.4.dp, color = DieterShell)
                Spacer(Modifier.width(4.dp))
                Text("Working", color = DieterShell, fontSize = 9.sp)
            }
        }
        if (expanded) {
            Column(Modifier.padding(start = 20.dp), verticalArrangement = Arrangement.spacedBy(5.dp)) {
                subagents.forEach { subagent ->
                    val presented = SubagentPresentation(subagent, kotlin.time.Clock.System.now())
                    Surface(shape = RoundedCornerShape(8.dp), color = DieterSurfaceHigh, modifier = Modifier.fillMaxWidth()) {
                        Column(Modifier.padding(horizontal = 9.dp, vertical = 7.dp), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                if (subagent.status == "running") CircularProgressIndicator(Modifier.size(11.dp), strokeWidth = 1.4.dp, color = DieterShell)
                                else Icon(if (subagent.status == "completed") Icons.Outlined.CheckCircle else Icons.Outlined.Cancel, null, tint = if (subagent.status == "completed") DieterEyes else DieterMuted, modifier = Modifier.size(12.dp))
                                Spacer(Modifier.width(6.dp))
                                Text(
                                    presented.title,
                                    Modifier.weight(1f),
                                    fontSize = 10.sp,
                                    fontWeight = FontWeight.SemiBold,
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis,
                                )
                                Text(subagent.status, color = DieterMuted, fontSize = 8.sp)
                            }
                            presented.statusLine?.let { Text(it, color = DieterMuted, fontSize = 9.sp, maxLines = 1, overflow = TextOverflow.Ellipsis) }
                            val metrics = presented.summaryMetrics
                            if (metrics.isNotEmpty()) Text(metrics.joinToString(" · "), color = DieterMuted, fontSize = 8.sp)
                            if (subagent.error.isNotBlank()) Text(subagent.error, color = MaterialTheme.colorScheme.error, fontSize = 9.sp)
                        }
                    }
                }
            }
        }
    }
}

@Composable
internal fun ReasoningPart(text: String) {
    if (text.isBlank()) return
    var expanded by remember { mutableStateOf(false) }
    Column(Modifier.fillMaxWidth()) {
        Row(
            Modifier.fillMaxWidth().clip(RoundedCornerShape(6.dp)).clickable { expanded = !expanded }
                .padding(horizontal = 4.dp, vertical = 5.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(
                Icons.Outlined.ChevronRight,
                contentDescription = null,
                tint = DieterMuted,
                modifier = Modifier.size(14.dp).rotate(if (expanded) 90f else 0f),
            )
            Spacer(Modifier.width(5.dp))
            Text("Reasoning", color = DieterMuted, fontSize = 11.sp, fontWeight = FontWeight.SemiBold)
            if (!expanded) {
                Spacer(Modifier.width(6.dp))
                Text(
                    text.lineSequence().firstOrNull { it.isNotBlank() }.orEmpty().replace("**", ""),
                    color = DieterMuted.copy(alpha = 0.72f),
                    fontSize = 10.sp,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
        if (expanded) {
            SelectionContainer {
                Text(
                    text,
                    modifier = Modifier.padding(start = 23.dp, top = 3.dp, bottom = 5.dp),
                    color = DieterMuted,
                    fontSize = 12.sp,
                    lineHeight = 18.sp,
                )
            }
        }
    }
}

@Composable
internal fun AgentAvatar() {
    Surface(
        color = DieterSurfaceHigh,
        contentColor = DieterShell,
        shape = RoundedCornerShape(10.dp),
        modifier = Modifier.size(32.dp),
    ) {
        Box(contentAlignment = Alignment.Center) {
            Row(
                Modifier.size(width = 17.dp, height = 16.dp),
                horizontalArrangement = Arrangement.spacedBy(2.dp),
                verticalAlignment = Alignment.Top,
            ) {
                Box(Modifier.width(3.dp).height(16.dp).clip(RoundedCornerShape(2.dp)).background(DieterShell))
                Box(Modifier.width(3.dp).height(11.dp).clip(RoundedCornerShape(2.dp)).background(DieterShell))
                Box(Modifier.width(3.dp).height(8.dp).clip(RoundedCornerShape(2.dp)).background(DieterShell))
                Box(Modifier.width(3.dp).height(5.dp).clip(RoundedCornerShape(2.dp)).background(DieterShell))
            }
        }
    }
}

@Composable
internal fun AgentWorkingIndicator(label: String, startedAtMillis: Long?) {
    val transition = rememberInfiniteTransition(label = "agent-working")
    val shimmerOffset by transition.animateFloat(
        initialValue = -220f,
        targetValue = 720f,
        animationSpec = infiniteRepeatable(tween(2_000, easing = LinearEasing)),
        label = "activity-shimmer",
    )
    val nowMillis by produceState(System.currentTimeMillis(), startedAtMillis) {
        if (startedAtMillis == null) return@produceState
        while (true) {
            value = System.currentTimeMillis()
            delay(1_000L - ((value - startedAtMillis).coerceAtLeast(0L) % 1_000L))
        }
    }
    val textBrush = Brush.linearGradient(
        colors = listOf(DieterMuted, MaterialTheme.colorScheme.onSurface, DieterMuted),
        start = Offset(shimmerOffset - 150f, 0f),
        end = Offset(shimmerOffset + 150f, 0f),
    )
    Surface(
        color = DieterSurfaceHigh.copy(alpha = 0.85f),
        shape = CircleShape,
        border = androidx.compose.foundation.BorderStroke(1.dp, DieterShell.copy(alpha = 0.18f)),
        modifier = Modifier.padding(top = 2.dp, bottom = 6.dp)
            .animateContentSize()
            .testTag("agent-working")
            .semantics { contentDescription = label },
    ) {
        Row(
            Modifier.heightIn(min = 34.dp).padding(horizontal = 11.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            CircularProgressIndicator(
                modifier = Modifier.size(12.dp),
                color = DieterShell,
                trackColor = DieterShell.copy(alpha = 0.16f),
                strokeWidth = 1.7.dp,
            )
            Text(
                label,
                style = TextStyle(brush = textBrush),
                fontSize = 11.sp,
                fontWeight = FontWeight.Medium,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            startedAtMillis?.let { startedAt ->
                Text(
                    Durations.clock((nowMillis - startedAt).milliseconds),
                    color = DieterMuted,
                    fontSize = 11.sp,
                    fontFamily = FontFamily.Monospace,
                    maxLines = 1,
                    modifier = Modifier.semantics { contentDescription = "Elapsed time" },
                )
            }
        }
    }
}

@Composable
internal fun rememberAttachmentBitmap(
    part: MessagePart,
    maxDimension: Int = 900,
): ImageBitmap? = produceState<ImageBitmap?>(
    initialValue = null,
    key1 = part.url,
    key2 = part.data_,
    key3 = maxDimension,
) {
    value = withContext(Dispatchers.Default) {
        decodeAttachmentBitmap(part, maxDimension)?.asImageBitmap()
    }
}.value

@Composable
internal fun AttachmentPart(part: MessagePart) {
    val bitmap = rememberAttachmentBitmap(part)
    if (bitmap != null) {
        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Image(
                bitmap = bitmap,
                contentDescription = part.filename.ifBlank { "Attached image" },
                contentScale = ContentScale.FillWidth,
                modifier = Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp)),
            )
            if (part.filename.isNotBlank()) {
                Text(
                    part.filename,
                    color = DieterMuted,
                    fontSize = 11.sp,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
        return
    }
    Surface(
        shape = RoundedCornerShape(12.dp),
        color = DieterSurfaceHigh,
        border = androidx.compose.foundation.BorderStroke(1.dp, DieterOutline),
        modifier = Modifier.widthIn(max = 340.dp),
    ) {
        Row(
            Modifier.padding(horizontal = 12.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box(
                Modifier.size(38.dp).clip(RoundedCornerShape(10.dp)).background(DieterShellTint),
                contentAlignment = Alignment.Center,
            ) {
                Icon(Icons.Outlined.Description, null, tint = DieterShell, modifier = Modifier.size(19.dp))
            }
            Spacer(Modifier.width(10.dp))
            Column(Modifier.weight(1f)) {
                Text(
                    part.filename.ifBlank { "Attachment" },
                    fontSize = 13.sp,
                    fontWeight = FontWeight.SemiBold,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Text(Attachments.details(part), color = DieterMuted, fontSize = 10.sp, maxLines = 1)
            }
        }
    }
}

/** A run of routine steps (tool calls, reasoning) folded behind its summary, e.g. "Reasoning · 2 commands". */
@Composable
internal fun ActivityGroup(id: String, label: String, steps: List<TimelineStep>, model: DieterViewModel) {
    if (steps.isEmpty()) return
    var expanded by remember(id) { mutableStateOf(false) }
    Column(Modifier.fillMaxWidth().padding(vertical = 2.dp)) {
        Row(
            Modifier.clip(RoundedCornerShape(6.dp)).clickable { expanded = !expanded }
                .padding(horizontal = 4.dp, vertical = 5.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(
                Icons.Outlined.ChevronRight,
                contentDescription = if (expanded) "Collapse tool activity" else "Expand tool activity",
                tint = DieterMuted,
                modifier = Modifier.size(15.dp).rotate(if (expanded) 90f else 0f),
            )
            Spacer(Modifier.width(5.dp))
            Text(label, color = DieterMuted, fontSize = 11.sp, fontWeight = FontWeight.Medium)
        }
        if (expanded) {
            Column(
                Modifier.fillMaxWidth().padding(start = 7.dp, top = 2.dp)
                    .drawBehind {
                        drawLine(
                            color = DieterOutline,
                            start = Offset.Zero,
                            end = Offset(0f, size.height),
                            strokeWidth = 1.dp.toPx(),
                        )
                    }
                    .padding(start = 11.dp),
                verticalArrangement = Arrangement.spacedBy(2.dp),
            ) {
                steps.forEach { step ->
                    key(step.id) {
                        if (step.kind == StepKind.REASONING) ReasoningPart(step.text) else ToolItem(step.messageId, step.part, model)
                    }
                }
            }
        }
    }
}

@Composable
internal fun ToolItem(messageId: String, part: MessagePart, model: DieterViewModel, attention: Boolean = false) {
    var expanded by remember(part.tool_call_id, part.payload_revision) { mutableStateOf(false) }
    var payload by remember(part.tool_call_id, part.payload_revision) { mutableStateOf<ToolOutput?>(null) }
    var loading by remember(part.tool_call_id, part.payload_revision) { mutableStateOf(false) }
    var error by remember(part.tool_call_id, part.payload_revision) { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()
    val input = (payload?.input_json ?: part.input_json).utf8().trim()
    val output = (payload?.output_json ?: part.output_json).utf8().trim()
    val status = Tools.status(part)
    val failed = status == ToolStatus.FAILED
    val attentionLabel = if (status == ToolStatus.DENIED) "Tool denied" else "Approval requested"
    fun toggle() {
        expanded = !expanded
        if (expanded && payload == null && !loading && (part.has_input || part.has_output)) {
            loading = true
            scope.launch {
                runCatching { model.loadToolOutput(messageId, part) }
                    .onSuccess { payload = it; error = null }
                    .onFailure { error = it.message ?: "Could not load tool details" }
                loading = false
            }
        }
    }
    Column(
        Modifier.fillMaxWidth().then(
            if (attention) Modifier.border(1.dp, MaterialTheme.colorScheme.primary, RoundedCornerShape(6.dp))
                .padding(vertical = 2.dp) else Modifier,
        ),
    ) {
        Row(
            Modifier.fillMaxWidth().clip(RoundedCornerShape(5.dp)).clickable { toggle() }
                .padding(horizontal = 6.dp, vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(
                when {
                    attention -> Icons.Outlined.Schedule
                    failed -> Icons.Outlined.Cancel
                    else -> Icons.Outlined.Terminal
                },
                contentDescription = when {
                    attention -> attentionLabel
                    failed -> "Tool failed"
                    else -> null
                },
                tint = when {
                    attention -> MaterialTheme.colorScheme.primary
                    failed -> MaterialTheme.colorScheme.error
                    else -> DieterMuted
                },
                modifier = Modifier.size(13.dp),
            )
            Spacer(Modifier.width(6.dp))
            Text(
                Tools.displayName(part),
                color = DieterMuted,
                fontSize = 10.sp,
                fontWeight = FontWeight.SemiBold,
            )
            if (attention) {
                Spacer(Modifier.width(7.dp))
                Text(attentionLabel, color = MaterialTheme.colorScheme.primary, fontSize = 10.sp)
            }
            val preview = Tools.preview(part)
            if (preview.isNotBlank()) {
                Spacer(Modifier.width(7.dp))
                Text(
                    preview,
                    modifier = Modifier.weight(1f),
                    color = DieterMuted.copy(alpha = 0.67f),
                    fontFamily = FontFamily.Monospace,
                    fontSize = 9.sp,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            } else Spacer(Modifier.weight(1f))
            Icon(
                Icons.Outlined.ChevronRight,
                contentDescription = if (expanded) "Collapse details" else "Expand details",
                tint = DieterMuted,
                modifier = Modifier.size(13.dp).rotate(if (expanded) 90f else 0f),
            )
        }
        if (expanded) {
            val payloadError = payload?.error_text.orEmpty().ifBlank { part.error_text }
            if (loading) {
                Row(
                    Modifier.padding(start = 25.dp, top = 5.dp, bottom = 7.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    CircularProgressIndicator(Modifier.size(13.dp), strokeWidth = 1.5.dp)
                    Spacer(Modifier.width(7.dp))
                    Text("Loading tool details…", color = DieterMuted, fontSize = 10.sp)
                }
            }
            if (error != null) {
                Text(error.orEmpty(), Modifier.padding(start = 25.dp, bottom = 6.dp), color = MaterialTheme.colorScheme.error, fontSize = 10.sp)
            }
            if (payloadError.isNotBlank()) ToolPayloadBlock("Error", payloadError, error = true)
            if (input.isNotBlank()) ToolPayloadBlock("Input", input)
            if (output.isNotBlank()) ToolPayloadBlock("Output", output)
            if (!loading && error == null && payloadError.isBlank() && input.isBlank() && output.isBlank()) {
                Text("No additional payload", Modifier.padding(start = 25.dp, bottom = 6.dp), color = DieterMuted, fontSize = 10.sp)
            }
        }
    }
}

@Composable
internal fun ToolPayloadBlock(label: String, value: String, error: Boolean = false) {
    Column(Modifier.fillMaxWidth().padding(start = 25.dp, end = 6.dp, bottom = 6.dp)) {
        Text(label, color = if (error) MaterialTheme.colorScheme.error else DieterMuted, fontSize = 9.sp, fontWeight = FontWeight.SemiBold)
        Spacer(Modifier.height(3.dp))
        Surface(
            color = MaterialTheme.colorScheme.background,
            shape = RoundedCornerShape(6.dp),
            border = androidx.compose.foundation.BorderStroke(1.dp, DieterOutline),
        ) {
            SelectionContainer {
                Text(
                    value,
                    modifier = Modifier.fillMaxWidth().heightIn(max = 220.dp).verticalScroll(rememberScrollState())
                        .padding(horizontal = 8.dp, vertical = 7.dp),
                    color = if (error) MaterialTheme.colorScheme.error else DieterMuted,
                    fontFamily = FontFamily.Monospace,
                    fontSize = 9.sp,
                    lineHeight = 13.sp,
                )
            }
        }
    }
}

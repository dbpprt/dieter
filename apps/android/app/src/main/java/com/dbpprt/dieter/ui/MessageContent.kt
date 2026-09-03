@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)

package com.dbpprt.dieter.ui

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
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
import androidx.compose.material.icons.outlined.Description
import androidx.compose.material.icons.outlined.Schedule
import androidx.compose.material.icons.outlined.Terminal
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
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
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.dbpprt.dieter.ui.theme.DieterEyes
import com.dbpprt.dieter.ui.theme.DieterShell
import com.dbpprt.dieter.ui.theme.DieterMuted
import com.dbpprt.dieter.ui.theme.DieterOutline
import com.dbpprt.dieter.ui.theme.DieterSurfaceHigh
import com.dbpprt.dieter.v1.Schedule
import com.dbpprt.dieter.v1.MessagePart
import com.dbpprt.dieter.v1.Subagent
import com.dbpprt.dieter.v1.TaskPlan
import com.dbpprt.dieter.v1.UiMessage
import com.dbpprt.dieter.v1.ToolOutput
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.nio.charset.StandardCharsets
import com.dbpprt.dieter.ui.theme.DieterShellTint

@Composable
internal fun MessageParts(
    message: UiMessage,
    model: DieterViewModel,
    compact: Boolean = false,
    showReasoningTraces: Boolean,
    plan: TaskPlan? = null,
    subagents: List<Subagent> = emptyList(),
) {
    val timeline = remember(message, subagents, plan, showReasoningTraces) {
        buildConversationTimeline(
            parts = message.partsList,
            subagents = subagents,
            hasTaskPlan = plan != null,
            showReasoning = showReasoningTraces,
        )
    }
    if (plan != null) TaskPlanBlock(plan)
    timeline.forEachIndexed { index, item ->
        when (item) {
            is ConversationTimelineItem.Tools -> ToolGroup(
                messageId = message.id,
                groupKey = item.parts.firstOrNull()?.toolCallId.orEmpty().ifBlank { index.toString() },
                parts = item.parts,
                model = model,
            )
            ConversationTimelineItem.Subagents -> SubagentBlock(subagents)
            is ConversationTimelineItem.Part -> when (
                item.part.conversationPartPresentation(showReasoningTraces)
            ) {
                ConversationPartPresentation.TEXT -> SelectionContainer {
                    MessageMarkdown(item.part.text, compact)
                }
                ConversationPartPresentation.REASONING -> ReasoningPart(item.part.text)
                ConversationPartPresentation.FILE -> AttachmentPart(item.part)
                ConversationPartPresentation.FALLBACK_TEXT -> MessageMarkdown(item.part.text, compact)
                ConversationPartPresentation.TOOL,
                ConversationPartPresentation.HIDDEN -> Unit
            }
        }
    }
}

internal data class MessageMarkdownBlock(
    val text: String,
    val code: Boolean = false,
    val headingLevel: Int = 0,
)

internal fun parseMessageMarkdown(value: String): List<MessageMarkdownBlock> {
    val blocks = mutableListOf<MessageMarkdownBlock>()
    val pending = mutableListOf<String>()
    var inCode = false

    fun flush() {
        if (pending.isEmpty()) return
        val raw = pending.joinToString("\n").trimEnd()
        pending.clear()
        if (raw.isBlank()) return
        val heading = if (!inCode) raw.takeWhile { it == '#' }.length.takeIf { it in 1..4 } ?: 0 else 0
        val text = if (heading > 0 && raw.getOrNull(heading) == ' ') raw.drop(heading + 1) else raw
        blocks += MessageMarkdownBlock(text = text, code = inCode, headingLevel = heading)
    }

    value.lineSequence().forEach { line ->
        if (line.trimStart().startsWith("```")) {
            flush()
            inCode = !inCode
        } else if (!inCode && line.isBlank()) {
            flush()
        } else if (!inCode && line.trimStart().matches(Regex("^[-*]\\s+.*"))) {
            flush()
            blocks += MessageMarkdownBlock("• " + line.trimStart().drop(2))
        } else {
            pending += line
        }
    }
    flush()
    return blocks
}

@Composable
internal fun MessageMarkdown(value: String, compact: Boolean) {
    val blocks = remember(value) { parseMessageMarkdown(value) }
    Column(verticalArrangement = Arrangement.spacedBy(if (compact) 2.dp else 7.dp)) {
        blocks.forEach { block ->
            if (block.code) {
                Surface(color = DieterSurfaceHigh, shape = RoundedCornerShape(9.dp), modifier = Modifier.fillMaxWidth()) {
                    Text(
                        block.text,
                        color = DieterMuted,
                        fontFamily = FontFamily.Monospace,
                        fontSize = 11.sp,
                        lineHeight = 17.sp,
                        modifier = Modifier.padding(horizontal = 11.dp, vertical = 9.dp),
                    )
                }
            } else {
                val inline = remember(block.text) { markdownInlineText(block.text) }
                Text(
                    inline,
                    fontSize = if (block.headingLevel > 0) 15.sp else 14.sp,
                    fontWeight = if (block.headingLevel > 0) FontWeight.SemiBold else FontWeight.Normal,
                    lineHeight = if (compact) 20.sp else 21.sp,
                )
            }
        }
    }
}

internal val inlineMarkdownPattern = Regex("(\\*\\*([^*]+)\\*\\*|`([^`]+)`|\\[([^]]+)]\\(([^)]+)\\))")

internal fun markdownInlineText(value: String): AnnotatedString = buildAnnotatedString {
    var cursor = 0
    inlineMarkdownPattern.findAll(value).forEach { match ->
        append(value.substring(cursor, match.range.first))
        when {
            match.groupValues[2].isNotEmpty() -> pushStyle(SpanStyle(fontWeight = FontWeight.SemiBold))
            match.groupValues[3].isNotEmpty() -> pushStyle(
                SpanStyle(color = DieterShell, background = DieterSurfaceHigh, fontFamily = FontFamily.Monospace),
            )
            else -> pushStyle(SpanStyle(color = DieterShell, textDecoration = TextDecoration.Underline))
        }
        append(match.groupValues[2].ifEmpty { match.groupValues[3].ifEmpty { match.groupValues[4] } })
        pop()
        cursor = match.range.last + 1
    }
    append(value.substring(cursor))
}

@Composable
internal fun TaskPlanBlock(plan: TaskPlan) {
    val tasks = plan.phasesList.flatMap { it.tasksList }
    val active = plan.state == "active" && tasks.any { it.status == "in_progress" }
    var expanded by remember(plan.id, plan.revision) { mutableStateOf(active) }
    val completed = tasks.count { it.status == "completed" || it.status == "abandoned" }
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
                Text("$completed/${tasks.size}", color = DieterMuted, fontSize = 10.sp)
            }
            if (expanded) {
                Column(Modifier.padding(start = 31.dp, end = 9.dp, bottom = 9.dp), verticalArrangement = Arrangement.spacedBy(5.dp)) {
                    if (plan.explanation.isNotBlank()) Text(plan.explanation, color = DieterMuted, fontSize = 10.sp, lineHeight = 14.sp)
                    plan.phasesList.forEach { phase ->
                        if (phase.name.isNotBlank()) Text(phase.name.uppercase(), color = DieterMuted, fontSize = 9.sp, fontWeight = FontWeight.SemiBold)
                        phase.tasksList.forEach { task ->
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
                                        if (task.status == "in_progress" && task.activeForm.isNotBlank()) task.activeForm else task.content,
                                        color = if (task.status == "completed" || task.status == "abandoned") DieterMuted else MaterialTheme.colorScheme.onSurface,
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
    val active = subagents.any { it.status == "running" || it.status == "pending" }
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
                    Surface(shape = RoundedCornerShape(8.dp), color = DieterSurfaceHigh, modifier = Modifier.fillMaxWidth()) {
                        Column(Modifier.padding(horizontal = 9.dp, vertical = 7.dp), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                if (subagent.status == "running") CircularProgressIndicator(Modifier.size(11.dp), strokeWidth = 1.4.dp, color = DieterShell)
                                else Icon(if (subagent.status == "completed") Icons.Outlined.CheckCircle else Icons.Outlined.Cancel, null, tint = if (subagent.status == "completed") DieterEyes else DieterMuted, modifier = Modifier.size(12.dp))
                                Spacer(Modifier.width(6.dp))
                                Text(
                                    cleanSubagentTitle(subagent.task.ifBlank { subagent.name.ifBlank { subagent.agentType } }),
                                    Modifier.weight(1f),
                                    fontSize = 10.sp,
                                    fontWeight = FontWeight.SemiBold,
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis,
                                )
                                Text(subagent.status, color = DieterMuted, fontSize = 8.sp)
                            }
                            val activity = subagent.activity.ifBlank { subagent.description }
                            if (activity.isNotBlank()) Text(activity, color = DieterMuted, fontSize = 9.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                            val metrics = listOfNotNull(
                                subagent.model.takeIf(String::isNotBlank),
                                subagent.toolCount.takeIf { it > 0 }?.let { "$it tools" },
                            ) + subagentUsageMetrics(subagent.tokens, subagent.contextTokens, subagent.contextWindow)
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
internal fun AgentWorkingIndicator(toolName: String) {
    val transition = rememberInfiniteTransition(label = "agent-working")
    val phase by transition.animateFloat(
        initialValue = 0f,
        targetValue = 3f,
        animationSpec = infiniteRepeatable(tween(900, easing = LinearEasing)),
        label = "typing-phase",
    )
    Row(
        Modifier.fillMaxWidth().padding(top = 2.dp, bottom = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        AgentAvatar()
        Spacer(Modifier.width(10.dp))
        Surface(color = DieterSurfaceHigh, shape = RoundedCornerShape(17.dp)) {
            Row(
                Modifier.padding(horizontal = 11.dp, vertical = 9.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                Text(
                    agentWorkingLabel(toolName),
                    color = DieterMuted,
                    fontSize = 11.sp,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                repeat(3) { index ->
                    val active = phase.toInt().coerceIn(0, 2) == index
                    Box(
                        Modifier.size(if (active) 5.dp else 4.dp)
                            .clip(CircleShape)
                            .background(DieterShell.copy(alpha = if (active) 1f else 0.35f)),
                    )
                }
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
    key2 = part.data,
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
                Text(attachmentDetails(part), color = DieterMuted, fontSize = 10.sp, maxLines = 1)
            }
        }
    }
}

internal data class ToolCategory(val key: String, val singular: String, val plural: String)

internal fun toolCategory(part: MessagePart): ToolCategory {
    val name = part.toolName.ifBlank { part.type }.lowercase()
    return when {
        Regex("bash|shell|terminal|exec|command").containsMatchIn(name) -> ToolCategory("command", "command", "commands")
        Regex("apply.?patch|edit|replace").containsMatchIn(name) -> ToolCategory("edit", "edit", "edits")
        Regex("write|create.?file").containsMatchIn(name) -> ToolCategory("write", "write", "writes")
        Regex("read|view.?file").containsMatchIn(name) -> ToolCategory("read", "read", "reads")
        Regex("grep|glob|search|find").containsMatchIn(name) -> ToolCategory("search", "search", "searches")
        Regex("browser|navigate|click|screenshot").containsMatchIn(name) -> ToolCategory("browser", "browser action", "browser actions")
        else -> ToolCategory("tool", "tool call", "tool calls")
    }
}

internal fun toolGroupLabel(parts: List<MessagePart>): String {
    val counts = linkedMapOf<String, Pair<ToolCategory, Int>>()
    parts.forEach { part ->
        val category = toolCategory(part)
        counts[category.key] = category to ((counts[category.key]?.second ?: 0) + 1)
    }
    return counts.values.joinToString(", ") { (category, count) ->
        "$count ${if (count == 1) category.singular else category.plural}"
    }
}

internal fun displayToolName(name: String): String = name
    .removePrefix("tool-")
    .replace('_', ' ')
    .replace('-', ' ')
    .trim()
    .ifBlank { "Tool" }

internal fun toolPreview(part: MessagePart): String {
    val value = part.inputPreview.ifBlank {
        part.inputJson.toString(StandardCharsets.UTF_8).trim().replace(Regex("\\s+"), " ")
    }.ifBlank { part.outputPreview }
    return if (value.length > 140) value.take(137) + "…" else value
}

@Composable
internal fun ToolGroup(messageId: String, groupKey: String, parts: List<MessagePart>, model: DieterViewModel) {
    if (parts.isEmpty()) return
    var expanded by remember(messageId, groupKey) { mutableStateOf(false) }
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
            Text(toolGroupLabel(parts), color = DieterMuted, fontSize = 11.sp, fontWeight = FontWeight.Medium)
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
                parts.forEach { part -> ToolItem(messageId, part, model) }
            }
        }
    }
}

@Composable
internal fun ToolItem(messageId: String, part: MessagePart, model: DieterViewModel) {
    var expanded by remember(part.toolCallId, part.payloadRevision) { mutableStateOf(false) }
    var payload by remember(part.toolCallId, part.payloadRevision) { mutableStateOf<ToolOutput?>(null) }
    var loading by remember(part.toolCallId, part.payloadRevision) { mutableStateOf(false) }
    var error by remember(part.toolCallId, part.payloadRevision) { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()
    val input = (payload?.inputJson ?: part.inputJson).toString(StandardCharsets.UTF_8).trim()
    val output = (payload?.outputJson ?: part.outputJson).toString(StandardCharsets.UTF_8).trim()
    fun toggle() {
        expanded = !expanded
        if (expanded && payload == null && !loading && (part.hasInput || part.hasOutput)) {
            loading = true
            scope.launch {
                runCatching { model.loadToolOutput(messageId, part) }
                    .onSuccess { payload = it; error = null }
                    .onFailure { error = it.message ?: "Could not load tool details" }
                loading = false
            }
        }
    }
    Column(Modifier.fillMaxWidth()) {
        Row(
            Modifier.fillMaxWidth().clip(RoundedCornerShape(5.dp)).clickable { toggle() }
                .padding(horizontal = 6.dp, vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(Icons.Outlined.Terminal, null, tint = DieterMuted, modifier = Modifier.size(13.dp))
            Spacer(Modifier.width(6.dp))
            Text(
                displayToolName(part.toolName.ifBlank { part.type }),
                color = DieterMuted,
                fontSize = 10.sp,
                fontWeight = FontWeight.SemiBold,
            )
            val preview = toolPreview(part)
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
            val payloadError = payload?.errorText.orEmpty().ifBlank { part.errorText }
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

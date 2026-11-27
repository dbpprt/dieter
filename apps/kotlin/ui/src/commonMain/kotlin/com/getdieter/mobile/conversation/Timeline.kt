@file:OptIn(
    androidx.compose.material3.ExperimentalMaterial3Api::class,
    androidx.compose.foundation.layout.ExperimentalLayoutApi::class,
)

package com.getdieter.mobile.conversation

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.expandVertically
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.shrinkVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.dropShadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.lerp
import androidx.compose.ui.graphics.shadow.Shadow
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.DpOffset
import androidx.compose.ui.unit.dp
import com.getdieter.api.v1.MessagePart
import com.getdieter.api.v1.ToolOutput
import com.getdieter.client.v1.*
import com.getdieter.mobile.app.*
import com.getdieter.mobile.channels.PeerNoticeCard
import com.getdieter.mobile.design.*

/** One row of the transcript. */
@Composable
internal fun TimelineRow(
    row: TimelineItem,
    view: ConversationSlice,
    openUrl: (String) -> Unit,
    onAttachment: (MessagePart) -> Unit,
    onTool: (TimelineStep) -> Unit,
    onCopy: () -> Unit,
) {
    var expanded by rememberSaveable(row.id) { mutableStateOf(false) }
    if (row.activity && !expanded) {
        ActivitySummaryRow(row.summary, false) { expanded = true }
        return
    }
    if (row.user) {
        UserMessage(row, view, openUrl, onAttachment, onCopy)
        return
    }
    val menu = rememberMenuState()
    MenuAnchor(menu) {
        Column(
            Modifier.fillMaxWidth()
                .then(
                    if (row.copyable)
                        Modifier.pressable(
                            onClick = {},
                            onLongClick = {
                                menu.show(
                                    listOf(
                                        MenuSection(
                                            listOf(
                                                ChromeAction(
                                                    "copy",
                                                    "Copy",
                                                    Glyph.COPY,
                                                    onClick = onCopy,
                                                )
                                            )
                                        )
                                    )
                                )
                            },
                            role = null,
                        )
                    else Modifier
                )
                .padding(horizontal = ScreenMargin + 2.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            if (row.activity)
                ActivitySummaryRow(row.summary, true, padded = false) { expanded = false }
            row.groups.forEach { group ->
                var open by rememberSaveable(group.id) { mutableStateOf(false) }
                if (group.activity && !row.activity)
                    ActivitySummaryRow(group.summary, open, padded = false) { open = !open }
                if (!group.activity || open || row.activity)
                    StepList(group.steps, row, view, openUrl, onAttachment, onTool)
            }
            view.conversation
                ?.task_plans
                .orEmpty()
                .filter { it.id in row.plan_ids }
                .forEach { TaskPlanCard(it) }
        }
    }
}

/**
 * A group's steps in order. Consecutive tool calls share one card with a rail between them, so a
 * burst of reads and edits reads as one piece of work rather than a stack of pills.
 */
@Composable
private fun StepList(
    steps: List<TimelineStep>,
    row: TimelineItem,
    view: ConversationSlice,
    openUrl: (String) -> Unit,
    onAttachment: (MessagePart) -> Unit,
    onTool: (TimelineStep) -> Unit,
) {
    var index = 0
    while (index < steps.size) {
        val step = steps[index]
        if (step.kind == TimelineStepKind.TIMELINE_STEP_KIND_TOOL) {
            var end = index
            while (
                end + 1 < steps.size &&
                    steps[end + 1].kind == TimelineStepKind.TIMELINE_STEP_KIND_TOOL
            ) end++
            ToolSteps(steps.subList(index, end + 1), onTool)
            index = end + 1
            continue
        }
        TimelineStepView(step, row, view, openUrl, onAttachment)
        index++
    }
}

@Composable
private fun TimelineStepView(
    step: TimelineStep,
    row: TimelineItem,
    view: ConversationSlice,
    openUrl: (String) -> Unit,
    onAttachment: (MessagePart) -> Unit,
) {
    val part =
        view.messages.firstOrNull { it.id == step.message_id }?.parts?.getOrNull(step.part_index)
    val text = step.text.ifEmpty { part?.text.orEmpty() }
    when (step.kind) {
        TimelineStepKind.TIMELINE_STEP_KIND_REASONING ->
            if (text.isNotBlank()) ReasoningRow(step.id, text)
        TimelineStepKind.TIMELINE_STEP_KIND_SUBAGENTS ->
            view.conversation
                ?.subagents
                .orEmpty()
                .filter { it.id in row.subagent_ids }
                .forEach { SubagentCard(it) }
        TimelineStepKind.TIMELINE_STEP_KIND_ATTACHMENT ->
            part?.let { AttachmentTile(it) { onAttachment(it) } }
        TimelineStepKind.TIMELINE_STEP_KIND_PEER_NOTICE -> {
            val store = LocalMobileStore.current
            val notice = step.peer_notice
            if (notice != null) PeerNoticeCard(notice, openUrl) { store?.openChannel(it) }
            else if (text.isNotEmpty()) RichText(text, openUrl)
        }
        else -> if (text.isNotEmpty()) RichText(text, openUrl)
    }
}

/** The agent's reasoning behind a "Thinking" disclosure; open by default, so nothing is lost. */
@Composable
private fun ReasoningRow(id: String, text: String) {
    var open by rememberSaveable(id) { mutableStateOf(true) }
    val secondary = palette.secondaryLabel
    Column(Modifier.fillMaxWidth()) {
        Row(
            Modifier.clip(CircleShape)
                .pressable(onClick = { open = !open })
                .padding(vertical = 4.dp, horizontal = 4.dp)
                .semantics { contentDescription = (if (open) "Hide " else "Show ") + "thinking" },
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            Icon(Glyph.BRAIN, null, tint = secondary, size = 14.dp, weight = GlyphWeight.MEDIUM)
            Text(
                "Thinking",
                style = type.footnote.copy(fontWeight = FontWeight.SemiBold),
                color = secondary,
            )
            DisclosureChevron(open)
        }
        AnimatedVisibility(
            open,
            enter = expandVertically(Motion.settle()) + fadeIn(),
            exit = shrinkVertically(Motion.settle()) + fadeOut(),
        ) {
            Row(Modifier.padding(start = 6.dp, top = 2.dp).height(IntrinsicSize.Min)) {
                Box(Modifier.width(2.dp).fillMaxHeight().background(palette.separator, CircleShape))
                Spacer(Modifier.width(12.dp))
                Text(
                    text,
                    style = type.subheadline.copy(fontStyle = FontStyle.Italic),
                    color = secondary,
                    maxLines = 40,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
    }
}

@Composable
private fun UserMessage(
    row: TimelineItem,
    view: ConversationSlice,
    openUrl: (String) -> Unit,
    onAttachment: (MessagePart) -> Unit,
    onCopy: () -> Unit,
) {
    val menu = rememberMenuState()
    val steps = row.groups.flatMap { it.steps }
    Column(
        Modifier.fillMaxWidth().padding(horizontal = ScreenMargin),
        horizontalAlignment = Alignment.End,
    ) {
        if (row.origin_label.isNotEmpty())
            // A turn an agent channel message started, not the user.
            Row(
                Modifier.padding(bottom = 4.dp, end = 6.dp).testTag("message-origin-${row.id}"),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                Icon(Glyph.TAG, null, tint = palette.info, size = 11.dp, weight = GlyphWeight.BOLD)
                Text(
                    row.origin_label,
                    style = type.caption.copy(fontWeight = FontWeight.SemiBold),
                    color = palette.info,
                )
            }
        steps
            .filter { it.kind == TimelineStepKind.TIMELINE_STEP_KIND_ATTACHMENT }
            .forEach { step ->
                view.messages
                    .firstOrNull { it.id == step.message_id }
                    ?.parts
                    ?.getOrNull(step.part_index)
                    ?.let { part ->
                        AttachmentTile(part, Modifier.padding(bottom = 6.dp)) { onAttachment(part) }
                    }
            }
        val text =
            steps
                .filter { it.kind != TimelineStepKind.TIMELINE_STEP_KIND_ATTACHMENT }
                .joinToString("\n\n") { step ->
                    step.text.ifEmpty {
                        view.messages
                            .firstOrNull { it.id == step.message_id }
                            ?.parts
                            ?.getOrNull(step.part_index)
                            ?.text
                            .orEmpty()
                    }
                }
                .trim()
        if (text.isNotEmpty())
            MenuAnchor(menu) {
                val shape = userBubbleShape()
                Box(
                    Modifier.widthIn(max = 560.dp)
                        .fillMaxWidth(.86f)
                        .wrapContentWidth(Alignment.End)
                        .then(
                            if (!apple && !palette.dark)
                                Modifier.dropShadow(
                                    shape,
                                    Shadow(
                                        radius = 10.dp,
                                        color = Color.Black.copy(alpha = .08f),
                                        offset = DpOffset(0.dp, 3.dp),
                                    ),
                                )
                            else Modifier
                        )
                        .clip(shape)
                        .background(userBubbleBrush())
                        .then(if (row.unconfirmed) Modifier.graphicsAlpha(.6f) else Modifier)
                        .pressable(
                            onClick = {},
                            onLongClick = {
                                menu.show(
                                    listOf(
                                        MenuSection(
                                            listOf(
                                                ChromeAction(
                                                    "copy",
                                                    "Copy",
                                                    Glyph.COPY,
                                                    onClick = onCopy,
                                                )
                                            )
                                        )
                                    )
                                )
                            },
                            role = null,
                        )
                        .padding(horizontal = 15.dp, vertical = 11.dp)
                ) {
                    CompositionLocalProvider(
                        androidx.compose.material3.LocalContentColor provides
                            if (apple) palette.label else colors.onPrimaryContainer
                    ) {
                        RichText(text, openUrl)
                    }
                }
            }
        val delivery = row.delivery
        if (
            row.delivery_label.isNotEmpty() &&
                delivery != MessageDelivery.MESSAGE_DELIVERY_SYNCED &&
                delivery != MessageDelivery.MESSAGE_DELIVERY_UNSPECIFIED
        )
            Text(
                row.delivery_label,
                Modifier.padding(top = 4.dp, end = 6.dp),
                style = type.caption,
                color =
                    if (delivery == MessageDelivery.MESSAGE_DELIVERY_FAILED) palette.destructive
                    else palette.secondaryLabel,
            )
    }
}

/** iOS keeps its even bubble; Android's grows a tail toward the sender's edge. */
@Composable
@ReadOnlyComposable
private fun userBubbleShape(): Shape =
    if (apple) RoundedCornerShape(20.dp)
    else RoundedCornerShape(topStart = 22.dp, topEnd = 22.dp, bottomEnd = 8.dp, bottomStart = 22.dp)

/** The bubble's fill: iOS's grey, or a tinted gradient that is a little deeper at the top. */
@Composable
@ReadOnlyComposable
private fun userBubbleBrush(): Brush {
    if (apple) {
        val grey = if (palette.dark) Color(0xFF2C2C2E) else Color(0xFFE9E9EB)
        return Brush.linearGradient(listOf(grey, grey))
    }
    val base = colors.primaryContainer
    val deep = lerp(base, colors.primary, if (palette.dark) .16f else .1f)
    return Brush.linearGradient(
        0f to deep,
        1f to base,
        start = Offset.Zero,
        end = Offset(600f, 400f),
    )
}

/** "Reasoning · 1 edit · 1 command": the disclosure over a run of routine work. */
@Composable
private fun ActivitySummaryRow(
    summary: String,
    open: Boolean,
    padded: Boolean = true,
    toggle: () -> Unit,
) {
    val tint = if (open) palette.label else palette.secondaryLabel
    Row(
        Modifier.then(if (padded) Modifier.padding(horizontal = ScreenMargin) else Modifier)
            .clip(CircleShape)
            .background(
                if (open) Color.Transparent
                else palette.fill.copy(alpha = palette.fill.alpha * .55f)
            )
            .pressable(onClick = toggle)
            .padding(vertical = 5.dp, horizontal = if (open) 4.dp else 10.dp)
            .semantics { contentDescription = (if (open) "Hide " else "Show ") + summary },
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(Glyph.SPARKLES, null, tint = tint, size = 14.dp)
        Spacer(Modifier.width(7.dp))
        Text(
            summary.ifEmpty { "Agent activity" },
            style = type.footnote.copy(fontWeight = FontWeight.Medium),
            color = tint,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
        Spacer(Modifier.width(5.dp))
        DisclosureChevron(open, tint)
    }
}

/** A run of tool calls as one card: each a row with the tool's glyph, its title and its state. */
@Composable
private fun ToolSteps(steps: List<TimelineStep>, onTool: (TimelineStep) -> Unit) {
    val shape = RoundedCornerShape(16.dp)
    val rail = palette.separator
    Column(
        Modifier.fillMaxWidth()
            .clip(shape)
            .background(palette.fill.copy(alpha = palette.fill.alpha * .55f))
            .then(
                if (apple) Modifier.border(.5.dp, palette.separator.copy(alpha = .5f), shape)
                else Modifier
            )
            .testTag("tool-steps")
    ) {
        steps.forEachIndexed { index, step ->
            ToolStepRow(
                step,
                first = index == 0,
                last = index == steps.lastIndex,
                rail = rail,
                onClick = { onTool(step) },
            )
        }
    }
}

@Composable
private fun ToolStepRow(
    step: TimelineStep,
    first: Boolean,
    last: Boolean,
    rail: Color,
    onClick: () -> Unit,
) {
    val running = step.tool_status == ToolCallStatus.TOOL_CALL_STATUS_RUNNING
    val done = step.tool_status == ToolCallStatus.TOOL_CALL_STATUS_COMPLETED
    val statusTint =
        when {
            step.tool_attention -> palette.destructive
            running -> palette.accent
            else -> palette.secondaryLabel
        }
    val glyphTint = if (step.tool_attention) palette.destructive else palette.secondaryLabel
    Row(
        Modifier.fillMaxWidth()
            .pressable(onClick = onClick, highlight = true)
            .drawBehind {
                // The rail joins the glyph circles of consecutive steps.
                val x = (12 + 12).dp.toPx()
                val radius = 12.dp.toPx()
                if (!first)
                    drawLine(rail, Offset(x, 0f), Offset(x, center.y - radius), 1.5.dp.toPx())
                if (!last)
                    drawLine(
                        rail,
                        Offset(x, center.y + radius),
                        Offset(x, size.height),
                        1.5.dp.toPx(),
                    )
            }
            .padding(start = 12.dp, end = 10.dp, top = 7.dp, bottom = 7.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            Modifier.size(24.dp)
                .background(
                    if (step.tool_attention) palette.destructive.copy(alpha = .14f)
                    else palette.cell,
                    CircleShape,
                ),
            contentAlignment = Alignment.Center,
        ) {
            Icon(toolGlyph(step.tool_title), null, tint = glyphTint, size = 13.dp)
        }
        Spacer(Modifier.width(10.dp))
        Text(
            step.tool_title.ifEmpty { "Tool" },
            Modifier.weight(1f),
            style = type.footnote.copy(fontWeight = FontWeight.Medium),
            color = palette.label,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
        Spacer(Modifier.width(8.dp))
        when {
            running -> Spinner(Modifier.size(13.dp), color = palette.accent)
            done ->
                Icon(
                    Glyph.CHECK,
                    step.tool_status_label.ifEmpty { "Completed" },
                    tint = palette.success,
                    size = 13.dp,
                    weight = GlyphWeight.BOLD,
                )
            else ->
                Text(
                    step.tool_status_label,
                    style = type.caption.copy(fontWeight = FontWeight.Medium),
                    color = statusTint,
                    maxLines = 1,
                )
        }
        Spacer(Modifier.width(6.dp))
        Icon(
            Glyph.CHEVRON_RIGHT,
            null,
            tint = palette.tertiaryLabel,
            size = 11.dp,
            weight = GlyphWeight.SEMIBOLD,
        )
    }
}

/** A glyph for what the tool does, read from its title ("read file", "bash", "edit", …). */
private fun toolGlyph(title: String): Glyph {
    val t = title.lowercase()
    return when {
        "search" in t || "grep" in t || "glob" in t || "find" in t -> Glyph.SEARCH
        "edit" in t || "write" in t || "patch" in t || "apply" in t -> Glyph.EDIT
        "read" in t || "file" in t || "open" in t -> Glyph.DOC_TEXT
        "web" in t || "fetch" in t || "http" in t || "browse" in t -> Glyph.GLOBE
        "agent" in t || "task" in t || "delegate" in t -> Glyph.SUBAGENTS
        "list" in t || "ls" == t || "dir" in t -> Glyph.FOLDER
        "git" in t || "commit" in t || "branch" in t -> Glyph.BRANCH
        else -> Glyph.TERMINAL
    }
}

@Composable
private fun AttachmentTile(part: MessagePart, modifier: Modifier = Modifier, onClick: () -> Unit) {
    Row(
        modifier
            .widthIn(max = 300.dp)
            .clip(RoundedCornerShape(14.dp))
            .background(palette.cell)
            .border(.5.dp, palette.separator.copy(alpha = .5f), RoundedCornerShape(14.dp))
            .pressable(onClick = onClick, highlight = true)
            .padding(10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            Modifier.size(36.dp).clip(RoundedCornerShape(8.dp)).background(palette.fill),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                if (part.media_type.startsWith("image/")) Glyph.IMAGE else Glyph.FILE_PLAIN,
                null,
                tint = palette.secondaryLabel,
                size = 18.dp,
            )
        }
        Spacer(Modifier.width(10.dp))
        Column(Modifier.weight(1f, fill = false)) {
            Text(
                part.filename.ifEmpty { "Attachment" },
                style = type.subheadline.copy(fontWeight = FontWeight.Medium),
                color = palette.label,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                com.getdieter.core.composition.Attachments.details(part),
                style = type.caption,
                color = palette.secondaryLabel,
                maxLines = 1,
            )
        }
    }
}

@Composable
internal fun ToolOutputSheet(tool: ToolOutput, onDismiss: () -> Unit) {
    Sheet(tool.tool_name.ifEmpty { "Tool" }, onDismiss) {
        Column(
            Modifier.padding(horizontal = 20.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text(tool.state, style = type.subheadline, color = palette.secondaryLabel)
            listOf(
                    "Input" to tool.input_json.utf8(),
                    "Output" to tool.output_json.utf8(),
                    "Error" to tool.error_text,
                )
                .filter { it.second.isNotEmpty() }
                .forEach { (title, body) ->
                    FormLabel(title)
                    SelectionContainer {
                        Text(
                            body,
                            Modifier.fillMaxWidth()
                                .clip(RoundedCornerShape(14.dp))
                                .background(palette.cell)
                                .horizontalScroll(rememberScrollState())
                                .padding(12.dp),
                            style = type.mono,
                            color = if (title == "Error") palette.destructive else palette.label,
                        )
                    }
                }
        }
    }
}

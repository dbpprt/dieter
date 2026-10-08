@file:OptIn(
    androidx.compose.material3.ExperimentalMaterial3Api::class,
    androidx.compose.foundation.layout.ExperimentalLayoutApi::class,
)

package com.dbpprt.dieter.mobile

import androidx.compose.animation.*
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.dbpprt.dieter.api.v1.MessagePart
import com.dbpprt.dieter.api.v1.Subagent
import com.dbpprt.dieter.api.v1.ToolOutput
import com.dbpprt.dieter.client.v1.*
import com.dbpprt.dieter.core.presentation.SubagentPresentation
import com.dbpprt.dieter.core.presentation.TaskPlans
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch

@Composable
internal fun ConversationScreen(store: MobileStore, cardId: String, openUrl: (String) -> Unit) {
    val view by store.conversation.collectAsState()
    val selected by store.selectedCard.collectAsState()
    var editing by remember { mutableStateOf(false) }
    val workspace by store.workspace.collectAsState()
    val current = selected == cardId || view.card_id == cardId
    val card = view.card.takeIf { current }
    // The board already knows the title while the transcript loads.
    val known = card ?: workspace.cards.firstOrNull { it.id == cardId }
    val chat = known?.scope == "chat"
    val subagents = view.conversation?.subagents.orEmpty()
    val chrome =
        ScreenChrome(
            known?.title?.ifBlank { null } ?: if (chat) "Chat" else "Conversation",
            subtitle =
                listOfNotNull(view.project?.name, if (chat) "Chat" else view.board?.name)
                    .filter { it.isNotBlank() }
                    .joinToString(" · "),
            actions =
                listOfNotNull(
                    if (!chat)
                        ChromeAction("pane-changes", "Changes", Glyph.CHANGES) {
                            store.push(MobileRoute.Pane(cardId, CardPane.CHANGES))
                        }
                    else null,
                    ChromeAction(
                        "conversation-menu",
                        "Conversation actions",
                        Glyph.MORE_HORIZONTAL,
                        menu =
                            conversationMenu(store, view, cardId, subagents.size) {
                                editing = true
                            },
                    ),
                ),
        )
    Screen(chrome, listState = rememberLazyListState()) {
        if (!current || (view.loading && view.timeline.isEmpty())) {
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Spinner(Modifier.size(28.dp))
            }
            return@Screen
        }
        Transcript(store, view, cardId, openUrl, padding)
    }
    if (editing) card?.let { CardEditSheet(store, it) { editing = false } }
}

private fun conversationMenu(
    store: MobileStore,
    view: ConversationSlice,
    cardId: String,
    subagents: Int,
    edit: () -> Unit,
): List<MenuSection> {
    val card = view.card
    val chat = card?.scope == "chat"
    val panes =
        CardPane.entries
            .filter { !(chat && it == CardPane.CHANGES) }
            .map { pane ->
                ChromeAction(
                    "pane-${pane.name.lowercase()}",
                    if (pane == CardPane.SUBAGENTS && subagents > 0) "${pane.title} ($subagents)"
                    else pane.title,
                    pane.glyph,
                ) {
                    store.push(MobileRoute.Pane(cardId, pane))
                }
            }
    val agent = buildList {
        if (view.state?.can_start == true)
            add(ChromeAction("start", "Start agent", Glyph.PLAY) { store.start() })
        if (view.state?.can_halt == true)
            add(ChromeAction("stop", "Stop agent", Glyph.STOP, destructive = true) { store.stop() })
        add(
            ChromeAction("refresh", "Refresh", Glyph.REFRESH) {
                store.command(Command(refresh_conversation = RefreshConversation(cardId)))
            }
        )
    }
    val organize =
        card
            ?.let {
                listOf(
                    MenuSection(
                        listOf(ChromeAction("edit-${it.id}", "Edit…", Glyph.EDIT) { edit() })
                    )
                ) + cardMenuSections(store, it).drop(1)
            }
            .orEmpty()
    return listOf(MenuSection(panes), MenuSection(agent)) + organize
}

@Composable
private fun Transcript(
    store: MobileStore,
    view: ConversationSlice,
    selected: String,
    openUrl: (String) -> Unit,
    padding: PaddingValues,
) {
    val busy by store.busy.collectAsState()
    val drafts by store.draftTexts.collectAsState()
    var draft by rememberSaveable(selected) { mutableStateOf(drafts[selected].orEmpty()) }
    LaunchedEffect(drafts[selected]) { if (draft.isEmpty()) draft = drafts[selected].orEmpty() }
    var agentSheet by remember(selected) { mutableStateOf(false) }
    var following by rememberSaveable(selected) { mutableStateOf(true) }
    var toolOutput by remember(selected) { mutableStateOf<ToolOutput?>(null) }
    val list = rememberLazyListState()
    val coroutine = rememberCoroutineScope()
    val clipboard = LocalClipboardManager.current
    var attachments by remember(selected) { mutableStateOf<List<MessagePart>>(emptyList()) }
    val pick =
        rememberAttachmentPicker(
            { added ->
                com.dbpprt.dieter.core.composition.Attachments.appending(attachments, added)
                    .fold({ attachments = it }, { store.error.value = it.message.orEmpty() })
            },
            { store.error.value = it },
        )
    val preview = rememberAttachmentViewer { store.error.value = it }
    // Only the person's own scrolling decides whether the transcript follows new output.
    LaunchedEffect(list, selected) {
        snapshotFlow { list.isScrollInProgress }
            .distinctUntilChanged()
            .drop(1)
            .collect { scrolling ->
                if (!scrolling && list.layoutInfo.totalItemsCount > 0)
                    following = !list.canScrollForward
            }
    }
    var landed by remember(selected) { mutableStateOf(false) }
    LaunchedEffect(
        view.timeline.size,
        view.timeline.lastOrNull()?.groups?.size,
        view.state?.working,
        view.loading,
    ) {
        if (!following && landed) return@LaunchedEffect
        val count = snapshotFlow { list.layoutInfo.totalItemsCount }.first { it > 0 }
        // Applied by the next measure pass; this can resume while the list is being laid out.
        list.requestScrollToItem(count - 1)
        if (view.timeline.isNotEmpty()) landed = true
    }
    val state = view.state
    fun loadTool(step: TimelineStep) = store.action {
        val part =
            view.messages
                .firstOrNull { it.id == step.message_id }
                ?.parts
                ?.getOrNull(step.part_index) ?: return@action
        toolOutput =
            store.core
                .dispatch(
                    Command(
                        load_tool_output =
                            LoadToolOutput(
                                selected,
                                step.message_id,
                                part.tool_call_id,
                                part.payload_revision,
                            )
                    )
                )
                .tool_output
    }
    Column(Modifier.fillMaxSize().imePadding()) {
        Box(Modifier.weight(1f)) {
            LazyColumn(
                Modifier.fillMaxSize().testTag("conversation-timeline"),
                state = list,
                contentPadding =
                    PaddingValues(top = padding.calculateTopPadding() + 8.dp, bottom = 12.dp),
                verticalArrangement = Arrangement.spacedBy(14.dp),
            ) {
                if (view.error.isNotBlank())
                    item("error") {
                        Banner(
                            "Conversation unavailable",
                            view.error,
                            Modifier.padding(horizontal = ScreenMargin),
                            tone = Tone.DANGER,
                            actionLabel = "Retry",
                            onAction = {
                                store.command(
                                    Command(refresh_conversation = RefreshConversation(selected))
                                )
                            },
                        )
                    }
                if (view.has_earlier)
                    item("history") {
                        Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
                            DButton(
                                if (view.loading_earlier) "Loading…" else "Show earlier messages",
                                store::loadEarlier,
                                kind = ButtonKind.TONAL,
                                glyph = Glyph.HISTORY,
                                loading = view.loading_earlier,
                            )
                        }
                    }
                state
                    ?.unsent_task
                    ?.takeIf { it.isNotBlank() }
                    ?.let { task ->
                        item("unsent-task") {
                            UnsentTask(store, task, state.can_start, busy, openUrl)
                        }
                    }
                items(view.timeline, key = { it.id }) { row ->
                    TimelineRow(
                        row,
                        view,
                        openUrl,
                        onAttachment = preview,
                        onTool = ::loadTool,
                        onCopy = {
                            clipboard.setText(AnnotatedString(rowText(row, view)))
                        },
                    )
                }
                view.conversation
                    ?.task_plans
                    .orEmpty()
                    .filter { it.id in view.unattached_plan_ids }
                    .forEach { plan ->
                        item("plan-${plan.id}") {
                            TaskPlanCard(plan, Modifier.padding(horizontal = ScreenMargin))
                        }
                    }
                if (state?.working == true) item("working") { WorkingIndicator(state) }
                view.conversation?.provider_status?.let { provider ->
                    item("provider-status") {
                        Banner(
                            "Provider",
                            provider.message,
                            Modifier.padding(horizontal = ScreenMargin),
                            tone = Tone.WARNING,
                        )
                    }
                }
                view.turn_failure?.let { failure ->
                    item("turn-failure") {
                        Banner(
                            "The turn failed",
                            failure.summary,
                            Modifier.padding(horizontal = ScreenMargin),
                            tone = Tone.DANGER,
                            actionLabel = if (failure.retryable) "Retry" else null,
                            onAction = if (failure.retryable) store::retryTurn else null,
                        )
                    }
                }
                items(view.conversation?.queue.orEmpty(), key = { "queue-${it.id}" }) { queued ->
                    QueuedMessage(
                        queued.text,
                        canSteer = state?.steerable_id == queued.id,
                        onEdit = {
                            store.action {
                                store.core
                                    .dispatch(
                                        Command(
                                            remove_queued_message =
                                                RemoveQueuedMessage(
                                                    selected,
                                                    queued.id,
                                                    edit = true,
                                                )
                                        )
                                    )
                                    .queued_message
                                    ?.let {
                                        draft = it.text
                                        attachments =
                                            it.parts.filter { part -> part.type != "text" }
                                        store.saveDraft(selected, draft)
                                    }
                            }
                        },
                        onRemove = {
                            store.command(
                                Command(
                                    remove_queued_message = RemoveQueuedMessage(selected, queued.id)
                                )
                            )
                        },
                        onSteer = {
                            store.command(
                                Command(steer_conversation = SteerConversation(selected, queued.id))
                            )
                        },
                    )
                }
                item("end") { Spacer(Modifier.height(1.dp)) }
            }
            JumpToLatest(
                !following,
                Modifier.align(Alignment.BottomCenter).padding(bottom = 10.dp),
            ) {
                val jump = {
                    following = true
                    store.command(Command(return_to_latest = ReturnToLatest(selected)))
                    coroutine.launch {
                        if (list.layoutInfo.totalItemsCount > 0)
                            list.animateScrollToItem(list.layoutInfo.totalItemsCount - 1)
                    }
                    Unit
                }
                if (apple)
                    CircleButton(
                        Glyph.ARROW_DOWN,
                        "Jump to latest",
                        jump,
                        Modifier.shadow(
                                6.dp,
                                CircleShape,
                                ambientColor = androidx.compose.ui.graphics.Color.Black.copy(.15f),
                                spotColor = androidx.compose.ui.graphics.Color.Black.copy(.15f),
                            )
                            .background(palette.cell, CircleShape)
                            .border(.5.dp, palette.separator.copy(.4f), CircleShape),
                        size = 40.dp,
                    )
                else
                    androidx.compose.material3.SmallFloatingActionButton(
                        jump,
                        Modifier.semantics { contentDescription = "Jump to latest" },
                        containerColor = colors.surfaceContainerHighest,
                    ) {
                        Icon(Glyph.ARROW_DOWN, null, size = 24.dp)
                    }
            }
        }
        Composer(
            store,
            view,
            selected,
            draft,
            onDraft = {
                draft = it
                store.saveDraft(selected, it)
            },
            attachments = attachments,
            onRemoveAttachment = { index ->
                attachments = attachments.filterIndexed { i, _ -> i != index }
            },
            onAttach = pick,
            busy = busy,
            bottomInset = padding.calculateBottomPadding(),
            onAgent = { agentSheet = true },
            onSend = {
                val text = draft
                val parts = attachments
                store.action {
                    store.send(text, selected, parts)
                    draft = ""
                    attachments = emptyList()
                    following = true
                }
            },
        )
    }
    if (agentSheet)
        Sheet("Agent", { agentSheet = false }, size = SheetSize.MEDIUM) {
            AgentSettings(view.state?.agent) {
                store.command(Command(choose_agent = ChooseAgent(selected, it)))
            }
        }
    toolOutput?.let { tool -> ToolOutputSheet(tool) { toolOutput = null } }
}

private fun rowText(row: TimelineItem, view: ConversationSlice) =
    row.groups
        .flatMap { it.steps }
        .filter { it.kind == TimelineStepKind.TIMELINE_STEP_KIND_TEXT }
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

@Composable
private fun UnsentTask(
    store: MobileStore,
    task: String,
    canStart: Boolean,
    busy: Boolean,
    openUrl: (String) -> Unit,
) {
    ContentCard(Modifier.padding(horizontal = ScreenMargin)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(Glyph.DOC_TEXT, null, tint = palette.secondaryLabel, size = 18.dp)
            Spacer(Modifier.width(8.dp))
            Text("Task", Modifier.weight(1f), style = type.headline, color = palette.label)
            if (canStart)
                DButton(
                    "Start",
                    store::start,
                    glyph = Glyph.PLAY,
                    enabled = !busy,
                    modifier = Modifier.testTag("start-task"),
                )
        }
        Spacer(Modifier.height(8.dp))
        RichText(task, openUrl)
    }
}

@Composable
private fun WorkingIndicator(state: ConversationState) {
    Row(
        Modifier.fillMaxWidth().padding(horizontal = ScreenMargin + 2.dp).semantics(
            mergeDescendants = true
        ) {},
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Spinner(Modifier.size(16.dp))
        Spacer(Modifier.width(10.dp))
        Text(
            state.live_activity.ifEmpty { "Working…" },
            style = type.subheadline,
            color = palette.secondaryLabel,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

@Composable
private fun QueuedMessage(
    text: String,
    canSteer: Boolean,
    onEdit: () -> Unit,
    onRemove: () -> Unit,
    onSteer: () -> Unit,
) {
    Column(
        Modifier.fillMaxWidth().padding(horizontal = ScreenMargin),
        horizontalAlignment = Alignment.End,
    ) {
        Box(
            Modifier.widthIn(max = 520.dp)
                .fillMaxWidth(.85f)
                .clip(RoundedCornerShape(20.dp))
                .border(1.dp, palette.separator, RoundedCornerShape(20.dp))
                .padding(horizontal = 14.dp, vertical = 10.dp)
        ) {
            Text(
                text,
                style = type.body,
                color = palette.secondaryLabel,
                maxLines = 6,
                overflow = TextOverflow.Ellipsis,
            )
        }
        Row(Modifier.padding(top = 4.dp), verticalAlignment = Alignment.CenterVertically) {
            Icon(Glyph.CLOCK, null, tint = palette.secondaryLabel, size = 13.dp)
            Spacer(Modifier.width(4.dp))
            Text("Queued", style = type.footnote, color = palette.secondaryLabel)
            Spacer(Modifier.width(4.dp))
            DButton("Edit", onEdit, kind = ButtonKind.PLAIN)
            DButton("Remove", onRemove, kind = ButtonKind.PLAIN)
            if (canSteer) DButton("Send now", onSteer, kind = ButtonKind.PLAIN)
        }
    }
}

@Composable
private fun TimelineRow(
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
                    group.steps.forEach { step ->
                        TimelineStepView(step, row, view, openUrl, onAttachment, onTool)
                    }
            }
            view.conversation
                ?.task_plans
                .orEmpty()
                .filter { it.id in row.plan_ids }
                .forEach { TaskPlanCard(it) }
        }
    }
}

@Composable
private fun TimelineStepView(
    step: TimelineStep,
    row: TimelineItem,
    view: ConversationSlice,
    openUrl: (String) -> Unit,
    onAttachment: (MessagePart) -> Unit,
    onTool: (TimelineStep) -> Unit,
) {
    val part =
        view.messages.firstOrNull { it.id == step.message_id }?.parts?.getOrNull(step.part_index)
    val text = step.text.ifEmpty { part?.text.orEmpty() }
    when (step.kind) {
        TimelineStepKind.TIMELINE_STEP_KIND_TOOL -> ToolRow(step) { onTool(step) }
        TimelineStepKind.TIMELINE_STEP_KIND_REASONING ->
            if (text.isNotBlank())
                Row {
                    Box(
                        Modifier.width(2.dp)
                            .heightIn(min = 18.dp)
                            .background(palette.separator, CircleShape)
                    )
                    Spacer(Modifier.width(10.dp))
                    Text(
                        text,
                        style = type.subheadline.copy(fontStyle = FontStyle.Italic),
                        color = palette.secondaryLabel,
                        maxLines = 12,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
        TimelineStepKind.TIMELINE_STEP_KIND_SUBAGENTS ->
            view.conversation
                ?.subagents
                .orEmpty()
                .filter { it.id in row.subagent_ids }
                .forEach { SubagentCard(it) }
        TimelineStepKind.TIMELINE_STEP_KIND_ATTACHMENT ->
            part?.let { AttachmentTile(it) { onAttachment(it) } }
        else -> if (text.isNotEmpty()) RichText(text, openUrl)
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
                Box(
                    Modifier.widthIn(max = 560.dp)
                        .fillMaxWidth(.86f)
                        .wrapContentWidth(Alignment.End)
                        .clip(RoundedCornerShape(if (apple) 20.dp else 22.dp))
                        .background(if (apple) userBubbleApple() else colors.primaryContainer)
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
                        .padding(horizontal = 14.dp, vertical = 10.dp)
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

@Composable
private fun userBubbleApple() =
    if (palette.dark) androidx.compose.ui.graphics.Color(0xFF2C2C2E)
    else androidx.compose.ui.graphics.Color(0xFFE9E9EB)

@Composable
private fun ActivitySummaryRow(
    summary: String,
    open: Boolean,
    padded: Boolean = true,
    toggle: () -> Unit,
) {
    Row(
        Modifier.then(if (padded) Modifier.padding(horizontal = ScreenMargin) else Modifier)
            .clip(CircleShape)
            .pressable(onClick = toggle)
            .padding(vertical = 4.dp, horizontal = 2.dp)
            .semantics { contentDescription = (if (open) "Hide " else "Show ") + summary },
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(Glyph.SPARKLES, null, tint = palette.secondaryLabel, size = 15.dp)
        Spacer(Modifier.width(6.dp))
        Text(
            summary.ifEmpty { "Agent activity" },
            style = type.subheadline,
            color = palette.secondaryLabel,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
        Spacer(Modifier.width(4.dp))
        DisclosureChevron(open)
    }
}

@Composable
private fun ToolRow(step: TimelineStep, onClick: () -> Unit) {
    Row(
        Modifier.fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(palette.fill.copy(alpha = palette.fill.alpha * .7f))
            .pressable(onClick = onClick, highlight = true)
            .padding(horizontal = 12.dp, vertical = 9.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(Glyph.TERMINAL, null, tint = palette.secondaryLabel, size = 15.dp)
        Spacer(Modifier.width(9.dp))
        Text(
            step.tool_title,
            Modifier.weight(1f),
            style = type.footnote.copy(fontWeight = FontWeight.Medium),
            color = palette.label,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
        Spacer(Modifier.width(8.dp))
        Text(
            step.tool_status_label,
            style = type.caption,
            color = if (step.tool_attention) palette.destructive else palette.secondaryLabel,
            maxLines = 1,
        )
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
                com.dbpprt.dieter.core.composition.Attachments.details(part),
                style = type.caption,
                color = palette.secondaryLabel,
                maxLines = 1,
            )
        }
    }
}

@Composable
private fun Composer(
    store: MobileStore,
    view: ConversationSlice,
    selected: String,
    draft: String,
    onDraft: (String) -> Unit,
    attachments: List<MessagePart>,
    onRemoveAttachment: (Int) -> Unit,
    onAttach: () -> Unit,
    busy: Boolean,
    bottomInset: androidx.compose.ui.unit.Dp,
    onAgent: () -> Unit,
    onSend: () -> Unit,
) {
    val state = view.state
    val agent = state?.agent
    val canSend = (draft.isNotBlank() || attachments.isNotEmpty()) && !busy && view.card != null
    val showStop = state?.can_halt == true && draft.isBlank() && attachments.isEmpty()
    val reviewable =
        view.card?.scope != "chat" &&
            view.card != null &&
            state?.can_halt != true &&
            view.board?.lanes?.any { it.id == "review" } == true &&
            view.card?.lane != "review"
    val imeVisible =
        (WindowInsets.ime.getBottom(androidx.compose.ui.platform.LocalDensity.current) > 0)
    Column(
        Modifier.fillMaxWidth()
            .background(
                if (apple)
                    Brush.verticalGradient(
                        0f to palette.background.copy(alpha = 0f),
                        .18f to palette.background,
                    )
                else SolidColor(colors.surfaceContainer)
            )
            .padding(
                top = if (apple) 10.dp else 8.dp,
                bottom = if (imeVisible) 8.dp else bottomInset.coerceAtLeast(8.dp),
            )
    ) {
        Row(
            Modifier.fillMaxWidth()
                .horizontalScroll(rememberScrollState())
                .padding(horizontal = ScreenMargin, vertical = 2.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            if (agent != null)
                ComposerChip(
                    listOf(agent.provider_label, agent.model_label, agent.effort_label)
                        .filter { it.isNotEmpty() }
                        .joinToString(" · "),
                    Glyph.SPARKLES,
                    Modifier.testTag("agent-chip"),
                    onClick = onAgent,
                    chevron = true,
                )
            if ((state?.context_percent ?: 0) > 0)
                ComposerChip(
                    "${state?.context_percent}% context",
                    Glyph.CPU,
                    warning = state?.context_near_limit == true,
                )
            if (state?.can_start == true)
                ComposerChip("Start", Glyph.PLAY, onClick = store::start, prominent = true)
            if (reviewable)
                ComposerChip(
                    "Move to Review",
                    Glyph.CHECKLIST,
                    Modifier.testTag("move-review"),
                    onClick = { store.move("review") },
                )
            state
                ?.pending_tools_summary
                ?.takeIf { it.isNotEmpty() }
                ?.let { ComposerChip(it, Glyph.HOURGLASS) }
        }
        if (attachments.isNotEmpty())
            Row(
                Modifier.fillMaxWidth()
                    .horizontalScroll(rememberScrollState())
                    .padding(horizontal = ScreenMargin, vertical = 6.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                attachments.forEachIndexed { index, part ->
                    Row(
                        Modifier.clip(CircleShape)
                            .background(palette.fill)
                            .padding(start = 12.dp, end = 4.dp, top = 4.dp, bottom = 4.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Icon(Glyph.ATTACH, null, tint = palette.secondaryLabel, size = 14.dp)
                        Spacer(Modifier.width(5.dp))
                        Text(
                            part.filename.ifEmpty { "Attachment" },
                            style = type.footnote,
                            color = palette.label,
                            maxLines = 1,
                        )
                        Box(
                            Modifier.size(28.dp)
                                .clip(CircleShape)
                                .pressable(onClick = { onRemoveAttachment(index) })
                                .semantics { contentDescription = "Remove attachment" },
                            contentAlignment = Alignment.Center,
                        ) {
                            Icon(
                                Glyph.CLOSE,
                                null,
                                tint = palette.secondaryLabel,
                                size = 12.dp,
                                weight = GlyphWeight.BOLD,
                            )
                        }
                    }
                }
            }
        Row(
            Modifier.fillMaxWidth()
                .padding(start = ScreenMargin - 4.dp, end = ScreenMargin - 4.dp, top = 6.dp),
            verticalAlignment = Alignment.Bottom,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            CircleButton(
                Glyph.ADD,
                "Attach images or files",
                onAttach,
                Modifier.testTag("attach"),
                enabled = attachments.size < 4,
                size = if (apple) 38.dp else 44.dp,
            )
            Row(
                Modifier.weight(1f)
                    .heightIn(min = if (apple) 38.dp else 48.dp)
                    .clip(RoundedCornerShape(if (apple) 20.dp else 24.dp))
                    .background(if (apple) palette.cell else colors.surfaceContainerHighest)
                    .then(
                        if (apple)
                            Modifier.border(
                                .5.dp,
                                palette.separator.copy(alpha = .6f),
                                RoundedCornerShape(20.dp),
                            )
                        else Modifier
                    )
                    .padding(start = 14.dp, end = 4.dp),
                verticalAlignment = Alignment.Bottom,
            ) {
                Box(Modifier.weight(1f).padding(vertical = if (apple) 8.dp else 12.dp)) {
                    if (draft.isEmpty())
                        Text(
                            if (view.state?.working == true) "Queue a message…" else "Message",
                            style = type.body,
                            color = palette.secondaryLabel,
                        )
                    BasicTextField(
                        draft,
                        onDraft,
                        Modifier.fillMaxWidth().testTag("message-input").semantics {
                            contentDescription = "Message"
                        },
                        textStyle = type.body.copy(color = palette.label),
                        cursorBrush = SolidColor(if (apple) palette.info else colors.primary),
                        maxLines = 6,
                    )
                }
                val sendSize = if (apple) 30.dp else 40.dp
                Box(Modifier.padding(bottom = if (apple) 4.dp else 4.dp)) {
                    if (showStop)
                        SendButton(
                            Glyph.STOP,
                            "Stop agent",
                            store::stop,
                            enabled = !busy,
                            size = sendSize,
                            destructive = true,
                        )
                    else
                        SendButton(
                            Glyph.ARROW_UP,
                            "Send message",
                            onSend,
                            enabled = canSend,
                            size = sendSize,
                        )
                }
            }
        }
    }
}

@Composable
private fun SendButton(
    glyph: Glyph,
    description: String,
    onClick: () -> Unit,
    enabled: Boolean,
    size: androidx.compose.ui.unit.Dp,
    destructive: Boolean = false,
) {
    val container =
        when {
            !enabled -> palette.fill
            destructive && !apple -> colors.errorContainer
            apple -> palette.accent.let { if (it == palette.label) palette.label else it }
            else -> colors.primary
        }
    val content =
        when {
            !enabled -> palette.tertiaryLabel
            destructive && !apple -> colors.onErrorContainer
            apple -> palette.onAccent
            else -> colors.onPrimary
        }
    Box(
        Modifier.size(size)
            .clip(CircleShape)
            .background(container)
            .pressable(onClick = onClick, enabled = enabled)
            .semantics { contentDescription = description }
            .testTag(if (glyph == Glyph.STOP) "stop-agent" else "send-message"),
        contentAlignment = Alignment.Center,
    ) {
        Icon(
            glyph,
            null,
            tint = content,
            size = size * (if (glyph == Glyph.STOP) .42f else .55f),
            weight = GlyphWeight.BOLD,
        )
    }
}

@Composable
private fun ComposerChip(
    text: String,
    glyph: Glyph,
    modifier: Modifier = Modifier,
    onClick: (() -> Unit)? = null,
    chevron: Boolean = false,
    warning: Boolean = false,
    prominent: Boolean = false,
) {
    val tint =
        if (warning) palette.warning.readableOn(palette.background)
        else if (prominent) palette.onAccent else palette.label
    Row(
        modifier
            .height(30.dp)
            .clip(CircleShape)
            .background(
                if (prominent) palette.accent
                else if (apple) palette.cell else colors.surfaceContainerHigh
            )
            .then(
                if (apple && !prominent)
                    Modifier.border(.5.dp, palette.separator.copy(alpha = .5f), CircleShape)
                else Modifier
            )
            .then(if (onClick != null) Modifier.pressable(onClick = onClick) else Modifier)
            .padding(horizontal = 11.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(5.dp),
    ) {
        Icon(glyph, null, tint = tint, size = 13.dp, weight = GlyphWeight.MEDIUM)
        Text(
            text,
            style = type.footnote.copy(fontWeight = FontWeight.Medium),
            color = tint,
            maxLines = 1,
        )
        if (chevron)
            Icon(
                Glyph.CHEVRON_DOWN,
                null,
                tint = palette.secondaryLabel,
                size = 10.dp,
                weight = GlyphWeight.BOLD,
            )
    }
}

@Composable
private fun ToolOutputSheet(tool: ToolOutput, onDismiss: () -> Unit) {
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

// ---------------------------------------------------------------------------------------------
// Conversation panes
// ---------------------------------------------------------------------------------------------

@Composable
internal fun CardPaneScreen(
    store: MobileStore,
    cardId: String,
    pane: CardPane,
    openUrl: (String) -> Unit,
) {
    when (pane) {
        CardPane.SUBAGENTS -> SubagentsScreen(store, cardId)
        CardPane.CHANGES -> ReviewScreen(store)
        CardPane.FILES -> FilesScreen(store, inConversation = true)
        CardPane.TERMINAL -> TerminalsScreen(store, inConversation = true)
        CardPane.PROCESSES -> ProcessesScreen(store)
    }
}

@Composable
private fun SubagentsScreen(store: MobileStore, cardId: String) {
    val view by store.conversation.collectAsState()
    val agents = view.conversation?.subagents.orEmpty()
    Screen(ScreenChrome("Subagents", subtitle = view.card?.title.orEmpty())) {
        LazyColumn(
            Modifier.fillMaxSize().testTag("subagents"),
            state = listState,
            contentPadding =
                PaddingValues(
                    start = ScreenMargin,
                    end = ScreenMargin,
                    top = padding.calculateTopPadding() + 8.dp,
                    bottom = padding.calculateBottomPadding() + 16.dp,
                ),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            if (agents.isEmpty())
                item {
                    EmptyState(
                        Glyph.SUBAGENTS,
                        "No subagents",
                        "Delegated work appears here when the agent starts it.",
                        Modifier.padding(top = 60.dp),
                    )
                }
            items(agents, key = { it.id }) {
                SubagentCard(it, expandedByDefault = agents.size == 1)
            }
        }
    }
}

@Composable
internal fun SubagentCard(agent: Subagent, expandedByDefault: Boolean = false) {
    val now = rememberNow()
    val view = SubagentPresentation(agent, now)
    var expanded by rememberSaveable(agent.id) { mutableStateOf(expandedByDefault) }
    ContentCard(
        onClick = { expanded = !expanded },
        modifier = Modifier.testTag("subagent-${agent.id}"),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(
                Modifier.size(32.dp).clip(CircleShape).background(palette.fill),
                contentAlignment = Alignment.Center,
            ) {
                Icon(Glyph.SUBAGENTS, null, tint = palette.secondaryLabel, size = 16.dp)
            }
            Spacer(Modifier.width(10.dp))
            Column(Modifier.weight(1f)) {
                Text(
                    view.title,
                    style = type.headline,
                    color = palette.label,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Text(
                    view.identity,
                    style = type.footnote,
                    color = palette.secondaryLabel,
                    maxLines = 1,
                )
            }
            val tint = if (view.active) palette.info else palette.success
            Row(
                Modifier.clip(CircleShape)
                    .background(tint.copy(alpha = .14f))
                    .padding(horizontal = 8.dp, vertical = 3.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                if (view.active) LiveDot(tint, size = 7.dp)
                else
                    Icon(
                        Glyph.CHECK,
                        null,
                        tint = tint.readableOn(palette.cell),
                        size = 11.dp,
                        weight = GlyphWeight.BOLD,
                    )
                Spacer(Modifier.width(4.dp))
                Text(
                    view.statusLabel,
                    style = type.caption.copy(fontWeight = FontWeight.Medium),
                    color = tint.readableOn(palette.cell),
                )
            }
        }
        view.statusLine?.let {
            Spacer(Modifier.height(10.dp))
            Text(it, style = type.subheadline, color = palette.label)
        }
        view.contextFraction?.let {
            Spacer(Modifier.height(10.dp))
            ProgressBar(it.toFloat())
        }
        val metrics = (view.usageMetrics + view.elapsedLabel).filter { it.isNotEmpty() }
        if (metrics.isNotEmpty()) {
            Spacer(Modifier.height(8.dp))
            Text(metrics.joinToString(" · "), style = type.footnote, color = palette.secondaryLabel)
        }
        AnimatedVisibility(expanded) {
            Column(
                Modifier.padding(top = 10.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Hairline()
                (view.narrative + view.technical).forEach { section ->
                    Text(
                        section.label,
                        style = type.footnote.copy(fontWeight = FontWeight.SemiBold),
                        color = palette.secondaryLabel,
                    )
                    Text(
                        section.value,
                        style = if (section.monospace) type.monoSmall else type.subheadline,
                        color = palette.label,
                    )
                }
            }
        }
    }
}

@Composable
internal fun TaskPlanCard(plan: com.dbpprt.dieter.api.v1.TaskPlan, modifier: Modifier = Modifier) {
    val progress = TaskPlans.progress(plan)
    ContentCard(modifier) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(Glyph.CHECKLIST, null, tint = palette.secondaryLabel, size = 18.dp)
            Spacer(Modifier.width(8.dp))
            Text("Plan", Modifier.weight(1f), style = type.headline, color = palette.label)
            Text(
                "${progress.completed} of ${progress.total}",
                style = type.footnote,
                color = palette.secondaryLabel,
            )
        }
        Spacer(Modifier.height(10.dp))
        ProgressBar(
            if (progress.total == 0) 0f else progress.completed.toFloat() / progress.total,
            color = palette.success,
        )
        Spacer(Modifier.height(6.dp))
        plan.phases.forEach { phase ->
            if (phase.name.isNotEmpty())
                Text(
                    phase.name,
                    Modifier.padding(top = 8.dp, bottom = 2.dp),
                    style = type.subheadline.copy(fontWeight = FontWeight.SemiBold),
                    color = palette.label,
                )
            phase.tasks.forEach { task ->
                val done = TaskPlans.finished(task)
                Row(Modifier.padding(vertical = 4.dp), verticalAlignment = Alignment.Top) {
                    Icon(
                        if (done) Glyph.CHECK_CIRCLE else Glyph.CIRCLE,
                        if (done) "Done" else "Open",
                        Modifier.padding(top = 1.dp),
                        tint = if (done) palette.success else palette.tertiaryLabel,
                        size = 18.dp,
                    )
                    Spacer(Modifier.width(10.dp))
                    Text(
                        TaskPlans.text(task),
                        style = type.subheadline,
                        color = if (done) palette.secondaryLabel else palette.label,
                    )
                }
            }
        }
    }
}

/** Agent, model, effort and provider options as grouped rows with menus. */
@Composable
internal fun AgentSettings(agent: AgentControlsState?, onChoice: (AgentChoice) -> Unit) {
    if (agent == null) {
        Row(Modifier.fillMaxWidth().padding(24.dp), horizontalArrangement = Arrangement.Center) {
            Spinner()
        }
        return
    }
    val rows =
        buildList<@Composable (Position) -> Unit> {
            add { position ->
                PickerRow(
                    "Agent",
                    agent.provider_label,
                    agent.providers.map { it.id to it.name },
                    agent.selection?.provider.orEmpty(),
                    agent.provider_enabled,
                    position,
                    Glyph.SPARKLES,
                ) {
                    onChoice(AgentChoice(provider = it))
                }
            }
            add { position ->
                PickerRow(
                    "Model",
                    agent.model_label,
                    agent.models.map { it.id to it.name },
                    agent.selection?.model.orEmpty(),
                    agent.model_enabled,
                    position,
                    Glyph.CPU,
                ) {
                    onChoice(AgentChoice(model = it))
                }
            }
            if (agent.effort_choices.isNotEmpty())
                add { position ->
                    PickerRow(
                        "Effort",
                        agent.effort_label,
                        agent.effort_choices.map { it.id to it.name },
                        agent.effort_value,
                        agent.effort_enabled,
                        position,
                        Glyph.BOLT,
                    ) {
                        onChoice(AgentChoice(effort = it))
                    }
                }
        }
    Group(rows) { row, position -> row(position) }
    if (agent.options.isNotEmpty()) {
        SectionHeader("Options")
        Group(agent.options) { option, position ->
            val value = agent.option_values[option.id].orEmpty()
            val enabled = agent.option_enabled[option.id] == true
            when (agent.option_kinds[option.id]) {
                AgentOptionKind.AGENT_OPTION_KIND_TOGGLE ->
                    ListRow(
                        option.name,
                        position = position,
                        enabled = enabled,
                        trailing = {
                            DSwitch(
                                agent.option_on[option.id] == true,
                                {
                                    onChoice(
                                        AgentChoice(
                                            option = AgentOptionChoice(option.id, it.toString())
                                        )
                                    )
                                },
                                enabled = enabled,
                            )
                        },
                    )
                AgentOptionKind.AGENT_OPTION_KIND_CHOICE ->
                    PickerRow(
                        option.name,
                        option.choices.firstOrNull { it.value_ == value }?.name?.ifEmpty { value }
                            ?: value,
                        option.choices.map { it.value_ to it.name.ifEmpty { it.value_ } },
                        value,
                        enabled,
                        position,
                    ) {
                        onChoice(AgentChoice(option = AgentOptionChoice(option.id, it)))
                    }
                else ->
                    GroupItem(position) {
                        Column(Modifier.padding(horizontal = 16.dp, vertical = 10.dp)) {
                            Text(option.name, style = type.footnote, color = palette.secondaryLabel)
                            BasicTextField(
                                value,
                                {
                                    onChoice(AgentChoice(option = AgentOptionChoice(option.id, it)))
                                },
                                Modifier.fillMaxWidth().padding(top = 4.dp),
                                enabled = enabled,
                                textStyle = type.body.copy(color = palette.label),
                                cursorBrush = SolidColor(palette.info),
                            )
                        }
                    }
            }
        }
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
    MenuAnchor(menu) {
        ListRow(
            title,
            Modifier.testTag(tag),
            position = position,
            glyph = glyph,
            enabled = enabled && options.isNotEmpty(),
            onClick = {
                menu.show(
                    listOf(
                        MenuSection(
                            options.map { (key, label) ->
                                ChromeAction(
                                    "$tag-$key",
                                    label,
                                    checked = key == selected || label == value,
                                ) {
                                    onSelect(key)
                                }
                            }
                        )
                    )
                )
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

@Composable
private fun JumpToLatest(visible: Boolean, modifier: Modifier, content: @Composable () -> Unit) {
    AnimatedVisibility(
        visible,
        modifier,
        enter = fadeIn() + scaleIn(initialScale = .8f),
        exit = fadeOut() + scaleOut(targetScale = .8f),
    ) {
        content()
    }
}

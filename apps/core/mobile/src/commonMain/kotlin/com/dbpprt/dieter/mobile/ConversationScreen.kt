@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)

package com.dbpprt.dieter.mobile

import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.dbpprt.dieter.api.v1.MessagePart
import com.dbpprt.dieter.api.v1.Subagent
import com.dbpprt.dieter.api.v1.ToolOutput
import com.dbpprt.dieter.client.v1.*
import com.dbpprt.dieter.core.presentation.SubagentPresentation
import com.dbpprt.dieter.core.presentation.TaskPlans
import com.dbpprt.dieter.mobile.icons.*
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.launch

@Composable
internal fun ConversationScreen(store: MobileStore, openUrl: (String) -> Unit) {
    val keyboard = androidx.compose.ui.platform.LocalSoftwareKeyboardController.current
    val view by store.conversation.collectAsState()
    val selected by store.selectedCard.collectAsState()
    val tab by store.detailTab.collectAsState()
    var actions by remember(selected) { mutableStateOf(false) }
    Column(Modifier.fillMaxSize().imePadding()) {
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 8.dp, vertical = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            IconButton(onClick = store::back) { Icon(Icons.Outlined.ArrowBack, "Back to board") }
            Column(Modifier.weight(1f)) {
                Text(
                    view.card?.title ?: "Conversation",
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.SemiBold,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
                Text(
                    listOf(view.project?.name, view.board?.name)
                        .filterNotNull()
                        .filter { it.isNotBlank() }
                        .joinToString(" · "),
                    style = MaterialTheme.typography.bodySmall,
                    color = colors.onSurfaceVariant,
                )
            }
            IconButton(
                onClick = {
                    store.command(Command(refresh_conversation = RefreshConversation(selected)))
                }
            ) {
                Icon(Icons.Outlined.Refresh, "Refresh conversation")
            }
            IconButton(onClick = { actions = true }) {
                Icon(Icons.Outlined.MoreHoriz, "Conversation actions")
            }
            IconButton(onClick = { keyboard?.hide() }) {
                Icon(Icons.Outlined.KeyboardHide, "Hide keyboard")
            }
        }
        val tabs = listOf("Conversation", "Subagents", "Changes", "Files", "Terminal", "Processes")
        PrimaryScrollableTabRow(
            tabs.indexOf(tab).coerceAtLeast(0),
            containerColor = colors.background,
            edgePadding = 12.dp,
        ) {
            tabs.forEach { title ->
                Tab(
                    tab == title,
                    { store.selectDetail(title) },
                    text = {
                        Text(
                            if (title == "Subagents")
                                "$title ${view.conversation?.subagents?.size ?: 0}"
                            else title
                        )
                    },
                )
            }
        }
        when (tab) {
            "Subagents" -> SubagentsPane(view.conversation?.subagents.orEmpty())
            "Changes" -> ReviewScreen(store)
            "Processes" -> ProcessesScreen(store)
            "Files" -> FilesScreen(store, inConversation = true)
            "Terminal" -> TerminalsScreen(store, inConversation = true)
            else -> Transcript(store, view, selected, openUrl)
        }
    }
    if (actions) view.card?.let { CardActions(store, it) { actions = false } }
}

@Composable
private fun ColumnScope.Transcript(
    store: MobileStore,
    view: ConversationSlice,
    selected: String,
    openUrl: (String) -> Unit,
) {
    val busy by store.busy.collectAsState()
    val drafts by store.draftTexts.collectAsState()
    var draft by rememberSaveable(selected) { mutableStateOf(drafts[selected].orEmpty()) }
    LaunchedEffect(drafts[selected]) { if (draft.isEmpty()) draft = drafts[selected].orEmpty() }
    var settings by rememberSaveable(selected) { mutableStateOf(false) }
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
    LaunchedEffect(list, selected) {
        snapshotFlow { list.isScrollInProgress }
            .distinctUntilChanged()
            .collect { scrolling ->
                if (!scrolling && list.layoutInfo.totalItemsCount > 0)
                    following = !list.canScrollForward
            }
    }
    LaunchedEffect(view.timeline, view.state?.working, view.loading) {
        if (following && list.layoutInfo.totalItemsCount > 0)
            list.scrollToItem(list.layoutInfo.totalItemsCount - 1)
    }
    if (view.error.isNotBlank())
        Notice(
            "Conversation unavailable",
            view.error,
            { store.command(Command(refresh_conversation = RefreshConversation(selected))) },
        )
    if (view.loading && view.timeline.isEmpty()) LinearProgressIndicator(Modifier.fillMaxWidth())
    Box(Modifier.weight(1f)) {
        LazyColumn(
            Modifier.fillMaxSize().testTag("conversation-timeline"),
            state = list,
            contentPadding = PaddingValues(16.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            if (view.has_earlier)
                item("history") {
                    TextButton(onClick = store::loadEarlier, enabled = !view.loading_earlier) {
                        Text(
                            if (view.loading_earlier) "Loading earlier messages…"
                            else "Load earlier messages"
                        )
                    }
                }
            view.state
                ?.unsent_task
                ?.takeIf { it.isNotBlank() }
                ?.let { task ->
                    item("unsent-task") { FormSection("Agent task") { RichText(task, openUrl) } }
                }
            items(view.timeline, key = { it.id }) { row ->
                TimelineRow(
                    row,
                    view,
                    openUrl,
                    onAttachment = preview,
                    onTool = { step ->
                        store.action {
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
                    },
                    onCopy = {
                        val text =
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
                        clipboard.setText(AnnotatedString(text))
                    },
                )
            }
            view.conversation
                ?.task_plans
                .orEmpty()
                .filter { it.id in view.unattached_plan_ids }
                .forEach { plan -> item("plan-${plan.id}") { TaskPlanCard(plan) } }
            if (view.state?.working == true)
                item("working") {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp)
                        Text(
                            view.state?.live_activity?.ifEmpty { "Agent working…" }.orEmpty(),
                            style = MaterialTheme.typography.bodySmall,
                            color = colors.onSurfaceVariant,
                        )
                    }
                }
            view.conversation?.provider_status?.let { provider ->
                item("provider-status") {
                    Text(
                        provider.message,
                        color = colors.tertiary,
                        style = MaterialTheme.typography.bodySmall,
                    )
                }
            }
            view.turn_failure?.let { failure ->
                item("turn-failure") {
                    Notice(
                        "Turn failed",
                        failure.summary,
                        store::retryTurn,
                        "Retry turn",
                        danger = true,
                    )
                }
            }
            items(view.conversation?.queue.orEmpty(), key = { "queue-${it.id}" }) { queued ->
                FormSection("Queued for the next turn") {
                    Text(queued.text, style = MaterialTheme.typography.bodyMedium)
                    Row {
                        TextButton(
                            onClick = {
                                store.action {
                                    val removed =
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
                                    removed?.let {
                                        draft = it.text
                                        attachments =
                                            it.parts.filter { part -> part.type != "text" }
                                        store.saveDraft(selected, draft)
                                    }
                                }
                            }
                        ) {
                            Text("Edit")
                        }
                        TextButton(
                            onClick = {
                                store.command(
                                    Command(
                                        remove_queued_message =
                                            RemoveQueuedMessage(selected, queued.id)
                                    )
                                )
                            }
                        ) {
                            Text("Remove")
                        }
                        if (view.state?.steerable_id == queued.id)
                            TextButton(
                                onClick = {
                                    store.command(
                                        Command(
                                            steer_conversation =
                                                SteerConversation(selected, queued.id)
                                        )
                                    )
                                }
                            ) {
                                Text("Run now")
                            }
                    }
                }
            }
            item("end") { Spacer(Modifier.height(1.dp)) }
        }
        if (!following)
            FilledTonalIconButton(
                onClick = {
                    following = true
                    store.command(Command(return_to_latest = ReturnToLatest(selected)))
                    coroutine.launch {
                        if (list.layoutInfo.totalItemsCount > 0)
                            list.animateScrollToItem(list.layoutInfo.totalItemsCount - 1)
                    }
                },
                modifier = Modifier.align(Alignment.BottomEnd).padding(12.dp),
            ) {
                Icon(Icons.Outlined.ArrowDownward, "Jump to latest")
            }
    }
    Surface(color = colors.surface, border = BorderStroke(1.dp, colors.outlineVariant)) {
        Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                val agent = view.state?.agent
                Text(
                    listOfNotNull(agent?.provider_label, agent?.model_label, agent?.effort_label)
                        .joinToString(" · "),
                    Modifier.weight(1f),
                    color = colors.onSurfaceVariant,
                    style = MaterialTheme.typography.labelSmall,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                if ((view.state?.context_percent ?: 0) > 0)
                    Text(
                        "${view.state?.context_percent}% context",
                        style = MaterialTheme.typography.labelSmall,
                        color =
                            if (view.state?.context_near_limit == true) colors.error
                            else colors.onSurfaceVariant,
                    )
                IconButton(onClick = { settings = !settings }, modifier = Modifier.size(40.dp)) {
                    Icon(Icons.Outlined.Tune, "Agent settings", Modifier.size(18.dp))
                }
            }
            if (settings)
                AgentSettings(view.state?.agent) {
                    store.command(Command(choose_agent = ChooseAgent(selected, it)))
                }
            AttachmentChips(
                attachments,
                onRemove = { index ->
                    attachments = attachments.filterIndexed { i, _ -> i != index }
                },
            )
            Row(
                verticalAlignment = Alignment.Bottom,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                IconButton(onClick = pick, enabled = attachments.size < 4) {
                    Icon(Icons.Outlined.AttachFile, "Attach images or files")
                }
                MobileTextField(
                    draft,
                    {
                        draft = it
                        store.saveDraft(selected, it)
                    },
                    Modifier.weight(1f).testTag("message-input"),
                    placeholder = { Text("Keep the conversation going…") },
                    shape = RoundedCornerShape(18.dp),
                    maxLines = 6,
                )
                if (view.state?.can_halt == true && draft.isBlank() && attachments.isEmpty())
                    FilledIconButton(onClick = store::stop, enabled = !busy) {
                        Icon(Icons.Outlined.Stop, "Stop agent")
                    }
                else
                    FilledIconButton(
                        onClick = {
                            val text = draft
                            store.action {
                                store.send(text, selected, attachments)
                                draft = ""
                                attachments = emptyList()
                                following = true
                            }
                        },
                        enabled =
                            (draft.isNotBlank() || attachments.isNotEmpty()) &&
                                !busy &&
                                view.card != null,
                    ) {
                        Icon(Icons.Outlined.ArrowUpward, "Send message")
                    }
            }
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                if (view.state?.can_start == true)
                    TextButton(onClick = store::start, enabled = !busy) { Text("Start") }
                if (
                    view.card?.scope != "chat" &&
                        view.card != null &&
                        view.state?.can_halt != true &&
                        view.board?.lanes?.any { it.id == "review" } == true
                )
                    TextButton(onClick = { store.move("review") }, enabled = !busy) {
                        Text("Review")
                    }
                if (view.state?.pending_tools_summary?.isNotEmpty() == true)
                    Text(
                        view.state!!.pending_tools_summary,
                        style = MaterialTheme.typography.bodySmall,
                        color = colors.onSurfaceVariant,
                    )
            }
        }
    }
    toolOutput?.let { tool ->
        ModalBottomSheet(onDismissRequest = { toolOutput = null }) {
            Column(
                Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(16.dp),
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                Text(
                    tool.tool_name + " · " + tool.state,
                    style = MaterialTheme.typography.titleMedium,
                )
                SelectionContainer {
                    Text(
                        listOf(tool.input_json.utf8(), tool.output_json.utf8(), tool.error_text)
                            .filter { it.isNotEmpty() }
                            .joinToString("\n\n"),
                        fontFamily = FontFamily.Monospace,
                        style = MaterialTheme.typography.bodySmall,
                    )
                }
            }
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
    var expanded by remember(row.id) { mutableStateOf(false) }
    val shape = RoundedCornerShape(14.dp)
    if (row.activity && !expanded) {
        Surface(onClick = { expanded = true }, color = colors.surfaceContainerHigh, shape = shape) {
            Row(Modifier.padding(12.dp), verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Outlined.ChevronRight, "Expand agent activity", Modifier.size(16.dp))
                Text(row.summary, style = MaterialTheme.typography.labelMedium)
            }
        }
        return
    }
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        if (!row.activity)
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    if (row.user) "You" else "Dieter",
                    style = MaterialTheme.typography.labelMedium,
                    fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.weight(1f),
                )
                if (row.copyable)
                    IconButton(onClick = onCopy, modifier = Modifier.size(32.dp)) {
                        Icon(Icons.Outlined.ContentCopy, "Copy message", Modifier.size(16.dp))
                    }
            }
        row.groups.forEach { group ->
            var groupOpen by remember(group.id) { mutableStateOf(false) }
            if (group.activity)
                TextButton(onClick = { groupOpen = !groupOpen }) {
                    Icon(
                        if (groupOpen) Icons.Outlined.ExpandMore else Icons.Outlined.ChevronRight,
                        null,
                        Modifier.size(16.dp),
                    )
                    Text(group.summary, style = MaterialTheme.typography.labelMedium)
                }
            if (!group.activity || groupOpen || row.activity)
                group.steps.forEach { step ->
                    val part =
                        view.messages
                            .firstOrNull { it.id == step.message_id }
                            ?.parts
                            ?.getOrNull(step.part_index)
                    val text = step.text.ifEmpty { part?.text.orEmpty() }
                    when (step.kind) {
                        TimelineStepKind.TIMELINE_STEP_KIND_TOOL ->
                            Surface(
                                onClick = { onTool(step) },
                                shape = RoundedCornerShape(9.dp),
                                color = colors.surfaceContainerHigh,
                            ) {
                                Row(
                                    Modifier.padding(10.dp),
                                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                                ) {
                                    Icon(Icons.Outlined.Terminal, null, Modifier.size(16.dp))
                                    Text(
                                        step.tool_title,
                                        Modifier.weight(1f),
                                        style = MaterialTheme.typography.labelMedium,
                                    )
                                    Text(
                                        step.tool_status_label,
                                        color =
                                            if (step.tool_attention) colors.error
                                            else colors.onSurfaceVariant,
                                        style = MaterialTheme.typography.labelSmall,
                                    )
                                }
                            }
                        TimelineStepKind.TIMELINE_STEP_KIND_REASONING ->
                            Text(
                                text,
                                style = MaterialTheme.typography.bodySmall,
                                color = colors.onSurfaceVariant,
                            )
                        TimelineStepKind.TIMELINE_STEP_KIND_SUBAGENTS ->
                            view.conversation
                                ?.subagents
                                .orEmpty()
                                .filter { it.id in row.subagent_ids }
                                .forEach { SubagentCard(it) }
                        TimelineStepKind.TIMELINE_STEP_KIND_ATTACHMENT ->
                            part?.let {
                                Surface(
                                    onClick = { onAttachment(it) },
                                    color = colors.surfaceContainerHigh,
                                    shape = RoundedCornerShape(8.dp),
                                ) {
                                    Column(Modifier.padding(10.dp)) {
                                        CompactBadge(
                                            it.filename.ifEmpty { "Attachment" },
                                            Icons.Outlined.AttachFile,
                                        )
                                        Text(
                                            com.dbpprt.dieter.core.composition.Attachments.details(
                                                it
                                            ),
                                            style = MaterialTheme.typography.labelSmall,
                                        )
                                    }
                                }
                            }
                        else ->
                            if (text.isNotEmpty()) {
                                if (row.user)
                                    Surface(shape = shape, color = colors.surfaceContainerHigh) {
                                        Box(Modifier.padding(12.dp)) { RichText(text, openUrl) }
                                    }
                                else RichText(text, openUrl)
                            }
                    }
                }
        }
        view.conversation
            ?.task_plans
            .orEmpty()
            .filter { it.id in row.plan_ids }
            .forEach { TaskPlanCard(it) }
        if (row.delivery_label.isNotEmpty())
            Text(
                row.delivery_label,
                style = MaterialTheme.typography.labelSmall,
                color = colors.onSurfaceVariant,
            )
        if (row.activity) TextButton(onClick = { expanded = false }) { Text("Collapse activity") }
    }
}

@Composable
internal fun SubagentsPane(agents: List<Subagent>) {
    if (agents.isEmpty())
        Empty("No delegated agents", "Delegated work appears here when the agent creates it.")
    else
        LazyColumn(
            contentPadding = PaddingValues(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            items(agents, key = { it.id }) { SubagentCard(it) }
        }
}

@Composable
private fun SubagentCard(agent: Subagent) {
    val now = rememberNow()
    val view = SubagentPresentation(agent, now)
    var expanded by remember(agent.id) { mutableStateOf(false) }
    Surface(
        onClick = { expanded = !expanded },
        shape = RoundedCornerShape(14.dp),
        color = colors.surfaceContainerHigh,
    ) {
        Column(Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row {
                Text(view.title, Modifier.weight(1f), style = MaterialTheme.typography.titleSmall)
                Text(
                    view.statusLabel,
                    style = MaterialTheme.typography.labelSmall,
                    color = colors.secondary,
                )
            }
            Text(
                view.identity,
                style = MaterialTheme.typography.labelSmall,
                color = colors.onSurfaceVariant,
            )
            view.statusLine?.let { Text(it, style = MaterialTheme.typography.bodySmall) }
            view.contextFraction?.let {
                LinearProgressIndicator(
                    progress = { it.toFloat() },
                    modifier = Modifier.fillMaxWidth(),
                )
            }
            Text(
                (view.usageMetrics + view.elapsedLabel)
                    .filter { it.isNotEmpty() }
                    .joinToString(" · "),
                style = MaterialTheme.typography.labelSmall,
                color = colors.onSurfaceVariant,
            )
            if (expanded)
                (view.narrative + view.technical).forEach { section ->
                    Text(
                        section.label,
                        fontWeight = FontWeight.SemiBold,
                        style = MaterialTheme.typography.labelSmall,
                    )
                    Text(
                        section.value,
                        style = MaterialTheme.typography.bodySmall,
                        fontFamily =
                            if (section.monospace) FontFamily.Monospace else FontFamily.Default,
                    )
                }
        }
    }
}

@Composable
private fun TaskPlanCard(plan: com.dbpprt.dieter.api.v1.TaskPlan) {
    val progress = TaskPlans.progress(plan)
    FormSection("Plan · ${progress.completed}/${progress.total}") {
        plan.phases.forEach { phase ->
            if (phase.name.isNotEmpty())
                Text(phase.name, style = MaterialTheme.typography.labelLarge)
            phase.tasks.forEach { task ->
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(
                        if (TaskPlans.finished(task)) Icons.Outlined.CheckCircle
                        else Icons.Outlined.RadioButtonUnchecked,
                        null,
                        Modifier.size(16.dp),
                    )
                    Spacer(Modifier.width(8.dp))
                    Text(TaskPlans.text(task), style = MaterialTheme.typography.bodySmall)
                }
            }
        }
    }
}

@Composable
internal fun AttachmentChips(parts: List<MessagePart>, onRemove: (Int) -> Unit) {
    FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        parts.forEachIndexed { index, part ->
            InputChip(
                selected = false,
                onClick = { onRemove(index) },
                label = { Text(part.filename.ifEmpty { "Attachment" }, maxLines = 1) },
                trailingIcon = {
                    Icon(Icons.Outlined.Close, "Remove attachment", Modifier.size(16.dp))
                },
            )
        }
    }
}

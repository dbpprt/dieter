@file:OptIn(
    androidx.compose.material3.ExperimentalMaterial3Api::class,
    androidx.compose.foundation.layout.ExperimentalLayoutApi::class,
)

package com.getdieter.mobile.conversation

import androidx.compose.animation.*
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.input.nestedscroll.NestedScrollConnection
import androidx.compose.ui.input.nestedscroll.NestedScrollSource
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.getdieter.api.v1.MessagePart
import com.getdieter.api.v1.ToolOutput
import com.getdieter.client.v1.*
import com.getdieter.mobile.app.*
import com.getdieter.mobile.board.*
import com.getdieter.mobile.creation.*
import com.getdieter.mobile.design.*
import com.getdieter.mobile.design.Tone
import com.getdieter.mobile.navigation.*
import com.getdieter.mobile.platform.*
import com.getdieter.mobile.store.*
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.launch

@Composable
internal fun ConversationScreen(store: MobileStore, cardId: String, openUrl: (String) -> Unit) {
    val view by store.conversation.slice.collectAsState()
    val selected by store.conversation.selectedCard.collectAsState()
    var editing by remember { mutableStateOf(false) }
    val workspace by store.workspace.slice.collectAsState()
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
            add(ChromeAction("start", "Start agent", Glyph.PLAY) { store.conversation.start() })
        if (view.state?.can_halt == true)
            add(
                ChromeAction("stop", "Stop agent", Glyph.STOP, destructive = true) {
                    store.conversation.stop()
                }
            )
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
    val drafts by store.conversation.draftTexts.collectAsState()
    var draft by rememberSaveable(selected) { mutableStateOf(drafts[selected].orEmpty()) }
    LaunchedEffect(drafts[selected]) { if (draft.isEmpty()) draft = drafts[selected].orEmpty() }
    var agentSheet by remember(selected) { mutableStateOf(false) }
    var following by rememberSaveable(selected) { mutableStateOf(true) }
    var toolOutput by remember(selected) { mutableStateOf<ToolOutput?>(null) }
    val list = rememberLazyListState()
    val coroutine = rememberCoroutineScope()
    val clipboard = LocalClipboardManager.current
    var attachments by remember(selected) { mutableStateOf<List<MessagePart>>(emptyList()) }
    val shares by store.sharing.composerShares.collectAsState()
    // Items shared from another app wait here for this conversation's composer.
    LaunchedEffect(selected, shares[selected]) {
        store.sharing.takeComposerShare(selected)?.let { shared ->
            com.getdieter.core.composition.Attachments.appending(
                    attachments,
                    shared.attachments,
                )
                .fold({ attachments = it }, { store.error.value = it.message.orEmpty() })
            if (shared.text.isNotBlank())
                draft = listOf(draft, shared.text).filter { it.isNotBlank() }.joinToString("\n")
        }
    }
    val pick =
        rememberAttachmentPicker(
            { added ->
                com.getdieter.core.composition.Attachments.appending(attachments, added)
                    .fold({ attachments = it }, { store.error.value = it.message.orEmpty() })
            },
            { store.error.value = it },
        )
    val preview = rememberAttachmentViewer { store.error.value = it }
    // Only the person's own dragging detaches the transcript from new output.
    val userScroll =
        remember(list, selected) {
            object : NestedScrollConnection {
                override fun onPreScroll(available: Offset, source: NestedScrollSource): Offset {
                    if (source == NestedScrollSource.UserInput && available.y != 0f)
                        following = false
                    return Offset.Zero
                }
            }
        }
    // Scrolling back to the end attaches it again.
    LaunchedEffect(list, selected) {
        snapshotFlow { list.isScrollInProgress }
            .distinctUntilChanged()
            .drop(1)
            .collect { scrolling ->
                if (!scrolling && !following && list.layoutInfo.totalItemsCount > 0)
                    following = !list.canScrollForward
            }
    }
    // While following, stay at the measured end: new output, native text measurement and
    // keyboard changes can all remeasure the list after the transcript update. The scroll is
    // applied by the next measure pass, since this can resume while the list is laid out.
    LaunchedEffect(list, selected, following) {
        if (!following) return@LaunchedEffect
        snapshotFlow {
            if (!list.isScrollInProgress && list.canScrollForward) list.layoutInfo.totalItemsCount
            else 0
        }
            .collect { count -> if (count > 0) list.requestScrollToItem(count - 1) }
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
                Modifier.fillMaxSize().nestedScroll(userScroll).testTag("conversation-timeline"),
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
                                store.conversation::loadEarlier,
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
                            onAction =
                                if (failure.retryable) store.conversation::retryTurn else null,
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
                                        store.conversation.saveDraft(selected, draft)
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
        if (view.syncing) {
            Row(
                Modifier.fillMaxWidth()
                    .padding(horizontal = ScreenMargin, vertical = 8.dp)
                    .testTag("conversation-refreshing")
                    .semantics(mergeDescendants = true) {
                        contentDescription = "Refreshing conversation"
                    },
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Spinner(Modifier.size(14.dp))
                Text("Refreshing…", style = type.caption, color = palette.secondaryLabel)
            }
        }
        Composer(
            store,
            view,
            selected,
            draft,
            onDraft = {
                draft = it
                store.conversation.saveDraft(selected, it)
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
                    store.conversation.send(text, selected, parts)
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
                    store.conversation::start,
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

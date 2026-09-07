@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)

package com.dbpprt.dieter.ui

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.outlined.Cancel
import androidx.compose.material.icons.outlined.ChatBubbleOutline
import androidx.compose.material.icons.outlined.KeyboardArrowDown
import androidx.compose.material.icons.outlined.Refresh
import androidx.compose.material.icons.outlined.Schedule
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.dbpprt.dieter.ui.theme.DieterAmber
import com.dbpprt.dieter.ui.theme.DieterShell
import com.dbpprt.dieter.ui.theme.DieterShellDeep
import com.dbpprt.dieter.ui.theme.DieterMuted
import com.dbpprt.dieter.ui.theme.DieterOutline
import com.dbpprt.dieter.ui.theme.DieterSurface
import com.dbpprt.dieter.ui.theme.DieterSurfaceHigh
import com.dbpprt.dieter.v1.QueuedMessage
import com.dbpprt.dieter.v1.Schedule
import com.dbpprt.dieter.v1.MessagePart
import com.dbpprt.dieter.v1.Subagent
import com.dbpprt.dieter.v1.TaskPlan
import com.dbpprt.dieter.v1.UiMessage
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.withContext
import com.dbpprt.dieter.ui.theme.DieterAmberTint
import com.dbpprt.dieter.ui.theme.DieterAbyss

@Composable
internal fun ConversationBody(state: DieterUiState, model: DieterViewModel, modifier: Modifier = Modifier) {
    val allMessages = remember(state.olderMessages, state.conversation) {
        mergedConversationMessages(state.olderMessages, state.conversation?.conversation?.messagesList.orEmpty())
    }
    val listState = remember(state.selectedCardId) { LazyListState() }
    var initialScrollComplete by remember(state.selectedCardId) { mutableStateOf(false) }
    var followingLatest by remember(state.selectedCardId) { mutableStateOf(true) }
    var historyAnchorPending by remember(state.selectedCardId) { mutableStateOf(false) }
    var historyAnchorKey by remember(state.selectedCardId) { mutableStateOf<String?>(null) }
    var historyKeepLatest by remember(state.selectedCardId) { mutableStateOf(false) }
    var historyStartAtRequest by remember(state.selectedCardId) { mutableStateOf(0) }
    var historyObservedLoading by remember(state.selectedCardId) { mutableStateOf(false) }
    var text by remember { mutableStateOf("") }
    var composerError by remember { mutableStateOf<String?>(null) }
    var awaitingAgent by remember(state.selectedCardId) { mutableStateOf(false) }
    var assistantCountAtSend by remember(state.selectedCardId) { mutableStateOf(0) }
    var observedActiveTurn by remember(state.selectedCardId) { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    val attachments = remember(state.selectedCardId) { mutableStateListOf<MessagePart>() }
    var attachmentPickerVisible by remember(state.selectedCardId) { mutableStateOf(false) }
    val conversation = state.conversation?.conversation
    val queuedMessages = conversation?.queueList.orEmpty()
    val card = state.conversation?.detail?.card ?: state.selectedCard
    val unsentTask = card?.unsentTaskText()
    val draftAttachments = conversation?.draftAttachmentsList.orEmpty()
    val hasUnsentDraft = card?.initialPromptSentAt?.isBlank() == true &&
        (unsentTask != null || draftAttachments.isNotEmpty())
    val plansByMessage = remember(conversation) {
        conversation?.taskPlansList.orEmpty()
            .groupBy(TaskPlan::getMessageId)
            .mapValues { (_, plans) -> plans.maxBy(TaskPlan::getRevision) }
    }
    val subagentsByMessage = remember(conversation) {
        conversation?.subagentsList.orEmpty().groupBy(Subagent::getMessageId)
    }
    val messages = remember(allMessages, plansByMessage, subagentsByMessage, state.showReasoningTraces) {
        allMessages.filter { message ->
            message.hasRenderableConversationContent(
                taskPlan = plansByMessage[message.id],
                subagents = subagentsByMessage[message.id].orEmpty(),
                includeReasoning = state.showReasoningTraces,
            )
        }
    }
    val runtime = resolvedCardRuntime(
        card?.runtime.orEmpty(),
        conversation?.status.orEmpty(),
        card?.id?.let(state.cardOperations::get),
    )
    val activeTurn = isActiveCardRuntime(runtime)
    val interrupting = card != null && state.cardOperations[card.id] == CardOperation.CANCELLING
    val turnFailure = remember(allMessages, conversation?.status, card?.runtime) {
        resolveConversationTurnFailure(
            messages = allMessages,
            conversationStatus = conversation?.status.orEmpty(),
            cardRuntime = card?.runtime.orEmpty(),
        )
    }
    var presentedFailureLog by remember(card?.id, turnFailure?.log) { mutableStateOf<String?>(null) }
    var failureRetryQueued by remember(card?.id, turnFailure?.log) { mutableStateOf(false) }
    val assistantCount = remember(messages) {
        messages.count { it.role.equals("assistant", true) || it.role.equals("agent", true) }
    }
    val contextUsage = remember(allMessages) { latestContextUsage(allMessages) }
    // Keep the live cue at the transcript tail for the whole turn. Partial
    // assistant text must not make the agent appear idle while it is still
    // generating more text or running tools.
    val showAgentWorking = shouldShowAgentWorking(activeTurn, awaitingAgent)
    fun addPickedAttachments(uris: List<android.net.Uri>, imagesOnly: Boolean) {
        if (uris.isEmpty()) return
        scope.launch {
            composerError = null
            val results = withContext(Dispatchers.IO) {
                uris.map { uri -> runCatching { readAttachmentPart(context, uri, imagesOnly) } }
            }
            val incoming = results.mapNotNull(Result<MessagePart>::getOrNull)
            val limitError = attachmentLimitError(attachments, incoming)
            if (limitError == null) attachments += incoming
            composerError = limitError ?: results.firstNotNullOfOrNull { result ->
                result.exceptionOrNull()?.message
            }
        }
    }
    val imagePicker = rememberLauncherForActivityResult(
        ActivityResultContracts.PickMultipleVisualMedia(MAX_COMPOSER_ATTACHMENTS),
    ) { uris -> addPickedAttachments(uris, imagesOnly = true) }
    val filePicker = rememberLauncherForActivityResult(
        ActivityResultContracts.OpenMultipleDocuments(),
    ) { uris -> addPickedAttachments(uris, imagesOnly = false) }
    LaunchedEffect(activeTurn, assistantCount, state.error) {
        if (activeTurn) observedActiveTurn = true
        if (state.error != null || assistantCount > assistantCountAtSend || (observedActiveTurn && !activeTurn)) {
            awaitingAgent = false
        }
        if (activeTurn || turnFailure == null || state.error != null) failureRetryQueued = false
    }
    var consumedScrollRequest by remember(state.selectedCardId) { mutableStateOf(Long.MIN_VALUE) }
    LaunchedEffect(listState) {
        snapshotFlow { listState.isScrollInProgress }
            .distinctUntilChanged()
            .collect { scrolling ->
                if (scrolling) {
                    followingLatest = false
                } else if (initialScrollComplete) {
                    followingLatest = listState.isAtConversationEnd()
                }
            }
    }
    fun requestEarlierHistory(viewport: ConversationHistoryViewport) {
        if (!shouldLoadEarlierConversationHistory(
                hasMore = state.historyHasMore,
                loading = state.historyLoading,
                anchorPending = historyAnchorPending,
                initialScrollComplete = initialScrollComplete,
                viewport = viewport,
            )
        ) return
        historyAnchorPending = true
        historyObservedLoading = false
        historyKeepLatest = followingLatest && listState.isAtConversationEnd()
        historyStartAtRequest = state.historyStart
        historyAnchorKey = if (historyKeepLatest) {
            null
        } else {
            listState.layoutInfo.visibleItemsInfo
                .map { it.key.toString() }
                .firstOrNull { it.startsWith("message:") }
                ?: messages.firstOrNull()?.let { conversationMessageKey(it, 0) }
        }
        model.loadOlderMessages()
    }
    LaunchedEffect(
        listState,
        state.selectedCardId,
        state.historyHasMore,
        state.historyLoading,
        historyAnchorPending,
        initialScrollComplete,
    ) {
        snapshotFlow {
            val layout = listState.layoutInfo
            ConversationHistoryViewport(
                firstVisibleItemIndex = listState.firstVisibleItemIndex,
                canScrollBackward = listState.canScrollBackward,
                canScrollForward = listState.canScrollForward,
                hasItems = layout.totalItemsCount > 0,
            )
        }
            .distinctUntilChanged()
            .collect(::requestEarlierHistory)
    }
    LaunchedEffect(
        state.historyStart,
        state.historyLoading,
        messages.size,
        historyAnchorPending,
    ) {
        if (!historyAnchorPending) return@LaunchedEffect
        if (!state.historyHasMore && !state.historyLoading && state.historyStart == historyStartAtRequest) {
            historyAnchorPending = false
            historyAnchorKey = null
            historyObservedLoading = false
            return@LaunchedEffect
        }
        if (state.historyLoading) {
            historyObservedLoading = true
            return@LaunchedEffect
        }
        if (!historyObservedLoading && state.historyStart == historyStartAtRequest) return@LaunchedEffect
        if (state.historyStart != historyStartAtRequest) {
            delay(1)
            if (historyKeepLatest) {
                val endIndex = listState.layoutInfo.totalItemsCount - 1
                if (endIndex >= 0) listState.scrollToItem(endIndex)
                followingLatest = true
            } else if (historyAnchorKey != null) {
                val messageIndex = messages.withIndex().indexOfFirst { (index, message) ->
                    conversationMessageKey(message, index) == historyAnchorKey
                }
                if (messageIndex >= 0) {
                    val historyItems = if (state.historyHasMore || state.historyLoading) 1 else 0
                    val unsentTaskItems = if (hasUnsentDraft) 1 else 0
                    listState.scrollToItem(historyItems + unsentTaskItems + messageIndex)
                }
                followingLatest = false
            }
        } else {
            // Keep the anchor pending after a failed request. This prevents an
            // automatic retry loop; the visible history control remains a
            // manual retry path.
            return@LaunchedEffect
        }
        historyAnchorPending = false
        historyAnchorKey = null
        historyObservedLoading = false
    }
    LaunchedEffect(
        state.conversationScrollRequest,
        messages.size,
        messages.lastOrNull()?.hashCode(),
        unsentTask,
        draftAttachments.hashCode(),
        showAgentWorking,
        queuedMessages.size,
        queuedMessages.lastOrNull()?.id,
    ) {
        // Wait until the updated row sizes are reflected in LazyListState.
        // If new tool/model content grew below the current viewport, preserve
        // the reading position and expose the explicit jump affordance.
        withFrameNanos { }
        val historyItems = if (state.historyHasMore || state.historyLoading) 1 else 0
        val unsentTaskItems = if (hasUnsentDraft) 1 else 0
        val endIndex = historyItems + unsentTaskItems + messages.size +
            (if (showAgentWorking) 1 else 0) + queuedMessages.size
        val explicitOpenScroll = consumedScrollRequest != state.conversationScrollRequest
        val isAtLatestAfterUpdate = listState.isAtConversationEnd()
        if ((hasUnsentDraft || messages.isNotEmpty() || showAgentWorking || queuedMessages.isNotEmpty()) &&
            shouldFollowConversationUpdate(
                explicitOpenScroll = explicitOpenScroll,
                initialScrollComplete = initialScrollComplete,
                followingLatest = followingLatest,
                isAtLatestAfterUpdate = isAtLatestAfterUpdate,
            )
        ) {
            listState.scrollToItem(endIndex)
            consumedScrollRequest = state.conversationScrollRequest
            initialScrollComplete = true
            followingLatest = true
        } else if (initialScrollComplete && followingLatest && !isAtLatestAfterUpdate) {
            followingLatest = false
        }
    }
    Column(modifier) {
        if (!hasUnsentDraft && messages.isEmpty() && !showAgentWorking && queuedMessages.isEmpty()) {
            if (state.conversation == null) LoadingState(Modifier.weight(1f))
            else EmptyList("Conversation is ready", "Send a message to resume the same durable harness session.", Icons.Outlined.ChatBubbleOutline, Modifier.weight(1f))
        } else {
            Box(Modifier.weight(1f)) {
                LazyColumn(
                    state = listState,
                    modifier = Modifier.fillMaxSize()
                        .alpha(if (initialScrollComplete) 1f else 0f)
                        .testTag("conversation-list"),
                    contentPadding = PaddingValues(horizontal = 12.dp, vertical = 12.dp),
                    verticalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    if (state.historyHasMore || state.historyLoading) {
                        item(key = "history") {
                            OutlinedButton(
                                onClick = model::loadOlderMessages,
                                enabled = !state.historyLoading,
                                modifier = Modifier.fillMaxWidth(),
                            ) {
                                if (state.historyLoading) {
                                    CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp)
                                    Spacer(Modifier.width(8.dp))
                                    Text("Loading earlier messages…", color = DieterMuted, fontSize = 11.sp)
                                } else {
                                    Text("Load earlier messages · ${allMessages.size} of ${state.historyTotal}")
                                }
                            }
                        }
                    }
                    if (hasUnsentDraft) {
                        item(key = "unsent-agent-task") {
                            UnsentTaskMessage(unsentTask.orEmpty(), draftAttachments)
                        }
                    }
                    itemsIndexed(messages, key = { index, message -> conversationMessageKey(message, index) }) { _, message ->
                        val plan = plansByMessage[message.id]
                        val subagents = subagentsByMessage[message.id].orEmpty()
                        // animateItem eases freshly synced messages in instead
                        // of teleporting the stale transcript to the new tail.
                        Box(Modifier.animateItem()) {
                            MessageBlock(
                                message,
                                model,
                                showAgentAvatar = card?.scope == "chat",
                                showReasoningTraces = state.showReasoningTraces,
                                plan = plan,
                                subagents = subagents,
                            )
                        }
                    }
                    if (showAgentWorking) {
                        item(key = "agent-working") {
                            AgentWorkingIndicator(conversation?.pendingToolsList?.lastOrNull()?.toolName.orEmpty())
                        }
                    }
                    if (turnFailure != null) {
                        item(key = "turn-failure") {
                            TurnFailureBanner(
                                failure = turnFailure,
                                retrying = failureRetryQueued,
                                onViewLog = { presentedFailureLog = turnFailure.log },
                                onRetry = {
                                    if (!failureRetryQueued) {
                                        failureRetryQueued = true
                                        model.retryFailedTurn(turnFailure.retryParts)
                                    }
                                },
                            )
                        }
                    }
                    items(queuedMessages, key = { "queued-${it.id}" }) { queued ->
                        QueuedMessageBlock(
                            queued = queued,
                            showInterrupt = queued.id == queuedMessages.firstOrNull()?.id && activeTurn,
                            interrupting = interrupting,
                            onInterrupt = model::cancelSelected,
                        )
                    }
                    item(key = "conversation-end") { Spacer(Modifier.height(1.dp)) }
                }
                if (initialScrollComplete && !followingLatest && listState.canScrollForward) {
                    FilledTonalButton(
                        onClick = {
                            scope.launch {
                                val endIndex = listState.layoutInfo.totalItemsCount - 1
                                if (endIndex >= 0) listState.scrollToItem(endIndex)
                                followingLatest = true
                            }
                        },
                        modifier = Modifier
                            .align(Alignment.BottomCenter)
                            .padding(bottom = 12.dp)
                            .height(36.dp)
                            .testTag("jump-to-latest"),
                        shape = CircleShape,
                        colors = ButtonDefaults.filledTonalButtonColors(
                            containerColor = DieterSurfaceHigh,
                            contentColor = MaterialTheme.colorScheme.onSurface,
                        ),
                        contentPadding = PaddingValues(horizontal = 13.dp),
                    ) {
                        Icon(Icons.Outlined.KeyboardArrowDown, null, Modifier.size(18.dp))
                        Spacer(Modifier.width(4.dp))
                        Text("Jump to latest", fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
                    }
                }
            }
        }
        if (state.selectedCard?.lane?.contains("review", ignoreCase = true) == true) {
            Row(
                Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp)
                    .clip(RoundedCornerShape(16.dp)).background(DieterAmberTint).padding(12.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(Icons.Outlined.Schedule, null, tint = DieterAmber)
                Spacer(Modifier.width(10.dp))
                Column(Modifier.weight(1f)) {
                    Text("Ready for review", fontWeight = FontWeight.SemiBold, color = DieterAmber)
                    Text("Send feedback or mark it done.", fontSize = 12.sp, color = DieterMuted)
                }
                Button(
                    onClick = model::markDone,
                    colors = ButtonDefaults.buttonColors(containerColor = DieterAmber, contentColor = DieterAbyss),
                ) { Text("Mark done") }
            }
        }
        if (card?.canStartFromTodo(draftAttachments.isNotEmpty()) == true) {
            StartCardBanner(
                starting = state.cardOperations[card.id] == CardOperation.STARTING,
                error = state.cardOperationErrors[card.id],
                onStart = model::startSelectedCard,
            )
        }
        MessageComposer(
            value = text,
            placeholder = "Message the local agent…",
            enabled = !state.working,
            harnesses = state.harnesses,
            card = state.selectedCard,
            contextUsage = contextUsage,
            attachments = attachments,
            error = composerError,
            onValueChange = { text = it },
            onAttach = { attachmentPickerVisible = true },
            onRemoveAttachment = { attachments.removeAt(it) },
            onSend = { provider, selectedModel, effort, providerOptions ->
                val message = text.trim()
                if (message.isNotBlank() || attachments.isNotEmpty()) {
                    assistantCountAtSend = assistantCount
                    observedActiveTurn = false
                    awaitingAgent = true
                    val parts = attachments.toList()
                    model.sendMessage(message, parts, provider, selectedModel, effort, providerOptions) {
                        if (text.trim() == message) text = ""
                        if (attachments.toList() == parts) attachments.clear()
                    }
                }
            },
        )
    }
    if (attachmentPickerVisible) {
        AttachmentPickerSheet(
            onDismiss = { attachmentPickerVisible = false },
            onImages = {
                attachmentPickerVisible = false
                imagePicker.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly))
            },
            onFiles = {
                attachmentPickerVisible = false
                filePicker.launch(arrayOf("*/*"))
            },
        )
    }
    presentedFailureLog?.let { log ->
        TurnFailureLogDialog(log = log, onDismiss = { presentedFailureLog = null })
    }
}

@Composable
internal fun TurnFailureBanner(
    failure: ConversationTurnFailure,
    retrying: Boolean,
    onViewLog: () -> Unit,
    onRetry: () -> Unit,
) {
    Surface(
        color = DieterSurfaceHigh.copy(alpha = 0.94f),
        shape = RoundedCornerShape(17.dp),
        border = androidx.compose.foundation.BorderStroke(1.dp, MaterialTheme.colorScheme.error.copy(alpha = 0.48f)),
        shadowElevation = 4.dp,
        modifier = Modifier.fillMaxWidth().testTag("turn-failure"),
    ) {
        Column(Modifier.padding(15.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Row(verticalAlignment = Alignment.Top) {
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text(
                        "Turn failed",
                        color = MaterialTheme.colorScheme.onSurface,
                        fontSize = 16.sp,
                        fontWeight = FontWeight.SemiBold,
                    )
                    SelectionContainer {
                        Text(
                            "Turn failed — ${failure.summary}",
                            color = MaterialTheme.colorScheme.error,
                            fontSize = 13.sp,
                            lineHeight = 18.sp,
                        )
                    }
                }
                Spacer(Modifier.width(8.dp))
                Icon(Icons.Outlined.Cancel, null, tint = MaterialTheme.colorScheme.error, modifier = Modifier.size(20.dp))
            }
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Surface(color = MaterialTheme.colorScheme.error.copy(alpha = 0.13f), shape = CircleShape) {
                    Text(
                        "●  Failed",
                        color = MaterialTheme.colorScheme.error,
                        fontSize = 11.sp,
                        fontWeight = FontWeight.SemiBold,
                        modifier = Modifier.padding(horizontal = 10.dp, vertical = 6.dp),
                    )
                }
                Spacer(Modifier.weight(1f))
                TextButton(onClick = onViewLog, modifier = Modifier.testTag("turn-failure-view-log")) {
                    Text("View log", fontWeight = FontWeight.SemiBold)
                }
                Button(
                    onClick = onRetry,
                    enabled = !retrying && failure.retryParts.isNotEmpty(),
                    modifier = Modifier.testTag("turn-failure-retry"),
                    colors = ButtonDefaults.buttonColors(
                        containerColor = MaterialTheme.colorScheme.onSurface,
                        contentColor = MaterialTheme.colorScheme.surface,
                    ),
                ) {
                    if (retrying) CircularProgressIndicator(Modifier.size(14.dp), strokeWidth = 2.dp)
                    else Icon(Icons.Outlined.Refresh, null, Modifier.size(16.dp))
                    Spacer(Modifier.width(5.dp))
                    Text(if (retrying) "Retry queued…" else "Retry turn", fontWeight = FontWeight.SemiBold)
                }
            }
        }
    }
}

@Composable
internal fun TurnFailureLogDialog(log: String, onDismiss: () -> Unit) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Turn failure log") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text("Complete output captured from the local harness worker.", color = DieterMuted, fontSize = 12.sp)
                Surface(
                    color = DieterSurface,
                    shape = RoundedCornerShape(10.dp),
                    border = androidx.compose.foundation.BorderStroke(1.dp, DieterOutline),
                ) {
                    SelectionContainer {
                        Text(
                            log,
                            fontFamily = FontFamily.Monospace,
                            fontSize = 11.sp,
                            lineHeight = 16.sp,
                            modifier = Modifier.fillMaxWidth().heightIn(max = 360.dp)
                                .verticalScroll(rememberScrollState()).padding(12.dp)
                                .testTag("turn-failure-log"),
                        )
                    }
                }
            }
        },
        confirmButton = { TextButton(onClick = onDismiss) { Text("Done") } },
        modifier = Modifier.testTag("turn-failure-log-dialog"),
    )
}

@Composable
internal fun QueuedMessageBlock(
    queued: QueuedMessage,
    showInterrupt: Boolean,
    interrupting: Boolean,
    onInterrupt: () -> Unit,
) {
    val parts = queued.partsList.ifEmpty {
        listOf(MessagePart.newBuilder().setType("text").setText(queued.text).build())
    }
    Column(
        Modifier.fillMaxWidth(),
        horizontalAlignment = Alignment.End,
        verticalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        Surface(
            color = DieterShellDeep.copy(alpha = 0.82f),
            contentColor = Color.White,
            shape = RoundedCornerShape(17.dp),
            border = androidx.compose.foundation.BorderStroke(1.dp, DieterAmber.copy(alpha = 0.48f)),
            modifier = Modifier.widthIn(max = 340.dp).testTag("queued-message-${queued.id}"),
        ) {
            Column(
                Modifier.padding(start = 13.dp, top = 9.dp, end = 9.dp, bottom = 8.dp),
                verticalArrangement = Arrangement.spacedBy(7.dp),
            ) {
                Column(Modifier.padding(end = 9.dp)) {
                    parts.forEach { part ->
                        when {
                            part.type == "text" && part.text.isNotBlank() -> SelectionContainer {
                                MessageMarkdown(part.text, compact = true)
                            }
                            part.type == "file" -> AttachmentPart(part)
                            part.text.isNotBlank() -> MessageMarkdown(part.text, compact = true)
                        }
                    }
                }
                Row(
                    Modifier.fillMaxWidth().heightIn(min = 28.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Icon(Icons.Outlined.Schedule, null, Modifier.size(13.dp), tint = DieterAmber)
                    Spacer(Modifier.width(5.dp))
                    Text(
                        "QUEUED",
                        color = DieterAmber,
                        fontSize = 10.sp,
                        fontWeight = FontWeight.Bold,
                        letterSpacing = 0.7.sp,
                    )
                    if (showInterrupt) {
                        Spacer(Modifier.weight(1f))
                        Surface(
                            onClick = onInterrupt,
                            enabled = !interrupting,
                            modifier = Modifier
                                .heightIn(min = 28.dp)
                                .testTag("interrupt-queued-message")
                                .semantics {
                                    contentDescription = "Interrupt current turn and send this message now"
                                },
                            shape = CircleShape,
                            color = MaterialTheme.colorScheme.error.copy(alpha = 0.11f),
                            contentColor = MaterialTheme.colorScheme.error,
                            border = androidx.compose.foundation.BorderStroke(
                                1.dp,
                                MaterialTheme.colorScheme.error.copy(alpha = 0.24f),
                            ),
                        ) {
                            Row(
                                Modifier.padding(horizontal = 9.dp, vertical = 5.dp),
                                verticalAlignment = Alignment.CenterVertically,
                            ) {
                                if (interrupting) {
                                    CircularProgressIndicator(
                                        Modifier.size(13.dp),
                                        strokeWidth = 2.dp,
                                        color = MaterialTheme.colorScheme.error,
                                    )
                                } else {
                                    Icon(Icons.Outlined.Cancel, null, Modifier.size(14.dp))
                                }
                                Spacer(Modifier.width(5.dp))
                                Text(
                                    if (interrupting) "Interrupting…" else "Interrupt",
                                    fontSize = 11.sp,
                                    fontWeight = FontWeight.SemiBold,
                                )
                            }
                        }
                    }
                }
            }
        }
    }
}

@Composable
internal fun UnsentTaskMessage(task: String, attachments: List<MessagePart> = emptyList()) {
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
        Surface(
            color = DieterSurfaceHigh.copy(alpha = 0.72f),
            contentColor = DieterMuted,
            shape = RoundedCornerShape(17.dp),
            border = androidx.compose.foundation.BorderStroke(1.dp, DieterOutline),
            modifier = Modifier.widthIn(max = 340.dp).testTag("unsent-agent-task"),
        ) {
            Column(
                Modifier.padding(horizontal = 13.dp, vertical = 10.dp),
                verticalArrangement = Arrangement.spacedBy(7.dp),
            ) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Outlined.Schedule, null, Modifier.size(14.dp))
                    Spacer(Modifier.width(6.dp))
                    Text("NOT SENT", fontSize = 10.sp, fontWeight = FontWeight.Bold, letterSpacing = 0.8.sp)
                }
                if (task.isNotBlank()) SelectionContainer { MessageMarkdown(task, compact = true) }
                attachments.forEach { part -> AttachmentPart(part) }
            }
        }
    }
}

@Composable
internal fun StartCardBanner(starting: Boolean, error: String?, onStart: () -> Unit) {
    Surface(
        color = DieterShell.copy(alpha = 0.12f),
        shape = RoundedCornerShape(16.dp),
        border = androidx.compose.foundation.BorderStroke(1.dp, DieterShell.copy(alpha = 0.34f)),
        modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 8.dp),
    ) {
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Column(Modifier.weight(1f)) {
                Text("Ready to start", fontWeight = FontWeight.SemiBold, fontSize = 14.sp)
                Text(
                    if (starting) "The daemon accepted the start request…" else "Run the saved task and move this card to Running.",
                    color = DieterMuted,
                    fontSize = 12.sp,
                    lineHeight = 17.sp,
                )
                if (!error.isNullOrBlank()) {
                    Text(error, color = MaterialTheme.colorScheme.error, fontSize = 11.sp, lineHeight = 15.sp)
                }
            }
            Button(
                onClick = onStart,
                enabled = !starting,
                modifier = Modifier.testTag("start-card"),
                colors = ButtonDefaults.buttonColors(
                    containerColor = DieterShell,
                    contentColor = DieterAbyss,
                ),
            ) {
                if (starting) {
                    CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp)
                } else {
                    Icon(Icons.Default.PlayArrow, null, Modifier.size(18.dp))
                }
                Spacer(Modifier.width(6.dp))
                Text(if (starting) "Starting…" else "Start card")
            }
        }
    }
}

internal fun LazyListState.isAtConversationEnd(): Boolean {
    val layout = layoutInfo
    if (layout.totalItemsCount == 0) return true
    return layout.visibleItemsInfo.lastOrNull()?.index == layout.totalItemsCount - 1
}

internal fun conversationMessageKey(message: UiMessage, index: Int): String =
    if (message.id.isNotBlank()) "message:${message.id}" else "message:anonymous:${message.hashCode()}:$index"

@Composable
internal fun MessageBlock(
    message: UiMessage,
    model: DieterViewModel,
    showAgentAvatar: Boolean,
    showReasoningTraces: Boolean,
    plan: TaskPlan? = null,
    subagents: List<Subagent> = emptyList(),
) {
    val fromUser = message.role.equals("user", true) || message.role.equals("human", true)
    val failed = model.isFailedOutboxItem(message.id)
    val pendingAlpha = if (model.isPendingMessage(message.id) && !failed) 0.52f else 1f
    if (fromUser) {
        Row(Modifier.fillMaxWidth().alpha(pendingAlpha), horizontalArrangement = Arrangement.End) {
            Surface(
                color = DieterShellDeep,
                contentColor = Color.White,
                shape = RoundedCornerShape(17.dp),
                modifier = Modifier.widthIn(max = 340.dp),
            ) {
                Box {
                    Column(Modifier.padding(start = 13.dp, top = 8.dp, end = 18.dp, bottom = 8.dp)) {
                        MessageParts(
                            message,
                            model,
                            compact = true,
                            showReasoningTraces = showReasoningTraces,
                            plan = plan,
                            subagents = subagents,
                        )
                        if (failed) {
                            Row(
                                Modifier.fillMaxWidth().padding(top = 4.dp),
                                horizontalArrangement = Arrangement.End,
                                verticalAlignment = Alignment.CenterVertically,
                            ) {
                                Text("Send failed", color = MaterialTheme.colorScheme.error, fontSize = 11.sp)
                                Spacer(Modifier.weight(1f))
                                TextButton(onClick = { model.retryOutboxItem(message.id) }) { Text("Retry") }
                                TextButton(
                                    onClick = { model.discardOutboxItem(message.id) },
                                    modifier = Modifier.testTag("failed-message-remove:${message.id}"),
                                ) { Text("Remove", color = MaterialTheme.colorScheme.error) }
                            }
                        }
                    }
                    if (!failed) {
                        MessageDeliveryReceipt(
                            messageDeliveryState(
                                pending = model.isPendingMessage(message.id),
                                accepted = model.isAcceptedOutboxItem(message.id),
                                failed = false,
                            ),
                            Modifier.align(Alignment.BottomEnd).offset(x = (-4).dp, y = (-4).dp),
                        )
                    }
                }
            }
        }
    } else if (showAgentAvatar) {
        Row(Modifier.fillMaxWidth().alpha(pendingAlpha), verticalAlignment = Alignment.Top) {
            AgentAvatar()
            Spacer(Modifier.width(10.dp))
            Column(Modifier.weight(1f)) {
                MessageParts(message, model, showReasoningTraces = showReasoningTraces, plan = plan, subagents = subagents)
            }
        }
    } else {
        Column(Modifier.fillMaxWidth().alpha(pendingAlpha)) {
            MessageParts(message, model, showReasoningTraces = showReasoningTraces, plan = plan, subagents = subagents)
        }
    }
}

enum class MessageDeliveryState { LOCAL, ACCEPTED, SYNCED, FAILED }

fun messageDeliveryState(pending: Boolean, accepted: Boolean, failed: Boolean): MessageDeliveryState = when {
    failed -> MessageDeliveryState.FAILED
    !pending -> MessageDeliveryState.SYNCED
    accepted -> MessageDeliveryState.ACCEPTED
    else -> MessageDeliveryState.LOCAL
}

@Composable
internal fun MessageDeliveryReceipt(state: MessageDeliveryState, modifier: Modifier = Modifier) {
    val tint = if (state == MessageDeliveryState.FAILED) MaterialTheme.colorScheme.error else Color.White.copy(alpha = 0.72f)
    val description = when (state) {
        MessageDeliveryState.LOCAL -> "Waiting to send"
        MessageDeliveryState.ACCEPTED -> "Accepted by daemon"
        MessageDeliveryState.SYNCED -> "Synced"
        MessageDeliveryState.FAILED -> "Send failed; retry or remove this message"
    }
    Box(modifier.width(14.dp).height(10.dp)) {
        when (state) {
            MessageDeliveryState.LOCAL -> Icon(Icons.Outlined.Schedule, description, tint = tint, modifier = Modifier.size(10.dp))
            MessageDeliveryState.ACCEPTED -> Icon(Icons.Default.Check, description, tint = tint, modifier = Modifier.size(11.dp))
            MessageDeliveryState.SYNCED -> {
                Icon(Icons.Default.Check, description, tint = tint, modifier = Modifier.offset(x = (-1).dp).size(11.dp))
                Icon(Icons.Default.Check, null, tint = tint, modifier = Modifier.offset(x = 3.dp).size(11.dp))
            }
            MessageDeliveryState.FAILED -> Text("!", color = tint, fontSize = 10.sp)
        }
    }
}

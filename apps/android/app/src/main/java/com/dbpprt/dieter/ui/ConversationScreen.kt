@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)

package com.dbpprt.dieter.ui

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
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
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
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
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
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
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.nestedscroll.NestedScrollConnection
import androidx.compose.ui.input.nestedscroll.NestedScrollSource
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.currentStateAsState
import com.dbpprt.dieter.api.v1.MessagePart
import com.dbpprt.dieter.api.v1.QueuedMessage
import com.dbpprt.dieter.core.composition.Attachments
import com.dbpprt.dieter.core.conversation.TurnFailure
import com.dbpprt.dieter.core.presentation.ConversationPresentation
import com.dbpprt.dieter.core.presentation.Delivery
import com.dbpprt.dieter.core.presentation.DeliveryState
import com.dbpprt.dieter.core.presentation.TimelineItem
import com.dbpprt.dieter.core.selection.AgentControls
import com.dbpprt.dieter.ui.theme.DieterAbyss
import com.dbpprt.dieter.ui.theme.DieterAmber
import com.dbpprt.dieter.ui.theme.DieterAmberTint
import com.dbpprt.dieter.ui.theme.DieterMuted
import com.dbpprt.dieter.ui.theme.DieterOutline
import com.dbpprt.dieter.ui.theme.DieterShell
import com.dbpprt.dieter.ui.theme.DieterShellDeep
import com.dbpprt.dieter.ui.theme.DieterSurface
import com.dbpprt.dieter.ui.theme.DieterSurfaceHigh
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** The open conversation's transcript and composer; [presentation] and the composer's [agent] pickers come from the card detail. */
@Composable
internal fun ConversationBody(
    state: DieterUiState,
    model: DieterViewModel,
    presentation: ConversationPresentation,
    agent: AgentControls?,
    modifier: Modifier = Modifier,
) {
    val items = presentation.timeline.items
    val listState = remember(state.selectedCardId) { LazyListState() }
    var initialScrollComplete by remember(state.selectedCardId) { mutableStateOf(false) }
    var followingLatest by remember(state.selectedCardId) { mutableStateOf(true) }
    var historyAnchorPending by remember(state.selectedCardId) { mutableStateOf(false) }
    var historyAnchorKey by remember(state.selectedCardId) { mutableStateOf<String?>(null) }
    var historyKeepLatest by remember(state.selectedCardId) { mutableStateOf(false) }
    var historyStartAtRequest by remember(state.selectedCardId) { mutableStateOf(0) }
    var historyObservedLoading by remember(state.selectedCardId) { mutableStateOf(false) }
    var composerError by remember(state.selectedCardId) { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    var attachmentPickerVisible by remember(state.selectedCardId) { mutableStateOf(false) }
    val conversation = state.conversation?.conversation
    val card = presentation.card
    val lifecycleState by LocalLifecycleOwner.current.lifecycle.currentStateAsState()
    val latestVisible by remember(listState) { derivedStateOf { listState.isAtConversationEnd() } }
    val responseLoaded = (conversation?.last_seq ?: 0) >= (card?.response_seq ?: 0)
    LaunchedEffect(card?.id, card?.response_seq, card?.seen_response_seq, initialScrollComplete, responseLoaded,
        latestVisible, lifecycleState, state.connected) {
        if (lifecycleState == Lifecycle.State.RESUMED && initialScrollComplete && latestVisible && state.connected && card != null) {
            // Let the completed reply settle into the viewport. Scrolling or backgrounding
            // cancels this effect before it can acknowledge a merely mounted message.
            delay(200)
            if (listState.isAtConversationEnd()) model.markResponseSeen(card.id)
        }
    }
    val host = card?.let(state::conversationHost)
    val storageQueue = host?.id?.let(state.machineOutboxSummaries::get)?.takeIf { it.storageBanner }
    val draft = state.composerDraft
    val creationFailure = card?.id
        ?.takeIf(state.failedOutboxIds::contains)
        ?.let(model::conversationCreationFailure)
    val turnFailure = presentation.turnFailure
    var presentedFailureLog by remember(card?.id, turnFailure?.log) { mutableStateOf<String?>(null) }
    fun addPickedAttachments(uris: List<android.net.Uri>, imagesOnly: Boolean) {
        if (uris.isEmpty()) return
        scope.launch {
            composerError = null
            val results = withContext(Dispatchers.IO) {
                uris.map { uri -> runCatching { readAttachmentPart(context, uri, imagesOnly) } }
            }
            // The core takes every readable file or none of them, and says which limit they break.
            composerError = model.addComposerAttachments(results.mapNotNull(Result<MessagePart>::getOrNull))
                ?: results.firstNotNullOfOrNull { result -> result.exceptionOrNull()?.message }
        }
    }
    val imagePicker = rememberLauncherForActivityResult(
        ActivityResultContracts.PickMultipleVisualMedia(Attachments.MAX_COUNT),
    ) { uris -> addPickedAttachments(uris, imagesOnly = true) }
    val filePicker = rememberLauncherForActivityResult(
        ActivityResultContracts.OpenMultipleDocuments(),
    ) { uris -> addPickedAttachments(uris, imagesOnly = false) }
    var consumedScrollRequest by remember(state.selectedCardId) { mutableStateOf(Long.MIN_VALUE) }
    LaunchedEffect(listState) {
        snapshotFlow { listState.isScrollInProgress }
            .distinctUntilChanged()
            .collect { scrolling ->
                if (!scrolling && initialScrollComplete && !followingLatest) {
                    followingLatest = listState.isAtConversationEnd()
                }
            }
    }
    val userScrollConnection = remember(state.selectedCardId) {
        object : NestedScrollConnection {
            override fun onPreScroll(available: Offset, source: NestedScrollSource): Offset {
                if (source == NestedScrollSource.UserInput && available.y != 0f && initialScrollComplete) {
                    followingLatest = false
                }
                return Offset.Zero
            }
        }
    }
    val rows = ConversationRows(
        history = state.historyHasMore || state.historyLoading,
        unsentTask = presentation.hasUnsentDraft,
        timelineItems = items.size,
        working = presentation.working,
        turnFailure = turnFailure != null,
        queued = presentation.queue.size,
    )
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
            val ids = items.mapTo(HashSet()) { it.id }
            listState.layoutInfo.visibleItemsInfo.map { it.key.toString() }.firstOrNull { it in ids } ?: items.firstOrNull()?.id
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
        items.size,
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
                val itemIndex = items.indexOfFirst { it.id == historyAnchorKey }
                if (itemIndex >= 0) listState.scrollToItem(rows.timelineStart + itemIndex)
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
        items.size,
        items.lastOrNull()?.hashCode(),
        presentation.unsentTask,
        presentation.draftAttachments.hashCode(),
        presentation.working,
        turnFailure != null,
        presentation.queue.size,
        presentation.queue.lastOrNull()?.id,
    ) {
        // Wait until the updated row sizes are reflected in LazyListState.
        // If new tool/model content grew below the current viewport, preserve
        // the reading position and expose the explicit jump affordance.
        withFrameNanos { }
        val explicitOpenScroll = consumedScrollRequest != state.conversationScrollRequest
        if (!presentation.empty &&
            shouldFollowConversationUpdate(
                explicitOpenScroll = explicitOpenScroll,
                initialScrollComplete = initialScrollComplete,
                followingLatest = followingLatest,
            )
        ) {
            listState.scrollToItem(rows.end)
            consumedScrollRequest = state.conversationScrollRequest
            initialScrollComplete = true
            followingLatest = true
        }
    }
    Column(modifier) {
        if (host != null && storageQueue != null) {
            StorageDeliveryBanner(
                machineName = host.label,
                detail = storageQueue.deliveryLabel,
                onRetry = { model.retryOutboxForEndpoint(host.id) },
            )
        }
        creationFailure?.let { failure ->
            CreationFailureBanner(
                failure = failure,
                onRetry = { model.retryOutboxItem(card.id) },
                onDiscard = { model.discardOutboxItem(card.id) },
            )
        }
        if (presentation.empty) {
            if (state.conversation == null) LoadingState(Modifier.weight(1f))
            else EmptyList("Conversation is ready", "Send a message to resume the same durable harness session.", Icons.Outlined.ChatBubbleOutline, Modifier.weight(1f))
        } else {
            val workspaceRoot = state.workspaceReview.workspace?.path?.takeIf { state.workspaceReview.cardId == card?.id }
            Box(Modifier.weight(1f)) {
                CompositionLocalProvider(LocalWorkspaceRoot provides workspaceRoot) {
                LazyColumn(
                    state = listState,
                    modifier = Modifier.fillMaxSize()
                        .alpha(if (initialScrollComplete) 1f else 0f)
                        .nestedScroll(userScrollConnection)
                        .testTag("conversation-list"),
                    contentPadding = PaddingValues(horizontal = 12.dp, vertical = 12.dp),
                    verticalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    if (rows.history) {
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
                                    Text("Load earlier messages · ${presentation.loadedMessages} of ${state.historyTotal}")
                                }
                            }
                        }
                    }
                    if (rows.unsentTask) {
                        item(key = "unsent-agent-task") {
                            UnsentTaskMessage(presentation.unsentTask.orEmpty(), presentation.draftAttachments)
                        }
                    }
                    items(items, key = { it.id }) { item ->
                        // animateItem eases freshly synced messages in instead
                        // of teleporting the stale transcript to the new tail.
                        Box(Modifier.animateItem()) {
                            when (item) {
                                is TimelineItem.Message -> MessageBlock(item, presentation, model, showAgentAvatar = presentation.chat)
                                is TimelineItem.Activity -> ActivityBlock(item, model, showAgentAvatar = presentation.chat)
                            }
                        }
                    }
                    if (rows.working) {
                        item(key = "agent-working") {
                            AgentWorkingIndicator(presentation.liveActivity.english(), presentation.turnStart?.toEpochMilliseconds())
                        }
                    }
                    if (turnFailure != null) {
                        item(key = "turn-failure") {
                            TurnFailureBanner(
                                failure = turnFailure,
                                retrying = presentation.retrying,
                                onViewLog = { presentedFailureLog = turnFailure.log },
                                onRetry = model::retryFailedTurn,
                            )
                        }
                    }
                    items(presentation.queue, key = { "queued-${it.id}" }) { queued ->
                        QueuedMessageBlock(
                            queued = queued,
                            showInterrupt = queued.id == presentation.steerableId,
                            interrupting = presentation.interrupting,
                            pending = queued.id in draft.pendingQueueIds,
                            onEdit = { model.removeQueuedMessage(queued, edit = true) },
                            onRemove = { model.removeQueuedMessage(queued, edit = false) },
                            onInterrupt = { model.steerQueuedMessage(queued) },
                        )
                    }
                    item(key = "conversation-end") { Spacer(Modifier.height(1.dp)) }
                }
                }
                if (initialScrollComplete && !followingLatest && listState.canScrollForward) {
                    FilledTonalButton(
                        onClick = {
                            scope.launch {
                                val endIndex = listState.layoutInfo.totalItemsCount - 1
                                if (endIndex >= 0) listState.animateScrollToItem(endIndex)
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
        if (presentation.readyForReview) {
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
        if (card != null && (presentation.canStart || presentation.starting)) {
            StartCardBanner(
                starting = presentation.starting,
                error = state.cardOperationErrors[card.id],
                onStart = model::startSelectedCard,
            )
        }
        MessageComposer(
            value = draft.text,
            placeholder = "Message the local agent…",
            enabled = !state.working,
            controls = agent,
            contextUsage = presentation.contextUsage,
            respondingModel = presentation.respondingModel,
            attachments = draft.attachments,
            error = composerError,
            onValueChange = model::updateComposerText,
            onChoose = model::chooseAgent,
            onAttach = { attachmentPickerVisible = true },
            onRemoveAttachment = model::removeComposerAttachment,
            onSend = model::sendDraft,
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
internal fun StorageDeliveryBanner(machineName: String, detail: String, onRetry: () -> Unit) {
    Surface(
        color = DieterSurfaceHigh,
        border = androidx.compose.foundation.BorderStroke(1.dp, DieterAmber.copy(alpha = 0.48f)),
        modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 8.dp)
            .testTag("storage-delivery"),
    ) {
        Column(Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text("Low disk space on $machineName", color = DieterAmber, fontWeight = FontWeight.SemiBold)
            Text(detail, color = DieterMuted, fontSize = 12.sp)
            OutlinedButton(onClick = onRetry, modifier = Modifier.testTag("storage-delivery-retry")) {
                Text("Retry now")
            }
        }
    }
}

@Composable
internal fun CreationFailureBanner(
    failure: String,
    onRetry: () -> Unit,
    onDiscard: () -> Unit,
) {
    Surface(
        color = DieterSurfaceHigh.copy(alpha = 0.94f),
        border = androidx.compose.foundation.BorderStroke(1.dp, MaterialTheme.colorScheme.error.copy(alpha = 0.48f)),
        modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 8.dp)
            .testTag("creation-failure"),
    ) {
        Column(Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text("Conversation was not created", fontWeight = FontWeight.SemiBold)
            SelectionContainer {
                Text(
                    failure,
                    color = MaterialTheme.colorScheme.error,
                    fontSize = 13.sp,
                    lineHeight = 18.sp,
                )
            }
            Text(
                "No work started on the daemon. Retry this creation or discard the local draft.",
                color = DieterMuted,
                fontSize = 12.sp,
            )
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Button(onClick = onRetry, modifier = Modifier.testTag("creation-failure-retry")) {
                    Text("Retry creation")
                }
                TextButton(onClick = onDiscard, modifier = Modifier.testTag("creation-failure-discard")) {
                    Text("Discard")
                }
            }
        }
    }
}

@Composable
internal fun TurnFailureBanner(
    failure: TurnFailure,
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
    pending: Boolean,
    onEdit: () -> Unit,
    onRemove: () -> Unit,
    onInterrupt: () -> Unit,
) {
    val parts = queued.parts.ifEmpty {
        listOf(MessagePart(type = "text", text = queued.text))
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
                    Spacer(Modifier.weight(1f))
                    if (pending) {
                        CircularProgressIndicator(Modifier.size(15.dp), strokeWidth = 2.dp, color = DieterAmber)
                    } else {
                        TextButton(
                            onClick = onEdit,
                            modifier = Modifier.heightIn(min = 28.dp).testTag("edit-queued-message-${queued.id}"),
                            contentPadding = PaddingValues(horizontal = 7.dp),
                        ) { Text("Edit", fontSize = 11.sp) }
                        TextButton(
                            onClick = onRemove,
                            modifier = Modifier.heightIn(min = 28.dp).testTag("remove-queued-message-${queued.id}"),
                            contentPadding = PaddingValues(horizontal = 7.dp),
                        ) { Text("Remove", fontSize = 11.sp, color = MaterialTheme.colorScheme.error) }
                    }
                    if (showInterrupt) {
                        Surface(
                            onClick = onInterrupt,
                            enabled = !interrupting && !pending,
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

@Composable
internal fun MessageBlock(
    item: TimelineItem.Message,
    presentation: ConversationPresentation,
    model: DieterViewModel,
    showAgentAvatar: Boolean,
) {
    val message = item.message
    val delivery = presentation.delivery(message.id)
    val failed = delivery == DeliveryState.FAILED
    val pendingAlpha = if (presentation.unconfirmed(message.id)) 0.52f else 1f
    if (item.user) {
        Row(Modifier.fillMaxWidth().alpha(pendingAlpha), horizontalArrangement = Arrangement.End) {
            Surface(
                color = DieterShellDeep,
                contentColor = Color.White,
                shape = RoundedCornerShape(17.dp),
                modifier = Modifier.widthIn(max = 340.dp),
            ) {
                Box {
                    Column(Modifier.padding(start = 13.dp, top = 8.dp, end = 18.dp, bottom = 8.dp)) {
                        MessageParts(item, model, compact = true)
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
                        MessageDeliveryReceipt(delivery, Modifier.align(Alignment.BottomEnd).offset(x = (-4).dp, y = (-4).dp))
                    }
                }
            }
        }
    } else if (showAgentAvatar) {
        Row(Modifier.fillMaxWidth().alpha(pendingAlpha), verticalAlignment = Alignment.Top) {
            AgentAvatar()
            Spacer(Modifier.width(10.dp))
            Column(Modifier.weight(1f)) { MessageParts(item, model) }
        }
    } else {
        Column(Modifier.fillMaxWidth().alpha(pendingAlpha)) { MessageParts(item, model) }
    }
}

/** Consecutive assistant messages that only used tools or reasoned, folded into one summary. */
@Composable
internal fun ActivityBlock(item: TimelineItem.Activity, model: DieterViewModel, showAgentAvatar: Boolean) {
    val content: @Composable () -> Unit = {
        ActivityGroup(item.id, item.summary.english(), item.steps, model)
    }
    if (showAgentAvatar) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.Top) {
            AgentAvatar()
            Spacer(Modifier.width(10.dp))
            Column(Modifier.weight(1f)) { content() }
        }
    } else {
        Column(Modifier.fillMaxWidth()) { content() }
    }
}

@Composable
internal fun MessageDeliveryReceipt(state: DeliveryState, modifier: Modifier = Modifier) {
    val tint = if (state == DeliveryState.FAILED) MaterialTheme.colorScheme.error else Color.White.copy(alpha = 0.72f)
    val description = Delivery.label(state)
    Box(modifier.width(14.dp).height(10.dp)) {
        when (state) {
            DeliveryState.LOCAL, DeliveryState.QUEUED -> Icon(Icons.Outlined.Schedule, description, tint = tint, modifier = Modifier.size(10.dp))
            DeliveryState.ACCEPTED -> Icon(Icons.Default.Check, description, tint = tint, modifier = Modifier.size(11.dp))
            DeliveryState.SYNCED -> {
                Icon(Icons.Default.Check, description, tint = tint, modifier = Modifier.offset(x = (-1).dp).size(11.dp))
                Icon(Icons.Default.Check, null, tint = tint, modifier = Modifier.offset(x = 3.dp).size(11.dp))
            }
            DeliveryState.FAILED -> Text("!", color = tint, fontSize = 10.sp)
        }
    }
}

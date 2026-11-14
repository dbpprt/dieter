package com.getdieter.core.presentation

import com.getdieter.api.v1.Board
import com.getdieter.api.v1.Card
import com.getdieter.api.v1.Changeset
import com.getdieter.api.v1.HarnessCatalog
import com.getdieter.api.v1.MessagePart
import com.getdieter.api.v1.PendingTool
import com.getdieter.api.v1.QueuedMessage
import com.getdieter.api.v1.Subagent
import com.getdieter.api.v1.TaskPlan
import com.getdieter.api.v1.TaskPlanItem
import com.getdieter.api.v1.UiMessage
import com.getdieter.client.v1.ConversationState
import com.getdieter.client.v1.QueuedMessageState
import com.getdieter.core.board.CardOperation
import com.getdieter.core.board.CardPolicy
import com.getdieter.core.board.Cards
import com.getdieter.core.board.Lanes
import com.getdieter.core.board.RuntimeState
import com.getdieter.core.board.Runtimes
import com.getdieter.core.composition.WorkspaceMode
import com.getdieter.core.conversation.ConversationView
import com.getdieter.core.conversation.TurnFailure
import com.getdieter.core.metadata.MachineMetadata
import com.getdieter.core.outbox.OutboxPolicy
import com.getdieter.core.outbox.OutboxView
import com.getdieter.core.runtime.Timestamps
import com.getdieter.core.store.WorkspaceView
import kotlin.time.Instant

/**
 * Everything the conversation screen shows, derived from the open conversation once for every
 * client.
 */
data class ConversationPresentation(
    /**
     * The card, with a start still in the outbox applied (moved to the running lane, "starting").
     */
    val card: Card?,
    val timeline: Timeline,
    /** Loaded messages, older history included; the history control counts them. */
    val loadedMessages: Int,
    /** The runtime to show: a local start or cancel wins over the reported state. */
    val runtime: String,
    val activeTurn: Boolean,
    /** Show the agent as working: an active turn, or a sent message still waiting for its reply. */
    val working: Boolean,
    val liveActivity: LiveActivity,
    /** [liveActivity] with the turn's latest reasoning summary, for clients that show reasoning. */
    val liveReasoning: LiveActivity,
    val turnStart: Instant?,
    val turnFailure: TurnFailure?,
    /** The failed turn's retry was sent and has not run yet. */
    val retrying: Boolean,
    val contextUsage: ContextUsage?,
    /** The model Claude Code reported for its latest reply; it may differ from the selection. */
    val respondingModel: String?,
    /**
     * The trimmed task of a card whose task was never sent, while no user message exists; shown as
     * not sent.
     */
    val unsentTask: String?,
    /** Attachments saved with a never-started card; they belong to the unsent task. */
    val draftAttachments: List<MessagePart>,
    val queue: List<QueuedMessage>,
    /** The queued message that may interrupt the running turn now. */
    val steerableId: String?,
    val interrupting: Boolean,
    val readyForReview: Boolean,
    /** A Start can run the card's saved task now; false while a start is in flight. */
    val canStart: Boolean,
    /** A Start of the card is in flight: this client's, or one still in the outbox. */
    val starting: Boolean,
    /** The agent can be halted: it works and is not already stopping, or it waits for input. */
    val canHalt: Boolean,
    /** Running tool calls the transcript has not finished yet, in order. */
    val pendingTools: List<PendingTool>,
    /** A standalone chat, not a board card. */
    val chat: Boolean,
    /** The timeline and live activity show reasoning traces. */
    val showReasoning: Boolean,
    private val pendingIds: Set<String>,
    private val acceptedIds: Set<String>,
    private val failedIds: Set<String>,
) {
    val hasUnsentDraft: Boolean
        get() = unsentTask != null || draftAttachments.isNotEmpty()

    /** Nothing to show yet: no history, no task, no work, no queue. */
    val empty: Boolean
        get() = !hasUnsentDraft && timeline.items.isEmpty() && !working && queue.isEmpty()

    fun delivery(messageId: String): DeliveryState =
        Delivery.state(messageId, pendingIds, acceptedIds, failedIds)

    /** A message this device sent that the daemon has not confirmed; it renders dimmed. */
    fun unconfirmed(messageId: String): Boolean = messageId in pendingIds && messageId !in failedIds

    /** "1 command · 1 read" for [pendingTools]; null when there are none. */
    val pendingToolsSummary: String?
        get() =
            pendingTools
                .takeIf { it.isNotEmpty() }
                ?.let { tools -> ActivitySummary.ofTools(tools.map { it.tool_name }).english() }
}

object ConversationPresenter {
    /**
     * Presents [view]. [fallbackCard] stands in until the conversation's own snapshot arrives;
     * [operation] is this client's start or cancel in flight, and a start still in [outbox] counts
     * as one. [harnesses] is the conversation machine's catalog, for context windows a step does
     * not report. [cache] keeps per-message steps between presentations of the same conversation.
     */
    fun present(
        view: ConversationView,
        outbox: OutboxView,
        board: Board?,
        operation: CardOperation? = null,
        showReasoning: Boolean = false,
        fallbackCard: Card? = null,
        harnesses: HarnessCatalog? = null,
        cache: TimelineCache? = null,
    ): ConversationPresentation {
        val conversation = view.conversation
        // Account previews may be ahead of a cached or delayed full transcript. They describe
        // live work only; their truncated messages never replace the timeline or queued content.
        val activity = view.activity ?: conversation
        val reported = view.card ?: fallbackCard
        val pendingStart = reported != null && startPending(reported, outbox)
        // A start still in the outbox shows as this client's start, on the card as it will look.
        val card = reported?.let { if (pendingStart) CardPolicy.started(it, board) ?: it else it }
        val inFlight = operation ?: CardOperation.STARTING.takeIf { pendingStart }
        val messages = view.messages
        val queue = conversation?.queue.orEmpty()
        val cardIsNewer =
            Timestamps.compare(card?.runtime_updated_at.orEmpty(), activity?.updated_at.orEmpty()) >
                0
        val activityIsNewer =
            Timestamps.compare(activity?.updated_at.orEmpty(), card?.runtime_updated_at.orEmpty()) >
                0
        val runtime =
            Runtimes.resolved(
                card?.runtime?.takeUnless { activityIsNewer },
                activity?.status?.takeUnless { cardIsNewer },
                inFlight,
            )
        val activeTurn = Runtimes.isActive(runtime)
        // Optimistic sends and queued follow-ups never describe the provider's turn.
        val excluded =
            queue.mapTo(HashSet()) { it.id } + outbox.pendingMessageIds + outbox.failedIds
        val live = activity?.messages.orEmpty().filterNot { it.id in excluded }
        val neverSent = card != null && card.initial_prompt_sent_at.isEmpty()
        val draftAttachments =
            if (neverSent) conversation?.draft_attachments.orEmpty() else emptyList()
        val liveActivity =
            LiveActivities.resolve(
                live,
                activity?.pending_tools.orEmpty(),
                activity?.task_plans.orEmpty(),
                showReasoning,
                // A local start or cancel shows as "Starting agent…" or "Stopping…" before the
                // daemon reports it.
                activity?.status,
                runtime,
                activity?.provider_status,
            )
        val turnFailure = TurnFailure.resolve(messages, activity?.status, reported?.runtime)
        return ConversationPresentation(
            card = card,
            timeline =
                TimelineBuilder.build(
                    messages,
                    queuedIds = queue.mapTo(HashSet()) { it.id },
                    plans = latestPlans(conversation?.task_plans.orEmpty()),
                    subagents = conversation?.subagents.orEmpty(),
                    options =
                        TimelineOptions(
                            showReasoning = showReasoning,
                            failedMessageId = turnFailure?.failedMessageId?.ifEmpty { null },
                        ),
                    cache = cache,
                ),
            loadedMessages = messages.size,
            runtime = runtime,
            activeTurn = activeTurn,
            working = activeTurn || view.awaitingReply,
            liveActivity = liveActivity,
            liveReasoning =
                if (showReasoning) liveActivity
                else LiveActivities.withReasoning(liveActivity, live),
            turnStart = LiveActivities.turnStart(live, card?.runtime_updated_at),
            turnFailure = turnFailure,
            retrying = view.retrying,
            contextUsage =
                ContextUsage.latest(messages) { modelId ->
                    if (card == null) 0L
                    else ContextUsage.catalogWindow(harnesses, card.provider, modelId, card.model)
                },
            respondingModel =
                if (card?.provider == CLAUDE_CODE) respondingModel(messages) else null,
            unsentTask = card?.let { unsentTask(it, messages) },
            draftAttachments = draftAttachments,
            queue = queue,
            steerableId =
                queue.firstOrNull()?.id?.takeIf {
                    activeTurn &&
                        Runtimes.classify(runtime) != RuntimeState.STOPPING &&
                        it !in outbox.pendingMessageIds
                },
            interrupting = Runtimes.classify(runtime) == RuntimeState.STOPPING,
            readyForReview = card != null && Lanes.isReview(card.lane),
            canStart =
                card != null && CardPolicy.canStart(card, board, draftAttachments.isNotEmpty()),
            starting = inFlight == CardOperation.STARTING,
            canHalt =
                inFlight != CardOperation.CANCELLING &&
                    (Runtimes.classify(runtime) == RuntimeState.ACTIVE ||
                        listOf(
                                activity?.status?.takeUnless { cardIsNewer },
                                card?.runtime?.takeUnless { activityIsNewer },
                            )
                            .any { Runtimes.classify(it) == RuntimeState.NEEDS_INPUT }),
            pendingTools =
                LiveActivities.unfinishedPendingTools(live, activity?.pending_tools.orEmpty()),
            chat = card != null && Cards.isChat(card),
            showReasoning = showReasoning,
            pendingIds = outbox.pendingMessageIds,
            acceptedIds = outbox.acceptedIds,
            failedIds = outbox.failedIds,
        )
    }

    /**
     * [present] for the client contract. The card, its board, and this client's operation on it
     * come from [workspace] and [operations] until the conversation has them; the model catalog
     * comes from the conversation machine's entry in [machines].
     */
    fun presentForClient(
        view: ConversationView,
        outbox: OutboxView,
        workspace: WorkspaceView,
        operations: Map<String, CardOperation>,
        machines: Map<String, MachineMetadata> = emptyMap(),
        showReasoning: Boolean = false,
        cache: TimelineCache? = null,
    ): ConversationPresentation {
        val card = view.card ?: workspace.card(view.cardId)
        return present(
            view,
            outbox,
            card?.board_id?.let(workspace::board),
            card?.id?.let(operations::get),
            showReasoning,
            fallbackCard = card,
            harnesses = view.daemonId?.let(machines::get)?.harnesses,
            cache = cache,
        )
    }

    /**
     * What the conversation screen shows besides the transcript, as the client contract carries it.
     */
    fun state(presented: ConversationPresentation): ConversationState =
        ConversationState(
            runtime = presented.runtime,
            active_turn = presented.activeTurn,
            working = presented.working,
            live_activity = if (presented.working) presented.liveActivity.english() else "",
            live_reasoning = if (presented.working) presented.liveReasoning.english() else "",
            turn_started_at_millis = presented.turnStart?.toEpochMilliseconds() ?: 0,
            responding_model = presented.respondingModel.orEmpty(),
            unsent_task = presented.unsentTask.orEmpty(),
            steerable_id = presented.steerableId.orEmpty(),
            can_start = presented.canStart,
            starting = presented.starting,
            context_used_tokens = presented.contextUsage?.usedTokens ?: 0,
            context_window_tokens = presented.contextUsage?.windowTokens ?: 0,
            unsent_attachments = presented.draftAttachments.isNotEmpty(),
            context_percent = presented.contextUsage?.percent ?: 0,
            context_near_limit = presented.contextUsage?.nearLimit == true,
            pending_tools_summary = presented.pendingToolsSummary.orEmpty(),
            pending_tool_ids = presented.pendingTools.map { it.id },
            can_halt = presented.canHalt,
            chat = presented.chat,
            show_reasoning = presented.showReasoning,
            queued_messages =
                presented.queue.mapIndexed { index, message ->
                    val pending = presented.unconfirmed(message.id)
                    val stopping = index == 0 && presented.interrupting
                    QueuedMessageState(
                        id = message.id,
                        delivery_label =
                            when {
                                pending -> Delivery.label(presented.delivery(message.id))
                                stopping -> "Waiting for agent to stop…"
                                index == 0 -> "Queued · runs after the current turn"
                                else -> "Queued · runs after earlier messages"
                            },
                        pending_delivery = pending,
                        stopping = stopping,
                        can_edit = !pending && !stopping,
                        can_remove = !pending && !stopping,
                        can_send_now = message.id == presented.steerableId,
                    )
                },
        )

    const val CLAUDE_CODE = "claude-code"

    /** A start of [card] waits in [outbox] and the card's task was not sent yet. */
    fun startPending(card: Card, outbox: OutboxView): Boolean =
        card.initial_prompt_sent_at.isEmpty() &&
            (card.id in outbox.startingCardIds || outbox.resolve(card.id) in outbox.startingCardIds)

    /**
     * The trimmed task of a card whose task was never sent, while [messages] holds no user message
     * (a chat being created already shows its first message); null when blank. Any lane, scope, or
     * merge state.
     */
    fun unsentTask(card: Card, messages: List<UiMessage>): String? =
        card.initial_prompt.trim().takeIf {
            it.isNotEmpty() && card.initial_prompt_sent_at.isEmpty() && messages.none(Parts::isUser)
        }

    /** Each message's plan at its latest revision. */
    fun latestPlans(plans: List<TaskPlan>): List<TaskPlan> =
        plans.groupBy { it.message_id }.values.map { revisions -> revisions.maxBy { it.revision } }

    /** The model the latest assistant reply reports in its metadata. */
    fun respondingModel(messages: List<UiMessage>): String? {
        val message =
            messages.lastOrNull { it.role.equals("assistant", ignoreCase = true) } ?: return null
        return MessageMetadata.string(MessageMetadata.of(message), "modelId")?.trim()?.ifEmpty {
            null
        }
    }
}

/** Progress of a rendered task plan. */
object TaskPlans {
    /**
     * [completed] counts finished and abandoned tasks; [active] means a task is in progress now.
     */
    data class Progress(val completed: Int, val total: Int, val active: Boolean)

    fun progress(plan: TaskPlan): Progress {
        val tasks = plan.phases.flatMap { it.tasks }
        return Progress(
            tasks.count(::finished),
            tasks.size,
            plan.state == "active" && tasks.any { it.status == "in_progress" },
        )
    }

    fun finished(task: TaskPlanItem): Boolean =
        task.status == "completed" || task.status == "abandoned"

    /** The task's text: its active form while it is in progress. */
    fun text(task: TaskPlanItem): String =
        if (task.status == "in_progress" && task.active_form.isNotBlank()) task.active_form
        else task.content
}

/** The card detail's tabs and counts. */
object CardDetails {
    /** A chat shows its detail tabs once the daemon has it or it delegated work. */
    fun showsTabs(card: Card, subagents: List<Subagent>): Boolean =
        !Cards.isChat(card) || OutboxPolicy.isServerBacked(card.id) || subagents.isNotEmpty()

    /**
     * Files the card's own worktree changed; a project-directory conversation has none of its own.
     */
    fun changedFiles(card: Card, reviewed: Changeset?): Int =
        if (WorkspaceMode.of(card) == WorkspaceMode.PROJECT) 0
        else reviewed?.files?.size ?: card.workspace?.changed_files ?: 0
}

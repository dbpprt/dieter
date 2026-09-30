package com.dbpprt.dieter.core.presentation

import com.dbpprt.dieter.api.v1.Board
import com.dbpprt.dieter.api.v1.Card
import com.dbpprt.dieter.api.v1.Changeset
import com.dbpprt.dieter.api.v1.MessagePart
import com.dbpprt.dieter.api.v1.QueuedMessage
import com.dbpprt.dieter.api.v1.Subagent
import com.dbpprt.dieter.api.v1.TaskPlan
import com.dbpprt.dieter.api.v1.TaskPlanItem
import com.dbpprt.dieter.api.v1.UiMessage
import com.dbpprt.dieter.core.board.CardOperation
import com.dbpprt.dieter.core.board.CardPolicy
import com.dbpprt.dieter.core.board.Lanes
import com.dbpprt.dieter.core.board.Runtimes
import com.dbpprt.dieter.core.composition.WorkspaceMode
import com.dbpprt.dieter.core.conversation.ConversationView
import com.dbpprt.dieter.core.conversation.TurnFailure
import com.dbpprt.dieter.core.outbox.OutboxPolicy
import com.dbpprt.dieter.core.outbox.OutboxView
import kotlin.time.Instant
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/** Everything the conversation screen shows, derived from the open conversation once for every client. */
data class ConversationPresentation(
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
    val turnStart: Instant?,
    val turnFailure: TurnFailure?,
    /** The failed turn's retry was sent and has not run yet. */
    val retrying: Boolean,
    val contextUsage: ContextUsage?,
    /** The model Claude Code reported for its latest reply; it may differ from the selection. */
    val respondingModel: String?,
    /** The saved task of a card that was never started, shown as not sent. */
    val unsentTask: String?,
    /** Attachments saved with a never-started card. */
    val draftAttachments: List<MessagePart>,
    val queue: List<QueuedMessage>,
    /** The queued message that may interrupt the running turn now. */
    val steerableId: String?,
    val interrupting: Boolean,
    val readyForReview: Boolean,
    val canStart: Boolean,
    val starting: Boolean,
    private val pendingIds: Set<String>,
    private val acceptedIds: Set<String>,
    private val failedIds: Set<String>,
) {
    val hasUnsentDraft: Boolean get() = unsentTask != null || draftAttachments.isNotEmpty()

    /** Nothing to show yet: no history, no task, no work, no queue. */
    val empty: Boolean get() = !hasUnsentDraft && timeline.items.isEmpty() && !working && queue.isEmpty()

    fun delivery(messageId: String): DeliveryState = Delivery.state(messageId, pendingIds, acceptedIds, failedIds)

    /** A message this device sent that the daemon has not confirmed; it renders dimmed. */
    fun unconfirmed(messageId: String): Boolean = messageId in pendingIds && messageId !in failedIds
}

object ConversationPresenter {
    /**
     * Presents [view]. [fallbackCard] stands in until the conversation's own
     * snapshot arrives; [operation] is this client's start or cancel in flight.
     */
    fun present(
        view: ConversationView,
        outbox: OutboxView,
        board: Board?,
        operation: CardOperation? = null,
        showReasoning: Boolean = false,
        fallbackCard: Card? = null,
    ): ConversationPresentation {
        val conversation = view.conversation
        val card = view.card ?: fallbackCard
        val messages = view.messages
        val queue = conversation?.queue.orEmpty()
        val runtime = Runtimes.resolved(card?.runtime, conversation?.status, operation)
        val activeTurn = Runtimes.isActive(runtime)
        // Optimistic sends and queued follow-ups never describe the provider's turn.
        val excluded = queue.mapTo(HashSet()) { it.id } + outbox.pendingMessageIds + outbox.failedIds
        val live = conversation?.messages.orEmpty().filterNot { it.id in excluded }
        val neverSent = card != null && card.initial_prompt_sent_at.isEmpty()
        val draftAttachments = if (neverSent) conversation?.draft_attachments.orEmpty() else emptyList()
        return ConversationPresentation(
            card = card,
            timeline = TimelineBuilder.build(
                messages,
                queuedIds = queue.mapTo(HashSet()) { it.id },
                plans = latestPlans(conversation?.task_plans.orEmpty()),
                subagents = conversation?.subagents.orEmpty(),
                options = TimelineOptions(showReasoning = showReasoning),
            ),
            loadedMessages = messages.size,
            runtime = runtime,
            activeTurn = activeTurn,
            working = activeTurn || view.awaitingReply,
            liveActivity = LiveActivities.resolve(
                live, conversation?.pending_tools.orEmpty(), conversation?.task_plans.orEmpty(), showReasoning,
                // A local start or cancel shows as "Starting agent…" or "Stopping…" before the daemon reports it.
                conversation?.status, runtime, conversation?.provider_status,
            ),
            turnStart = LiveActivities.turnStart(live, card?.runtime_updated_at),
            turnFailure = TurnFailure.resolve(messages, conversation?.status, card?.runtime),
            retrying = view.retrying,
            contextUsage = ContextUsage.latest(messages),
            respondingModel = if (card?.provider == CLAUDE_CODE) respondingModel(messages) else null,
            unsentTask = card?.let(::unsentTask),
            draftAttachments = draftAttachments,
            queue = queue,
            steerableId = queue.firstOrNull()?.id?.takeIf { activeTurn },
            interrupting = operation == CardOperation.CANCELLING,
            readyForReview = card != null && Lanes.isReview(card.lane),
            canStart = card != null && CardPolicy.canStart(card, board, draftAttachments.isNotEmpty()),
            starting = operation == CardOperation.STARTING,
            pendingIds = outbox.pendingMessageIds,
            acceptedIds = outbox.acceptedIds,
            failedIds = outbox.failedIds,
        )
    }

    const val CLAUDE_CODE = "claude-code"

    /** A never-started card's task, while it can still be edited. */
    fun unsentTask(card: Card): String? = card.initial_prompt.trim().takeIf { CardPolicy.canEditDraft(card) && it.isNotEmpty() }

    /** Each message's plan at its latest revision. */
    fun latestPlans(plans: List<TaskPlan>): List<TaskPlan> =
        plans.groupBy { it.message_id }.values.map { revisions -> revisions.maxBy { it.revision } }

    /** The model the latest assistant reply reports in its metadata. */
    fun respondingModel(messages: List<UiMessage>): String? {
        val message = messages.lastOrNull { it.role.equals("assistant", ignoreCase = true) } ?: return null
        if (message.metadata_json.size == 0) return null
        val metadata = runCatching { Json.parseToJsonElement(message.metadata_json.utf8()) as? JsonObject }.getOrNull() ?: return null
        return (metadata["modelId"] as? JsonPrimitive)?.takeIf { it.isString }?.content?.trim()?.ifEmpty { null }
    }
}

/** Progress of a rendered task plan. */
object TaskPlans {
    /** [completed] counts finished and abandoned tasks; [active] means a task is in progress now. */
    data class Progress(val completed: Int, val total: Int, val active: Boolean)

    fun progress(plan: TaskPlan): Progress {
        val tasks = plan.phases.flatMap { it.tasks }
        return Progress(tasks.count(::finished), tasks.size, plan.state == "active" && tasks.any { it.status == "in_progress" })
    }

    fun finished(task: TaskPlanItem): Boolean = task.status == "completed" || task.status == "abandoned"

    /** The task's text: its active form while it is in progress. */
    fun text(task: TaskPlanItem): String = if (task.status == "in_progress" && task.active_form.isNotBlank()) task.active_form else task.content
}

/** The card detail's tabs and counts. */
object CardDetails {
    /** A chat shows its detail tabs once the daemon has it or it delegated work. */
    fun showsTabs(card: Card, subagents: List<Subagent>): Boolean =
        card.scope != "chat" || OutboxPolicy.isServerBacked(card.id) || subagents.isNotEmpty()

    /** Files the card's own worktree changed; a project-directory conversation has none of its own. */
    fun changedFiles(card: Card, reviewed: Changeset?): Int =
        if (WorkspaceMode.of(card) == WorkspaceMode.PROJECT) 0 else reviewed?.files?.size ?: card.workspace?.changed_files ?: 0
}

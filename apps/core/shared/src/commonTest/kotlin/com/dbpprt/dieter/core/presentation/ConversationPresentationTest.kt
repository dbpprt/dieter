package com.dbpprt.dieter.core.presentation

import com.dbpprt.dieter.api.v1.Board
import com.dbpprt.dieter.api.v1.Card
import com.dbpprt.dieter.api.v1.CardDetail
import com.dbpprt.dieter.api.v1.ChangedFile
import com.dbpprt.dieter.api.v1.Changeset
import com.dbpprt.dieter.api.v1.Conversation
import com.dbpprt.dieter.api.v1.ConversationSnapshot
import com.dbpprt.dieter.api.v1.Lane
import com.dbpprt.dieter.api.v1.MessagePart
import com.dbpprt.dieter.api.v1.QueuedMessage
import com.dbpprt.dieter.api.v1.Subagent
import com.dbpprt.dieter.api.v1.TaskPlan
import com.dbpprt.dieter.api.v1.TaskPlanItem
import com.dbpprt.dieter.api.v1.TaskPlanPhase
import com.dbpprt.dieter.api.v1.UiMessage
import com.dbpprt.dieter.api.v1.WorkspaceSummary
import com.dbpprt.dieter.core.board.CardOperation
import com.dbpprt.dieter.core.board.CardPolicy
import com.dbpprt.dieter.core.conversation.ConversationView
import com.dbpprt.dieter.core.outbox.OutboxView
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlin.time.Instant
import okio.ByteString.Companion.encodeUtf8

class ConversationPresentationTest {
    private val board = Board(id = "b", lanes = listOf(Lane(id = "todo", name = "Todo"), Lane(id = "running", name = "Running"), Lane(id = "review", name = "In review")))
    private val started = Card(
        id = "c", scope = "board", lane = "running", runtime = "running", provider = "codex",
        initial_prompt = "Ship it", initial_prompt_sent_at = "2026-09-30T10:00:00Z",
    )
    private val todo = Card(id = "c", scope = "board", lane = "todo", initial_prompt = "  Verify the native flow  ")

    private fun user(id: String, createdAt: String = "") = UiMessage(
        id = id, role = "user", parts = listOf(MessagePart(type = "text", text = "go")),
        metadata_json = (if (createdAt.isEmpty()) "" else """{"createdAt":"$createdAt"}""").encodeUtf8(),
    )

    private fun assistant(id: String, vararg parts: MessagePart, metadata: String = "") =
        UiMessage(id = id, role = "assistant", parts = parts.toList(), metadata_json = metadata.encodeUtf8())

    private fun running(command: String) = MessagePart(type = "dynamic-tool", tool_call_id = command, tool_name = "bash", state = "input-available", input_preview = command)

    private fun present(
        card: Card?,
        conversation: Conversation? = Conversation(),
        outbox: OutboxView = OutboxView(),
        operation: CardOperation? = null,
        awaitingReply: Boolean = false,
        retrying: Boolean = false,
    ): ConversationPresentation {
        val view = ConversationView(
            cardId = "c", presented = ConversationSnapshot(detail = CardDetail(card = card), conversation = conversation),
            loading = false, awaitingReply = awaitingReply, retrying = retrying,
        )
        return ConversationPresenter.present(view, outbox, board, operation)
    }

    @Test
    fun liveActivityAndTimerIgnoreOptimisticQueuedAndFailedMessages() {
        val conversation = Conversation(
            status = "running",
            messages = listOf(
                user("u", "2026-09-30T10:00:00Z"), assistant("a", running("go test ./...")),
                user("pending", "2026-09-30T10:01:00Z"), user("queued", "2026-09-30T10:02:00Z"), user("failed", "2026-09-30T10:03:00Z"),
            ),
            queue = listOf(QueuedMessage(id = "queued"), QueuedMessage(id = "later")),
        )
        val outbox = OutboxView(pendingMessageIds = setOf("pending", "failed"), acceptedIds = setOf("pending"), failedIds = setOf("failed"))
        val presentation = present(started, conversation, outbox)
        assertEquals("Running go test ./...", presentation.liveActivity.english())
        assertEquals(Instant.parse("2026-09-30T10:00:00Z"), presentation.turnStart)
        assertEquals("Thinking…", present(started, conversation).liveActivity.english(), "unexcluded sends would end the provider's turn")
        assertEquals(listOf("message:u", "tools:a", "message:pending", "message:failed"), presentation.timeline.items.map { it.id }, "queued follow-ups render in the queue")
        assertEquals(5, presentation.loadedMessages)
        assertTrue(presentation.activeTurn && presentation.working)
        assertEquals("queued", presentation.steerableId)

        val idle = present(started.copy(runtime = "idle"), conversation.copy(status = "idle"), outbox)
        assertNull(idle.steerableId, "only a running turn can be steered")
        assertFalse(idle.working)
        val awaiting = present(started.copy(runtime = "idle"), conversation.copy(status = "idle"), outbox, awaitingReply = true)
        assertFalse(awaiting.activeTurn)
        assertTrue(awaiting.working, "a sent message shows the agent working before its turn starts")
    }

    @Test
    fun deliveryFollowsTheOutbox() {
        val outbox = OutboxView(pendingMessageIds = setOf("pending", "failed"), acceptedIds = setOf("pending"), failedIds = setOf("failed"))
        val presentation = present(started, outbox = outbox)
        assertEquals(DeliveryState.ACCEPTED, presentation.delivery("pending"))
        assertEquals(DeliveryState.FAILED, presentation.delivery("failed"))
        assertEquals(DeliveryState.SYNCED, presentation.delivery("u"))
        assertEquals(DeliveryState.LOCAL, present(started, outbox = OutboxView(pendingMessageIds = setOf("pending"))).delivery("pending"))
        assertTrue(presentation.unconfirmed("pending"))
        assertFalse(presentation.unconfirmed("failed"), "a failed send shows its error instead")
        assertFalse(presentation.unconfirmed("u"))
    }

    @Test
    fun localStartsAndCancelsWinOverTheReportedRuntime() {
        val starting = present(todo, operation = CardOperation.STARTING)
        assertEquals("starting", starting.runtime)
        assertTrue(starting.starting && starting.activeTurn && starting.working)
        assertFalse(starting.interrupting)
        assertEquals("Starting agent…", starting.liveActivity.english(), "a local start shows before the daemon reports it")
        val cancelling = present(started, operation = CardOperation.CANCELLING)
        assertEquals("cancelling", cancelling.runtime)
        assertEquals("Stopping…", cancelling.liveActivity.english())
        assertTrue(cancelling.interrupting)
        assertFalse(cancelling.starting)
    }

    @Test
    fun neverStartedCardsExposeTheirDraftAndReviewCardsWaitForTheUser() {
        val draft = present(todo)
        assertEquals("Verify the native flow", draft.unsentTask)
        assertTrue(draft.hasUnsentDraft && draft.canStart)
        assertFalse(draft.empty)
        assertFalse(draft.readyForReview)

        val attachment = MessagePart(type = "file", filename = "brief.pdf", data_ = "pdf".encodeUtf8())
        val attachmentOnly = present(todo.copy(initial_prompt = " "), Conversation(draft_attachments = listOf(attachment)))
        assertNull(attachmentOnly.unsentTask)
        assertEquals(listOf(attachment), attachmentOnly.draftAttachments)
        assertTrue(attachmentOnly.hasUnsentDraft && attachmentOnly.canStart)

        val review = present(started.copy(runtime = "idle", lane = "review"), Conversation(draft_attachments = listOf(attachment)))
        assertNull(review.unsentTask)
        assertTrue(review.draftAttachments.isEmpty(), "a started card's saved attachments are no longer a draft")
        assertFalse(review.hasUnsentDraft || review.canStart)
        assertTrue(review.readyForReview)
        assertTrue(review.empty)
    }

    @Test
    fun onlyAnUnsentBoardTaskIsAnEditableDraft() {
        assertEquals("Verify the native flow", ConversationPresenter.unsentTask(todo))
        val sent = todo.copy(initial_prompt_sent_at = "2026-08-17T08:00:00Z")
        assertNull(ConversationPresenter.unsentTask(sent))
        assertFalse(CardPolicy.canEditDraft(sent))
        assertNull(ConversationPresenter.unsentTask(todo.copy(scope = "chat")))
        assertNull(ConversationPresenter.unsentTask(todo.copy(initial_prompt = " ")))
        assertFalse(CardPolicy.canEditDraft(todo.copy(initial_prompt = " ")))
        assertFalse(CardPolicy.canEditDraft(todo.copy(merged_into_card_id = "other")))
    }

    @Test
    fun aConversationWithoutDataIsEmptyUntilItsCardArrives() {
        val empty = ConversationPresenter.present(ConversationView(cardId = "c"), OutboxView(), null)
        assertNull(empty.card)
        assertTrue(empty.empty)
        assertEquals("idle", empty.runtime)
        assertFalse(empty.canStart || empty.readyForReview || empty.working)
        assertEquals(LiveActivity.Thinking, empty.liveActivity)
        val fallback = ConversationPresenter.present(ConversationView(cardId = "c"), OutboxView(), board, fallbackCard = todo)
        assertEquals(todo, fallback.card)
        assertTrue(fallback.canStart)
    }

    @Test
    fun failedTurnsAndRetriesComeFromTheConversation() {
        val failed = Conversation(status = "failed", messages = listOf(user("u"), assistant("a", MessagePart(type = "text", state = "error", text = "Turn failed — codex exited 1"))))
        val presentation = present(started.copy(runtime = "idle"), failed, retrying = true)
        assertEquals("codex exited 1", presentation.turnFailure?.summary)
        assertTrue(presentation.retrying)
        assertEquals(listOf("message:u"), presentation.timeline.items.map { it.id }, "the diagnostic lives in the failure banner")
        assertNull(present(started, Conversation(status = "running")).turnFailure)
    }

    @Test
    fun respondingModelIsReportedOnlyForClaudeCode() {
        val reply = assistant("a", MessagePart(type = "text", text = "Done"), metadata = """{"modelId":" claude-opus-4 "}""")
        val conversation = Conversation(messages = listOf(user("u"), reply))
        assertEquals("claude-opus-4", present(started.copy(provider = ConversationPresenter.CLAUDE_CODE), conversation).respondingModel)
        assertNull(present(started, conversation).respondingModel)
        assertNull(ConversationPresenter.respondingModel(listOf(user("u"))))
        assertNull(ConversationPresenter.respondingModel(listOf(reply, assistant("b"))), "only the latest reply counts")
        assertNull(ConversationPresenter.respondingModel(listOf(assistant("b", metadata = """{"modelId":42}"""))))
        assertNull(ConversationPresenter.respondingModel(listOf(assistant("b", metadata = """{"modelId":"  "}"""))))
    }

    @Test
    fun eachMessageShowsItsLatestPlanRevision() {
        val plans = listOf(
            TaskPlan(id = "p1", message_id = "a", revision = 1), TaskPlan(id = "p3", message_id = "a", revision = 3),
            TaskPlan(id = "p2", message_id = "a", revision = 2), TaskPlan(id = "q", message_id = "b", revision = 1),
        )
        assertEquals(listOf("p3", "q"), ConversationPresenter.latestPlans(plans).map { it.id })
        val presentation = present(started, Conversation(messages = listOf(assistant("a", MessagePart(type = "text", text = "Planned"))), task_plans = plans))
        assertEquals(listOf("p3"), assertIs<TimelineItem.Message>(presentation.timeline.items.single()).plans.map { it.id })
        assertEquals(listOf("q"), presentation.timeline.unattachedPlans.map { it.id })
    }

    @Test
    fun taskPlanProgressCountsFinishedWorkAndShowsActiveForms() {
        val tasks = listOf(
            TaskPlanItem(content = "Write tests", status = "completed"),
            TaskPlanItem(content = "Drop legacy path", status = "abandoned"),
            TaskPlanItem(content = "Verify", active_form = "Verifying", status = "in_progress"),
            TaskPlanItem(content = "Ship", status = "pending"),
        )
        val plan = TaskPlan(state = "active", phases = listOf(TaskPlanPhase(name = "Build", tasks = tasks.take(2)), TaskPlanPhase(name = "Release", tasks = tasks.drop(2))))
        assertEquals(TaskPlans.Progress(completed = 2, total = 4, active = true), TaskPlans.progress(plan))
        assertEquals(TaskPlans.Progress(completed = 2, total = 4, active = false), TaskPlans.progress(plan.copy(state = "completed")))
        assertFalse(TaskPlans.progress(TaskPlan(state = "active", phases = listOf(TaskPlanPhase(tasks = tasks.take(2))))).active, "nothing is in progress")
        assertEquals(listOf(true, true, false, false), tasks.map(TaskPlans::finished))
        assertEquals(listOf("Write tests", "Drop legacy path", "Verifying", "Ship"), tasks.map(TaskPlans::text))
        assertEquals("Verify", TaskPlans.text(tasks[2].copy(active_form = " ")))
    }

    @Test
    fun cardDetailTabsAndChangedFileCounts() {
        assertTrue(CardDetails.showsTabs(Card(id = "local_1", scope = "board"), emptyList()))
        assertFalse(CardDetails.showsTabs(Card(id = "local_1", scope = "chat"), emptyList()), "a chat still being created has nothing to show")
        assertTrue(CardDetails.showsTabs(Card(id = "c_1", scope = "chat"), emptyList()))
        assertTrue(CardDetails.showsTabs(Card(id = "local_1", scope = "chat"), listOf(Subagent(id = "worker"))))

        val worktree = Card(workspace_mode = "worktree", workspace = WorkspaceSummary(changed_files = 3))
        val reviewed = Changeset(files = listOf(ChangedFile(path = "a.kt")))
        assertEquals(3, CardDetails.changedFiles(worktree, null))
        assertEquals(1, CardDetails.changedFiles(worktree, reviewed), "the reviewed changeset is newer than the summary")
        assertEquals(0, CardDetails.changedFiles(Card(workspace_mode = "worktree"), null))
        assertEquals(0, CardDetails.changedFiles(worktree.copy(workspace_mode = "project"), reviewed), "a project-directory conversation has no changes of its own")
    }
}

package com.dbpprt.dieter.core.presentation

import com.dbpprt.dieter.api.v1.Board
import com.dbpprt.dieter.api.v1.Card
import com.dbpprt.dieter.api.v1.CardDetail
import com.dbpprt.dieter.api.v1.ChangedFile
import com.dbpprt.dieter.api.v1.Changeset
import com.dbpprt.dieter.api.v1.Conversation
import com.dbpprt.dieter.api.v1.ConversationSnapshot
import com.dbpprt.dieter.api.v1.Harness
import com.dbpprt.dieter.api.v1.HarnessCatalog
import com.dbpprt.dieter.api.v1.HarnessModel
import com.dbpprt.dieter.api.v1.Lane
import com.dbpprt.dieter.api.v1.MessagePart
import com.dbpprt.dieter.api.v1.PendingTool
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
        harnesses: HarnessCatalog? = null,
        showReasoning: Boolean = false,
    ): ConversationPresentation {
        val view = ConversationView(
            cardId = "c", presented = ConversationSnapshot(detail = CardDetail(card = card), conversation = conversation),
            loading = false, awaitingReply = awaitingReply, retrying = retrying,
        )
        return ConversationPresenter.present(view, outbox, board, operation, showReasoning, harnesses = harnesses)
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
        assertEquals(DeliveryState.QUEUED, Delivery.state("m", setOf("m"), emptySet(), emptySet(), queued = setOf("m")))
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
        assertTrue(CardPolicy.canEditDraft(todo))
        assertFalse(CardPolicy.canEditDraft(todo.copy(initial_prompt_sent_at = "2026-08-17T08:00:00Z")))
        assertFalse(CardPolicy.canEditDraft(todo.copy(scope = "chat")))
        assertFalse(CardPolicy.canEditDraft(todo.copy(initial_prompt = " ")))
        assertFalse(CardPolicy.canEditDraft(todo.copy(lane = "review")), "editing stays narrower than showing the unsent task")
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
            TaskPlanItem(content = "Drop the old path", status = "abandoned"),
            TaskPlanItem(content = "Verify", active_form = "Verifying", status = "in_progress"),
            TaskPlanItem(content = "Ship", status = "pending"),
        )
        val plan = TaskPlan(state = "active", phases = listOf(TaskPlanPhase(name = "Build", tasks = tasks.take(2)), TaskPlanPhase(name = "Release", tasks = tasks.drop(2))))
        assertEquals(TaskPlans.Progress(completed = 2, total = 4, active = true), TaskPlans.progress(plan))
        assertEquals(TaskPlans.Progress(completed = 2, total = 4, active = false), TaskPlans.progress(plan.copy(state = "completed")))
        assertFalse(TaskPlans.progress(TaskPlan(state = "active", phases = listOf(TaskPlanPhase(tasks = tasks.take(2))))).active, "nothing is in progress")
        assertEquals(listOf(true, true, false, false), tasks.map(TaskPlans::finished))
        assertEquals(listOf("Write tests", "Drop the old path", "Verifying", "Ship"), tasks.map(TaskPlans::text))
        assertEquals("Verify", TaskPlans.text(tasks[2].copy(active_form = " ")))
    }

    @Test
    fun cardDetailTabsAndChangedFileCounts() {
        assertTrue(CardDetails.showsTabs(Card(id = "local_1", scope = "board"), emptyList()))
        assertFalse(CardDetails.showsTabs(Card(id = "local_1", scope = "chat"), emptyList()), "a chat still being created has nothing to show")
        assertTrue(CardDetails.showsTabs(Card(id = "c_1", scope = "chat"), emptyList()))
        assertTrue(CardDetails.showsTabs(Card(id = "local_1", scope = "chat"), listOf(Subagent(id = "worker"))))
        assertTrue(CardDetails.showsTabs(Card(id = "local_1", scope = "chat", board_id = "b"), emptyList()), "a chat filed on a board shows its tabs like a card")

        val worktree = Card(workspace_mode = "worktree", workspace = WorkspaceSummary(changed_files = 3))
        val reviewed = Changeset(files = listOf(ChangedFile(path = "a.kt")))
        assertEquals(3, CardDetails.changedFiles(worktree, null))
        assertEquals(1, CardDetails.changedFiles(worktree, reviewed), "the reviewed changeset is newer than the summary")
        assertEquals(0, CardDetails.changedFiles(Card(workspace_mode = "worktree"), null))
        assertEquals(0, CardDetails.changedFiles(worktree.copy(workspace_mode = "project"), reviewed), "a project-directory conversation has no changes of its own")
    }

    @Test
    fun aStartStillInTheOutboxShowsAsStartingUntilSyncReportsTheTurn() {
        val outbox = OutboxView(startingCardIds = setOf("c"))
        val pending = present(todo, outbox = outbox)
        assertTrue(pending.starting)
        assertFalse(pending.canStart, "a second Start would only repeat the pending one")
        assertEquals("running", pending.card?.lane, "the card shows as it will look once started")
        assertEquals("starting", pending.runtime)
        assertTrue(pending.activeTurn && pending.working)
        assertEquals("Starting agent…", pending.liveActivity.english())
        assertTrue(ConversationPresenter.startPending(todo, outbox))
        val state = ConversationPresenter.state(pending)
        assertTrue(state.starting && !state.can_start)

        val reported = present(todo.copy(initial_prompt_sent_at = "2026-09-30T10:00:00Z", lane = "running", runtime = "running"), outbox = outbox)
        assertFalse(reported.starting, "sync reported the turn while the accepted start lingers")
        assertFalse(present(todo, outbox = OutboxView(startingCardIds = setOf("other"))).starting)
        assertTrue(present(todo, outbox = OutboxView(startingCardIds = setOf("server"), resolutions = mapOf("c" to "server"))).starting, "a start retargeted to the server ID")
        assertTrue(present(todo).canStart, "nothing in flight")
    }

    @Test
    fun anyTaskNeverSentShowsUntilAUserMessageExists() {
        assertEquals("Verify the native flow", ConversationPresenter.unsentTask(todo, emptyList()))
        assertEquals("Verify the native flow", present(todo.copy(lane = "review")).unsentTask, "a card moved on without starting still shows its task")
        assertEquals("Verify the native flow", present(todo.copy(merged_into_card_id = "other")).unsentTask)
        assertNull(present(todo.copy(initial_prompt = "  ")).unsentTask, "a blank task shows nothing")
        val chat = todo.copy(scope = "chat")
        assertEquals("Verify the native flow", present(chat).unsentTask)
        assertNull(present(chat, Conversation(messages = listOf(user("first")))).unsentTask, "a chat being created already shows its first message")
        assertNull(present(started).unsentTask)
        assertTrue(ConversationPresenter.state(present(todo, Conversation(draft_attachments = listOf(MessagePart(type = "file", filename = "brief.pdf"))))).unsent_attachments)
        assertFalse(ConversationPresenter.state(present(started, Conversation(draft_attachments = listOf(MessagePart(type = "file", filename = "brief.pdf"))))).unsent_attachments)
    }

    @Test
    fun contextUsageFallsBackToTheCatalogAndSurvivesANewTurn() {
        val catalog = HarnessCatalog(
            harnesses = listOf(Harness(id = "codex", default_model = "sol", models = listOf(HarnessModel(id = "sol", context_window = 200_000), HarnessModel(id = "luna", context_window = 400_000)))),
        )
        val step = assistant("a", MessagePart(type = "text", text = "Done"), metadata = """{"usage":{"totalTokens":60000},"modelId":"luna"}""")
        val conversation = Conversation(messages = listOf(user("u"), step))
        assertEquals(ContextUsage(60_000, 400_000, "luna"), present(started, conversation, harnesses = catalog).contextUsage, "the reported model's window")
        val unlisted = assistant("a", metadata = """{"usage":{"totalTokens":60000},"modelId":"claude-opus-4-1"}""")
        assertEquals(200_000L, present(started, Conversation(messages = listOf(unlisted)), harnesses = catalog).contextUsage?.windowTokens, "the card's model, here the harness default")
        assertEquals(400_000L, present(started.copy(model = "luna"), Conversation(messages = listOf(unlisted)), harnesses = catalog).contextUsage?.windowTokens)
        assertNull(present(started, conversation).contextUsage, "no catalog and no reported window")
        val reportedWindow = assistant("a", metadata = """{"usage":{"totalTokens":60000},"contextWindowTokens":1000000,"modelId":"luna"}""")
        assertEquals(1_000_000L, present(started, Conversation(messages = listOf(reportedWindow)), harnesses = catalog).contextUsage?.windowTokens, "the step's own window wins")

        val newTurn = Conversation(messages = listOf(user("u"), step, user("u2", "2026-09-30T10:05:00Z")))
        assertEquals(60_000L, present(started, newTurn, harnesses = catalog).contextUsage?.usedTokens, "a new turn keeps the last reported usage")
        val state = ConversationPresenter.state(present(started, conversation, harnesses = catalog))
        assertEquals(60_000L, state.context_used_tokens)
        assertEquals(400_000L, state.context_window_tokens)
        assertEquals(15, state.context_percent)
        assertFalse(state.context_near_limit)
        val full = assistant("a", metadata = """{"usage":{"totalTokens":380000},"modelId":"luna"}""")
        assertTrue(ConversationPresenter.state(present(started, Conversation(messages = listOf(full)), harnesses = catalog)).context_near_limit)
        assertEquals(0, ConversationPresenter.state(present(started)).context_percent)
    }

    @Test
    fun haltChatPendingToolsAndReasoningTravelWithTheState() {
        assertTrue(present(started).canHalt, "a running agent can be halted")
        assertFalse(present(started, operation = CardOperation.CANCELLING).canHalt, "not while it is stopping")
        assertFalse(present(started.copy(runtime = "idle"), Conversation(status = "idle")).canHalt)
        assertTrue(present(started.copy(runtime = "idle"), Conversation(status = "waiting_for_user")).canHalt, "an agent waiting for input")
        assertTrue(present(todo.copy(scope = "chat")).chat)
        assertFalse(present(todo).chat)
        assertFalse(present(todo.copy(scope = "chat", board_id = "b")).chat, "a chat filed on a board is a card")

        val pending = listOf(PendingTool(id = "p1", tool_call_id = "done", tool_name = "bash"), PendingTool(id = "p2", tool_call_id = "next", tool_name = "read_file"))
        val conversation = Conversation(
            status = "running", pending_tools = pending,
            messages = listOf(user("u"), assistant("a", MessagePart(type = "dynamic-tool", tool_call_id = "done", tool_name = "bash", state = "output-available"))),
        )
        val presented = present(started, conversation)
        assertEquals(listOf("p2"), presented.pendingTools.map { it.id }, "the transcript finished the first one")
        assertEquals("1 read", presented.pendingToolsSummary)
        assertNull(present(started).pendingToolsSummary)
        val state = ConversationPresenter.state(presented)
        assertEquals("1 read", state.pending_tools_summary)
        assertEquals(listOf("p2"), state.pending_tool_ids)
        assertTrue(state.can_halt)
        assertFalse(state.chat)
        assertFalse(state.show_reasoning)
        assertTrue(ConversationPresenter.state(present(started, showReasoning = true)).show_reasoning)
    }
}

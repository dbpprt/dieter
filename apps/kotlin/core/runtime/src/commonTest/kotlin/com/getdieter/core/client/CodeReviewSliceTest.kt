package com.getdieter.core.client

import com.getdieter.api.v1.Card
import com.getdieter.api.v1.CardDetail
import com.getdieter.api.v1.Conversation
import com.getdieter.api.v1.ConversationSnapshot
import com.getdieter.api.v1.Harness
import com.getdieter.api.v1.HarnessCatalog
import com.getdieter.api.v1.MessagePart
import com.getdieter.api.v1.UiMessage
import com.getdieter.client.v1.ConversationSlice
import com.getdieter.client.v1.TimelineStep
import com.getdieter.client.v1.TimelineStepKind
import com.getdieter.core.conversation.ConversationView
import com.getdieter.core.metadata.MachineMetadata
import com.getdieter.core.outbox.OutboxView
import com.getdieter.core.presentation.ConversationPresenter
import com.getdieter.core.presentation.Parts
import com.getdieter.core.store.WorkspaceView
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlin.time.Instant
import okio.ByteString.Companion.encodeUtf8

/** Code reviews in a conversation: their timeline cards and the conversation's reviewer state. */
class CodeReviewSliceTest {
    private val card =
        Card(id = "c_1", scope = "board", project_id = "p", lane = "running", runtime = "running")

    private val catalog =
        MachineMetadata(
            harnesses = HarnessCatalog(listOf(Harness(id = "claude-code", name = "Claude Code")))
        )

    private fun view(card: Card?, vararg messages: UiMessage) =
        ConversationView(
            cardId = "c_1",
            daemonId = "d",
            presented =
                ConversationSnapshot(
                    detail = card?.let { CardDetail(card = it) },
                    conversation = Conversation(status = "running", messages = messages.toList()),
                ),
            loading = false,
        )

    private fun slice(
        vararg messages: UiMessage,
        card: Card? = this.card,
        workspace: WorkspaceView = WorkspaceView(),
    ): ConversationSlice {
        val view = view(card, *messages)
        return conversationSlice(
            view,
            ConversationPresenter.presentForClient(
                view,
                OutboxView(),
                workspace,
                emptyMap(),
                machines = mapOf("d" to catalog),
            ),
        )
    }

    private fun review(json: String) =
        MessagePart(type = "data-code-review", data_json = json.trimIndent().encodeUtf8())

    private val completed =
        review(
            """
            {"id":"rev_1","cardId":"c_1","status":"completed","trigger":"agent",
             "harness":"claude-code","model":"opus","effort":"high","depth":"quick",
             "startedAt":"2026-11-27T10:00:00Z","finishedAt":"2026-11-27T10:00:42Z",
             "durationMs":42000,"summary":"Adds unborn-branch handling.","security":"No",
             "findings":[
               {"id":"f2","file":"README.md","startLine":4,"severity":"low","confidence":6,
                "title":"Typo","body":"*recieve*","status":"new"},
               {"id":"f1","file":"internal/git/unborn.go","startLine":23,"endLine":26,
                "severity":"high","confidence":9,"title":"Nil dereference",
                "body":"`head` may be nil.","suggestion":"Check `head` first.","status":"open"}
             ],
             "resolved":[{"id":"f0","file":"a.go","startLine":1,"severity":"medium",
               "title":"Leak","body":"closed","status":"resolved"}],
             "round":2,"previousReviewId":"rev_0","inputTokens":200000,"outputTokens":24000,
             "filesChanged":12,"additions":340,"deletions":41,"toolCallId":"call_9",
             "messageId":"a"}
            """
        )

    private fun request(id: String, name: String = "mcp__harness-tools__request_code_review") =
        MessagePart(
            type = "dynamic-tool",
            tool_call_id = id,
            tool_name = name,
            state = "output-available",
        )

    private fun bash(id: String) =
        MessagePart(
            type = "dynamic-tool",
            tool_call_id = id,
            tool_name = "bash",
            state = "output-available",
        )

    private fun ConversationSlice.steps(): List<TimelineStep> = timeline.flatMap { row ->
        row.groups.flatMap { it.steps }
    }

    @Test
    fun anAgentsReviewIsACardInPlaceOfItsToolCall() {
        val turn =
            UiMessage(
                id = "a",
                role = "assistant",
                parts = listOf(bash("t1"), request("call_9"), completed, bash("t2")),
            )
        val slice = slice(turn)
        val row = slice.timeline.single()
        assertEquals("message:a", row.id)
        assertFalse(row.activity, "a review keeps the message out of activity summaries")
        val steps = slice.steps()
        // The review card represents the request; the other tool calls stay.
        assertEquals(
            listOf("t1", "t2"),
            steps
                .filter { it.tool_title.isNotEmpty() }
                .map {
                    turn.parts[it.part_index].tool_call_id
                },
        )
        val step = steps.single { it.kind == TimelineStepKind.TIMELINE_STEP_KIND_CODE_REVIEW }
        assertFalse(step.routine)
        assertEquals(2, step.part_index)
        val review = assertNotNull(step.code_review)
        assertEquals("rev_1", review.review_id)
        assertEquals("c_1", review.card_id)
        assertEquals("completed", review.status)
        assertFalse(review.running)
        assertEquals("Code review", review.title)
        assertEquals("Claude Code · opus · quick · 42 s · 224k tokens", review.subtitle)
        assertEquals("2 findings · 1 high", review.counts_label)
        assertEquals("Round 2 · 1 resolved · 1 still open · 1 new", review.round_label)
        assertEquals("Requested by the agent", review.trigger_label)
        assertEquals("12 files · +340 −41", review.change_label)
        assertEquals("Adds unborn-branch handling.", review.summary)
        assertEquals("", review.security, "\"No\" is no concern")
        assertEquals("", review.error)
        assertEquals("high", review.highest_severity)
        assertEquals(
            Instant.parse("2026-11-27T10:00:00Z").toEpochMilliseconds(),
            review.started_at_millis,
        )
        assertEquals(
            Instant.parse("2026-11-27T10:00:42Z").toEpochMilliseconds(),
            review.finished_at_millis,
        )
        // Most severe first.
        assertEquals(listOf("f1", "f2"), review.findings.map { it.id })
        val high = review.findings.first()
        assertEquals("internal/git/unborn.go", high.file_)
        assertEquals(23, high.start_line)
        assertEquals(26, high.end_line)
        assertEquals("internal/git/unborn.go:23–26", high.location_label)
        assertEquals("High", high.severity_label)
        assertEquals(9, high.confidence)
        assertEquals("Nil dereference", high.title)
        assertEquals("`head` may be nil.", high.body)
        assertEquals("Check `head` first.", high.suggestion)
        assertEquals("Still open", high.status_label)
        val low = review.findings.last()
        assertEquals("README.md:4", low.location_label)
        assertEquals("Low", low.severity_label)
        assertEquals("New", low.status_label)
        assertEquals("", low.suggestion)
        assertEquals(listOf("Resolved"), review.resolved.map { it.status_label })
        assertEquals(listOf("a.go:1"), review.resolved.map { it.location_label })
        // The reviewer's words are not the agent's prose.
        assertFalse(Parts.isCopyable(completed))
        assertTrue(
            steps
                .filter { it.code_review == null }
                .none {
                    it.kind == TimelineStepKind.TIMELINE_STEP_KIND_CODE_REVIEW
                }
        )
    }

    @Test
    fun aRequestWithoutItsReviewKeepsItsToolRow() {
        // An older daemon, or a review whose part has not arrived: the call stays visible.
        val turn =
            UiMessage(
                id = "a",
                role = "assistant",
                parts = listOf(request("call_9", "request_code_review")),
            )
        val step = slice(turn).steps().single()
        assertEquals(TimelineStepKind.TIMELINE_STEP_KIND_TOOL, step.kind)
        // Another call's review does not hide it either.
        val other =
            UiMessage(id = "a", role = "assistant", parts = listOf(request("call_8"), completed))
        assertEquals(
            listOf(
                TimelineStepKind.TIMELINE_STEP_KIND_TOOL,
                TimelineStepKind.TIMELINE_STEP_KIND_CODE_REVIEW,
            ),
            slice(other).steps().map { it.kind },
        )
    }

    @Test
    fun anUnreadableReviewIsLeftOut() {
        val garbled = review("{not json")
        val nameless = review("""{"status":"completed"}""")
        val turn =
            UiMessage(
                id = "a",
                role = "assistant",
                parts =
                    listOf(
                        MessagePart(type = "text", text = "Done."),
                        garbled,
                        nameless,
                        MessagePart(type = "data-code-review"),
                    ),
            )
        val steps = slice(turn).steps()
        assertEquals(listOf(TimelineStepKind.TIMELINE_STEP_KIND_TEXT), steps.map { it.kind })
    }

    @Test
    fun aUsersReviewIsAMessageOfItsOwnAndRunsUntilReplaced() {
        val running =
            review(
                """
                {"id":"rev_2","cardId":"c_1","status":"running","trigger":"user",
                 "harness":"codex","model":"gpt-5","depth":"thorough",
                 "startedAt":"2026-11-27T10:00:00Z","round":1}
                """
            )
        val message =
            UiMessage(id = "msg_review_rev_2", role = "assistant", parts = listOf(running))
        val slice = slice(message)
        val row = slice.timeline.single()
        assertFalse(row.user)
        val review = slice.steps().single().code_review!!
        assertTrue(review.running)
        assertEquals("Reviewing changes…", review.title)
        // A harness the catalog does not name reads as its ID.
        assertEquals("codex · gpt-5 · thorough", review.subtitle)
        assertEquals("", review.counts_label)
        assertEquals("", review.round_label)
        assertEquals("Requested by you", review.trigger_label)
        assertEquals("", review.change_label)
        val state = slice.state!!.code_review!!
        assertTrue(state.running)
        assertFalse(state.can_start, "one review at a time")
        assertTrue(state.can_toggle)
        assertEquals("rev_2", state.latest?.review_id)
    }

    @Test
    fun failedAndEmptyReviewsSayWhat() {
        fun only(json: String) =
            slice(UiMessage(id = "m", role = "assistant", parts = listOf(review(json))))
                .steps()
                .single()
                .code_review!!
        val failed =
            only(
                """{"id":"r","status":"failed","error":"the review did not finish within 10m0s",
                   "harness":"claude-code","durationMs":600000}"""
            )
        assertEquals("Code review failed", failed.title)
        assertEquals("the review did not finish within 10m0s", failed.error)
        assertEquals("Claude Code · 10 min", failed.subtitle)
        assertEquals("", failed.counts_label)
        val cancelled =
            only("""{"id":"r","status":"cancelled","error":"the review was cancelled"}""")
        assertEquals("Code review cancelled", cancelled.title)
        assertEquals("the review was cancelled", cancelled.error)
        val empty =
            only(
                """{"id":"r","status":"completed","summary":"There are no changes to review.",
                   "security":"No"}"""
            )
        assertEquals("No changes to review", empty.counts_label)
        val clean =
            only(
                """{"id":"r","status":"completed","filesChanged":1,"additions":3,"deletions":0,
                   "security":"Writes the token to the log."}"""
            )
        assertEquals("No findings", clean.counts_label)
        assertEquals("1 file · +3 −0", clean.change_label)
        assertEquals("Writes the token to the log.", clean.security)
        val single =
            only(
                """{"id":"r","status":"completed","filesChanged":1,
                   "findings":[{"id":"f1","file":"a","severity":"high","title":"t","body":"b"}]}"""
            )
        assertEquals("1 finding", single.counts_label)
        assertEquals("a", single.findings.single().location_label)
    }

    @Test
    fun theConversationsReviewerFollowsItsCardAndLatestReview() {
        // Unknown until the card is.
        assertNull(slice(card = null).state?.code_review)
        val off = slice().state!!.code_review!!
        assertFalse(off.enabled)
        assertTrue(off.can_toggle)
        assertTrue(off.can_start)
        assertFalse(off.running)
        assertNull(off.latest)
        assertTrue(slice(card = card.copy(code_review = true)).state!!.code_review!!.enabled)
        // The board's copy carries a switch in flight before the conversation's own does.
        val switched =
            slice(
                workspace =
                    WorkspaceView(cards = mapOf("p" to listOf(card.copy(code_review = true))))
            )
        assertTrue(switched.state!!.code_review!!.enabled)
        // The newest review counts.
        val older = UiMessage(id = "a", role = "assistant", parts = listOf(completed))
        val newer =
            UiMessage(
                id = "b",
                role = "assistant",
                parts =
                    listOf(
                        review(
                            """{"id":"rev_3","status":"failed","error":"boom","startedAt":"2026-11-27T11:00:00Z"}"""
                        )
                    ),
            )
        val latest = slice(older, newer).state!!.code_review!!
        assertEquals("rev_3", latest.latest?.review_id)
        assertFalse(latest.running)
        assertTrue(latest.can_start)
        // An archived conversation keeps its reviewer and its reviews.
        val archived = slice(card = card.copy(archived = true)).state!!.code_review!!
        assertFalse(archived.can_toggle)
        assertFalse(archived.can_start)
        // One the outbox is still creating cannot be reviewed yet.
        val pending = slice(card = card.copy(id = "local_1")).state!!.code_review!!
        assertFalse(pending.can_toggle)
        assertFalse(pending.can_start)
    }
}

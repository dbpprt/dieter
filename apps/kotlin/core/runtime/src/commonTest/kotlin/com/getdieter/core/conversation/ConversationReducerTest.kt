package com.getdieter.core.conversation

import com.getdieter.api.v1.Card
import com.getdieter.api.v1.CardDetail
import com.getdieter.api.v1.Conversation
import com.getdieter.api.v1.ConversationPage
import com.getdieter.api.v1.ConversationSnapshot
import com.getdieter.api.v1.ConversationUpdate
import com.getdieter.api.v1.MessagePart
import com.getdieter.api.v1.ProviderStatus
import com.getdieter.api.v1.Subagent
import com.getdieter.api.v1.TaskPlan
import com.getdieter.api.v1.UiMessage
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertSame
import kotlin.test.assertTrue
import kotlin.time.Duration
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.seconds

class ConversationReducerTest {
    private val retention = TranscriptRetention()

    private fun message(id: String, text: String = id, role: String = "assistant") =
        UiMessage(id = id, role = role, parts = listOf(MessagePart(type = "text", text = text)))

    private fun snapshot(
        seq: Long,
        vararg ids: String,
        start: Int = 0,
        total: Int = ids.size,
        updatedAt: String = "2026-09-30T12:00:00Z",
    ) =
        ConversationSnapshot(
            detail = CardDetail(card = Card(id = "c")),
            conversation =
                Conversation(
                    card_id = "c",
                    last_seq = seq,
                    updated_at = updatedAt,
                    messages = ids.map { message(it) },
                ),
            page =
                ConversationPage(
                    start = start,
                    end = start + ids.size,
                    total = total,
                    has_more = start > 0,
                ),
        )

    @Test
    fun snapshotStartsAndDeltasReplaceRemoveAndAppendInOrder() {
        val started =
            ConversationReducer.apply(
                TranscriptState(),
                ConversationUpdate(snapshot = snapshot(1, "one", "old")),
                retention,
            )
        assertEquals(listOf("one", "old"), started.messages.map { it.id })
        val next =
            ConversationReducer.apply(
                started,
                ConversationUpdate(
                    changed_messages = listOf(message("one", "new"), message("two")),
                    removed_message_ids = listOf("old"),
                    status = "running",
                    last_seq = 8,
                    subagents = listOf(Subagent(id = "s")),
                    task_plans = listOf(TaskPlan(id = "p")),
                ),
                retention,
            )
        val conversation = next.conversation!!
        assertEquals(listOf("one", "two"), conversation.messages.map { it.id })
        assertEquals("new", conversation.messages[0].parts.single().text)
        assertEquals("running", conversation.status)
        assertEquals(8, conversation.last_seq)
        assertEquals(listOf("s"), conversation.subagents.map { it.id })
        assertEquals(
            listOf("old"),
            next.older.map { it.id },
            "a message leaving the window moves into history",
        )
        assertEquals(listOf("old", "one", "two"), next.messages.map { it.id })
    }

    @Test
    fun aDeltaBeforeASnapshotAsksForOne() {
        assertFailsWith<ConversationReducer.MissingSnapshot> {
            ConversationReducer.apply(
                TranscriptState(),
                ConversationUpdate(last_seq = 1),
                retention,
            )
        }
    }

    @Test
    fun providerStatusFollowsEachUpdateAndEmptyStatusKeepsTheLastOne() {
        var state =
            ConversationReducer.apply(
                TranscriptState(),
                ConversationUpdate(snapshot = snapshot(1, "a")),
                retention,
            )
        state =
            ConversationReducer.apply(
                state,
                ConversationUpdate(
                    last_seq = 2,
                    status = "running",
                    provider_status = ProviderStatus(state = "reconnecting", attempt = 1),
                ),
                retention,
            )
        assertEquals(1, state.conversation!!.provider_status?.attempt)
        state = ConversationReducer.apply(state, ConversationUpdate(last_seq = 3), retention)
        assertNull(state.conversation!!.provider_status)
        assertEquals("running", state.conversation!!.status)
    }

    @Test
    fun olderFramesNeverRollTheTranscriptBack() {
        val state =
            ConversationReducer.apply(
                TranscriptState(),
                ConversationUpdate(
                    snapshot = snapshot(5, "a", "b", updatedAt = "2026-09-30T12:00:05Z")
                ),
                retention,
            )
        assertSame(
            state,
            ConversationReducer.apply(
                state,
                ConversationUpdate(last_seq = 4, changed_messages = listOf(message("x"))),
                retention,
            ),
        )
        assertSame(
            state,
            ConversationReducer.apply(
                state,
                ConversationUpdate(
                    last_seq = 5,
                    updated_at = "2026-09-30T12:00:01Z",
                    changed_messages = listOf(message("x")),
                ),
                retention,
            ),
        )
        val stale =
            ConversationReducer.apply(
                state,
                ConversationUpdate(snapshot = snapshot(3, "a")),
                retention,
            )
        assertEquals(
            listOf("a", "b"),
            stale.messages.map { it.id },
            "a delayed read cannot replace a newer tail",
        )
        assertTrue(ConversationReducer.isOlder(Conversation(last_seq = 5), 4, ""))
        assertFalse(ConversationReducer.isOlder(Conversation(last_seq = 5), 6, ""))
    }

    @Test
    fun aNewerRevisionWinsOverARicherPageAtTheSameSequence() {
        val old = snapshot(5, "a", "b", "c")
        val incoming =
            snapshot(5, "c", start = 2, total = 3, updatedAt = "2026-09-30T12:00:01Z").let {
                it.copy(
                    conversation =
                        it.conversation!!.copy(
                            status = "idle",
                            messages = listOf(message("c", "finished")),
                            queue = listOf(com.getdieter.api.v1.QueuedMessage(id = "next")),
                        )
                )
            }
        val state =
            ConversationReducer.applySnapshot(TranscriptState(snapshot = old), incoming, retention)
        assertEquals("idle", state.conversation!!.status)
        assertEquals("finished", state.messages.last().parts.single().text)
        assertEquals(
            listOf("a", "b", "c"),
            state.messages.map { it.id },
            "the larger page survives as history",
        )
        assertEquals("next", state.conversation!!.queue.single().id)
        val delayed = ConversationReducer.applySnapshot(state, old, retention)
        assertEquals(
            state.messages,
            delayed.messages,
            "a delayed richer page cannot roll back content",
        )
        assertEquals("idle", delayed.conversation!!.status)
    }

    @Test
    fun snapshotsKeepHistoryThatStillJoinsTheWindow() {
        var state =
            TranscriptState(
                snapshot = snapshot(3, "c", "d", start = 2, total = 4),
                older = listOf(message("a"), message("b")),
                history = ConversationHistory(start = 0, total = 4),
            )
        state =
            ConversationReducer.apply(
                state,
                ConversationUpdate(snapshot = snapshot(4, "d", "e", start = 3, total = 5)),
                retention,
            )
        assertEquals(listOf("a", "b", "c", "d", "e"), state.messages.map { it.id })
        val gap =
            ConversationReducer.apply(
                state,
                ConversationUpdate(snapshot = snapshot(9, "x", "y", start = 20, total = 22)),
                retention,
            )
        assertEquals(
            listOf("x", "y"),
            gap.messages.map { it.id },
            "history that no longer joins is dropped, never shown across a gap",
        )
        assertEquals(20, gap.history.start)
        assertTrue(gap.history.hasMore)
    }

    @Test
    fun retentionKeepsTheRequestedEndWithinBothBudgets() {
        val messages = (0 until 12).map { message(it.toString().padStart(2, '0'), "x".repeat(100)) }
        val size = UiMessage.ADAPTER.encodedSize(messages[0]).toLong()
        val bounded = TranscriptRetention(count = 5, bytes = size * 3 + 1)
        assertEquals(
            listOf("00", "01", "02") to 9,
            bounded.window(messages, keepingEarlier = true).let { (kept, removed) ->
                kept.map { it.id } to removed
            },
        )
        assertEquals(
            listOf("09", "10", "11"),
            bounded.window(messages, keepingEarlier = false).first.map { it.id },
        )
        assertEquals(
            listOf("00"),
            TranscriptRetention(count = 5, bytes = 1)
                .window(messages, keepingEarlier = true)
                .first
                .map { it.id },
            "one oversized message is still kept",
        )
        assertEquals(
            5,
            TranscriptRetention(count = 5, bytes = Long.MAX_VALUE)
                .window(messages, keepingEarlier = false)
                .first
                .size,
        )
    }

    @Test
    fun resubscriptionIsImmediateThenBacksOff() {
        assertEquals(Duration.ZERO, ConversationSession.resubscribeDelay(0))
        assertEquals(Duration.ZERO, ConversationSession.resubscribeDelay(1))
        assertEquals(250.milliseconds, ConversationSession.resubscribeDelay(2))
        assertEquals(450.milliseconds, ConversationSession.resubscribeDelay(3))
        assertEquals(5.seconds, ConversationSession.resubscribeDelay(20))
    }

    @Test
    fun aFailedTurnKeepsItsLogAndRetryPayload() {
        val request =
            UiMessage(
                id = "u",
                role = "user",
                parts =
                    listOf(
                        MessagePart(type = "text", text = "Run the tests"),
                        MessagePart(type = "file", url = "data:text/plain;base64,aGk="),
                    ),
            )
        val failed =
            UiMessage(
                id = "a",
                role = "assistant",
                parts =
                    listOf(
                        MessagePart(
                            type = "text",
                            text =
                                "Turn failed — codex exited 1 after 42s (context overflow).\nstderr: boom",
                            state = "error",
                        )
                    ),
            )
        val failure = TurnFailure.resolve(listOf(request, failed), "failed", "idle")!!
        assertEquals("codex exited 1 after 42s (context overflow).", failure.summary)
        assertTrue("stderr: boom" in failure.log)
        assertEquals(2, failure.retryParts.size)
        assertEquals("a", failure.failedMessageId)
        assertNull(TurnFailure.resolve(listOf(request, failed), "idle", "idle"))
        val silent = TurnFailure.resolve(listOf(request), "failed", "")!!
        assertEquals(TurnFailure.FALLBACK_LOG, silent.log)
        assertEquals(TurnFailure.FALLBACK_SUMMARY, silent.summary)
        assertEquals("x".repeat(179) + "…", TurnFailure.summary("x".repeat(300)))
    }
}

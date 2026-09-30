package com.dbpprt.dieter.core.outbox

import com.dbpprt.dieter.api.v1.Board
import com.dbpprt.dieter.api.v1.Card
import com.dbpprt.dieter.api.v1.CardDetail
import com.dbpprt.dieter.api.v1.Conversation
import com.dbpprt.dieter.api.v1.ConversationSnapshot
import com.dbpprt.dieter.api.v1.CreateConversationRequest
import com.dbpprt.dieter.api.v1.Lane
import com.dbpprt.dieter.api.v1.MessagePart
import com.dbpprt.dieter.api.v1.QueuedMessage
import com.dbpprt.dieter.api.v1.SendMessageRequest
import com.dbpprt.dieter.api.v1.StartCardRequest
import com.dbpprt.dieter.api.v1.UiMessage
import com.dbpprt.dieter.core.journal.OutboxEntry
import com.dbpprt.dieter.core.journal.OutboxKind
import com.dbpprt.dieter.core.journal.OutboxPlacement
import com.dbpprt.dieter.core.journal.OutboxState
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlin.time.Duration.Companion.seconds
import kotlin.time.Instant
import okio.ByteString.Companion.encodeUtf8
import okio.ByteString.Companion.toByteString

class OutboxPolicyTest {
    private val now = Instant.parse("2026-09-30T12:00:00Z")

    private fun create(command: String, daemon: String = "d1", chat: Boolean = false, deferStart: Boolean = true, lane: String = "todo", at: Long = 0) =
        OutboxEntry(
            command_id = command, client_id = "client-a", daemon_id = daemon,
            kind = if (chat) OutboxKind.OUTBOX_KIND_CREATE_CHAT else OutboxKind.OUTBOX_KIND_CREATE_CARD,
            request = CreateConversationRequest(project_id = "p", board_id = "b", lane = lane, prompt = "hello", defer_start = deferStart, client_id = "client-a", command_id = command)
                .let { CreateConversationRequest.ADAPTER.encode(it).toByteString() },
            optimistic_id = OutboxPolicy.localConversationId(command), created_at_millis = at,
        )

    private fun send(command: String, card: String, daemon: String = "d1", at: Long = 0, placement: OutboxPlacement = OutboxPlacement.OUTBOX_PLACEMENT_TRANSCRIPT) =
        OutboxEntry(
            command_id = command, client_id = "client-a", daemon_id = daemon, kind = OutboxKind.OUTBOX_KIND_SEND_MESSAGE,
            request = SendMessageRequest.ADAPTER.encode(SendMessageRequest(card_id = card, parts = listOf(MessagePart(type = "text", text = command)), message_id = "m_$command")).toByteString(),
            optimistic_id = "m_$command", placement = placement, created_at_millis = at,
        )

    @Test
    fun expectedIdsMatchTheDaemonDerivation() {
        // Go: "c_" + hex(sha256("client-a\x00cmd-1"))[:24]
        assertEquals("c_db16d5acadb6bea9198d0a90", OutboxPolicy.expectedConversationId("client-a", "cmd-1"))
        assertEquals(OutboxPolicy.expectedConversationId("client-a", "cmd-1"), OutboxPolicy.expectedConversationId(" client-a ", "cmd-1\n"))
        assertNull(OutboxPolicy.expectedConversationId("", "cmd"))
        assertNull(OutboxPolicy.expectedConversationId("a".repeat(201), "cmd"))
        assertEquals("local_abc123", OutboxPolicy.localConversationId("abc-123"))
    }

    @Test
    fun deliveryKeepsMachineOrderAndWaitsForDependencies() {
        val created = create("1")
        val dependent = send("2", created.optimistic_id)
        val other = send("3", "c_other", daemon = "d2")
        val entries = listOf(created, dependent, other)
        assertEquals("1", OutboxPolicy.next(entries, listOf("d1", "d2"), now)?.command_id)
        assertEquals("3", OutboxPolicy.next(entries, listOf("d2", "d1"), now)?.command_id)

        // While the create retries, its follow-up waits too.
        val retrying = created.copy(state = OutboxState.OUTBOX_STATE_RETRYING, next_attempt_at_millis = (now + 5.seconds).toEpochMilliseconds())
        assertNull(OutboxPolicy.next(listOf(retrying, dependent), listOf("d1"), now))
        assertEquals(5.seconds, OutboxPolicy.nextRetryDelay(listOf(retrying, dependent), setOf("d1"), now))

        // A failed create blocks its follow-up until the user acts.
        val failed = created.copy(state = OutboxState.OUTBOX_STATE_FAILED)
        assertNull(OutboxPolicy.next(listOf(failed, dependent), listOf("d1"), now))
        assertNull(OutboxPolicy.nextRetryDelay(listOf(failed, dependent), setOf("d1"), now))

        // Once accepted, the follow-up is deliverable, even under the expected ID.
        val accepted = created.copy(server_id = "c_x")
        assertEquals("2", OutboxPolicy.next(listOf(accepted, dependent), listOf("d1"), now)?.command_id)
        val expected = OutboxPolicy.expectedConversationId("client-a", "1")!!
        assertTrue(OutboxPolicy.hasPendingCreation(send("4", expected), listOf(created)))
        assertFalse(OutboxPolicy.hasPendingCreation(send("4", expected, daemon = "d2"), listOf(created)))
    }

    @Test
    fun acceptanceRetargetsSendsAndStarts() {
        val start = OutboxEntry(
            command_id = "s", kind = OutboxKind.OUTBOX_KIND_START_CARD, optimistic_id = "local_1",
            request = StartCardRequest.ADAPTER.encode(StartCardRequest(card_id = "local_1")).toByteString(),
        )
        val retargeted = OutboxPolicy.retargetDependencies(listOf(send("m", "local_1"), send("n", "c_other"), start), "local_1", "c_1")
        assertEquals("c_1", OutboxPolicy.sendRequest(retargeted[0])!!.card_id)
        assertEquals("c_other", OutboxPolicy.sendRequest(retargeted[1])!!.card_id)
        assertEquals("c_1", OutboxPolicy.startRequest(retargeted[2])!!.card_id)
        assertEquals("c_1", retargeted[2].optimistic_id)
    }

    @Test
    fun retargetingNeverDuplicatesARow() {
        val local = Card(id = "local_1", title = "draft")
        val server = Card(id = "c_1", title = "server")
        assertEquals(listOf(server), OutboxPolicy.retargetedCards(listOf(local, server), "local_1", "c_1"))
        assertEquals(listOf(Card(id = "c_1", title = "draft")), OutboxPolicy.retargetedCards(listOf(local), "local_1", "c_1"))
        assertEquals(listOf(server), OutboxPolicy.retargetedCards(listOf(local), "local_1", "c_1", authoritative = server))
        assertEquals(listOf(server), OutboxPolicy.retargetedCards(listOf(server, server.copy(title = "dup")), "local_1", "c_1"))
    }

    @Test
    fun creationCompletesOnlyOnceTheFirstTurnWasAdmitted() {
        val running = create("1", lane = "running", deferStart = false)
        assertTrue(OutboxPolicy.creationRequiresStart(running))
        assertFalse(OutboxPolicy.creationIsComplete(running, Card(id = "c")))
        assertTrue(OutboxPolicy.creationIsComplete(running, Card(id = "c", initial_prompt_sent_at = "2026-09-30T12:00:00Z")))
        assertFalse(OutboxPolicy.creationRequiresStart(create("2", lane = "todo", deferStart = false)))
        assertTrue(OutboxPolicy.creationRequiresStart(create("3", chat = true, deferStart = false)))
        assertFalse(OutboxPolicy.creationRequiresStart(create("4", chat = true, deferStart = true)))
    }

    @Test
    fun optimisticRowsDescribeTheRequest() {
        val card = OutboxPolicy.optimisticCard(create("1", at = now.toEpochMilliseconds()))!!
        assertEquals("local_1", card.id)
        assertEquals("board", card.scope)
        assertEquals("pending", card.runtime)
        assertEquals("d1", card.owner_daemon_id)
        assertEquals(now, Instant.parse(card.created_at))
        val failed = OutboxPolicy.optimisticCard(create("2", chat = true).copy(state = OutboxState.OUTBOX_STATE_FAILED, server_id = "c_2"))!!
        assertEquals("c_2", failed.id)
        assertEquals("", failed.board_id)
        assertEquals("failed", failed.runtime)
    }

    private fun metadata(at: Instant) = "{\"createdAt\":\"$at\"}".encodeUtf8()

    @Test
    fun localSendsKeepTheirChronologicalPlace() {
        val t0 = now.toEpochMilliseconds()
        val snapshot = ConversationSnapshot(
            detail = CardDetail(card = Card(id = "c")),
            conversation = Conversation(
                card_id = "c",
                messages = listOf(
                    UiMessage(id = "u1", role = "user", metadata_json = metadata(now)),
                    UiMessage(id = "a1", role = "assistant", metadata_json = metadata(now + 10.seconds)),
                ),
            ),
        )
        val early = send("early", "c", at = t0 + 5_000)
        val late = send("late", "c", at = t0 + 20_000)
        val queued = send("queued", "c", at = t0 + 30_000, placement = OutboxPlacement.OUTBOX_PLACEMENT_QUEUE)
        val failedQueued = queued.copy(command_id = "fq", optimistic_id = "m_fq", state = OutboxState.OUTBOX_STATE_FAILED)
        val result = OutboxPolicy.overlayOptimisticMessages(snapshot, listOf(late, early, queued, failedQueued, send("elsewhere", "other")))
        assertEquals(listOf("u1", "m_early", "a1", "m_late", "m_fq"), result.conversation!!.messages.map { it.id })
        assertEquals(listOf("m_queued"), result.conversation!!.queue.map { it.id })

        // A send the daemon already queued is not shown twice.
        val serverQueued = snapshot.copy(conversation = snapshot.conversation!!.copy(queue = listOf(QueuedMessage(id = "m_late"))))
        assertEquals(listOf("u1", "m_early", "a1"), OutboxPolicy.overlayOptimisticMessages(serverQueued, listOf(early, late)).conversation!!.messages.map { it.id })
    }

    @Test
    fun aPendingChatShowsItsFirstMessageUntilTheTranscriptHasOne() {
        val chat = create("1", chat = true, deferStart = false).copy(server_id = "c_1")
        val empty = ConversationSnapshot(detail = CardDetail(card = Card(id = "c_1")), conversation = Conversation(card_id = "c_1"))
        assertEquals(listOf("local_1_initial"), OutboxPolicy.overlayOptimisticMessages(empty, listOf(chat)).conversation!!.messages.map { it.id })
        val answered = empty.copy(conversation = Conversation(card_id = "c_1", messages = listOf(UiMessage(id = "u", role = "user"))))
        assertEquals(listOf("u"), OutboxPolicy.overlayOptimisticMessages(answered, listOf(chat)).conversation!!.messages.map { it.id })
    }

    @Test
    fun acceptedCommandsSettleOnlyOnSyncEvidence() {
        val createCard = create("1").copy(server_id = "c_1")
        assertFalse(OutboxPolicy.isSynced(createCard, emptyMap(), emptyMap()))
        assertTrue(OutboxPolicy.isSynced(createCard, mapOf("c_1" to Card(id = "c_1")), emptyMap()))
        assertFalse(OutboxPolicy.isSynced(create("2"), mapOf("c_1" to Card(id = "c_1")), emptyMap()), "unaccepted entries never settle")

        val sent = send("m", "c_1").copy(server_id = "m_m")
        val withMessage = mapOf("c_1" to ConversationSnapshot(conversation = Conversation(messages = listOf(UiMessage(id = "m_m")))))
        assertFalse(OutboxPolicy.isSynced(sent, emptyMap(), emptyMap()))
        assertTrue(OutboxPolicy.isSynced(sent, emptyMap(), withMessage))
        val queuedOnDaemon = mapOf("c_1" to ConversationSnapshot(conversation = Conversation(queue = listOf(QueuedMessage(id = "m_m")))))
        assertTrue(OutboxPolicy.isSynced(sent, emptyMap(), queuedOnDaemon))
    }

    @Test
    fun summariesCountUndeliveredWorkPerMachine() {
        val entries = listOf(
            create("1"), send("2", "c", daemon = "d1").copy(state = OutboxState.OUTBOX_STATE_RETRYING, last_error = "gRPC UNAVAILABLE: No space left on device"),
            send("3", "c", daemon = "d2").copy(state = OutboxState.OUTBOX_STATE_FAILED, last_error = "gRPC NOT_FOUND"),
            send("4", "c", daemon = "d2").copy(server_id = "m"),
        )
        val summaries = OutboxPolicy.summaries(entries)
        assertEquals(MachineOutboxSummary(1, 1, retrying = true, failed = false, failureMessage = "gRPC UNAVAILABLE: No space left on device"), summaries["d1"])
        assertTrue(summaries.getValue("d1").storageBlocked)
        assertEquals(1, summaries.getValue("d2").itemCount)
        assertTrue(summaries.getValue("d2").failed)
        assertEquals(60.seconds, OutboxPolicy.backoff(3, "no space left on device"))
    }
}

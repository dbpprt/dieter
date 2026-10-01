package com.dbpprt.dieter.core

import com.dbpprt.dieter.api.v1.CreateConversationRequest
import com.dbpprt.dieter.core.composition.DraftKey
import com.dbpprt.dieter.core.connection.ConnectionPhase
import com.dbpprt.dieter.core.conversation.ConversationConfig
import com.dbpprt.dieter.core.conversation.ConversationSession
import com.dbpprt.dieter.core.outbox.OutboxPolicy
import com.dbpprt.dieter.core.testing.EndToEnd
import com.dbpprt.dieter.core.testing.IsolatedGateway
import com.dbpprt.dieter.core.testing.await
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import kotlin.time.Duration.Companion.seconds

/** CONV scenarios against a real daemon running the mock harness. */
class ConversationEndToEndTest : EndToEnd() {
    @AfterTest
    fun tearDown() = tearDownRuntimes()

    private suspend fun chat(runtime: CoreRuntime, fixture: IsolatedGateway, prompt: String) = runtime.createConversation(
        CreateConversationRequest(project_id = fixture.projectId, title = prompt, prompt = prompt, provider = "mock", model = "mock", effort = "low", workspace_mode = "project"),
        chat = true,
    )

    private fun ConversationSession.texts(role: String) = view.value.messages.filter { it.role == role }.flatMap { it.parts }.filter { it.type == "text" }.map { it.text }

    private suspend fun ConversationSession.awaitReplies(count: Int) = view.await(60.seconds, describe = { "$count replies: ${texts("user")} / ${texts("assistant").size} (${view.value})" }) { view ->
        view.messages.count { it.role == "assistant" } >= count && view.conversation?.status?.let { it != "running" && it != "starting" } == true
    }

    @Test
    fun aChatStreamsFromItsLocalIdThroughItsFirstTurnAndIsMarkedRead() = e2e {
        val fixture = fixture()
        val runtime = runtime(fixture)
        runtime.awaitConnected()
        runtime.awaitLoaded(fixture)
        val local = chat(runtime, fixture, "first question")
        val session = runtime.openConversation(local.id)
        assertTrue(session.view.value.pending || OutboxPolicy.isServerBacked(session.cardId))
        session.view.await(30.seconds, describe = { "resolved: ${runtime.outbox.view.value.entries}" }) { OutboxPolicy.isServerBacked(it.cardId) && !it.loading }
        session.awaitReplies(1)
        assertEquals(listOf("first question"), session.texts("user"))
        assertEquals(fixture.daemonId, session.view.value.daemonId)

        val card = runtime.workspace.state.await(describe = { "reply recorded" }) { (it.card(session.cardId)?.response_seq ?: 0) > 0 }.card(session.cardId)!!
        if (card.seen_response_seq < card.response_seq) {
            assertTrue(runtime.onConversation(session) { markReadIfVisible() })
            runtime.workspace.state.await(describe = { "seen" }) { view -> view.card(session.cardId)?.let { it.seen_response_seq >= it.response_seq } == true }
        }
        assertEquals(false, runtime.onConversation(session) { markReadIfVisible() }, "a seen reply is not marked again")
    }

    @Test
    fun draftsSendAndHistoryPagesBackBeyondTheLiveWindow() = e2e {
        val fixture = fixture()
        val runtime = runtime(fixture) { it.copy(conversations = ConversationConfig(pageSize = 3, watchLimit = 3)) }
        runtime.awaitConnected()
        runtime.awaitLoaded(fixture)
        val local = chat(runtime, fixture, "turn 0")
        val session = runtime.openConversation(local.id)
        session.view.await(30.seconds) { OutboxPolicy.isServerBacked(it.cardId) }
        session.awaitReplies(1)
        val key = DraftKey(session.view.value.daemonId!!, session.cardId)
        val composer = runtime.onCore { runtime.drafts.editor(key) }
        for (turn in 1..3) {
            // Keystrokes land off the core dispatcher, one by one, and the send takes all of them.
            "turn $turn".let { text -> for (end in 1..text.length) composer.setText(text.take(end)) }
            // The composer shows the send as awaiting a reply at once, before anything streams.
            val id = runtime.onConversation(session) { sendDraft().also { assertTrue(view.value.awaitingReply) } }
            assertTrue(id != null)
            assertEquals(false, session.view.value.retrying)
            assertEquals("", composer.state.value.text, "the sent text leaves the composer")
            assertEquals("", runtime.onCore { runtime.drafts.draft(key).text })
            session.awaitReplies(turn + 1)
            session.view.await(30.seconds, describe = { "reply settles the wait" }) { !it.awaitingReply }
        }
        val view = session.view.value
        assertTrue(view.conversation!!.messages.size <= 3 + 1, "the live window stays bounded")
        // Earlier turns slid into history while streaming, or are one page away.
        while (runtime.onConversation(session) { loadEarlier() }) Unit
        assertEquals(listOf("turn 0", "turn 1", "turn 2", "turn 3"), session.texts("user"))
        assertTrue(session.view.value.messages.count { it.role == "assistant" } >= 4)
    }

    @Test
    fun theStreamRecoversWhenTheMachineReturns() = e2e {
        val fixture = fixture()
        val runtime = runtime(fixture)
        runtime.awaitConnected()
        runtime.awaitLoaded(fixture)
        val local = chat(runtime, fixture, "before")
        val session = runtime.openConversation(local.id)
        session.view.await(30.seconds) { OutboxPolicy.isServerBacked(it.cardId) }
        session.awaitReplies(1)

        fixture.daemonOffline()
        runtime.connection.state.await { it.phase == ConnectionPhase.NO_MACHINE }
        session.view.await(20.seconds, describe = { "syncing: ${session.view.value}" }) { it.syncing }
        assertEquals(listOf("before"), session.texts("user"), "cached messages stay readable")
        runtime.onConversation(session) { send(listOf(com.dbpprt.dieter.api.v1.MessagePart(type = "text", text = "after"))) }
        fixture.daemonOnline()
        session.awaitReplies(2)
        assertEquals(listOf("before", "after"), session.texts("user"))
    }
}

package com.dbpprt.dieter.core

import com.dbpprt.dieter.api.v1.CreateConversationRequest
import com.dbpprt.dieter.api.v1.MessagePart
import com.dbpprt.dieter.client.v1.AdoptSession
import com.dbpprt.dieter.client.v1.Command
import com.dbpprt.dieter.client.v1.ConversationSlice
import com.dbpprt.dieter.client.v1.CreateConversation
import com.dbpprt.dieter.client.v1.Failure
import com.dbpprt.dieter.client.v1.RenameCard
import com.dbpprt.dieter.client.v1.SendMessage
import com.dbpprt.dieter.client.v1.SessionSlice
import com.dbpprt.dieter.client.v1.Slice
import com.dbpprt.dieter.client.v1.Update
import com.dbpprt.dieter.client.v1.WorkspaceSlice
import com.dbpprt.dieter.core.client.ClientApi
import com.dbpprt.dieter.core.client.ClientFailure
import com.dbpprt.dieter.core.outbox.OutboxPolicy
import com.dbpprt.dieter.core.testing.EndToEnd
import com.dbpprt.dieter.core.testing.await
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue
import kotlin.time.Duration.Companion.seconds
import kotlinx.coroutines.flow.MutableStateFlow

/**
 * The D7 contract end to end: a UI that only dispatches commands and applies
 * observed snapshots and deltas signs in, sees the workspace, creates and
 * renames a card, and chats, exactly as the Apple façade does with bytes.
 */
class ClientApiEndToEndTest : EndToEnd() {
    @AfterTest
    fun tearDown() = tearDownRuntimes()

    /** Folds updates as a UI would; a sequence gap fails the test. */
    private class Mirror {
        val session = MutableStateFlow<SessionSlice?>(null)
        val workspace = MutableStateFlow<WorkspaceSlice?>(null)
        val conversation = MutableStateFlow<ConversationSlice?>(null)
        private val sequences = mutableMapOf<Slice, Long>()

        fun accept(update: Update) {
            val last = sequences[update.slice] ?: 0
            check(update.sequence == last + 1) { "missed an update of ${update.slice}: $last → ${update.sequence}" }
            sequences[update.slice] = update.sequence
            update.session?.let { session.value = it }
            update.workspace?.let { workspace.value = it }
            update.workspace_delta?.let { delta -> workspace.value = ClientApi.apply(checkNotNull(workspace.value), delta) }
            update.conversation?.let { conversation.value = it }
            update.conversation_delta?.let { delta -> conversation.value = ClientApi.apply(checkNotNull(conversation.value), delta) }
        }
    }

    @Test
    fun aByteOnlyUiSignsInCreatesRenamesAndChats() = e2e {
        val fixture = fixture()
        val runtime = runtime(fixture, token = null)
        val api = ClientApi(runtime)
        val mirror = Mirror()
        val subscriptions = listOf(Slice.SLICE_SESSION, Slice.SLICE_WORKSPACE).map { slice ->
            api.observe(slice, "") { update -> mirror.accept(Update.ADAPTER.decode(update.encode())) }
        }

        val invalid = assertFailsWith<ClientFailure> { api.dispatch(Command(adopt_session = AdoptSession(gateway_url = fixture.url, session_token = ""))) }
        assertEquals(Failure.Kind.KIND_INVALID, invalid.failure.kind)
        api.dispatch(Command(adopt_session = AdoptSession(gateway_url = fixture.url, session_token = fixture.token, name = "Isolated")))
        val session = mirror.session.await(30.seconds, describe = { "connected: ${mirror.session.value}" }) { it?.phase == SessionSlice.Phase.PHASE_CONNECTED }!!
        assertTrue(session.signed_in)
        assertEquals(fixture.daemonId, session.attached_machine_id)
        assertTrue(session.machines.any { it.id == fixture.daemonId && it.online && it.attached })
        mirror.workspace.await(describe = { "project" }) { slice -> slice?.projects?.any { it.id == fixture.projectId } == true }

        val created = api.dispatch(
            Command(
                create_conversation = CreateConversation(
                    request = CreateConversationRequest(
                        project_id = fixture.projectId, board_id = fixture.boardId, lane = "todo", title = "From the client contract",
                        prompt = "hello", defer_start = true, workspace_mode = "project",
                    ),
                ),
            ),
        ).card!!
        mirror.workspace.await(describe = { "created card" }) { slice -> slice?.cards?.any { it.title == "From the client contract" } == true }
        val serverId = mirror.workspace.await(30.seconds, describe = { "synced card" }) { slice ->
            slice?.cards?.any { OutboxPolicy.isServerBacked(it.id) && it.title == "From the client contract" } == true
        }!!.cards.first { it.title == "From the client contract" }.id
        assertTrue(created.id.isNotEmpty())
        api.dispatch(Command(rename_card = RenameCard(card_id = serverId, title = "Renamed through bytes")))
        mirror.workspace.await(describe = { "renamed" }) { slice -> slice?.cards?.any { it.id == serverId && it.title == "Renamed through bytes" } == true }
        assertEquals(mirror.workspace.value, api.workspaceSlices().await { true }, "folded deltas equal a fresh snapshot")

        val chat = api.dispatch(
            Command(
                create_conversation = CreateConversation(
                    request = CreateConversationRequest(project_id = fixture.projectId, title = "chat", prompt = "first", provider = "mock", model = "mock", effort = "low", workspace_mode = "project"),
                    chat = true,
                ),
            ),
        ).card!!
        val watching = api.observe(Slice.SLICE_CONVERSATION, chat.id) { mirror.accept(Update.ADAPTER.decode(it.encode())) }
        fun replies() = mirror.conversation.value?.messages.orEmpty().count { it.role == "assistant" }
        mirror.conversation.await(60.seconds, describe = { "first reply: ${mirror.conversation.value}" }) { replies() >= 1 && it?.conversation?.status !in setOf("running", "starting") }
        val cardId = mirror.conversation.value!!.card_id
        api.dispatch(Command(send_message = SendMessage(card_id = cardId, parts = listOf(MessagePart(type = "text", text = "second")))))
        mirror.conversation.await(60.seconds, describe = { "second reply: ${mirror.conversation.value}" }) { replies() >= 2 && it?.conversation?.status !in setOf("running", "starting") }
        assertEquals(
            listOf("first", "second"),
            mirror.conversation.value!!.messages.filter { it.role == "user" }.flatMap { it.parts }.filter { it.type == "text" }.map { it.text },
        )
        watching.close()
        subscriptions.forEach { it.close() }
    }
}

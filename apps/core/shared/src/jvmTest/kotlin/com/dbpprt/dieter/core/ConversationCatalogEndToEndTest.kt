package com.dbpprt.dieter.core

import com.dbpprt.dieter.api.v1.CreateConversationRequest
import com.dbpprt.dieter.client.v1.AgentChoice
import com.dbpprt.dieter.client.v1.ChooseAgent
import com.dbpprt.dieter.client.v1.Command
import com.dbpprt.dieter.client.v1.ConversationSlice
import com.dbpprt.dieter.client.v1.SendMessage
import com.dbpprt.dieter.client.v1.Slice
import com.dbpprt.dieter.client.v1.Update
import com.dbpprt.dieter.core.client.ClientApi
import com.dbpprt.dieter.core.testing.EndToEnd
import com.dbpprt.dieter.core.testing.SliceFolds
import com.dbpprt.dieter.core.testing.await
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import kotlin.time.Duration.Companion.seconds
import kotlinx.coroutines.flow.MutableStateFlow

/** A fresh client opens an existing task without first loading a creation form. */
class ConversationCatalogEndToEndTest : EndToEnd() {
    @AfterTest fun tearDown() = tearDownRuntimes()

    @Test
    fun openingAnExistingConversationLoadsItsCatalogAndSendsTheChosenAgent() = e2e {
        val fixture = fixture()
        val runtime = runtime(fixture)
        runtime.awaitConnected()
        runtime.awaitLoaded(fixture)
        // Create through the daemon-facing path, without opening a creation
        // preview or explicitly requesting metadata on this client.
        val local =
            runtime.createConversation(
                CreateConversationRequest(
                    project_id = fixture.projectId,
                    board_id = fixture.boardId,
                    lane = "todo",
                    title = "Existing conversation",
                    provider = "mock",
                    model = "mock",
                    effort = "low",
                    workspace_mode = "project",
                ),
                chat = false,
            )
        val cardId =
            runtime.outbox.view
                .await(30.seconds, describe = { "created conversation" }) {
                    it.resolve(local.id) != local.id
                }
                .resolve(local.id)
        runtime.awaitSynced(cardId)
        assertTrue(
            runtime.metadata.machines.value.isEmpty(),
            "creation must not mask the cold catalog",
        )

        val api = ClientApi(runtime)
        val conversation = MutableStateFlow<ConversationSlice?>(null)
        var sequence = 0L
        val watching =
            api.observe(Slice.SLICE_CONVERSATION, cardId) { emitted ->
                val update = Update.ADAPTER.decode(emitted.encode())
                assertEquals(
                    sequence + 1,
                    update.sequence,
                    "every catalog update must reach the client",
                )
                sequence = update.sequence
                update.conversation?.let { conversation.value = it }
                update.conversation_delta?.let {
                    conversation.value = SliceFolds.apply(checkNotNull(conversation.value), it)
                }
            }
        val agent =
            conversation
                .await(describe = { "existing conversation's catalog" }) {
                    it?.state?.agent?.models?.any { model -> model.id == "mock" } == true
                }!!
                .state!!
                .agent!!
        assertEquals("Mock", agent.provider_label)
        assertEquals("Mock", agent.model_label)
        assertTrue(agent.model_enabled)
        assertTrue(agent.effort_enabled)
        api.dispatch(
            Command(
                choose_agent = ChooseAgent(card_id = cardId, choice = AgentChoice(model = "mock"))
            )
        )
        api.dispatch(
            Command(
                choose_agent = ChooseAgent(card_id = cardId, choice = AgentChoice(effort = "high"))
            )
        )
        conversation.await(describe = { "chosen effort" }) {
            it?.state?.agent?.selection?.effort == "high"
        }
        api.dispatch(
            Command(send_message = SendMessage(card_id = cardId, text = "Use the chosen agent"))
        )
        conversation.await(60.seconds, describe = { "reply with the chosen agent" }) { slice ->
            slice?.messages?.any { message ->
                message.role == "assistant" &&
                    message.parts.any { it.text == "Mock harness received: Use the chosen agent" }
            } == true && slice.card?.effort == "high"
        }
        watching.close()
    }
}

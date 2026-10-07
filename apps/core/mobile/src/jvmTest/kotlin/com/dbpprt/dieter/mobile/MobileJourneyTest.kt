package com.dbpprt.dieter.mobile

import com.dbpprt.dieter.client.v1.*
import com.dbpprt.dieter.core.client.ClientApi
import com.dbpprt.dieter.core.testing.*
import kotlin.coroutines.ContinuationInterceptor
import kotlin.test.*
import kotlin.time.Duration.Companion.seconds
import kotlinx.coroutines.*

class MobileJourneyTest : EndToEnd() {
    @AfterTest fun cleanup() = tearDownRuntimes()

    @Test
    fun sharedTaskJourneySurvivesFollowUpAndSyncsToAnotherClient() = e2e {
        val fixture = fixture()
        val runtime = runtime(fixture)
        val otherRuntime = runtime(fixture)
        runtime.awaitConnected()
        runtime.awaitLoaded(fixture)
        otherRuntime.awaitConnected()
        otherRuntime.awaitLoaded(fixture)
        val uiDispatcher = coroutineContext[ContinuationInterceptor] as CoroutineDispatcher
        val first = MobileStore(RuntimeMobileCore(ClientApi(runtime)), uiDispatcher)
        val second = MobileStore(RuntimeMobileCore(ClientApi(otherRuntime)), uiDispatcher)
        try {
            first.workspace.await { it.boards.any { board -> board.id == fixture.boardId } }
            first.chooseBoard(fixture.boardId)
            first.board.await { it.lanes.isNotEmpty() }
            first.agentSelection = com.dbpprt.dieter.api.v1.HarnessSelection("mock", "mock", "low")
            val localId =
                first.create("Shared mobile spike", "Explain this durable conversation", run = true)
            first.openCard(localId)
            val cardId =
                first.outbox.await { localId in it.resolutions }.resolutions.getValue(localId)
            runtime.awaitSynced(cardId)
            val completed =
                first.conversation.await(
                    60.seconds,
                    describe = {
                        "reply for $cardId: selected=${first.selectedCard.value}, card=${first.conversation.value.card?.provider}, failure=${first.conversation.value.turn_failure}, messages=${first.conversation.value.messages}"
                    },
                ) {
                    it.messages.any { message ->
                        message.role == "assistant" &&
                            message.parts.any { part ->
                                part.text.startsWith("Mock harness received:")
                            }
                    } && it.state?.working == false
                }
            assertNull(completed.turn_failure)
            assertEquals("Shared mobile spike", first.conversation.value.card?.title)
            first.send("Continue in the same task")
            first.conversation.await(60.seconds) {
                it.messages.any { message ->
                    message.role == "assistant" &&
                        message.parts.any { part ->
                            part.text.contains("Mock harness received: Continue in the same task")
                        }
                } && it.state?.working == false
            }
            assertEquals(cardId, first.conversation.value.card_id)
            first.move("review")
            second.workspace.await {
                it.cards.any { card -> card.id == cardId && card.lane == "review" }
            }
            first.back()
            assertTrue(first.selectedCard.value.isEmpty())
            first.openCard(cardId)
            first.conversation.await {
                it.messages.any { message ->
                    message.parts.any { part -> part.text.contains("Continue in the same task") }
                }
            }
        } finally {
            first.close()
            second.close()
        }
    }

    @Test
    fun queuedActionsKeepTheTaskSelectedWhenTheyWereRequested() = runBlocking {
        val sent = mutableListOf<Command>()
        val fake =
            object : MobileCore {
                override suspend fun dispatch(command: Command): Result {
                    sent += command
                    return Result(done = Done())
                }

                override fun observe(slice: Slice, scope: String, receive: (Update) -> Unit) =
                    com.dbpprt.dieter.core.client.ClientSubscription {}
            }
        val store = MobileStore(fake, Dispatchers.Unconfined)
        try {
            store.openCard("first")
            val release = CompletableDeferred<Unit>()
            store.action { release.await() }
            store.move("review")
            store.stop()
            store.start()
            store.loadEarlier()
            store.openCard("second")
            release.complete(Unit)
            yield()
            assertEquals("first", sent.single { it.move_card != null }.move_card?.card_id)
            assertEquals("first", sent.single { it.cancel_card != null }.cancel_card?.card_id)
            assertEquals("first", sent.single { it.start_card != null }.start_card?.card_id)
            assertEquals(
                "first",
                sent.single { it.load_earlier_messages != null }.load_earlier_messages?.card_id,
            )
        } finally {
            store.close()
        }
    }

    @Test
    fun switchingConversationsRejectsLateUpdatesFromClosedScopes() = runBlocking {
        val callbacks = mutableMapOf<String, (Update) -> Unit>()
        val fake =
            object : MobileCore {
                override suspend fun dispatch(command: Command) = Result(done = Done())

                override fun observe(
                    slice: Slice,
                    scope: String,
                    receive: (Update) -> Unit,
                ): com.dbpprt.dieter.core.client.ClientSubscription {
                    callbacks[scope] = receive
                    return com.dbpprt.dieter.core.client.ClientSubscription {}
                }
            }
        val store = MobileStore(fake, Dispatchers.Unconfined)
        store.openCard("first")
        val old = callbacks.getValue("first")
        store.openCard("second")
        callbacks.getValue("second")(Update(conversation = ConversationSlice(card_id = "second")))
        old(Update(conversation = ConversationSlice(card_id = "first")))
        assertEquals("second", store.conversation.value.card_id)
        store.close()
        callbacks.getValue("second")(Update(conversation = ConversationSlice(card_id = "late")))
        assertEquals("second", store.conversation.value.card_id)
    }
}

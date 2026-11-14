package com.getdieter.mobile.store

import com.getdieter.api.v1.Conversation
import com.getdieter.api.v1.QueuedMessage
import com.getdieter.client.v1.*
import kotlin.test.*
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.*

@OptIn(ExperimentalCoroutinesApi::class)
class ConversationQueueTest {
    @Test
    fun sendingOnlyClearsTheDraftThatWasActuallySent() = runTest {
        val fake = FakeMobileCore()
        val sent = CompletableDeferred<Unit>()
        val core =
            object : MobileCore by fake {
                override suspend fun dispatch(command: Command): Result {
                    val result = fake.dispatch(command)
                    if (command.send_message != null) sent.await()
                    return result
                }
            }
        val store = MobileStore(core, StandardTestDispatcher(testScheduler))
        try {
            store.openConversation("card")
            runCurrent()
            store.conversation.saveDraft("card", "First message")
            store.action { store.conversation.send("First message") }
            runCurrent()
            store.conversation.saveDraft("card", "New draft typed while sending")
            sent.complete(Unit)
            runCurrent()
            assertEquals(
                "New draft typed while sending",
                store.conversation.draftTexts.value["card"],
            )
        } finally {
            store.close()
        }
    }

    @Test
    fun sendNowShowsEachWaitAndIgnoresRepeatedTapsUntilTheQueueAdvances() = runTest {
        val fake = FakeMobileCore()
        val reply = CompletableDeferred<Unit>()
        val core =
            object : MobileCore by fake {
                override suspend fun dispatch(command: Command): Result {
                    val result = fake.dispatch(command)
                    if (command.steer_conversation != null) reply.await()
                    return result
                }
            }
        val store = MobileStore(core, StandardTestDispatcher(testScheduler))
        try {
            store.openConversation("card")
            runCurrent()
            fun publish(vararg ids: String) =
                fake.publish(
                    Slice.SLICE_CONVERSATION,
                    "card",
                    Update(
                        conversation =
                            ConversationSlice(
                                card_id = "card",
                                conversation =
                                    Conversation(queue = ids.map { QueuedMessage(id = it) }),
                            )
                    ),
                )
            publish("first", "second")
            runCurrent()
            val earlierAction = CompletableDeferred<Unit>()
            store.action { earlierAction.await() }
            runCurrent()

            store.conversation.sendNow("first")
            store.conversation.sendNow("first")
            assertEquals(QueueActionPhase.WAITING, store.conversation.queueAction.value?.phase)
            runCurrent()
            assertTrue(fake.sentOf { it.steer_conversation }.isEmpty())

            earlierAction.complete(Unit)
            runCurrent()
            assertEquals(QueueActionPhase.SENDING, store.conversation.queueAction.value?.phase)
            reply.complete(Unit)
            runCurrent()
            assertEquals(QueueActionPhase.STOPPING, store.conversation.queueAction.value?.phase)
            store.conversation.sendNow("first")
            store.conversation.removeQueued("first")
            runCurrent()
            assertEquals(1, fake.sentOf { it.steer_conversation }.size)
            assertTrue(fake.sentOf { it.remove_queued_message }.isEmpty())

            publish("second")
            runCurrent()
            assertNull(store.conversation.queueAction.value)
        } finally {
            store.close()
        }
    }

    @Test
    fun aFailedQueueActionKeepsTheMessageAndDraftAndCanBeRetried() = runTest {
        var fail = true
        val fake = FakeMobileCore { command ->
            if (command.remove_queued_message != null) {
                if (fail) error("Machine disconnected. Try again.")
                Result(queued_message = QueuedMessage(id = "next", text = "Queued draft"))
            } else Result(done = Done())
        }
        val store = MobileStore(fake, StandardTestDispatcher(testScheduler))
        try {
            store.openConversation("card")
            runCurrent()
            store.conversation.saveDraft("card", "Keep my draft")
            var recalled = ""
            store.conversation.editQueued("next") { recalled = it.text }
            assertTrue(store.conversation.queueAction.value!!.pending)
            runCurrent()
            val failure = store.conversation.queueAction.value!!
            assertFalse(failure.pending)
            assertTrue(failure.error.contains("disconnected"))
            assertEquals("Keep my draft", store.conversation.draftTexts.value["card"])
            assertEquals("", recalled)
            fail = false
            store.conversation.editQueued("next") { recalled = it.text }
            runCurrent()
            assertNull(store.conversation.queueAction.value)
            assertEquals("Queued draft", recalled)
            assertEquals("Queued draft", store.conversation.draftTexts.value["card"])
        } finally {
            store.close()
        }
    }
}

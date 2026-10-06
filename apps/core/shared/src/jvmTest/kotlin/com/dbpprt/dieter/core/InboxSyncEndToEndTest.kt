package com.dbpprt.dieter.core

import com.dbpprt.dieter.api.v1.CreateConversationRequest
import com.dbpprt.dieter.api.v1.MarkConversationReadRequest
import com.dbpprt.dieter.client.v1.ActivitySlice
import com.dbpprt.dieter.client.v1.Slice
import com.dbpprt.dieter.client.v1.Update
import com.dbpprt.dieter.core.activity.ActivityKind
import com.dbpprt.dieter.core.client.ClientApi
import com.dbpprt.dieter.core.connection.ConnectionPhase
import com.dbpprt.dieter.core.testing.EndToEnd
import com.dbpprt.dieter.core.testing.await
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlin.time.Duration.Companion.seconds
import kotlinx.coroutines.flow.MutableStateFlow

/**
 * Android's domain feed and Apple's byte slice follow other clients without a transcript session.
 */
class InboxSyncEndToEndTest : EndToEnd() {
    @AfterTest fun tearDown() = tearDownRuntimes()

    @Test
    fun relayInboxesFollowRepliesReadReceiptsAndArchivesWithoutOpeningCards() = e2e {
        verifyInboxes(null)
    }

    @Test
    fun directInboxesFollowRepliesReadReceiptsAndArchivesWithoutOpeningCards() = e2e {
        verifyInboxes("live")
    }

    private suspend fun verifyInboxes(route: String?) {
        val fixture = fixture(directRoute = route)
        val actor = runtime(fixture)
        val observer = runtime(fixture)
        actor.awaitLoaded(fixture)
        observer.awaitLoaded(fixture)
        val apple = MutableStateFlow<ActivitySlice?>(null)
        val subscription =
            ClientApi(observer).observe(Slice.SLICE_ACTIVITY, "") {
                apple.value = Update.ADAPTER.decode(it.encode()).activity
            }
        try {
            for (chat in listOf(false, true)) {
                val created =
                    actor.onMachine(fixture.daemonId) { client ->
                        val request =
                            CreateConversationRequest(
                                project_id = fixture.projectId,
                                board_id = if (chat) "" else fixture.boardId,
                                lane = "running",
                                title = "Unopened ${if (chat) "chat" else "card"}",
                                prompt = "Reply to the inbox",
                                provider = "mock",
                                model = "mock",
                                workspace_mode = "project",
                            )
                        if (chat) client.CreateChat().execute(request)
                        else client.CreateCard().execute(request)
                    }
                val unread =
                    apple
                        .await(60.seconds, describe = { "unopened reply: ${apple.value}" }) { slice
                            ->
                            slice?.rows?.any { it.card?.id == created.id && it.kind == "UNREAD" } ==
                                true
                        }!!
                        .rows
                        .single { it.card?.id == created.id }
                assertTrue(unread.needs_you)
                assertTrue(
                    observer.currentActivity().any {
                        it.id == created.id && it.kind == ActivityKind.UNREAD
                    }
                )
                assertNull(observer.onCore { observer.conversations.session(created.id) })
                actor.onMachine(fixture.daemonId) {
                    it.MarkConversationRead()
                        .execute(
                            MarkConversationReadRequest(created.id, unread.card!!.response_seq)
                        )
                }
                apple.await(describe = { "remote read receipt" }) { slice ->
                    slice?.rows?.any {
                        it.card?.id == created.id &&
                            !it.needs_you &&
                            it.card?.seen_response_seq == unread.card!!.response_seq
                    } == true
                }
                assertTrue(observer.currentActivity().none { it.id == created.id && it.needsYou })
                actor.workspace.state.await(60.seconds, describe = { "worker cleanup finished" }) {
                    it.card(created.id)?.runtime == "idle"
                }

                // App only / Smart sleep keeps the cached inbox; the next window catches up.
                observer.setActive(false)
                observer.connection.state.await { it.phase == ConnectionPhase.DISCONNECTED }
                actor.onBoard { archive(created.id) }
                assertTrue(observer.connection.refreshForWidget(30.seconds))
                // Refresh success guarantees the projection was applied, without an extra wait or
                // card open.
                assertNull(observer.workspace.state.value.card(created.id))
                assertTrue(observer.currentActivity().none { it.id == created.id })
                apple.await { slice ->
                    slice != null && slice.rows.none { it.card?.id == created.id }
                }
                observer.setActive(true)
                observer.awaitConnected()
            }
            assertEquals(ConnectionPhase.CONNECTED, observer.connection.state.value.phase)
        } finally {
            subscription.close()
        }
    }
}

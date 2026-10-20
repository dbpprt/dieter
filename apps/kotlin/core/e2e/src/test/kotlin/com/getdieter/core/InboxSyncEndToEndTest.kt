package com.getdieter.core

import com.getdieter.api.v1.CreateConversationRequest
import com.getdieter.api.v1.MarkConversationReadRequest
import com.getdieter.client.v1.ActivitySlice
import com.getdieter.client.v1.Command
import com.getdieter.client.v1.DeleteInboxRule
import com.getdieter.client.v1.InboxRule
import com.getdieter.client.v1.NavigationCommand
import com.getdieter.client.v1.NavigationSlice
import com.getdieter.client.v1.Slice
import com.getdieter.client.v1.Update
import com.getdieter.core.activity.ActivityKind
import com.getdieter.core.client.ClientApi
import com.getdieter.core.connection.ConnectionPhase
import com.getdieter.core.testing.EndToEnd
import com.getdieter.core.testing.await
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

    @Test
    fun inboxRulesSyncToOtherClientsAndFilterTheirFeeds() = e2e {
        val fixture = fixture()
        val actor = runtime(fixture)
        val observer = runtime(fixture)
        actor.awaitLoaded(fixture)
        observer.awaitLoaded(fixture)
        val navigation = MutableStateFlow<NavigationSlice?>(null)
        val activity = MutableStateFlow<ActivitySlice?>(null)
        val observed = ClientApi(observer)
        val subscriptions =
            listOf(
                observed.observe(Slice.SLICE_NAVIGATION, "") {
                    navigation.value = Update.ADAPTER.decode(it.encode()).navigation
                },
                observed.observe(Slice.SLICE_ACTIVITY, "") {
                    activity.value = Update.ADAPTER.decode(it.encode()).activity
                },
            )
        try {
            val created =
                actor.onMachine(fixture.daemonId) { client ->
                    client
                        .CreateCard()
                        .execute(
                            CreateConversationRequest(
                                project_id = fixture.projectId,
                                board_id = fixture.boardId,
                                lane = "running",
                                title = "Ruled card",
                                prompt = "Reply to the inbox",
                                provider = "mock",
                                model = "mock",
                                workspace_mode = "project",
                            )
                        )
                }
            activity.await(60.seconds, describe = { "card in the inbox" }) { slice ->
                slice?.rows?.any { it.card?.id == created.id } == true
            }
            // A rule saved on one client hides the project's conversations on the other.
            ClientApi(actor)
                .dispatch(
                    Command(
                        navigation =
                            NavigationCommand(
                                save_inbox_rule =
                                    InboxRule(
                                        name = "Quiet",
                                        hide = true,
                                        project_ids = listOf(fixture.projectId),
                                        enabled = true,
                                    )
                            )
                    )
                )
            val rule =
                navigation
                    .await(60.seconds, describe = { "rule synced: ${navigation.value}" }) { slice ->
                        slice?.inbox_rules?.isNotEmpty() == true
                    }!!
                    .inbox_rules
                    .single()
            assertEquals(listOf(fixture.projectId), rule.project_ids)
            activity.await(60.seconds, describe = { "card hidden: ${activity.value}" }) { slice ->
                slice != null &&
                    slice.rows.none { it.card?.id == created.id } &&
                    (slice.summary?.hidden ?: 0) > 0
            }
            assertTrue(observer.currentActivity().none { it.id == created.id })
            ClientApi(actor)
                .dispatch(
                    Command(
                        navigation = NavigationCommand(delete_inbox_rule = DeleteInboxRule(rule.id))
                    )
                )
            activity.await(60.seconds, describe = { "card back: ${activity.value}" }) { slice ->
                slice?.rows?.any { it.card?.id == created.id } == true
            }
        } finally {
            subscriptions.forEach { it.close() }
        }
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

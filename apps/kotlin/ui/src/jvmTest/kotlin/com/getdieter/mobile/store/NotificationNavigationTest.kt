package com.getdieter.mobile.store

import com.getdieter.client.v1.*
import com.getdieter.mobile.navigation.*
import kotlin.test.*
import kotlinx.coroutines.*

class NotificationNavigationTest {
    @Test
    fun notificationTapWaitsForSignInAndCatchUpThenOpensTheCardInInbox() = runBlocking {
        val observers = mutableMapOf<Slice, (Update) -> Unit>()
        val fake =
            object : MobileCore {
                override suspend fun dispatch(command: Command) = Result(done = Done())

                override fun observe(
                    slice: Slice,
                    scope: String,
                    receive: (Update) -> Unit,
                ): com.getdieter.core.client.ClientSubscription {
                    observers[slice] = receive
                    return com.getdieter.core.client.ClientSubscription {}
                }
            }
        val store = MobileStore(fake, Dispatchers.Unconfined)
        try {
            observers.getValue(Slice.SLICE_SESSION)(
                Update(session = SessionSlice(phase = SessionSlice.Phase.PHASE_AUTH_REQUIRED))
            )
            store.openNotification("card")
            assertEquals("", store.conversation.selectedCard.value)
            observers.getValue(Slice.SLICE_WORKSPACE)(
                Update(workspace = WorkspaceSlice(loaded = true))
            )
            assertEquals("", store.conversation.selectedCard.value)
            observers.getValue(Slice.SLICE_SESSION)(
                Update(session = SessionSlice(phase = SessionSlice.Phase.PHASE_CONNECTING))
            )
            assertEquals(
                "",
                store.conversation.selectedCard.value,
                "a missing card may still arrive during sync",
            )
            store.present(MobileRoute.Tool(ToolPage.FILES))
            observers.getValue(Slice.SLICE_WORKSPACE)(
                Update(
                    workspace =
                        WorkspaceSlice(
                            loaded = true,
                            cards = listOf(com.getdieter.api.v1.Card(id = "card")),
                        )
                )
            )
            assertEquals("card", store.conversation.selectedCard.value)
            assertEquals(MobileTab.INBOX, store.routes.value.tab)
            assertNull(store.routes.value.modal)
            store.openNotification("gone")
            observers.getValue(Slice.SLICE_SESSION)(
                Update(
                    session =
                        SessionSlice(phase = SessionSlice.Phase.PHASE_CONNECTED, synced = true)
                )
            )
            assertEquals(MobileTab.INBOX, store.routes.value.tab)
            assertEquals("This task is no longer available.", store.error.value)
        } finally {
            store.close()
        }
    }
}

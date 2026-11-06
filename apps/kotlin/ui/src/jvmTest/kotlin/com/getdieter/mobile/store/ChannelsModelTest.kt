package com.getdieter.mobile.store

import com.getdieter.client.v1.*
import com.getdieter.mobile.navigation.*
import kotlin.test.*
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.*

@OptIn(ExperimentalCoroutinesApi::class)
class ChannelsModelTest {
    private fun TestScope.store(core: FakeMobileCore) =
        MobileStore(core, StandardTestDispatcher(testScheduler))

    private fun channels(core: FakeMobileCore) =
        core.sentOf { it.channels }.filter { it.set_setting == null }

    @Test
    fun theChannelListWatchesOnlyTheOpenChannel() = runTest {
        val core = FakeMobileCore()
        val store = store(core)
        try {
            runCurrent()
            // The list and the switch are observed for the badge and Settings.
            assertTrue(core.observing(Slice.SLICE_CHANNELS, MobileStore.CHANNELS_SCOPE))
            assertTrue(core.observing(Slice.SLICE_CHANNEL_SETTINGS))
            store.openMore(MobileRoute.Channels)
            runCurrent()
            assertEquals(listOf(Step()), channels(core).mapNotNull { it.refresh })

            store.showFrom(MobileRoute.Channels, MobileRoute.Channel("p_pricing"))
            runCurrent()
            val opened = channels(core).drop(1)
            assertEquals(listOf("p_pricing"), opened.mapNotNull { it.select?.project_id })
            assertEquals(listOf(true), opened.mapNotNull { it.active?.on })
            assertTrue(opened.all { it.scope == MobileStore.CHANNELS_SCOPE })

            // Back to the list: the stream is no longer watched.
            store.pop()
            runCurrent()
            assertEquals(false, channels(core).mapNotNull { it.active?.on }.last())
        } finally {
            store.close()
        }
    }

    @Test
    fun aChannelMessageInATurnOpensItsChannelAboveTheConversation() = runTest {
        val core = FakeMobileCore()
        val store = store(core)
        try {
            store.selectTab(MobileTab.CHATS)
            store.openConversation("c_chat")
            store.openChannel("p_pricing")
            runCurrent()
            // Every layout has the tab it opened from, so back returns to the conversation.
            assertEquals(MobileTab.CHATS, store.routes.value.tab)
            assertEquals(
                listOf(
                    MobileRoute.Root(MobileTab.CHATS),
                    MobileRoute.Conversation("c_chat"),
                    MobileRoute.Channel("p_pricing"),
                ),
                store.routes.value.stack,
            )
            assertEquals("p_pricing", channels(core).mapNotNull { it.select }.single().project_id)
        } finally {
            store.close()
        }
    }

    @Test
    fun postsCarryTheAudienceAndHereNeverWakes() = runTest {
        val reply = ChannelsSlice(unread = 2, unread_label = "2")
        val core = FakeMobileCore { command ->
            if (command.channels != null) Result(channels = reply) else Result(done = Done())
        }
        val store = store(core)
        try {
            var posted = 0
            store.channels.post(
                "Rebase first.",
                listOf("c_one"),
                here = false,
                ChannelMessageKind.CHANNEL_MESSAGE_KIND_REQUEST,
                wake = true,
            ) {
                posted++
            }
            store.channels.post(
                "Stop pushing.",
                listOf("c_one"),
                here = true,
                ChannelMessageKind.CHANNEL_MESSAGE_KIND_NOTE,
                wake = true,
            ) {
                posted++
            }
            runCurrent()
            val posts = channels(core).mapNotNull { it.post }
            assertEquals(listOf("c_one"), posts[0].to_card_ids)
            assertTrue(posts[0].wake && !posts[0].here)
            assertTrue(posts[1].here && posts[1].to_card_ids.isEmpty() && !posts[1].wake)
            assertEquals(2, posted)
            // The command's reply is the surface after it, which feeds the tab badge.
            assertEquals("2", store.channels.slice.value.unread_label)

            store.channels.setEnabled(true)
            runCurrent()
            val setting = core.sentOf { it.channels?.set_setting }.single()
            assertEquals(ChannelSettingScope.CHANNEL_SETTING_SCOPE_GLOBAL, setting.scope)
            assertEquals(ChannelSettingMode.CHANNEL_SETTING_MODE_ON, setting.mode)
        } finally {
            store.close()
        }
    }
}

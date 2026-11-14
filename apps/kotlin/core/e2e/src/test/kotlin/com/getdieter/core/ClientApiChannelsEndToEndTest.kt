package com.getdieter.core

import com.getdieter.client.v1.ChannelAuthorKind
import com.getdieter.client.v1.ChannelMessageKind
import com.getdieter.client.v1.ChannelPin
import com.getdieter.client.v1.ChannelPost
import com.getdieter.client.v1.ChannelRef
import com.getdieter.client.v1.ChannelsCommand
import com.getdieter.client.v1.ChannelsSlice
import com.getdieter.client.v1.Command
import com.getdieter.client.v1.Slice
import com.getdieter.client.v1.Step
import com.getdieter.client.v1.Toggle
import com.getdieter.client.v1.Update
import com.getdieter.core.client.ClientApi
import com.getdieter.core.testing.EndToEnd
import com.getdieter.core.testing.await
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import kotlin.time.Duration.Companion.seconds
import kotlinx.coroutines.flow.MutableStateFlow

/**
 * Agent channels through the client contract against a real daemon: the project's channel lists
 * without any setting and its stream shows the user's posts live.
 */
class ClientApiChannelsEndToEndTest : EndToEnd() {
    @AfterTest fun tearDown() = tearDownRuntimes()

    @Test
    fun theAppListsPostsAndWatchesTheStream() = e2e {
        val fixture = fixture()
        val runtime = runtime(fixture)
        runtime.awaitConnected()
        runtime.awaitLoaded(fixture)
        val api = ClientApi(runtime)
        val scope = "channels-test"

        val channels = MutableStateFlow<ChannelsSlice?>(null)
        val channelsWatch =
            api.observe(Slice.SLICE_CHANNELS, scope) {
                channels.value = Update.ADAPTER.decode(it.encode()).channels
            }
        fun command(action: ChannelsCommand) = Command(channels = action.copy(scope = scope))

        // Every project has a channel; nothing switches it on.
        val listed =
            channels.await(30.seconds, describe = { "listed: ${channels.value}" }) { slice ->
                slice?.channels.orEmpty().any { it.project_id == fixture.projectId }
            }!!
        assertEquals("", listed.error)

        api.dispatch(command(ChannelsCommand(active = Toggle(on = true))))
        api.dispatch(command(ChannelsCommand(select = ChannelRef(fixture.projectId))))
        val opened =
            channels.await(30.seconds, describe = { "stream: ${channels.value?.stream}" }) {
                it?.stream?.loading == false && it.stream?.composer?.can_post == true
            }!!
        assertTrue(opened.stream!!.subtitle.startsWith("Shared by your machines · read from "))

        val posted =
            api.dispatch(
                    command(ChannelsCommand(post = ChannelPost(body = "  hello from the app  ")))
                )
                .channels!!
        assertTrue(posted.stream!!.rows.any { it.body == "hello from the app" })
        api.dispatch(
            command(
                ChannelsCommand(
                    post =
                        ChannelPost(
                            body = "Tier caps live next to their rules.",
                            kind = ChannelMessageKind.CHANNEL_MESSAGE_KIND_DECISION,
                        )
                )
            )
        )
        // The stream shows both posts live; the decision is pinned.
        val live =
            channels.await(30.seconds, describe = { "rows: ${channels.value?.stream?.rows}" }) {
                val rows = it?.stream?.rows.orEmpty()
                rows.size >= 2 && it!!.stream!!.pins.isNotEmpty()
            }!!
        val rows = live.stream!!.rows
        assertEquals(
            listOf("hello from the app", "Tier caps live next to their rules."),
            rows.takeLast(2).map { it.body },
        )
        assertEquals(ChannelAuthorKind.CHANNEL_AUTHOR_KIND_HUMAN, rows.last().author?.kind)
        assertEquals("You", rows.last().author?.name)
        assertEquals("DECISION", rows.last().kind_label)
        // The same author within five minutes shares one name line.
        assertTrue(rows.last().continued)
        assertEquals("Tier caps live next to their rules.", live.stream!!.pins.first().body)
        assertEquals("Pins · 1", live.stream!!.pins_tab)
        // The user's own posts are never unread.
        assertEquals(0, live.unread)

        // @here reaches every running agent; it shows as such.
        api.dispatch(
            command(ChannelsCommand(post = ChannelPost(body = "Stop pushing.", here = true)))
        )
        val here =
            channels.await(30.seconds, describe = { "here: ${channels.value?.stream?.rows}" }) {
                it?.stream?.rows.orEmpty().any { row -> row.body == "Stop pushing." }
            }!!
        val hereRow = here.stream!!.rows.first { it.body == "Stop pushing." }
        assertTrue(hereRow.here)
        assertEquals("@here", hereRow.recipients)
        api.dispatch(command(ChannelsCommand(mark_read = Step())))

        // Unpinning resends the message with its original sequence.
        api.dispatch(command(ChannelsCommand(pin = ChannelPin(rows.last().id, pinned = false))))
        channels.await(30.seconds, describe = { "pins: ${channels.value?.stream?.pins}" }) {
            it?.stream?.pins?.isEmpty() == true
        }

        channelsWatch.close()
    }
}

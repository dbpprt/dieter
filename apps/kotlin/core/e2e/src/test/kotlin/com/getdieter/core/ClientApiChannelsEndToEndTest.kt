package com.getdieter.core

import com.getdieter.client.v1.ChannelAuthorKind
import com.getdieter.client.v1.ChannelMessageKind
import com.getdieter.client.v1.ChannelPin
import com.getdieter.client.v1.ChannelPost
import com.getdieter.client.v1.ChannelRef
import com.getdieter.client.v1.ChannelSettingChange
import com.getdieter.client.v1.ChannelSettingMode
import com.getdieter.client.v1.ChannelSettingScope
import com.getdieter.client.v1.ChannelSettingsSlice
import com.getdieter.client.v1.ChannelsCommand
import com.getdieter.client.v1.ChannelsSlice
import com.getdieter.client.v1.Command
import com.getdieter.client.v1.Slice
import com.getdieter.client.v1.Step
import com.getdieter.client.v1.Toggle
import com.getdieter.client.v1.Update
import com.getdieter.core.channels.ChannelsView
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
 * Agent channels through the client contract against a real daemon: the account-wide switch
 * replicates back through the KV, the project's channel lists, its stream shows the user's posts
 * live, and a project override turns it off again.
 */
class ClientApiChannelsEndToEndTest : EndToEnd() {
    @AfterTest fun tearDown() = tearDownRuntimes()

    @Test
    fun theAppTurnsChannelsOnPostsAndWatchesTheStream() = e2e {
        val fixture = fixture()
        val runtime = runtime(fixture)
        runtime.awaitConnected()
        runtime.awaitLoaded(fixture)
        val api = ClientApi(runtime)
        val scope = "channels-test"

        val settings = MutableStateFlow<ChannelSettingsSlice?>(null)
        val channels = MutableStateFlow<ChannelsSlice?>(null)
        val settingsWatch =
            api.observe(Slice.SLICE_CHANNEL_SETTINGS, "") {
                settings.value = Update.ADAPTER.decode(it.encode()).channel_settings
            }
        val channelsWatch =
            api.observe(Slice.SLICE_CHANNELS, scope) {
                channels.value = Update.ADAPTER.decode(it.encode()).channels
            }
        fun command(action: ChannelsCommand) = Command(channels = action.copy(scope = scope))

        // Off everywhere: nothing is listed and the list says how to turn it on.
        channels.await(20.seconds, describe = { "off: ${channels.value}" }) {
            it?.empty_title == ChannelsView.OFF_TITLE
        }
        assertEquals(false, settings.value?.global)

        api.dispatch(
            Command(
                channels =
                    ChannelsCommand(
                        set_setting =
                            ChannelSettingChange(
                                scope = ChannelSettingScope.CHANNEL_SETTING_SCOPE_GLOBAL,
                                mode = ChannelSettingMode.CHANNEL_SETTING_MODE_ON,
                            )
                    )
            )
        )
        // The machine's KV replicates the switch back to the account view.
        settings.await(30.seconds, describe = { "settings: ${settings.value}" }) {
            it?.global == true &&
                !it.saving &&
                it.projects.any { row -> row.id == fixture.projectId && row.effective }
        }
        val listed =
            channels.await(30.seconds, describe = { "listed: ${channels.value}" }) { slice ->
                slice?.machines.orEmpty().any { machine ->
                    machine.daemon_id == fixture.daemonId &&
                        machine.channels.any { it.project_id == fixture.projectId && it.enabled }
                }
            }!!
        assertTrue(listed.enabled)

        api.dispatch(command(ChannelsCommand(active = Toggle(on = true))))
        api.dispatch(
            command(ChannelsCommand(select = ChannelRef(fixture.daemonId, fixture.projectId)))
        )
        channels.await(30.seconds, describe = { "stream: ${channels.value?.stream}" }) {
            it?.stream?.loading == false && it.stream?.composer?.can_post == true
        }

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
        api.dispatch(command(ChannelsCommand(mark_read = Step())))

        // Unpinning resends the message with its original sequence.
        api.dispatch(command(ChannelsCommand(pin = ChannelPin(rows.last().id, pinned = false))))
        channels.await(30.seconds, describe = { "pins: ${channels.value?.stream?.pins}" }) {
            it?.stream?.pins?.isEmpty() == true
        }

        // A project override turns the project's channel off; the stream refuses posts.
        api.dispatch(
            Command(
                channels =
                    ChannelsCommand(
                        set_setting =
                            ChannelSettingChange(
                                scope = ChannelSettingScope.CHANNEL_SETTING_SCOPE_PROJECT,
                                id = fixture.projectId,
                                mode = ChannelSettingMode.CHANNEL_SETTING_MODE_OFF,
                            )
                    )
            )
        )
        settings.await(30.seconds, describe = { "override: ${settings.value}" }) { slice ->
            slice?.projects.orEmpty().any {
                it.id == fixture.projectId && it.label == "Off" && !it.effective
            }
        }
        channels.await(30.seconds, describe = { "off stream: ${channels.value?.stream}" }) {
            it?.stream?.enabled == false && it.stream?.composer?.can_post == false
        }
        val refused = runCatching {
            api.dispatch(command(ChannelsCommand(post = ChannelPost(body = "anyone?"))))
        }
            .exceptionOrNull()
        assertTrue(refused != null, "a post to a channel that is off fails")

        channelsWatch.close()
        settingsWatch.close()
    }
}

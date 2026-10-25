package com.getdieter.core.channels

import com.getdieter.api.v1.ChannelAuthor
import com.getdieter.api.v1.ChannelClaim
import com.getdieter.api.v1.ChannelFrame
import com.getdieter.api.v1.ChannelMember
import com.getdieter.api.v1.ChannelMessage
import com.getdieter.api.v1.ChannelSummary
import com.getdieter.client.v1.ChannelPost
import com.getdieter.core.runtime.CoreException
import com.getdieter.core.runtime.CoreLogger
import com.getdieter.core.testing.offlineSessions
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlin.time.Instant
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.runTest

class ChannelsTest {
    private val now = Instant.parse("2026-10-24T11:10:00Z")
    private val key = ChannelKey("d1", "p1")

    private fun slice(channels: Channels, switches: ChannelSwitches, reachable: Boolean = true) =
        channels.view.value.slice(
            switches,
            { if (it == "d1") "mbp-office" else it },
            { reachable },
            now,
        )

    private fun summary(unread: Int = 1, seen: Long = 1) =
        ChannelSummary(
            project_id = "p1",
            project_name = "pricing",
            enabled = true,
            last_seq = 2,
            seen_seq = seen,
            unread = unread,
            claims = 1,
            members =
                listOf(
                    ChannelMember(
                        card_id = "c1",
                        title = "Review headers",
                        status = "running",
                        enabled = true,
                    )
                ),
        )

    private fun message(seq: Long, kind: String = "agent") =
        ChannelMessage(
            id = "m$seq",
            project_id = "p1",
            seq = seq,
            kind = "note",
            author = ChannelAuthor(kind = kind, card_id = "c1", title = "Review headers"),
            body = "hello $seq",
            created_at = "2026-10-24T11:0$seq:00Z",
        )

    @Test
    fun nothingIsListedWhileEverySettingIsOff() = runTest {
        val settings = MutableStateFlow(ChannelSettingsView())
        val channels =
            Channels(
                offlineSessions(),
                { listOf("d1") },
                settings,
                backgroundScope,
                object : CoreLogger {},
            )
        channels.refresh()
        val off = slice(channels, settings.value.switches)
        assertFalse(off.enabled)
        assertEquals(ChannelsView.OFF_TITLE, off.empty_title)
        assertTrue(off.channels.isEmpty())

        // On, but the only machine cannot be reached: the list says why.
        settings.value = ChannelSettingsView(ChannelSwitches(global = true))
        channels.refresh()
        val failed = slice(channels, settings.value.switches)
        assertTrue(failed.enabled)
        assertTrue(failed.error.startsWith("mbp-office: "))
        assertEquals(ChannelsView.FAILED_TITLE, failed.empty_title)
        assertEquals(failed.error, failed.empty_detail)

        channels.stop()
        val none =
            Channels(
                offlineSessions(),
                { emptyList() },
                settings,
                backgroundScope,
                object : CoreLogger {},
            )
        none.refresh()
        assertEquals(
            ChannelsView.UNREACHABLE_TITLE,
            slice(none, settings.value.switches).empty_title,
        )
    }

    @Test
    fun aProjectHasOneChannelReadFromTheFirstMachineThatListsIt() = runTest {
        val settings = MutableStateFlow(ChannelSettingsView(ChannelSwitches(global = true)))
        val channels =
            Channels(
                offlineSessions(),
                { emptyList() },
                settings,
                backgroundScope,
                object : CoreLogger {},
            )
        val other = summary(unread = 0).copy(project_id = "p2", project_name = "checkout")
        // Every machine lists the account's channels; d1 is this device's.
        channels.applyListing(
            listOf(
                "d1" to Channels.Listing.Listed(listOf(summary(unread = 3))),
                "d2" to Channels.Listing.Listed(listOf(summary(unread = 5), other)),
            )
        )
        val listed = slice(channels, settings.value.switches)
        assertEquals(listOf("p2", "p1"), listed.channels.map { it.project_id })
        // The unread count is the serving machine's.
        assertEquals(3, listed.unread)
        assertEquals("", listed.error)

        channels.select("p1")
        assertEquals(ChannelKey("d1", "p1"), channels.view.value.streamKey)
        channels.select("p2")
        assertEquals(ChannelKey("d2", "p2"), channels.view.value.streamKey)

        // When this device's machine fails, the channel is read from the next one, afresh.
        channels.select("p1")
        channels.receive(key, ChannelFrame(messages = listOf(message(1)), reset = true))
        assertEquals(1, channels.view.value.stream.messages.size)
        channels.applyListing(
            listOf(
                "d1" to Channels.Listing.Failed("offline"),
                "d2" to Channels.Listing.Listed(listOf(summary(unread = 5), other)),
            )
        )
        assertEquals(ChannelKey("d2", "p1"), channels.view.value.streamKey)
        assertTrue(channels.view.value.stream.messages.isEmpty())
        val moved = slice(channels, settings.value.switches)
        assertEquals("Shared by your machines · read from d2", moved.stream!!.subtitle)
        assertEquals(5, moved.unread)
        // One machine failing while another serves is no error.
        assertEquals("", moved.error)
    }

    @Test
    fun theSelectedChannelFoldsItsStreamIntoTheSlice() = runTest {
        val settings = MutableStateFlow(ChannelSettingsView(ChannelSwitches(global = true)))
        val channels =
            Channels(
                offlineSessions(),
                { emptyList() },
                settings,
                backgroundScope,
                object : CoreLogger {},
            )
        channels.select("p1")
        assertEquals("p1", channels.view.value.selected)
        val loading = slice(channels, settings.value.switches).stream!!
        assertTrue(loading.loading)
        assertEquals("#p1", loading.title)
        assertEquals(ChannelsView.SHARED, loading.subtitle)
        assertFalse(loading.composer!!.can_post)
        assertFailsWith<CoreException> { channels.post(ChannelPost(body = "hi")) }

        channels.applyListing(listOf("d1" to Channels.Listing.Listed(listOf(summary()))))
        channels.receive(
            key,
            ChannelFrame(
                messages = listOf(message(1), message(2)),
                summary = summary(),
                claims =
                    listOf(
                        ChannelClaim(
                            project_id = "p1",
                            path = "a.ts",
                            card_id = "c1",
                            card_title = "Review headers",
                            since = "2026-10-24T11:08:00Z",
                        )
                    ),
                last_seq = 2,
                reset = true,
            ),
        )
        // A frame from a machine the channel is not read from is dropped.
        channels.receive(
            ChannelKey("d2", "p1"),
            ChannelFrame(messages = listOf(message(3)), reset = true),
        )

        val stream = slice(channels, settings.value.switches).stream!!
        assertFalse(stream.loading)
        assertEquals("#pricing", stream.title)
        assertEquals("Shared by your machines · read from mbp-office", stream.subtitle)
        assertEquals(listOf("m1", "m2"), stream.rows.map { it.id })
        // The first unread message starts its own group, under the "New" divider.
        assertEquals(listOf(false, false), stream.rows.map { it.continued })
        assertEquals("m2", stream.first_unread_row_id)
        assertEquals("1 live claim", stream.claims_summary)
        assertEquals("held 2m", stream.claims.single().held_label)
        assertEquals("Claims · 1", stream.claims_tab)
        assertEquals("Agents · 1", stream.members_tab)
        assertEquals("Pins", stream.pins_tab)
        assertTrue(stream.composer!!.can_post)
        assertEquals("Message #pricing", stream.composer!!.placeholder)

        // Reading needs the machine; without it the view still drops the badge until it answers.
        channels.markRead()
        val read = slice(channels, settings.value.switches).stream!!
        assertEquals(0, read.unread)
        assertEquals("", read.first_unread_row_id)

        // Commands go to the serving machine; offline, they fail and say so.
        assertFailsWith<Throwable> { channels.post(ChannelPost(body = "hi")) }
        assertTrue(channels.view.value.actionError!!.isNotEmpty())
        assertFalse(channels.view.value.sending)
        assertFailsWith<CoreException> { channels.post(ChannelPost(body = "   ")) }
        assertFailsWith<CoreException> {
            channels.post(ChannelPost(body = "stop", here = true, to_card_ids = listOf("c1")))
        }

        channels.select(null)
        assertNull(slice(channels, settings.value.switches).stream)
    }
}

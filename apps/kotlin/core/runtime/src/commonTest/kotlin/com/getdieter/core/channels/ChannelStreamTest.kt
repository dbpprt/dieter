package com.getdieter.core.channels

import com.getdieter.api.v1.ChannelAuthor
import com.getdieter.api.v1.ChannelClaim
import com.getdieter.api.v1.ChannelFrame
import com.getdieter.api.v1.ChannelMessage
import com.getdieter.api.v1.ChannelSummary
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class ChannelStreamTest {
    private fun message(
        seq: Long,
        body: String = "m$seq",
        pinned: Boolean = false,
        kind: String = "agent",
    ) =
        ChannelMessage(
            id = "m$seq",
            project_id = "p",
            seq = seq,
            kind = "note",
            author = ChannelAuthor(kind = kind, card_id = "c1", title = "Refactor"),
            body = body,
            pinned = pinned,
            created_at = "2026-10-24T10:00:0${seq % 10}Z",
        )

    private fun claim(path: String, card: String = "c1") =
        ChannelClaim(project_id = "p", path = path, card_id = card, card_title = "Refactor")

    @Test
    fun theFirstFrameLoadsAndLaterFramesAddAndReplaceMessagesById() {
        var state =
            ChannelStreamState()
                .apply(
                    ChannelFrame(
                        messages = listOf(message(1), message(2)),
                        summary = ChannelSummary(project_id = "p", last_seq = 2, unread = 2),
                        claims = listOf(claim("a.ts")),
                        last_seq = 2,
                        reset = true,
                    )
                )
        assertTrue(state.loaded)
        assertEquals(listOf("m1", "m2"), state.messages.map { it.id })
        assertEquals(1, state.claims.size)

        // A new message and a changed one (pinned), resent with its original sequence.
        state =
            state.apply(
                ChannelFrame(messages = listOf(message(3), message(1, pinned = true)), last_seq = 3)
            )
        assertEquals(listOf("m1", "m2", "m3"), state.messages.map { it.id })
        assertTrue(state.messages.first().pinned)
        // Claims and the summary stay when a frame leaves them out.
        assertEquals(1, state.claims.size)
        assertEquals(2, state.summary?.unread)
        assertEquals(3, state.lastSeq)
        assertEquals(3, state.newestSeq)
    }

    @Test
    fun aReconnectsResetKeepsOlderMessagesAndReplacesTheNewestPage() {
        val state =
            ChannelStreamState()
                .apply(
                    ChannelFrame(messages = (1L..4).map { message(it) }, reset = true, last_seq = 4)
                )
                .apply(
                    ChannelFrame(
                        messages = listOf(message(3, "edited"), message(4), message(5)),
                        reset = true,
                        last_seq = 5,
                    )
                )
        assertEquals(listOf("m1", "m2", "m3", "m4", "m5"), state.messages.map { it.id })
        assertEquals("edited", state.messages[2].body)
        // An empty reset page means the channel has no messages.
        assertTrue(state.apply(ChannelFrame(reset = true)).messages.isEmpty())
    }

    @Test
    fun claimsClearWhenTheSummaryCountsNoneAndHeartbeatsOnlyAdvanceTheSequence() {
        val loaded =
            ChannelStreamState()
                .apply(ChannelFrame(claims = listOf(claim("a.ts")), reset = true, last_seq = 1))
        val beat = loaded.apply(ChannelFrame(heartbeat = true, last_seq = 9))
        assertEquals(9, beat.lastSeq)
        assertEquals(loaded.claims, beat.claims)
        // The daemon sends no claim list once none are left; the summary says so.
        val released =
            beat.apply(ChannelFrame(summary = ChannelSummary(project_id = "p", claims = 0)))
        assertTrue(released.claims.isEmpty())
        val stillHeld =
            beat.apply(ChannelFrame(summary = ChannelSummary(project_id = "p", claims = 1)))
        assertEquals(1, stillHeld.claims.size)
    }

    @Test
    fun theWindowKeepsTheNewestMessages() {
        val many = (1L..(ChannelStreamState.WINDOW + 20)).map { message(it) }
        val state = ChannelStreamState().apply(ChannelFrame(messages = many, reset = true))
        assertEquals(ChannelStreamState.WINDOW, state.messages.size)
        assertEquals(21, state.messages.first().seq)
    }

    @Test
    fun readingAndReleasingUpdateTheStreamAtOnce() {
        val state =
            ChannelStreamState()
                .apply(
                    ChannelFrame(
                        messages = listOf(message(1), message(2), message(3, kind = "human")),
                        summary =
                            ChannelSummary(
                                project_id = "p",
                                seen_seq = 0,
                                unread = 2,
                                last_seq = 3,
                            ),
                        claims = listOf(claim("a.ts"), claim("b.ts", "c2")),
                        reset = true,
                    )
                )
        val read = state.read(1)
        assertEquals(1, read.summary?.seen_seq)
        // The user's own message never counts as unread.
        assertEquals(1, read.summary?.unread)
        assertEquals(read, read.read(1))
        val released = state.without(listOf(claim("a.ts")))
        assertEquals(listOf("b.ts"), released.claims.map { it.path })
        assertEquals(mapOf("c1" to "Refactor", "c2" to "Refactor"), state.titles)
        assertFalse(state.upsert(message(4)).messages.none { it.id == "m4" })
    }
}

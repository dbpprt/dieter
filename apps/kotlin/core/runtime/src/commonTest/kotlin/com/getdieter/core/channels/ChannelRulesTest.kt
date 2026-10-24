package com.getdieter.core.channels

import com.getdieter.api.v1.ChannelAuthor
import com.getdieter.api.v1.ChannelClaim
import com.getdieter.api.v1.ChannelDelivery
import com.getdieter.api.v1.ChannelMember
import com.getdieter.api.v1.ChannelMessage
import com.getdieter.api.v1.ChannelSummary
import com.getdieter.client.v1.ChannelAuthorKind
import com.getdieter.client.v1.ChannelMessageKind
import com.getdieter.client.v1.ChannelPresence
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlin.time.Instant

class ChannelRulesTest {
    private val agentA =
        ChannelAuthor(
            kind = "agent",
            card_id = "c1",
            title = "Review headers",
            harness = "codex",
            model = "gpt-5",
        )
    private val agentB = ChannelAuthor(kind = "agent", card_id = "c2", title = "Add MAX_TIER_3")
    private val human = ChannelAuthor(kind = "human", device_id = "d1")
    private val dieter = ChannelAuthor(kind = "dieter")
    private val titles =
        mapOf("c1" to "Review headers", "c2" to "Add MAX_TIER_3", "c3" to "Fix checkout tests")

    private fun message(
        seq: Long,
        author: ChannelAuthor,
        at: String,
        kind: String = "note",
        body: String = "body $seq",
        to: List<String> = emptyList(),
        files: List<String> = emptyList(),
        deliveries: List<ChannelDelivery> = emptyList(),
    ) =
        ChannelMessage(
            id = "m$seq",
            project_id = "p",
            seq = seq,
            kind = kind,
            author = author,
            body = body,
            to_card_ids = to,
            files = files,
            created_at = at,
            deliveries = deliveries,
        )

    @Test
    fun oneAuthorsMessagesWithinFiveMinutesShareANameLine() {
        val messages =
            listOf(
                message(1, agentA, "2026-10-24T11:00:00Z"),
                message(2, agentA, "2026-10-24T11:04:59Z"),
                message(3, agentA, "2026-10-24T11:10:00Z"),
                message(4, agentB, "2026-10-24T11:10:30Z"),
                message(5, dieter, "2026-10-24T11:10:40Z", kind = "hold", to = listOf("c2")),
                message(6, agentB, "2026-10-24T11:10:50Z"),
                message(7, human, "2026-10-24T11:11:00Z"),
                message(8, human, "2026-10-24T11:12:00Z"),
            )
        val rows = ChannelRules.rows(messages, seenSeq = 8, titles = titles)
        assertEquals(
            listOf(false, true, false, false, false, false, false, true),
            rows.rows.map { it.continued },
        )
        assertEquals(
            listOf(false, false, false, false, true, false, false, false),
            rows.rows.map { it.event },
        )
        assertNull(rows.firstUnreadId)
        assertEquals("You", rows.rows[6].author?.name)
        assertEquals(ChannelAuthorKind.CHANNEL_AUTHOR_KIND_HUMAN, rows.rows[6].author?.kind)
        assertEquals("codex · gpt-5", rows.rows[0].meta)
        assertEquals("RH", rows.rows[0].author?.initials)
    }

    @Test
    fun theFirstUnreadMessageStartsANewGroup() {
        val messages =
            listOf(
                message(1, agentA, "2026-10-24T11:00:00Z"),
                message(2, human, "2026-10-24T11:00:10Z"),
                message(3, agentA, "2026-10-24T11:00:20Z"),
                message(4, agentA, "2026-10-24T11:00:30Z"),
            )
        // The user's own message after the read position is not unread.
        val rows = ChannelRules.rows(messages, seenSeq = 1, titles = titles)
        assertEquals("m3", rows.firstUnreadId)
        assertEquals(listOf(false, false, false, true), rows.rows.map { it.continued })
    }

    @Test
    fun coordinationEventsReadAsOneLine() {
        val hold =
            message(
                1,
                dieter,
                "2026-10-24T11:00:00Z",
                kind = "hold",
                to = listOf("c2"),
                files = listOf("src/module3.js"),
                body =
                    "You just changed src/module3.js, which agent c1 ('Review headers') has been changing for 2 min.",
            )
        val request =
            message(
                2,
                dieter,
                "2026-10-24T11:00:00Z",
                kind = "request",
                to = listOf("c1"),
                files = listOf("src/module3.js"),
                body =
                    "Agent c2 ('Add MAX_TIER_3') wants to change src/module3.js, which you are changing.",
            )
        val release =
            message(
                3,
                dieter,
                "2026-10-24T11:00:00Z",
                kind = "release",
                to = listOf("c2"),
                files = listOf("a.js", "b.js"),
                body = "a.js, b.js is free now: agent c1 ('Review headers') finished.",
            )
        assertEquals(
            "Add MAX_TIER_3 changed src/module3.js, held by Review headers",
            ChannelRules.eventText(hold, titles),
        )
        assertEquals(
            "Add MAX_TIER_3 is waiting for src/module3.js from Review headers",
            ChannelRules.eventText(request, titles),
        )
        assertEquals(
            "Review headers released 2 files for Add MAX_TIER_3",
            ChannelRules.eventText(release, titles),
        )
        val row = ChannelRules.rows(listOf(release), 0, titles).rows.single()
        assertTrue(row.event)
        assertEquals("", row.kind_label)
        assertEquals("", row.recipients)
        assertEquals(ChannelMessageKind.CHANNEL_MESSAGE_KIND_RELEASE, row.kind)
    }

    @Test
    fun receiptsSayHowEachRecipientWasReached() {
        val delivered =
            message(
                1,
                human,
                "2026-10-24T11:00:00Z",
                kind = "request",
                to = listOf("c1", "c2"),
                deliveries =
                    listOf(
                        ChannelDelivery("c1", "pending", ""),
                        ChannelDelivery("c2", "digest", ""),
                        ChannelDelivery("c1", "steered", ""),
                    ),
            )
        assertEquals(
            "Add MAX_TIER_3: in next turn · Review headers: steered into turn",
            ChannelRules.receipt(delivered, titles),
        )
        assertEquals(
            "to Review headers, Add MAX_TIER_3",
            ChannelRules.recipients(delivered, titles),
        )
        val many = delivered.copy(deliveries = (1..5).map { ChannelDelivery("x$it", "woke", "") })
        assertEquals(
            "x1: woke idle agent · x2: woke idle agent · x3: woke idle agent · +2 more",
            ChannelRules.receipt(many, titles),
        )
        val row = ChannelRules.rows(listOf(delivered), 0, titles).rows.single()
        assertEquals("REQUEST", row.kind_label)
        assertTrue(row.direct)
        assertEquals("you", row.meta)
    }

    @Test
    fun avatarsMembersAndClaims() {
        assertEquals("AM", ChannelRules.initials("Add MAX_TIER_3"))
        assertEquals("RE", ChannelRules.initials("refactor"))
        assertEquals("?", ChannelRules.initials("  "))
        assertEquals(ChannelRules.colorIndex("c_42"), ChannelRules.colorIndex("c_42"))
        assertTrue(ChannelRules.colorIndex("c_42") in 0 until ChannelRules.COLORS)

        val members =
            ChannelRules.members(
                listOf(
                    ChannelMember(card_id = "c3", title = "Fix checkout tests", status = "idle"),
                    ChannelMember(
                        card_id = "c2",
                        title = "Add MAX_TIER_3",
                        status = "waiting",
                        waiting_on = listOf("src/module3.js"),
                    ),
                    ChannelMember(
                        card_id = "c1",
                        title = "Review headers",
                        status = "running",
                        harness = "codex",
                        model = "gpt-5",
                        holds = listOf("a", "b"),
                    ),
                )
            )
        assertEquals(listOf("c1", "c2", "c3"), members.map { it.card_id })
        assertEquals(
            listOf("Running", "Waiting on src/module3.js", "Idle"),
            members.map { it.presence_label },
        )
        assertEquals("codex · gpt-5 · holds 2 files", members[0].detail)
        assertEquals(ChannelPresence.CHANNEL_PRESENCE_WAITING, members[1].presence)

        val now = Instant.parse("2026-10-24T11:10:00Z")
        val claims =
            ChannelRules.claims(
                listOf(
                    ChannelClaim(
                        path = "b.ts",
                        card_id = "c1",
                        card_title = "Review headers",
                        since = "2026-10-24T11:09:30Z",
                    ),
                    ChannelClaim(
                        path = "a.ts",
                        card_id = "c1",
                        card_title = "Review headers",
                        since = "2026-10-24T11:02:00Z",
                        waiting_card_ids = listOf("c2"),
                    ),
                ),
                titles,
                now,
            )
        assertEquals(listOf("a.ts", "b.ts"), claims.map { it.path })
        assertEquals(listOf("held 8m", "held <1m"), claims.map { it.held_label })
        assertEquals("Add MAX_TIER_3 waiting", claims[0].waiting_label)
        assertEquals(
            "2 live claims · 1 waiting",
            ChannelRules.claimsSummary(
                listOf(
                    ChannelClaim(path = "a", waiting_card_ids = listOf("c2")),
                    ChannelClaim(path = "b"),
                )
            ),
        )
        assertEquals("Claims · 2", ChannelRules.tab("Claims", 2))
        assertEquals("Pins", ChannelRules.tab("Pins", 0))
    }

    @Test
    fun listsTheComposerAndBodies() {
        val summary =
            ChannelSummary(
                project_id = "p",
                project_name = "pricing",
                enabled = true,
                unread = 3,
                claims = 2,
                members =
                    listOf(
                        ChannelMember(card_id = "c1", status = "running", enabled = true),
                        ChannelMember(card_id = "c2", status = "idle", enabled = false),
                    ),
            )
        val row = ChannelRules.listRow("d1", summary, selected = true)
        assertEquals("d1/p", row.id)
        assertEquals("2 agents · 1 running · 2 claims", row.detail)
        assertEquals(3, row.unread)
        assertEquals("Off", ChannelRules.listDetail(summary.copy(enabled = false)))
        assertEquals(0, ChannelRules.listRow("d1", summary.copy(enabled = false), false).unread)
        assertEquals("", ChannelRules.unreadLabel(0))
        assertEquals("99+", ChannelRules.unreadLabel(120))

        val composer = ChannelRules.composer("pricing", true, true, "mbp", summary.members, false)
        assertTrue(composer.can_post)
        assertEquals("Message #pricing", composer.placeholder)
        assertEquals(listOf("c1"), composer.recipients.map { it.card_id })
        assertEquals(4, composer.kinds.size)
        val off = ChannelRules.composer("pricing", false, true, "mbp", summary.members, false)
        assertFalse(off.can_post)
        assertEquals(
            "mbp is not reachable.",
            ChannelRules.composer("pricing", true, false, "mbp", emptyList(), false)
                .disabled_reason,
        )

        assertEquals("Write a message first.", ChannelRules.bodyProblem("  "))
        assertNull(ChannelRules.bodyProblem("hi"))
        assertEquals(
            "A message is at most 4096 bytes.",
            ChannelRules.bodyProblem("é".repeat(2049)),
        )
        assertEquals(
            "decision",
            ChannelRules.kindName(ChannelMessageKind.CHANNEL_MESSAGE_KIND_DECISION),
        )
        assertEquals(ChannelMessageKind.CHANNEL_MESSAGE_KIND_NOTE, ChannelRules.kind("something"))
    }
}

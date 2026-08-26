package com.dbpprt.dieter.ui

import java.time.Instant
import java.time.ZoneId
import org.junit.Assert.assertEquals
import org.junit.Test

class TimestampFormattingTest {
    private val now = Instant.parse("2026-08-14T12:00:00Z")
    private val utc = ZoneId.of("UTC")

    @Test
    fun formatsRecentCommentsAsCompactRelativeAge() {
        assertEquals("now", shortTimestamp("2026-08-14T11:59:30Z", now, utc))
        assertEquals("5m", shortTimestamp("2026-08-14T11:55:00Z", now, utc))
        assertEquals("59m", shortTimestamp("2026-08-14T11:00:01Z", now, utc))
        assertEquals("1h", shortTimestamp("2026-08-14T11:00:00Z", now, utc))
        assertEquals("23h", shortTimestamp("2026-08-13T12:00:01Z", now, utc))
    }

    @Test
    fun formatsOlderCommentsAsShortDate() {
        assertEquals("Aug 13", shortTimestamp("2026-08-13T12:00:00Z", now, utc))
    }

    @Test
    fun formatsLatestCardModificationOrChatActivityAsRelativeAge() {
        assertEquals(
            "10min",
            boardCardActivityText("2026-08-14T11:50:00Z", "2026-08-14T10:00:00Z", now),
        )
        assertEquals(
            "2h",
            boardCardActivityText("2026-08-09T12:00:00Z", "2026-08-14T10:00:00Z", now),
        )
        assertEquals("5d", boardCardActivityText("2026-08-09T12:00:00Z", "", now))
        assertEquals("", boardCardActivityText("", "not-a-timestamp", now))
    }

    @Test
    fun formatsConversationRefreshStatusWhileKeepingCachedDataVisible() {
        val nowMillis = now.toEpochMilli()
        assertEquals("Refreshing…", conversationRefreshLabel(null, syncing = true, nowMillis = nowMillis))
        assertEquals(
            "Last refreshed just now · Refreshing…",
            conversationRefreshLabel(nowMillis - 20_000L, syncing = true, nowMillis = nowMillis),
        )
        assertEquals(
            "Last refreshed 5m ago",
            conversationRefreshLabel(nowMillis - 300_000L, syncing = false, nowMillis = nowMillis),
        )
    }
}

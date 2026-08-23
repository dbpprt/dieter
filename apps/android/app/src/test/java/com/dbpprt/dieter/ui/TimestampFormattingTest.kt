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
}

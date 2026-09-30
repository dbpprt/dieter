package com.dbpprt.dieter.core.presentation

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.time.Duration.Companion.days
import kotlin.time.Duration.Companion.hours
import kotlin.time.Duration.Companion.minutes
import kotlin.time.Duration.Companion.seconds
import kotlin.time.Instant

class AgesTest {
    private val now = Instant.parse("2026-08-14T12:00:00Z")
    private val day: (Instant) -> String = { "day ${it.toString().take(10)}" }
    private val dateTime: (Instant) -> String = { "at $it" }

    @Test fun compactAgesStayShort() {
        assertNull(Ages.compact(null, now))
        assertEquals("now", Ages.compact(now - 20.seconds, now))
        assertEquals("now", Ages.compact(now + 20.seconds, now))
        assertEquals("2m", Ages.compact(now - 2.minutes, now))
        assertEquals("2h", Ages.compact(now - 2.hours, now))
        assertEquals("3d", Ages.compact(now - 3.days, now))
    }

    @Test fun shortTimestampsAreRelativeForADayThenAbsolute() {
        fun short(value: String) = Ages.short(value, now, day, dateTime)
        assertEquals("now", short("2026-08-14T11:59:30Z"))
        assertEquals("5m", short("2026-08-14T11:55:00Z"))
        assertEquals("59m", short("2026-08-14T11:00:01Z"))
        assertEquals("1h", short("2026-08-14T11:00:00Z"))
        assertEquals("23h", short("2026-08-13T12:00:01Z"))
        assertEquals("day 2026-08-13", short("2026-08-13T12:00:00Z"))
        assertEquals("in <1m", short("2026-08-14T12:00:30Z"))
        assertEquals("in 5m", short("2026-08-14T12:05:00Z"))
        assertEquals("in 3h", short("2026-08-14T15:00:00Z"))
        assertEquals("at 2026-08-16T12:00:00Z", short("2026-08-16T12:00:00Z"))
        assertEquals("", short(" "))
        assertEquals("08-14", short("2026-08-14Tgarbage"))
    }

    @Test fun refreshLabelsKeepCachedDataVisible() {
        assertEquals("Refreshing…", Ages.refreshed(null, syncing = true, now, dateTime))
        assertEquals("Not refreshed yet", Ages.refreshed(null, syncing = false, now, dateTime))
        assertEquals("Last refreshed just now · Refreshing…", Ages.refreshed(now - 20.seconds, syncing = true, now, dateTime))
        assertEquals("Last refreshed 5m ago", Ages.refreshed(now - 5.minutes, syncing = false, now, dateTime))
        assertEquals("Last refreshed 2h ago", Ages.refreshed(now - 2.hours, syncing = false, now, dateTime))
        assertEquals("Last refreshed at 2026-08-12T12:00:00Z", Ages.refreshed(now - 2.days, syncing = false, now, dateTime))
    }

    @Test fun projectPathsShortenUnderDevelopment() {
        assertEquals("~/Development/dieter", DisplayPaths.compact("/Users/me/Development/dieter"))
        assertEquals("/srv/dieter", DisplayPaths.compact("/srv/dieter"))
        assertEquals("", DisplayPaths.compact(""))
    }
}

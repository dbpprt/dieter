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

    @Test fun spansCountWholeUnitsFromAMinute() {
        assertNull(Ages.span(59.seconds))
        assertNull(Ages.span((-5).minutes), "clock skew reads as under a minute")
        assertEquals(AgeSpan(1, AgeUnit.MINUTES), Ages.span(60.seconds))
        assertEquals("59m", Ages.span(3_599.seconds)?.compact)
        assertEquals("1h", Ages.span(1.hours)?.compact)
        assertEquals("23h", Ages.span(1.days - 1.seconds)?.compact)
        assertEquals("1d", Ages.span(1.days)?.compact)
        assertEquals("9d", Ages.span(9.days)?.compact, "without weeks, days keep counting")
        assertEquals("6d", Ages.span(7.days - 1.seconds, weeks = true)?.compact)
        assertEquals(AgeSpan(1, AgeUnit.WEEKS), Ages.span(13.days, weeks = true))
        assertEquals("2w", Ages.span(14.days, weeks = true)?.compact)
    }

    @Test fun compactAgesStayShort() {
        assertNull(Ages.compact(null, now))
        assertEquals("now", Ages.compact(now - 20.seconds, now))
        assertEquals("now", Ages.compact(now + 20.seconds, now))
        assertEquals("2m", Ages.compact(now - 2.minutes, now))
        assertEquals("2h", Ages.compact(now - 2.hours, now))
        assertEquals("3d", Ages.compact(now - 3.days, now))
        assertEquals("20d", Ages.compact(now - 20.days, now), "without weeks, days keep counting")
    }

    @Test fun chatAgesCountWeeksFromSevenDays() {
        assertEquals("now", Ages.compact(now - 25.seconds, now, weeks = true))
        assertEquals("now", Ages.compact(now + 5.minutes, now, weeks = true), "clock skew reads as now")
        assertEquals("5m", Ages.compact(now - 5.minutes, now, weeks = true))
        assertEquals("2h", Ages.compact(now - 2.hours, now, weeks = true))
        assertEquals("6d", Ages.compact(now - 6.days, now, weeks = true))
        assertEquals("3w", Ages.compact(now - 21.days, now, weeks = true))
    }

    @Test fun agoCountsWholeMinutesHoursAndDays() {
        assertEquals("just now", Ages.ago(now - 41.seconds, now), "seconds are not counted")
        assertEquals("just now", Ages.ago(now + 30.seconds, now), "the future reads as just now")
        assertEquals("2m ago", Ages.ago(now - 150.seconds, now))
        assertEquals("2h ago", Ages.ago(now - 7_200.seconds, now))
        assertEquals("3d ago", Ages.ago(now - 3.days, now))
        assertEquals("45d ago", Ages.ago(now - 45.days, now), "days keep counting")
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

    @Test fun pathsUnderAnyUsersHomeShortenToATilde() {
        assertEquals("~/Development/dieter", DisplayPaths.compact("/Users/me/Development/dieter"))
        assertEquals("~/Development/dieter", DisplayPaths.compact("/Users/office/Development/dieter"), "another machine's user")
        assertEquals("~/src/dieter", DisplayPaths.compact("/home/dennis/src/dieter"))
        assertEquals("~", DisplayPaths.compact("/Users/me"))
        assertEquals("/Users/Shared/dieter", DisplayPaths.compact("/Users/Shared/dieter"))
        assertEquals("/srv/Development/dieter", DisplayPaths.compact("/srv/Development/dieter"))
        assertEquals("/srv/dieter", DisplayPaths.compact("/srv/dieter"))
        assertEquals("relative/Users/me", DisplayPaths.compact("relative/Users/me"))
        assertEquals("", DisplayPaths.compact(""))
    }
}

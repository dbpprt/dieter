package com.dbpprt.dieter.core.client.rules

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.time.Instant

class FormatExportsTest {
    private val now = Instant.parse("2026-08-19T12:00:00Z").toEpochMilliseconds()
    private val minute = 60_000L
    private val hour = 60 * minute
    private val day = 24 * hour

    @Test
    fun bytesUseBinaryUnits() {
        assertEquals("512 B", FormatExports.bytes(512))
        assertEquals("1.5 KB", FormatExports.bytes(1_536))
        assertEquals("0 B", FormatExports.bytes(0), "an empty file reads as zero bytes")
        assertEquals("10.4 GB", FormatExports.bytes(11_200_000_000))
    }

    @Test
    fun compactAgesTreatZeroAsUnknown() {
        assertEquals("", FormatExports.compactAge(0, now))
        assertEquals("now", FormatExports.compactAge(now - 30_000, now))
        assertEquals("5m", FormatExports.compactAge(now - 5 * minute, now))
    }

    @Test
    fun menuBarIslandAndChatAgesShareOneCompactRule() {
        assertEquals("now", FormatExports.compactAge(now - 25_000, now, weeks = true))
        assertEquals("5m", FormatExports.compactAge(now - 5 * minute, now, weeks = true))
        assertEquals("2h", FormatExports.compactAge(now - 2 * hour, now, weeks = true))
        assertEquals("5d", FormatExports.compactAge(now - 5 * day, now, weeks = true))
        assertEquals("2w", FormatExports.compactAge(now - 15 * day, now, weeks = true))
        assertEquals("15d", FormatExports.compactAge(now - 15 * day, now), "the menu bar and island keep counting days")
        assertEquals("", FormatExports.compactAge(0, now, weeks = true))
    }

    @Test
    fun agoDropsSecondsAndReadsUnknownAsEmpty() {
        assertEquals("just now", FormatExports.ago(now - 41_000, now))
        assertEquals("2m ago", FormatExports.ago(now - 150_000, now))
        assertEquals("2h ago", FormatExports.ago(now - 7_200_000, now))
        assertEquals("3d ago", FormatExports.ago(now - 3 * day, now))
        assertEquals("", FormatExports.ago(0, now))
        assertEquals("8m ago", FormatExports.agoSince("2026-08-19T11:52:00Z", now))
        assertEquals("2m ago", FormatExports.agoSince("2026-08-19T11:57:30.123456Z", now), "fractional seconds parse")
        assertEquals("", FormatExports.agoSince("", now))
        assertEquals("", FormatExports.agoSince("soon", now))
    }

    @Test
    fun inboxAndCardAges() {
        assertEquals("Just now", FormatExports.activityAge(now - 20_000, now, suffix = false))
        assertEquals("5m", FormatExports.activityAge(now - 5 * minute, now, suffix = false))
        assertEquals("5m ago", FormatExports.activityAge(now - 5 * minute, now, suffix = true))
        assertEquals("Time unavailable", FormatExports.activityAge(0, now, suffix = false))
        assertEquals("10min", FormatExports.cardAge("2026-08-19T11:50:00Z", "2026-08-19T10:00:00Z", now))
        assertEquals("2h", FormatExports.cardAge("2026-08-14T12:00:00Z", "2026-08-19T10:00:00Z", now))
        assertEquals("5d", FormatExports.cardAge("2026-08-14T12:00:00Z", "", now))
        assertEquals("", FormatExports.cardAge("", "", now))
    }

    @Test
    fun refreshLabelsUseThePlatformDateBeyondADay() {
        assertEquals("Refreshing…", FormatExports.refreshed(0, syncing = true, now, dateTime = "Aug 17"))
        assertEquals("Last refreshed just now · Refreshing…", FormatExports.refreshed(now - 20_000, syncing = true, now, dateTime = "Aug 19"))
        assertEquals("Last refreshed 5m ago", FormatExports.refreshed(now - 5 * minute, syncing = false, now, dateTime = "Aug 19"))
        assertEquals("Last refreshed Aug 17, 12:00", FormatExports.refreshed(now - 2 * day, syncing = false, now, dateTime = "Aug 17, 12:00"))
    }

    @Test
    fun timestampsParseToEpochMillis() {
        assertEquals(now, FormatExports.epochMillis("2026-08-19T12:00:00Z"))
        assertEquals(now + 500, FormatExports.epochMillis("2026-08-19T12:00:00.5Z"))
        assertEquals(0L, FormatExports.epochMillis(""))
        assertEquals(0L, FormatExports.epochMillis("not-a-timestamp"))
    }

    @Test
    fun tokenCountsUseALowerCaseKAndRoundTiesUp() {
        assertEquals(listOf("999", "1.2k", "1.3k", "129k", "1.3M"), listOf(999L, 1_234L, 1_250L, 128_953L, 1_288_847L).map(FormatExports::compactTokens))
        assertEquals("Tokens unavailable", FormatExports.tokenUsageLabel(1_250, reportedMessages = 0, partial = true))
        assertEquals("1.3k tokens · partial", FormatExports.tokenUsageLabel(1_250, reportedMessages = 2, partial = true))
        assertEquals("129k tokens", FormatExports.tokenUsageLabel(128_953, reportedMessages = 2, partial = false))
    }

    @Test
    fun pathsUnderAHomeFolderAreCompacted() {
        assertEquals("~/Development/dieter", FormatExports.compactPath("/Users/office/Development/dieter"))
        assertEquals("/srv/dieter", FormatExports.compactPath("/srv/dieter"))
    }

    @Test
    fun attachmentsUseTheCoreLimitsAndWording() {
        val mb = 1024L * 1024
        assertEquals("", FormatExports.attachmentLimitError(listOf("a.png"), listOf(mb)))
        assertEquals("You can attach up to 4 images or files.", FormatExports.attachmentLimitError(List(5) { "f" }, List(5) { 1L }))
        assertEquals("Pasted Image 1.png is empty.", FormatExports.attachmentLimitError(listOf("Pasted Image 1.png"), listOf(0L)))
        assertEquals("Each attachment must be at most 5 MB.", FormatExports.attachmentLimitError(listOf("big.mov"), listOf(5 * mb + 1)))
        assertEquals("Attachments must total at most 6 MB.", FormatExports.attachmentLimitError(listOf("a", "b"), listOf(3 * mb, 3 * mb + 1)))
        assertEquals("image/png", FormatExports.attachmentMediaType("Image/PNG; charset=binary", "x"))
        assertEquals("application/pdf", FormatExports.attachmentMediaType("", "brief.PDF"))
        assertEquals("application/octet-stream", FormatExports.attachmentMediaType("", "README"))
        assertEquals("SVG · 512 B", FormatExports.attachmentDetails("", "image/svg+xml", 512))
        assertEquals("Up to 4 attachments · 5 MB each · 6 MB total", FormatExports.attachmentLimits())
    }
}

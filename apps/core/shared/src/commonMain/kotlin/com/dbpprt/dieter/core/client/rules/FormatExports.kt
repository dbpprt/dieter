package com.dbpprt.dieter.core.client.rules

import com.dbpprt.dieter.api.v1.Card
import com.dbpprt.dieter.core.activity.Activity
import com.dbpprt.dieter.core.board.CardAges
import com.dbpprt.dieter.core.composition.Attachments
import com.dbpprt.dieter.core.presentation.Ages
import com.dbpprt.dieter.core.presentation.ByteSizes
import com.dbpprt.dieter.core.presentation.DisplayPaths
import com.dbpprt.dieter.core.presentation.TokenCounts
import com.dbpprt.dieter.core.runtime.Timestamps
import kotlin.time.Instant

/**
 * Wording for counts, sizes, times, paths, and attachments, with primitive
 * inputs, as views call it while rendering. Times are epoch milliseconds;
 * 0 means unknown.
 *
 * Every `*Exports` object in this package is stateless, so its functions are
 * safe on any thread; the Apple façade's `SharedRules` forwards to them.
 */
object FormatExports {
    /** "512 B", "1.5 KB", "240 MB": binary units, independent of the locale. */
    fun bytes(count: Long): String = ByteSizes.format(count)

    /** "now", "5m", "3h", "2d" since [sinceMillis]; "" when unknown. */
    fun compactAge(sinceMillis: Long, nowMillis: Long): String = compactAge(sinceMillis, nowMillis, weeks = false)

    /** [compactAge], counting weeks ("3w") from seven days when [weeks], as chat rows do. */
    fun compactAge(sinceMillis: Long, nowMillis: Long, weeks: Boolean): String =
        Ages.compact(instant(sinceMillis), Instant.fromEpochMilliseconds(nowMillis), weeks).orEmpty()

    /** "just now", "5m ago", "3h ago", "2d ago" since [atMillis]; "" when unknown. */
    fun ago(atMillis: Long, nowMillis: Long): String =
        instant(atMillis)?.let { Ages.ago(it, Instant.fromEpochMilliseconds(nowMillis)) }.orEmpty()

    /** [ago] for an RFC 3339 [value]; "" when blank or unparseable. */
    fun agoSince(value: String, nowMillis: Long): String =
        Timestamps.parse(value)?.let { Ages.ago(it, Instant.fromEpochMilliseconds(nowMillis)) }.orEmpty()

    /** An inbox row's age: "Just now", "5m", "3h", "2d" ("5m ago" with [suffix]); "Time unavailable" when unknown. */
    fun activityAge(atMillis: Long, nowMillis: Long, suffix: Boolean): String =
        Activity.age(instant(atMillis), Instant.fromEpochMilliseconds(nowMillis), suffix)

    /** A board card's age from the later of its two RFC 3339 times: "now", "5min", "3h", "2d", "3w"; "" when neither parses. */
    fun cardAge(updatedAt: String, lastActivityAt: String, nowMillis: Long): String =
        CardAges.compact(Card(updated_at = updatedAt, last_activity_at = lastActivityAt), Instant.fromEpochMilliseconds(nowMillis))

    /**
     * "Last refreshed 5m ago · Refreshing…", "Refreshing…", or "Not refreshed
     * yet"; beyond a day it shows [dateTime], the platform's formatting of
     * [atMillis].
     */
    fun refreshed(atMillis: Long, syncing: Boolean, nowMillis: Long, dateTime: String): String =
        Ages.refreshed(instant(atMillis), syncing, Instant.fromEpochMilliseconds(nowMillis)) { dateTime }

    /** An RFC 3339 [value] in epoch milliseconds, so the platform can format it; 0 when blank or unparseable. */
    fun epochMillis(value: String): Long = Timestamps.parse(value)?.toEpochMilliseconds() ?: 0L

    /** "999", "1.2k", "129k", "1.3M". */
    fun compactTokens(value: Long): String = TokenCounts.compact(value)

    /** "1.2k tokens", "1.3M tokens · partial", or "Tokens unavailable". */
    fun tokenUsageLabel(totalTokens: Long, reportedMessages: Long, partial: Boolean): String =
        TokenCounts.label(totalTokens, reportedMessages, partial)

    /** A path under any user's home folder as "~/…"; other paths unchanged. */
    fun compactPath(path: String): String = DisplayPaths.compact(path)

    /**
     * The first attachment limit the files would break, "" when none:
     * [names] and [sizes] pair up by index, a size of 0 is an empty file.
     */
    fun attachmentLimitError(names: List<String>, sizes: List<Long>): String = Attachments.limitError(names, sizes).orEmpty()

    /** A media type the daemon accepts: [declared] lowercased without parameters, else guessed from [filename]. */
    fun attachmentMediaType(declared: String, filename: String): String = Attachments.mediaType(declared, filename)

    /** The base name an attachment is sent under: no directories, and a readable default when [raw] is empty. */
    fun attachmentFilename(raw: String, mediaType: String): String = Attachments.filename(raw, mediaType)

    /** "PNG · 1.2 MB", or just the type when [bytes] is 0. */
    fun attachmentDetails(filename: String, mediaType: String, bytes: Long): String = Attachments.details(filename, mediaType, bytes)

    /** "Up to 4 attachments · 5 MB each · 6 MB total". */
    fun attachmentLimits(): String = Attachments.LIMITS

    internal fun instant(millis: Long): Instant? = if (millis == 0L) null else Instant.fromEpochMilliseconds(millis)
}

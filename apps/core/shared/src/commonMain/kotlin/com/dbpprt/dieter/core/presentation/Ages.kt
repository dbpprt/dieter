package com.dbpprt.dieter.core.presentation

import com.dbpprt.dieter.core.runtime.Timestamps
import kotlin.time.Duration
import kotlin.time.Instant

enum class AgeUnit(val suffix: String) { MINUTES("m"), HOURS("h"), DAYS("d"), WEEKS("w") }

/** An elapsed time in its largest whole [unit]. */
data class AgeSpan(val count: Long, val unit: AgeUnit) {
    /** "5m", "3h", "2d", "3w". */
    val compact: String get() = "$count${unit.suffix}"
}

/**
 * Relative times as lists and headers show them. Every format counts with
 * [span]; beyond a day some fall back to an absolute time the platform
 * formats in the device's locale and zone.
 */
object Ages {
    /**
     * [elapsed] in whole minutes, hours, then days, or from seven days in
     * weeks when [weeks]. Null under a minute, which includes the future.
     */
    fun span(elapsed: Duration, weeks: Boolean = false): AgeSpan? {
        val seconds = elapsed.inWholeSeconds
        return when {
            seconds < 60 -> null
            seconds < 3_600 -> AgeSpan(seconds / 60, AgeUnit.MINUTES)
            seconds < 86_400 -> AgeSpan(seconds / 3_600, AgeUnit.HOURS)
            !weeks || seconds < 604_800 -> AgeSpan(seconds / 86_400, AgeUnit.DAYS)
            else -> AgeSpan(seconds / 604_800, AgeUnit.WEEKS)
        }
    }

    /** "now", "5m", "3h", "2d" since [since], or from seven days "3w" when [weeks]; null when unknown. */
    fun compact(since: Instant?, now: Instant, weeks: Boolean = false): String? {
        since ?: return null
        return span(now - since, weeks)?.compact ?: "now"
    }

    /** "just now", "5m ago", "3h ago", "2d ago" since [at]; days keep counting, and the future reads "just now". */
    fun ago(at: Instant, now: Instant): String = span(now - at)?.let { "${it.compact} ago" } ?: "just now"

    /**
     * An RFC 3339 [value] relative to [now]: "now", "5m", "3h", else its [day];
     * a future time reads "in <1m", "in 5m", "in 3h", else its [dateTime].
     * Blank is ""; unparseable text shows its date's tail.
     */
    fun short(value: String, now: Instant, day: (Instant) -> String, dateTime: (Instant) -> String): String {
        if (value.isBlank()) return ""
        val at = Timestamps.parse(value) ?: return value.substringBefore('T').takeLast(5)
        if (at > now) {
            val until = span(at - now) ?: return "in <1m"
            return if (until.unit == AgeUnit.DAYS) dateTime(at) else "in ${until.compact}"
        }
        val age = span(now - at) ?: return "now"
        return if (age.unit == AgeUnit.DAYS) day(at) else age.compact
    }

    /** "Last refreshed 5m ago · Refreshing…"; beyond a day, the [dateTime]. */
    fun refreshed(at: Instant?, syncing: Boolean, now: Instant, dateTime: (Instant) -> String): String {
        at ?: return if (syncing) "Refreshing…" else "Not refreshed yet"
        val age = span(now - at)
        val freshness = when {
            age == null -> "just now"
            age.unit == AgeUnit.DAYS -> dateTime(at)
            else -> "${age.compact} ago"
        }
        return "Last refreshed $freshness" + if (syncing) " · Refreshing…" else ""
    }
}

object DisplayPaths {
    private val home = Regex("^/(?:Users|home)/([^/]+)")

    /**
     * A path under any user's home folder ("/Users/<name>/…" or
     * "/home/<name>/…") shortened to "~/…", whichever machine it lives on.
     * Other paths, including macOS's "/Users/Shared", stay as they are.
     */
    fun compact(path: String): String {
        val match = home.find(path) ?: return path
        if (match.groupValues[1] == "Shared") return path
        return "~" + path.substring(match.value.length)
    }
}

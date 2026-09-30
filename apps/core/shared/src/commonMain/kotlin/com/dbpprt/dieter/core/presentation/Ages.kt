package com.dbpprt.dieter.core.presentation

import com.dbpprt.dieter.core.runtime.Timestamps
import kotlin.time.Duration
import kotlin.time.Instant

/**
 * Relative times as lists and headers show them. Beyond a day they fall back
 * to an absolute time the platform formats in the device's locale and zone.
 */
object Ages {
    /** "now", "5m", "3h", "2d" since [since]; null when unknown. */
    fun compact(since: Instant?, now: Instant): String? {
        since ?: return null
        val seconds = (now - since).coerceAtLeast(Duration.ZERO).inWholeSeconds
        return when {
            seconds < 60 -> "now"
            seconds < 3_600 -> "${seconds / 60}m"
            seconds < 86_400 -> "${seconds / 3_600}h"
            else -> "${seconds / 86_400}d"
        }
    }

    /**
     * An RFC 3339 [value] relative to [now]: "now", "5m", "3h", else its [day];
     * a future time reads "in <1m", "in 5m", "in 3h", else its [dateTime].
     * Blank is ""; unparseable text shows its date's tail.
     */
    fun short(value: String, now: Instant, day: (Instant) -> String, dateTime: (Instant) -> String): String {
        if (value.isBlank()) return ""
        val at = Timestamps.parse(value) ?: return value.substringBefore('T').takeLast(5)
        if (at > now) {
            val until = at - now
            return when {
                until.inWholeMinutes < 1 -> "in <1m"
                until.inWholeMinutes < 60 -> "in ${until.inWholeMinutes}m"
                until.inWholeHours < 24 -> "in ${until.inWholeHours}h"
                else -> dateTime(at)
            }
        }
        val age = now - at
        return when {
            age.inWholeMinutes < 1 -> "now"
            age.inWholeMinutes < 60 -> "${age.inWholeMinutes}m"
            age.inWholeHours < 24 -> "${age.inWholeHours}h"
            else -> day(at)
        }
    }

    /** "Last refreshed 5m ago · Refreshing…"; beyond a day, the [dateTime]. */
    fun refreshed(at: Instant?, syncing: Boolean, now: Instant, dateTime: (Instant) -> String): String {
        at ?: return if (syncing) "Refreshing…" else "Not refreshed yet"
        val age = (now - at).coerceAtLeast(Duration.ZERO)
        val freshness = when {
            age.inWholeSeconds < 60 -> "just now"
            age.inWholeMinutes < 60 -> "${age.inWholeMinutes}m ago"
            age.inWholeHours < 24 -> "${age.inWholeHours}h ago"
            else -> dateTime(at)
        }
        return "Last refreshed $freshness" + if (syncing) " · Refreshing…" else ""
    }
}

object DisplayPaths {
    private const val DEVELOPMENT = "/Development/"

    /** A project path shortened to "~/Development/…" when it lives there. */
    fun compact(path: String): String = if (DEVELOPMENT in path) "~$DEVELOPMENT${path.substringAfter(DEVELOPMENT)}" else path
}

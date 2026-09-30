package com.dbpprt.dieter.core.runtime

import kotlin.time.Instant

/** The daemon's RFC 3339 timestamps; blank or malformed values are unknown. */
object Timestamps {
    fun parse(value: String?): Instant? =
        value?.takeIf { it.isNotBlank() }?.let { runCatching { Instant.parse(it) }.getOrNull() }

    /** Orders two timestamps; unknown sorts first. */
    fun compare(a: String?, b: String?): Int {
        val left = parse(a)
        val right = parse(b)
        return when {
            left == null && right == null -> 0
            left == null -> -1
            right == null -> 1
            else -> left.compareTo(right)
        }
    }
}

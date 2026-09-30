package com.dbpprt.dieter.core.presentation

import kotlin.time.Duration
import kotlin.time.Instant

/** Elapsed time as a running clock: "0:42", "12:05", "1:01:01". */
object Durations {
    fun clock(elapsed: Duration): String {
        val seconds = elapsed.inWholeSeconds.coerceAtLeast(0)
        val hours = seconds / 3600
        val minutes = (seconds % 3600) / 60
        val rest = (seconds % 60).toString().padStart(2, '0')
        return if (hours > 0) "$hours:${minutes.toString().padStart(2, '0')}:$rest" else "$minutes:$rest"
    }

    fun clock(start: Instant, now: Instant): String = clock(now - start)
}

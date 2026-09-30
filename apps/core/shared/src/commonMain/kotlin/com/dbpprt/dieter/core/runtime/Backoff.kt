package com.dbpprt.dieter.core.runtime

import kotlin.math.pow
import kotlin.time.Duration
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.seconds

/**
 * Exponential retry delays. The named policies replace six formulas that the
 * native clients duplicated with slightly different constants.
 */
data class Backoff(val initial: Duration, val maximum: Duration, val factor: Double = 2.0) {
    /** Delay before retry [attempt] (0-based). */
    fun delay(attempt: Int): Duration {
        if (attempt <= 0) return initial
        val scaled = initial.inWholeMilliseconds * factor.pow(attempt.coerceAtMost(30))
        return minOf(scaled.milliseconds, maximum)
    }

    companion object {
        /** Gateway and daemon reconnection (Android 750 ms→10 s; Mac 1 s×1.8→15 s). */
        val CONNECTION = Backoff(750.milliseconds, 10.seconds)

        /** Resubscribing a feature stream on a live connection. */
        val STREAM = Backoff(500.milliseconds, 8.seconds)

        /** Durable command redelivery. */
        val OUTBOX = Backoff(750.milliseconds, 15.seconds)

        /** Redelivery while the daemon reports a full disk. */
        val OUTBOX_STORAGE = Backoff(60.seconds, 60.seconds)

        /** Screen-sharing session recovery. */
        val SCREEN = Backoff(250.milliseconds, 5.seconds)

        /** Terminal stream resubscription. */
        val TERMINAL = Backoff(500.milliseconds, 5.seconds, 1.8)

        /** Navigation-sync (SharedKV) redelivery. */
        val NAVIGATION = Backoff(2.seconds, 30.seconds)
    }
}

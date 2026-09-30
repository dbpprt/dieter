package com.dbpprt.dieter.core.runtime

import kotlin.time.Duration
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.withTimeout

/**
 * Runs [block] within [timeout]. An expired deadline is a transient failure,
 * not a cancellation, so loops and retry policies treat it like any other
 * unanswered call instead of silently stopping.
 */
suspend fun <T> withDeadline(timeout: Duration, message: String = "The machine did not answer in time.", block: suspend () -> T): T =
    try {
        withTimeout(timeout) { block() }
    } catch (expired: TimeoutCancellationException) {
        throw CoreException(FailureKind.TRANSIENT, message, expired)
    }

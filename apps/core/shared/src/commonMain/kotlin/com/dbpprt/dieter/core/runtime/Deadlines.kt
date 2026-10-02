package com.dbpprt.dieter.core.runtime

import kotlin.time.Duration
import kotlin.time.Duration.Companion.seconds
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.withTimeout

/** How long one request to a machine or the gateway may take. */
object Deadlines {
    /** An ordinary read or mutation. */
    val CALL = 15.seconds

    /** A read that scans a working tree or a repository. */
    val READ = 30.seconds

    /** Work that may provision a workspace, create a repository, or restart a machine. */
    val PROVISION = 60.seconds
}

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

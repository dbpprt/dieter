package com.dbpprt.dieter.data

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.launch
import kotlinx.coroutines.supervisorScope
import kotlinx.coroutines.withTimeoutOrNull

/** Race connection setup only. No application request is sent twice. */
internal suspend fun <T : Any> hedgedRoute(
    delayMillis: Long = 1_000,
    preferred: suspend () -> T,
    fallback: suspend () -> T,
    dispose: (T) -> Unit,
): T {
    var selected: T? = null
    try {
        return supervisorScope {
            val outcomes = Channel<Result<T>>(2, onUndeliveredElement = { it.getOrNull()?.let(dispose) })
            val preferredFailed = CompletableDeferred<Unit>()
            suspend fun attempt(operation: suspend () -> T, preferredAttempt: Boolean) {
                try {
                    val value = operation()
                    if (outcomes.trySend(Result.success(value)).isFailure) dispose(value)
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (error: Throwable) {
                    outcomes.trySend(Result.failure(error))
                    if (preferredAttempt) preferredFailed.complete(Unit)
                }
            }
            val first = launch { attempt(preferred, true) }
            val second = launch {
                withTimeoutOrNull(delayMillis) { preferredFailed.await() }
                attempt(fallback, false)
            }
            try {
                val result = outcomes.receive()
                (if (result.isSuccess) result.getOrThrow() else outcomes.receive().getOrThrow())
                    .also { selected = it }
            } finally {
                first.cancel()
                second.cancel()
                outcomes.cancel()
            }
        }
    } catch (error: Throwable) {
        // Cancellation can arrive after receive while the losing child closes.
        // In that case the selected transport was never handed to the caller.
        selected?.let(dispose)
        throw error
    }
}

package com.dbpprt.dieter.ui

import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeout

/** A slow snapshot keeps its place on the stream; a hedge never restarts it. */
internal suspend fun <T> collectConversationWithHedge(
    updates: Flow<T>,
    needsFreshFrame: Boolean,
    fetch: suspend () -> T,
    accept: suspend (T) -> Unit,
    onReadFailure: (Throwable) -> Unit,
    hedgeDelayMillis: Long = 500,
    readTimeoutMillis: Long = 15_000,
) = coroutineScope {
    val delivered = AtomicBoolean(!needsFreshFrame)
    val hedge = if (needsFreshFrame) launch {
        delay(hedgeDelayMillis)
        if (delivered.get()) return@launch
        try {
            val snapshot = withTimeout(readTimeoutMillis) { fetch() }
            if (delivered.compareAndSet(false, true)) accept(snapshot)
        } catch (error: Throwable) {
            // A read deadline is local to the hedge; selection cancellation
            // still cancels this whole subscription immediately.
            currentCoroutineContext().ensureActive()
            if (!delivered.get()) onReadFailure(error)
        }
    } else null
    try {
        updates.collect { snapshot ->
            delivered.set(true)
            hedge?.cancel()
            accept(snapshot)
        }
    } finally {
        hedge?.cancel()
    }
}

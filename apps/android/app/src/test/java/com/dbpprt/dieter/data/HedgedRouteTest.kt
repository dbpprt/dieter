package com.dbpprt.dieter.data

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.junit.Assert.*
import org.junit.Test

class HedgedRouteTest {
    @Test fun fastPreferredDoesNotStartRelay() = runBlocking {
        var fallback = 0
        val selected = hedgedRoute(preferred = { "rtc" }, fallback = { fallback++; "relay" }, dispose = {})
        assertEquals("rtc", selected)
        assertEquals(0, fallback)
    }

    @Test fun stalledRTCDoesNotHoldHealthyRelayUntilItsDeadline() = runBlocking {
        var canceled = false
        val selected = withTimeout(5_000) {
            hedgedRoute(delayMillis = 10,
                preferred = { try { awaitCancellation() } finally { canceled = true } },
                fallback = { "relay" }, dispose = {})
        }
        assertEquals("relay", selected)
        assertTrue(canceled)
    }

    @Test fun relayFailureStillAllowsRTCAndLateLosingTransportIsDisposed() = runBlocking {
        val relayFailed = CompletableDeferred<Unit>()
        val selected = hedgedRoute(delayMillis = 1,
            preferred = { relayFailed.await(); "rtc" },
            fallback = { relayFailed.complete(Unit); error("relay unavailable") }, dispose = {})
        assertEquals("rtc", selected)
        val closed = mutableListOf<String>()
        val second = hedgedRoute(delayMillis = 1,
            preferred = {
                try { awaitCancellation() } catch (_: CancellationException) { "late" }
            },
            fallback = { "relay" }, dispose = { closed += it })
        assertEquals("relay", second)
        assertEquals(listOf("late"), closed)
    }

    @Test fun parentCancellationCancelsBothCandidates() = runBlocking {
        val ready = CompletableDeferred<Unit>()
        var canceled = 0
        val task = async {
            hedgedRoute<String>(delayMillis = 1,
                preferred = { try { awaitCancellation() } finally { canceled++ } },
                fallback = { ready.complete(Unit); try { awaitCancellation() } finally { canceled++ } },
                dispose = {})
        }
        ready.await()
        task.cancel()
        task.join()
        assertEquals(2, canceled)
    }

    @Test fun cancellationWhileLoserClosesDisposesSelectedTransport() = runBlocking {
        val closing = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        val disposed = mutableListOf<String>()
        val task = async {
            hedgedRoute<String>(delayMillis = 1,
                preferred = {
                    try { awaitCancellation() } finally {
                        withContext(NonCancellable) { closing.complete(Unit); release.await() }
                    }
                },
                fallback = { "selected-relay" }, dispose = { disposed += it })
        }
        closing.await()
        task.cancel()
        release.complete(Unit)
        task.join()
        assertEquals(listOf("selected-relay"), disposed)
    }

}

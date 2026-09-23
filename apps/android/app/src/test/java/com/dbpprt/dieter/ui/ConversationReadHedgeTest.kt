package com.dbpprt.dieter.ui

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test

class ConversationReadHedgeTest {
    @Test fun slowFirstFrameSurvivesReadTimeoutWithoutResubscribing() = runBlocking {
        var subscriptions = 0
        val received = mutableListOf<String>()
        var failures = 0
        val readExpired = CompletableDeferred<Unit>()
        collectConversationWithHedge<String>(
            updates = flow { subscriptions++; readExpired.await(); emit("fresh") }, needsFreshFrame = true,
            fetch = { awaitCancellation() }, accept = { received += it },
            onReadFailure = { failures++; readExpired.complete(Unit) },
            hedgeDelayMillis = 1, readTimeoutMillis = 10,
        )
        assertEquals(1, subscriptions)
        assertEquals(1, failures)
        assertEquals(listOf("fresh"), received)
    }

    @Test fun deliveredStreamCancelsHedgeAndDoesNotReportItsFailure() = runBlocking {
        var canceled = false
        var failures = 0
        val received = mutableListOf<String>()
        val readStarted = CompletableDeferred<Unit>()
        collectConversationWithHedge<String>(
            updates = flow { readStarted.await(); emit("fresh") }, needsFreshFrame = true,
            fetch = { readStarted.complete(Unit); try { awaitCancellation() } finally { canceled = true } },
            accept = { received += it }, onReadFailure = { failures++ }, hedgeDelayMillis = 1,
        )
        assertTrue(canceled)
        assertEquals(0, failures)
        assertEquals(listOf("fresh"), received)
    }

    @Test fun currentLiveCacheDoesNotIssueReadOnQuietSubscription() = runBlocking {
        var reads = 0
        collectConversationWithHedge<String>(updates = flow<String> { delay(30) }, needsFreshFrame = false,
            fetch = { reads++; "unused" }, accept = {}, onReadFailure = { fail("unexpected failure") },
            hedgeDelayMillis = 1)
        assertEquals(0, reads)
    }
}

package com.dbpprt.dieter.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ConversationOpenSyncPlanTest {
    @Test
    fun healthyLiveCacheResumesWithoutWaitingForDuplicateFrame() {
        val plan = conversationOpenSyncPlan(cachedLastSeq = 42L, coveredByHealthyLiveSync = true)

        assertTrue(plan.cacheIsCurrent)
        assertFalse(plan.needsFreshFrame)
        assertEquals(42L, plan.afterSeq)
    }

    @Test
    fun cacheOutsideLiveProjectionRequestsNewestTail() {
        val plan = conversationOpenSyncPlan(cachedLastSeq = 42L, coveredByHealthyLiveSync = false)

        assertFalse(plan.cacheIsCurrent)
        assertTrue(plan.needsFreshFrame)
        assertEquals(0L, plan.afterSeq)
    }

    @Test
    fun missingCacheRequestsNewestTail() {
        val plan = conversationOpenSyncPlan(cachedLastSeq = null, coveredByHealthyLiveSync = true)

        assertTrue(plan.needsFreshFrame)
        assertEquals(0L, plan.afterSeq)
    }
}

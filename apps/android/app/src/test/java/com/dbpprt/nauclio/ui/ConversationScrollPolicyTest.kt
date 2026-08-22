package com.dbpprt.nauclio.ui

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ConversationScrollPolicyTest {
    @Test
    fun followsUpdatesWhileReaderIsAtLatest() {
        assertTrue(
            shouldFollowConversationUpdate(
                explicitOpenScroll = false,
                initialScrollComplete = true,
                followingLatest = true,
            ),
        )
    }

    @Test
    fun preservesReaderPositionAfterTheyScrollAway() {
        assertFalse(
            shouldFollowConversationUpdate(
                explicitOpenScroll = false,
                initialScrollComplete = true,
                followingLatest = false,
            ),
        )
    }

    @Test
    fun initialAndExplicitOpenRequestsAlwaysReachLatest() {
        assertTrue(
            shouldFollowConversationUpdate(
                explicitOpenScroll = false,
                initialScrollComplete = false,
                followingLatest = false,
            ),
        )
        assertTrue(
            shouldFollowConversationUpdate(
                explicitOpenScroll = true,
                initialScrollComplete = true,
                followingLatest = false,
            ),
        )
    }

    @Test
    fun loadsEarlierHistoryNearTheTopAndForAnUnfilledViewport() {
        assertTrue(
            shouldLoadEarlierConversationHistory(
                hasMore = true,
                loading = false,
                anchorPending = false,
                initialScrollComplete = true,
                viewport = viewport(firstVisibleItemIndex = 3, canScrollBackward = true, canScrollForward = true),
            ),
        )
        assertTrue(
            shouldLoadEarlierConversationHistory(
                hasMore = true,
                loading = false,
                anchorPending = false,
                initialScrollComplete = true,
                viewport = viewport(firstVisibleItemIndex = 8, canScrollBackward = false, canScrollForward = false),
            ),
        )
    }

    @Test
    fun doesNotOverlapHistoryRequestsOrPrefetchFromTheMiddle() {
        val middle = viewport(firstVisibleItemIndex = 8, canScrollBackward = true, canScrollForward = true)
        assertFalse(shouldLoadEarlierConversationHistory(true, false, false, true, middle))
        assertFalse(shouldLoadEarlierConversationHistory(true, true, false, true, middle.copy(firstVisibleItemIndex = 0)))
        assertFalse(shouldLoadEarlierConversationHistory(true, false, true, true, middle.copy(firstVisibleItemIndex = 0)))
        assertFalse(shouldLoadEarlierConversationHistory(false, false, false, true, middle.copy(firstVisibleItemIndex = 0)))
        assertFalse(shouldLoadEarlierConversationHistory(true, false, false, false, middle.copy(firstVisibleItemIndex = 0)))
    }

    private fun viewport(
        firstVisibleItemIndex: Int,
        canScrollBackward: Boolean,
        canScrollForward: Boolean,
    ) = ConversationHistoryViewport(
        firstVisibleItemIndex = firstVisibleItemIndex,
        canScrollBackward = canScrollBackward,
        canScrollForward = canScrollForward,
        hasItems = true,
    )
}

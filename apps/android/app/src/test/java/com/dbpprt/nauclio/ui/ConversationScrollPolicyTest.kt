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
}

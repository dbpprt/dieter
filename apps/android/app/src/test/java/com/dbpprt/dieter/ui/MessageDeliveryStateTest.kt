package com.dbpprt.dieter.ui

import org.junit.Assert.assertEquals
import org.junit.Test

class MessageDeliveryStateTest {
    @Test
    fun followsOutboxAndGlobalSyncAcknowledgements() {
        assertEquals(MessageDeliveryState.LOCAL, messageDeliveryState(pending = true, accepted = false, failed = false))
        assertEquals(MessageDeliveryState.ACCEPTED, messageDeliveryState(pending = true, accepted = true, failed = false))
        assertEquals(MessageDeliveryState.SYNCED, messageDeliveryState(pending = false, accepted = false, failed = false))
        assertEquals(MessageDeliveryState.FAILED, messageDeliveryState(pending = true, accepted = false, failed = true))
    }

    @Test
    fun resolvedNewChatRetargetsItsForegroundStream() {
        assertEquals(true, conversationStreamNeedsRestart("local_chat", "c_server"))
        assertEquals(false, conversationStreamNeedsRestart("c_server", "c_server"))
        assertEquals(false, conversationStreamNeedsRestart(null, null))
    }
}

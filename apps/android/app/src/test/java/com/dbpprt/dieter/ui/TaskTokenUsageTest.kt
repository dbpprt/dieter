package com.dbpprt.dieter.ui

import com.dbpprt.dieter.v1.TokenUsage
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class TaskTokenUsageTest {
    @Test fun distinguishesUnavailableAndPartialUsage() {
        val unavailable = TokenUsage.newBuilder().setMissingMessages(1).setPartial(true).build()
        assertEquals("Tokens unavailable", taskTokenUsageLabel(unavailable))
        val partial = unavailable.toBuilder().setReportedMessages(1).setInputTokens(100).setOutputTokens(25).setTotalTokens(125).build()
        assertEquals("125 tokens · partial", taskTokenUsageLabel(partial))
        assertTrue(taskTokenUsageDetail(partial).contains("100 input"))
        assertEquals("125 tokens", taskTokenUsageLabel(partial.toBuilder().setPartial(false).build()))
    }
}

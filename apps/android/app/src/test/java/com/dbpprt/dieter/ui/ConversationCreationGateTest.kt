package com.dbpprt.dieter.ui

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ConversationCreationGateTest {
    @Test
    fun `second submission is rejected until the admitted creation finishes`() {
        val gate = ConversationCreationGate()

        assertTrue(gate.tryAcquire())
        assertFalse(gate.tryAcquire())

        gate.release()
        assertTrue(gate.tryAcquire())
    }
}

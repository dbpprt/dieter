package com.dbpprt.dieter.ui

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class TerminalStateTest {
    @Test
    fun incrementalFramesAppendWithoutResettingTheEmulator() {
        val first = TerminalScreenReducer.apply(TerminalScreenState(), "hello".encodeToByteArray(), screenReset = true)
        val second = TerminalScreenReducer.apply(first, " world".encodeToByteArray(), screenReset = false)

        assertEquals("hello world", second.data.decodeToString())
        assertEquals(first.resetRevision, second.resetRevision)
        assertTrue(second.revision > first.revision)
    }

    @Test
    fun resetFrameReplacesStaleScrollback() {
        val stale = TerminalScreenState("stale".encodeToByteArray(), revision = 8, resetRevision = 2)
        val reset = TerminalScreenReducer.apply(stale, "fresh".encodeToByteArray(), screenReset = true)

        assertEquals("fresh", reset.data.decodeToString())
        assertEquals(3, reset.resetRevision)
    }

    @Test
    fun boundedClientReplayForcesRendererBaselineReset() {
        val state = TerminalScreenReducer.apply(
            TerminalScreenState("1234".encodeToByteArray(), resetRevision = 4),
            "56789".encodeToByteArray(),
            screenReset = false,
            limit = 6,
        )

        assertEquals("456789", state.data.decodeToString())
        assertEquals(5, state.resetRevision)
    }

    @Test
    fun terminalInputIsSplitAtTheTransportLimitWithoutDataLoss() {
        val input = ByteArray(TERMINAL_INPUT_CHUNK_LIMIT * 2 + 17) { (it % 251).toByte() }
        val chunks = terminalInputChunks(input)

        assertEquals(listOf(TERMINAL_INPUT_CHUNK_LIMIT, TERMINAL_INPUT_CHUNK_LIMIT, 17), chunks.map(ByteArray::size))
        assertArrayEquals(input, chunks.fold(byteArrayOf()) { combined, chunk -> combined + chunk })
    }
}

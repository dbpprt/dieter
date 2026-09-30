package com.dbpprt.dieter.core.platform

import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertNull
import kotlin.test.assertTrue

class ControlFramesTest {
    @Test fun dataFramesCarryTheTlsStreamAndAcksAreALoneByte() {
        val payload = byteArrayOf(9, 8, 7, 6)
        val frame = ControlFrames.data(payload, count = 3)
        assertContentEquals(byteArrayOf(0, 9, 8, 7), frame)
        val decoded = assertIs<ControlFrames.Frame.Data>(ControlFrames.decode(frame))
        assertContentEquals(byteArrayOf(9, 8, 7), decoded.payload)
        assertEquals(ControlFrames.Frame.Ack, ControlFrames.decode(ControlFrames.ack))
        assertEquals(ControlFrames.MAX_FRAME, ControlFrames.data(ByteArray(ControlFrames.MAX_PAYLOAD)).size)
        assertFailsWith<IllegalArgumentException> { ControlFrames.data(ByteArray(ControlFrames.MAX_PAYLOAD + 1)) }
        assertFailsWith<IllegalArgumentException> { ControlFrames.data(ByteArray(0)) }
    }

    @Test fun anythingElseIsAProtocolViolation() {
        assertNull(ControlFrames.decode(byteArrayOf()))
        assertNull(ControlFrames.decode(byteArrayOf(0)), "an empty data frame")
        assertNull(ControlFrames.decode(byteArrayOf(1, 0)), "an ack with a payload")
        assertNull(ControlFrames.decode(byteArrayOf(2, 5)), "an unknown type")
        assertNull(ControlFrames.decode(byteArrayOf(0, 5), binary = false), "text messages")
        assertNull(ControlFrames.decode(ByteArray(ControlFrames.MAX_FRAME + 1)), "oversized frames")
        assertEquals("dieter-control-tls-v1", ControlFrames.LABEL)
    }

    @Test fun theSendWindowIsBoundedAndRejectsUnsolicitedAcks() {
        val window = ControlWindow()
        assertFalse(window.acknowledge(), "an ack before any data")
        repeat(ControlFrames.WINDOW) { assertTrue(window.reserve()) }
        assertFalse(window.reserve())
        assertEquals(ControlFrames.WINDOW, window.inFlight)
        assertTrue(window.acknowledge())
        assertTrue(window.reserve())
        repeat(ControlFrames.WINDOW) { assertTrue(window.acknowledge()) }
        assertFalse(window.acknowledge())
        assertEquals(0, window.inFlight)
    }
}

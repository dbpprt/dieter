package com.dbpprt.dieter.core.terminals

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import okio.ByteString.Companion.encodeUtf8
import okio.ByteString.Companion.toByteString

class TerminalScreenTest {
    private class Recorder : TerminalRendererSink {
        val events = mutableListOf<String>()
        override fun reset() { events += "reset" }
        override fun feed(bytes: ByteArray) { events += "feed:${bytes.size}" }
        override fun redraw() { events += "redraw" }
    }

    @Test
    fun rendererReceivesOnlyNewBytesAndResetsOnANewEpoch() {
        val sink = Recorder()
        val cursor = TerminalReplayCursor()
        var screen = TerminalScreen.EMPTY.reset("hello".encodeUtf8())
        cursor.apply(screen, sink)
        screen = screen.append(" world".encodeUtf8())
        cursor.apply(screen, sink)
        cursor.apply(screen, sink)
        screen = screen.reset(okio.ByteString.EMPTY)
        cursor.apply(screen, sink)
        assertEquals(listOf("reset", "feed:5", "feed:6", "reset", "redraw"), sink.events)
    }

    @Test
    fun aLongSessionTrimsWithoutReplayingEverything() {
        val sink = Recorder()
        val cursor = TerminalReplayCursor()
        var screen = TerminalScreen.EMPTY.reset(okio.ByteString.EMPTY)
        val block = ByteArray(32 * 1024) { 'x'.code.toByte() }.toByteString()
        repeat(100) {
            screen = screen.append(block)
            cursor.apply(screen, sink)
        }
        assertEquals(TerminalScreen.LIMIT_BYTES, screen.size)
        assertEquals(100L * block.size - TerminalScreen.LIMIT_BYTES, screen.startOffset)
        assertEquals(1, sink.events.count { it == "reset" }, "trimming the head never forces a replay")
        assertEquals(100, sink.events.count { it.startsWith("feed:32768") })

        val late = Recorder()
        TerminalReplayCursor().apply(screen, late)
        assertEquals(listOf("reset", "feed:${TerminalScreen.LIMIT_BYTES}"), late.events, "a new view replays the retained window")
    }

    @Test
    fun oversizedResetsKeepTheSuffix() {
        val big = ByteArray(3 * 1024 * 1024) { (it % 251).toByte() }.toByteString()
        val screen = TerminalScreen.EMPTY.reset(big)
        assertEquals(TerminalScreen.LIMIT_BYTES, screen.size)
        assertEquals(big.substring(big.size - TerminalScreen.LIMIT_BYTES.toInt()), screen.bytesFrom(screen.startOffset))
        assertEquals("abc", TerminalScreen.EMPTY.reset("abc".encodeUtf8()).accessibilityText())
    }

    @Test
    fun stickyControlMapsSingleAsciiBytes() {
        assertEquals(listOf<Byte>(3), TerminalKeys.control("c".encodeToByteArray())?.toList())
        assertEquals(listOf<Byte>(3), TerminalKeys.control("C".encodeToByteArray())?.toList())
        assertEquals(listOf<Byte>(0), TerminalKeys.control(" ".encodeToByteArray())?.toList())
        assertEquals(listOf<Byte>(0x7f), TerminalKeys.control("?".encodeToByteArray())?.toList())
        assertNull(TerminalKeys.control("1".encodeToByteArray()))
        assertNull(TerminalKeys.control("ab".encodeToByteArray()))
    }
}

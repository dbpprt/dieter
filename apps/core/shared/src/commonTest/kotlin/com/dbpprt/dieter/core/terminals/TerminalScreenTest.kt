package com.dbpprt.dieter.core.terminals

import com.dbpprt.dieter.client.v1.TerminalKey
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

    private fun key(key: TerminalKey, shift: Boolean = false, alt: Boolean = false, control: Boolean = false, application: Boolean = false) =
        TerminalKeys.sequence(key, shift, alt, control, application).decodeToString()

    @Test
    fun specialKeysUseStandardVtSequences() {
        // Ported from the iOS accessory bar's tests.
        assertEquals("\u001b[A", key(TerminalKey.TERMINAL_KEY_UP))
        assertEquals("\u001b[B", key(TerminalKey.TERMINAL_KEY_DOWN))
        assertEquals("\u001b[D", key(TerminalKey.TERMINAL_KEY_LEFT))
        assertEquals("\u001b[C", key(TerminalKey.TERMINAL_KEY_RIGHT))
        assertEquals("\u001bOP", key(TerminalKeys.function(1)!!))
        assertEquals("\u001b[24~", key(TerminalKeys.function(12)!!))
        assertNull(TerminalKeys.function(13))
        assertNull(TerminalKeys.function(0))
        assertEquals("\u001b", key(TerminalKey.TERMINAL_KEY_ESCAPE))
        assertEquals("\t", key(TerminalKey.TERMINAL_KEY_TAB))
        assertEquals("\r", key(TerminalKey.TERMINAL_KEY_ENTER))
        assertEquals("\u007f", key(TerminalKey.TERMINAL_KEY_BACKSPACE))
        assertEquals("", key(TerminalKey.TERMINAL_KEY_UNSPECIFIED))
        val functions = (1..12).map { key(TerminalKeys.function(it)!!) }
        assertEquals(
            listOf("OP", "OQ", "OR", "OS", "[15~", "[17~", "[18~", "[19~", "[20~", "[21~", "[23~", "[24~").map { "\u001b$it" },
            functions,
        )
        assertEquals("\u001b[H", key(TerminalKey.TERMINAL_KEY_HOME))
        assertEquals("\u001b[F", key(TerminalKey.TERMINAL_KEY_END))
        assertEquals("\u001b[5~", key(TerminalKey.TERMINAL_KEY_PAGE_UP))
        assertEquals("\u001b[6~", key(TerminalKey.TERMINAL_KEY_PAGE_DOWN))
        assertEquals("\u001b[2~", key(TerminalKey.TERMINAL_KEY_INSERT))
        assertEquals("\u001b[3~", key(TerminalKey.TERMINAL_KEY_DELETE))
    }

    @Test
    fun cursorModeAndModifiersFollowXterm() {
        assertEquals("\u001bOA", key(TerminalKey.TERMINAL_KEY_UP, application = true), "application cursor mode")
        assertEquals("\u001bOH", key(TerminalKey.TERMINAL_KEY_HOME, application = true))
        assertEquals("\u001b[1;5A", key(TerminalKey.TERMINAL_KEY_UP, control = true, application = true), "a modifier overrides the mode")
        assertEquals("\u001b[1;2D", key(TerminalKey.TERMINAL_KEY_LEFT, shift = true))
        assertEquals("\u001b[1;3C", key(TerminalKey.TERMINAL_KEY_RIGHT, alt = true))
        assertEquals("\u001b[1;8B", key(TerminalKey.TERMINAL_KEY_DOWN, shift = true, alt = true, control = true))
        assertEquals("\u001b[1;5P", key(TerminalKey.TERMINAL_KEY_F1, control = true))
        assertEquals("\u001b[5;5~", key(TerminalKey.TERMINAL_KEY_PAGE_UP, control = true))
        assertEquals("\u001b[24;2~", key(TerminalKey.TERMINAL_KEY_F12, shift = true))
        assertEquals("\u001b[Z", key(TerminalKey.TERMINAL_KEY_TAB, shift = true))
        assertEquals("\u001b\r", key(TerminalKey.TERMINAL_KEY_ENTER, alt = true))
        assertEquals("\b", key(TerminalKey.TERMINAL_KEY_BACKSPACE, control = true))
    }

    @Test
    fun stickyControlMatchesTheIosAccessoryBar() {
        assertEquals(listOf<Byte>(0x1b), TerminalKeys.control("[".encodeToByteArray())?.toList())
        assertNull(TerminalKeys.control("paste".encodeToByteArray()))
        assertNull(TerminalKeys.control("é".encodeToByteArray()))
    }
}

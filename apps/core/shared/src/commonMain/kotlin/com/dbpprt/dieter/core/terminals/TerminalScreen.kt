package com.dbpprt.dieter.core.terminals

import com.dbpprt.dieter.client.v1.TerminalKey
import okio.Buffer
import okio.ByteString
import okio.ByteString.Companion.toByteString

/**
 * A terminal's retained output as an immutable list of chunks. The daemon's
 * `screen_reset` starts a new [epoch]; trimming to the byte limit only moves
 * [startOffset], so a renderer that keeps up never replays from scratch.
 */
class TerminalScreen private constructor(
    val epoch: Long,
    /** Offset of the first retained byte within the epoch. */
    val startOffset: Long,
    val chunks: List<ByteString>,
    val revision: Long,
) {
    val size: Long = chunks.sumOf { it.size.toLong() }
    val endOffset: Long get() = startOffset + size

    fun reset(data: ByteString): TerminalScreen = TerminalScreen(epoch + 1, 0, emptyList(), revision + 1).append(data, countRevision = false)

    fun append(data: ByteString, countRevision: Boolean = true): TerminalScreen {
        if (data.size == 0) return if (countRevision) TerminalScreen(epoch, startOffset, chunks, revision + 1) else this
        val next = chunks.toMutableList()
        var offset = 0
        val tail = next.lastOrNull()
        if (tail != null && tail.size < CHUNK_BYTES) {
            val take = minOf(CHUNK_BYTES - tail.size, data.size)
            next[next.lastIndex] = Buffer().write(tail).write(data, 0, take).readByteString()
            offset = take
        }
        while (offset < data.size) {
            val take = minOf(CHUNK_BYTES, data.size - offset)
            next += data.substring(offset, offset + take)
            offset += take
        }
        var start = startOffset
        var total = next.sumOf { it.size.toLong() }
        while (total > LIMIT_BYTES && next.size > 1) {
            val removed = next.removeAt(0)
            start += removed.size
            total -= removed.size
        }
        if (total > LIMIT_BYTES) {
            val only = next.single()
            val cut = (total - LIMIT_BYTES).toInt()
            next[0] = only.substring(cut)
            start += cut
        }
        return TerminalScreen(epoch, start, next, if (countRevision) revision + 1 else revision)
    }

    /** Bytes from absolute [offset] (within this epoch) to the end. */
    fun bytesFrom(offset: Long): ByteString {
        val buffer = Buffer()
        var position = startOffset
        for (chunk in chunks) {
            val end = position + chunk.size
            if (end > offset) buffer.write(chunk, maxOf(0, (offset - position).toInt()), chunk.size - maxOf(0, (offset - position).toInt()))
            position = end
        }
        return buffer.readByteString()
    }

    /** The last 16 KiB as text, for screen readers. */
    fun accessibilityText(): String = bytesFrom(maxOf(startOffset, endOffset - 16 * 1024)).utf8()

    companion object {
        const val CHUNK_BYTES = 64 * 1024
        const val LIMIT_BYTES = 2L * 1024 * 1024
        val EMPTY = TerminalScreen(0, 0, emptyList(), 0)
    }
}

/** What a native terminal view does with the next screen. */
interface TerminalRendererSink {
    fun reset()
    fun feed(bytes: ByteArray)
    fun redraw()
}

/**
 * Feeds a native emulator exactly the bytes it has not consumed. A new epoch,
 * or falling behind the retained window, resets and replays; otherwise only
 * the new suffix is fed. Converges even when snapshots are conflated.
 */
class TerminalReplayCursor {
    private var epoch = -1L
    private var consumed = 0L

    fun apply(screen: TerminalScreen, sink: TerminalRendererSink) {
        if (screen.epoch != epoch || consumed < screen.startOffset || consumed > screen.endOffset) {
            sink.reset()
            val all = screen.bytesFrom(screen.startOffset)
            if (all.size > 0) sink.feed(all.toByteArray()) else sink.redraw()
            epoch = screen.epoch
            consumed = screen.endOffset
            return
        }
        if (consumed < screen.endOffset) {
            sink.feed(screen.bytesFrom(consumed).toByteArray())
            consumed = screen.endOffset
        }
    }
}

/**
 * The bytes a terminal's keys send, as xterm encodes them, for accessory bars
 * on touch devices. Android's Termux renderer encodes hardware keys the same
 * way.
 */
object TerminalKeys {
    /**
     * The bytes [key] sends; empty for an unspecified key. Cursor keys follow
     * application cursor mode unless a modifier is held. Held modifiers become
     * xterm's `;N` parameter (1 + Shift 1, Alt 2, Control 4); Shift turns Tab
     * into back-tab, Alt prefixes Enter and Backspace with Escape, and Control
     * turns Backspace into BS.
     */
    fun sequence(key: TerminalKey, shift: Boolean = false, alt: Boolean = false, control: Boolean = false, applicationCursor: Boolean = false): ByteArray {
        val modifier = 1 + (if (shift) 1 else 0) + (if (alt) 2 else 0) + (if (control) 4 else 0)
        // Cursor and F1–F4 keys: `ESC [ x` or `ESC O x` alone, `ESC [ 1 ; N x` with modifiers.
        fun cursor(final: Char, application: Boolean) =
            if (modifier > 1) "$ESC[1;$modifier$final" else if (application) "${ESC}O$final" else "$ESC[$final"
        // Editing and F5–F12 keys: `ESC [ n ~`, `ESC [ n ; N ~` with modifiers.
        fun tilde(code: Int) = if (modifier > 1) "$ESC[$code;$modifier~" else "$ESC[$code~"
        val text = when (key) {
            TerminalKey.TERMINAL_KEY_UNSPECIFIED -> ""
            TerminalKey.TERMINAL_KEY_ESCAPE -> ESC
            TerminalKey.TERMINAL_KEY_TAB -> if (shift) "$ESC[Z" else "\t"
            TerminalKey.TERMINAL_KEY_ENTER -> (if (alt) ESC else "") + "\r"
            TerminalKey.TERMINAL_KEY_BACKSPACE -> (if (alt) ESC else "") + if (control) "\b" else "\u007f"
            TerminalKey.TERMINAL_KEY_UP -> cursor('A', applicationCursor)
            TerminalKey.TERMINAL_KEY_DOWN -> cursor('B', applicationCursor)
            TerminalKey.TERMINAL_KEY_RIGHT -> cursor('C', applicationCursor)
            TerminalKey.TERMINAL_KEY_LEFT -> cursor('D', applicationCursor)
            TerminalKey.TERMINAL_KEY_HOME -> cursor('H', applicationCursor)
            TerminalKey.TERMINAL_KEY_END -> cursor('F', applicationCursor)
            TerminalKey.TERMINAL_KEY_PAGE_UP -> tilde(5)
            TerminalKey.TERMINAL_KEY_PAGE_DOWN -> tilde(6)
            TerminalKey.TERMINAL_KEY_INSERT -> tilde(2)
            TerminalKey.TERMINAL_KEY_DELETE -> tilde(3)
            TerminalKey.TERMINAL_KEY_F1 -> cursor('P', application = true)
            TerminalKey.TERMINAL_KEY_F2 -> cursor('Q', application = true)
            TerminalKey.TERMINAL_KEY_F3 -> cursor('R', application = true)
            TerminalKey.TERMINAL_KEY_F4 -> cursor('S', application = true)
            TerminalKey.TERMINAL_KEY_F5 -> tilde(15)
            TerminalKey.TERMINAL_KEY_F6 -> tilde(17)
            TerminalKey.TERMINAL_KEY_F7 -> tilde(18)
            TerminalKey.TERMINAL_KEY_F8 -> tilde(19)
            TerminalKey.TERMINAL_KEY_F9 -> tilde(20)
            TerminalKey.TERMINAL_KEY_F10 -> tilde(21)
            TerminalKey.TERMINAL_KEY_F11 -> tilde(23)
            TerminalKey.TERMINAL_KEY_F12 -> tilde(24)
        }
        return text.encodeToByteArray()
    }

    /** F1 to F12 by [number]; null for any other number. */
    fun function(number: Int): TerminalKey? =
        if (number in 1..12) TerminalKey.fromValue(TerminalKey.TERMINAL_KEY_F1.value + number - 1) else null

    private const val ESC = "\u001b"

    /** Sticky Ctrl for one typed ASCII byte: letters and `@`..`_` to control codes, space to NUL, `?` to DEL. */
    fun control(bytes: ByteArray): ByteArray? {
        if (bytes.size != 1) return null
        val value = bytes[0].toInt()
        return when (value) {
            in '@'.code..'_'.code, in 'a'.code..'z'.code -> byteArrayOf((value and 0x1f).toByte())
            ' '.code -> byteArrayOf(0)
            '?'.code -> byteArrayOf(0x7f)
            else -> null
        }
    }
}

internal fun ByteArray.bytes(): ByteString = toByteString()

package com.dbpprt.dieter.core.terminals

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

object TerminalKeys {
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

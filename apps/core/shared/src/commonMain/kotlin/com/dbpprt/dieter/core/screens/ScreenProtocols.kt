package com.dbpprt.dieter.core.screens

import com.dbpprt.dieter.api.v1.RemoteDesktopClipboardFrame
import com.dbpprt.dieter.api.v1.RemoteDesktopClipboardItem
import com.dbpprt.dieter.api.v1.RemoteDesktopCursor
import com.dbpprt.dieter.api.v1.RemoteDesktopInput
import com.dbpprt.dieter.api.v1.RemoteDesktopKey
import com.dbpprt.dieter.api.v1.RemoteDesktopPointerButton
import com.dbpprt.dieter.api.v1.RemoteDesktopPointerMove
import com.dbpprt.dieter.api.v1.RemoteDesktopReceiverFeedback
import com.dbpprt.dieter.api.v1.RemoteDesktopReference
import com.dbpprt.dieter.api.v1.RemoteDesktopReleaseAll
import com.dbpprt.dieter.api.v1.RemoteDesktopScroll
import com.dbpprt.dieter.api.v1.RemoteDesktopText
import kotlin.math.roundToInt
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.seconds
import kotlin.time.Instant
import okio.Buffer
import okio.ByteString
import okio.ByteString.Companion.encodeUtf8

/** Data-channel labels, derived from the protocol version. */
object ScreenChannels {
    const val POINTER = "dieter-pointer-v$SCREEN_INPUT_PROTOCOL"
    const val INPUT = "dieter-input-state-v$SCREEN_INPUT_PROTOCOL"
    const val SESSION = "dieter-session-v$SCREEN_INPUT_PROTOCOL"
    const val CLIPBOARD = "dieter-clipboard-v1"
    const val MAX_INPUT_BYTES = 4096
    const val MAX_HOST_EVENT_BYTES = 350_000
    const val BACKPRESSURE_BYTES = 65_536L
}

object Modifiers {
    const val SHIFT = 1
    const val CONTROL = 2
    const val OPTION = 4
    const val COMMAND = 8
    const val CAPS_LOCK = 16
    const val FUNCTION = 32

    /** The shortcut modifiers: with one armed, typed characters become key presses. */
    const val SHORTCUTS = CONTROL or OPTION or COMMAND

    fun of(shift: Boolean, control: Boolean, option: Boolean, command: Boolean): Int =
        (if (shift) SHIFT else 0) or (if (control) CONTROL else 0) or (if (option) OPTION else 0) or (if (command) COMMAND else 0)
}

/** Something typed: a HID key press, or text the host inserts as is. */
sealed interface Typed {
    data class Key(val hid: Int) : Typed
    data class Text(val text: String) : Typed
}

/** Soft-keyboard input for a remote screen. */
object ScreenKeyboard {
    const val ENTER = 40
    const val BACKSPACE = 42
    const val DELETE = 76

    /** A key a toolbar shows: its label and HID usage, and for modifiers the mask it arms. */
    data class ToolbarKey(val label: String, val hid: Int, val modifier: Int = 0)

    val MODIFIER_KEYS = listOf(ToolbarKey("Ctrl", 224, Modifiers.CONTROL), ToolbarKey("Alt", 226, Modifiers.OPTION), ToolbarKey("Shift", 225, Modifiers.SHIFT), ToolbarKey("⌘", 227, Modifiers.COMMAND))

    val SPECIAL_KEYS = listOf(
        ToolbarKey("Esc", 41), ToolbarKey("Tab", 43), ToolbarKey("←", 80), ToolbarKey("↑", 82), ToolbarKey("↓", 81), ToolbarKey("→", 79),
        ToolbarKey("Enter", ENTER), ToolbarKey("Backspace", BACKSPACE), ToolbarKey("Delete", DELETE), ToolbarKey("Home", 74), ToolbarKey("End", 77),
        ToolbarKey("PgUp", 75), ToolbarKey("PgDn", 78),
    ) + (1..12).map { ToolbarKey("F$it", 57 + it) }

    /** Letters, digits, and space as HID usages. */
    fun hid(character: Char): Int? = when (val lower = character.lowercaseChar()) {
        in 'a'..'z' -> lower - 'a' + 4
        in '1'..'9' -> lower - '1' + 30
        '0' -> 39
        ' ' -> 44
        else -> null
    }

    /**
     * Text an input method committed. With a shortcut modifier armed it must
     * reach the host as key presses, or Cmd+A would type a literal "a".
     */
    fun committed(text: String, modifiers: Int): List<Typed> {
        if (modifiers and Modifiers.SHORTCUTS == 0) return listOf(Typed.Text(text))
        return text.map { character -> hid(character)?.let(Typed::Key) ?: Typed.Text(character.toString()) }
    }
}

/** Converts a 0..1 coordinate into the protocol's integer space. */
fun normalized(value: Double): Int = (value.coerceIn(0.0, 1.0) * 1_000_000).roundToInt()

/**
 * Builds input envelopes: per-channel sequences, one event ordinal across
 * both channels, and the state barrier that orders pointer moves after the
 * reliable input they follow.
 */
class ScreenInputEncoder(private val epoch: ByteString) {
    private var pointerSequence = 0L
    private var stateSequence = 0L
    private var eventOrdinal = 0L
    var lastPointerOrdinal = 0L
        private set

    val stateBarrier: Long get() = stateSequence

    private fun envelope(sequence: Long, displayGeneration: Long, controlGeneration: Long) = RemoteDesktopInput(
        protocol_version = SCREEN_INPUT_PROTOCOL, input_epoch = epoch, sequence = sequence, display_generation = displayGeneration,
        event_ordinal = ++eventOrdinal, state_barrier = stateSequence, control_generation = controlGeneration,
    )

    /** An unreliable pointer move (the latest wins). */
    fun move(x: Double, y: Double, displayGeneration: Long, controlGeneration: Long): RemoteDesktopInput =
        envelope(++pointerSequence, displayGeneration, controlGeneration)
            .copy(pointer_move = RemoteDesktopPointerMove(normalized(x), normalized(y)))
            .also { lastPointerOrdinal = it.event_ordinal }

    private fun reliable(displayGeneration: Long, controlGeneration: Long, fill: (RemoteDesktopInput) -> RemoteDesktopInput): RemoteDesktopInput {
        stateSequence++
        return fill(envelope(stateSequence, displayGeneration, controlGeneration).copy(state_barrier = stateSequence))
    }

    fun button(button: RemoteDesktopPointerButton.Button, down: Boolean, clicks: Int, x: Double, y: Double, modifiers: Int, displayGeneration: Long, controlGeneration: Long) =
        reliable(displayGeneration, controlGeneration) {
            it.copy(pointer_button = RemoteDesktopPointerButton(button, down, clicks.coerceIn(0, 3), normalized(x), normalized(y), modifiers and 0x3F))
        }.also { lastPointerOrdinal = it.event_ordinal }

    fun scroll(dx: Double, dy: Double, phase: Int, momentum: Int, modifiers: Int, precise: Boolean, displayGeneration: Long, controlGeneration: Long) =
        reliable(displayGeneration, controlGeneration) {
            it.copy(
                scroll = RemoteDesktopScroll(
                    delta_x = dx.roundToInt(), delta_y = dy.roundToInt(), precise = precise, modifiers = modifiers and 0x3F,
                    precise_delta_x = dx, precise_delta_y = dy, phase = phase and 0xFF, momentum_phase = momentum and 0xFF,
                ),
            )
        }

    fun key(hid: Int, down: Boolean, repeat: Boolean, modifiers: Int, displayGeneration: Long, controlGeneration: Long): RemoteDesktopInput? {
        if (hid !in 4..231) return null
        return reliable(displayGeneration, controlGeneration) { it.copy(key = RemoteDesktopKey(down = down, repeat = repeat, modifiers = modifiers and 0x3F, physical_key = hid)) }
    }

    fun text(chunk: String, displayGeneration: Long, controlGeneration: Long) =
        reliable(displayGeneration, controlGeneration) { it.copy(text = RemoteDesktopText(chunk)) }

    fun releaseAll(displayGeneration: Long, controlGeneration: Long) =
        reliable(displayGeneration, controlGeneration) { it.copy(release_all = RemoteDesktopReleaseAll()) }

    companion object {
        const val MAX_TEXT_BYTES = 8192
        const val TEXT_CHUNK_UTF16 = 512

        /** Chunks of at most 512 UTF-16 units that never split a surrogate pair; null when the insertion is too long. */
        fun textChunks(text: String): List<String>? {
            if (text.encodeUtf8().size > MAX_TEXT_BYTES) return null
            val chunks = mutableListOf<String>()
            var start = 0
            while (start < text.length) {
                var end = minOf(text.length, start + TEXT_CHUNK_UTF16)
                if (end < text.length && text[end - 1].isHighSurrogate()) end--
                chunks += text.substring(start, end)
                start = end
            }
            return chunks
        }

        private val unshifted = mapOf(
            '\n' to 40, '\r' to 40, '\t' to 43, ' ' to 44, '-' to 45, '=' to 46, '[' to 47, ']' to 48, '\\' to 49, ';' to 51, '\'' to 52,
            '`' to 53, ',' to 54, '.' to 55, '/' to 56,
        )
        private val shifted = mapOf(
            '!' to 30, '@' to 31, '#' to 32, '$' to 33, '%' to 34, '^' to 35, '&' to 36, '*' to 37, '(' to 38, ')' to 39,
            '_' to 45, '+' to 46, '{' to 47, '}' to 48, '|' to 49, ':' to 51, '"' to 52, '~' to 53, '<' to 54, '>' to 55, '?' to 56,
        )

        /** A single ASCII character typed with Control, Option, or Command held becomes a key stroke: (HID, needs Shift). */
        fun stroke(text: String): Pair<Int, Boolean>? {
            if (text.length != 1) return null
            val char = text[0]
            return when (char) {
                in 'a'..'z' -> (4 + (char - 'a')) to false
                in 'A'..'Z' -> (4 + (char - 'A')) to true
                in '1'..'9' -> (30 + (char - '1')) to false
                '0' -> 39 to false
                else -> unshifted[char]?.let { it to false } ?: shifted[char]?.let { it to true }
            }
        }

        /** Copy (C), cut (X), and paste (V) with Command alone are clipboard operations, not keys. */
        fun clipboardShortcut(hid: Int, modifiers: Int): String? {
            if ((modifiers and 0xF) != Modifiers.COMMAND) return null
            return when (hid) {
                6 -> "copy"
                27 -> "cut"
                25 -> "paste"
                else -> null
            }
        }
    }
}

/**
 * The receiver feedback sent every 500 ms and on decoded references. It
 * renews the daemon's lease; input counts as active for one second after
 * the last update.
 */
class ScreenFeedback(private val epoch: ByteString) {
    private var sequence = 0L
    private var measurementSequence = 1L
    private var measuredAt: Instant? = null
    private var sample = RemoteDesktopReceiverFeedback()
    private var references = emptyList<RemoteDesktopReference>()
    private var inputActive = false
    private var inputUpdatedAt: Instant? = null

    fun start(now: Instant) {
        sequence = 0
        measurementSequence = 1
        measuredAt = now
        references = emptyList()
    }

    fun update(measurement: RemoteDesktopReceiverFeedback, now: Instant) {
        sample = measurement
        measurementSequence++
        measuredAt = now
    }

    fun acknowledge(decoded: List<RemoteDesktopReference>) {
        references = (references + decoded).takeLast(8)
    }

    fun input(active: Boolean, now: Instant) {
        inputActive = active
        inputUpdatedAt = now
    }

    fun next(now: Instant): RemoteDesktopReceiverFeedback = sample.copy(
        protocol_version = SCREEN_INPUT_PROTOCOL, input_epoch = epoch, sequence = ++sequence,
        measurement_sequence = measurementSequence,
        measurement_age_ms = (measuredAt?.let { now - it }?.inWholeMilliseconds ?: 0).coerceIn(0, UInt.MAX_VALUE.toLong()).toInt(),
        decoded_references = references,
        input_active = inputActive && inputUpdatedAt?.let { now - it < 1.seconds } == true,
    )

    companion object {
        const val SKIP_BUFFERED_BYTES = 16_384L
        val INTERVAL = 500.milliseconds
    }
}

/**
 * Acknowledges host reference frames once the decoder produced them, within
 * two seconds; newer reference generations replace older ones.
 */
class ScreenReferences(private val millisecondQuantized: Boolean) {
    private var active = true
    private var generation = 0L
    private val decoded = ArrayDeque<Pair<UInt, Instant>>()
    private val pending = ArrayDeque<Pair<RemoteDesktopReference, Instant>>()

    private fun key(timestamp: UInt): UInt = if (millisecondQuantized) (timestamp / 90u) * 90u else timestamp

    fun decoded(timestamp: UInt, now: Instant): List<RemoteDesktopReference> {
        decoded.removeAll { now - it.second >= WINDOW }
        if (decoded.none { key(it.first) == key(timestamp) }) {
            if (decoded.size >= 128) decoded.removeFirst()
            decoded.addLast(timestamp to now)
        }
        return deliver(now)
    }

    fun expect(reference: RemoteDesktopReference, now: Instant): List<RemoteDesktopReference> {
        if (!active || reference.frame_id == 0L || reference.generation == 0L || reference.generation.toULong() < generation.toULong()) return emptyList()
        if (reference.generation.toULong() > generation.toULong()) {
            pending.clear()
            generation = reference.generation
        }
        if (pending.size >= 8) pending.removeFirst()
        pending.addLast(reference to now)
        return deliver(now)
    }

    private fun deliver(now: Instant): List<RemoteDesktopReference> {
        val acked = mutableListOf<RemoteDesktopReference>()
        val iterator = pending.iterator()
        while (iterator.hasNext()) {
            val (reference, at) = iterator.next()
            if (now - at >= WINDOW) {
                iterator.remove()
                continue
            }
            if (decoded.any { key(it.first) == key(reference.rtp_timestamp.toUInt()) && now - it.second < WINDOW }) {
                acked += reference
                iterator.remove()
            }
        }
        return acked
    }

    fun stop() {
        active = false
        decoded.clear()
        pending.clear()
    }

    private companion object {
        val WINDOW = 2.seconds
    }
}

/** Splits a clipboard payload into frames, and reassembles one within its limits. */
object ClipboardFraming {
    const val CHUNK = 16_384
    const val MAX_TOTAL = 8 * 1024 * 1024 + 64 * 1024
    const val MAX_MESSAGE = CHUNK + 128
    const val BUFFER_LIMIT = 32_768L

    fun frames(operationId: String, payload: ByteString): List<RemoteDesktopClipboardFrame> {
        if (payload.size == 0) return listOf(RemoteDesktopClipboardFrame(operation_id = operationId, end = true))
        return (0 until payload.size step CHUNK).map { offset ->
            val end = minOf(payload.size, offset + CHUNK)
            RemoteDesktopClipboardFrame(operation_id = operationId, data_ = payload.substring(offset, end), end = end == payload.size)
        }
    }

    /** Accumulates frames of one operation; throws on any violation, which closes the channel. */
    class Assembler(private val operationId: String) {
        private val buffer = Buffer()

        /** Returns the payload once the last frame arrived. */
        fun accept(message: ByteString): ByteString? {
            if (message.size > MAX_MESSAGE) throw IllegalStateException("Clipboard frame is too large")
            val frame = RemoteDesktopClipboardFrame.ADAPTER.decode(message)
            if (frame.operation_id != operationId) throw IllegalStateException("Clipboard frame belongs to another operation")
            if (frame.data_.size > CHUNK || buffer.size + frame.data_.size > MAX_TOTAL) throw IllegalStateException("Clipboard transfer is too large")
            buffer.write(frame.data_)
            return if (frame.end) buffer.readByteString() else null
        }
    }
}

object ClipboardContent {
    const val MAX_TEXT_BYTES = 1024 * 1024
    const val MAX_ITEMS = 64
    const val MAX_ITEM_BYTES = 8 * 1024 * 1024
    /** Image types that cross as one image item; anything else is a file. */
    val IMAGE_TYPES = setOf("image/png", "image/jpeg", "image/tiff", "image/webp")

    /** The first limit or naming rule the content breaks, or null. Paths never cross the wire. */
    fun validate(text: String, items: List<RemoteDesktopClipboardItem>): String? {
        if (text.isNotEmpty() && items.isNotEmpty()) return "Invalid clipboard file or image"
        if (text.encodeUtf8().size > MAX_TEXT_BYTES || items.size > MAX_ITEMS || items.sumOf { it.data_.size.toLong() } > MAX_ITEM_BYTES) {
            return "Clipboard limit: 1 MiB text or 8 MiB across 64 files"
        }
        val names = HashSet<String>()
        for (item in items) {
            val name = item.name
            if (name.isEmpty() || name.encodeUtf8().size > 255 || name == "." || name == ".." || name.any { it == '/' || it == '\\' || it == '\u0000' }) return "Invalid clipboard file or image"
            if (!names.add(name.lowercase())) return "Invalid clipboard file or image"
            if (item.mime_type.length > 128) return "Invalid clipboard file or image"
            if (item.kind == RemoteDesktopClipboardItem.Kind.IMAGE && (items.size != 1 || item.mime_type.lowercase() !in IMAGE_TYPES)) return "Invalid clipboard file or image"
        }
        return null
    }
}

/** Cursor shapes by ID; the host sends each image once per display generation. */
class CursorCache {
    private val shapes = LinkedHashMap<String, ByteString>()

    /** The cursor's image, caching a new valid one; null when the shape is unknown or invalid. */
    fun accept(cursor: RemoteDesktopCursor): ByteString? {
        if (cursor.png.size in 1..262_144 && cursor.width > 0 && cursor.height > 0 && cursor.width <= 256 && cursor.height <= 256) {
            if (shapes.size >= 32 && cursor.shape_id !in shapes) shapes.clear()
            shapes[cursor.shape_id] = cursor.png
        }
        return shapes[cursor.shape_id]
    }

    fun clear() = shapes.clear()

    companion object {
        /**
         * Whether to show the host's cursor position instead of the local one:
         * after a display change, or when no local gesture holds the cursor and
         * the host has seen this client's latest pointer input.
         */
        fun adoptHostPosition(displayChanged: Boolean, holding: Boolean, dragging: Boolean, hostOrdinal: Long, localOrdinal: Long, sinceLocalMove: kotlin.time.Duration): Boolean =
            displayChanged || (!holding && !dragging && hostOrdinal.toULong() >= localOrdinal.toULong() && sinceLocalMove > 100.milliseconds)
    }
}

/** Android key codes to USB HID usages (page 7). */
object AndroidKeys {
    private val table: Map<Int, Int> = buildMap {
        for (index in 0..25) put(29 + index, 4 + index) // KEYCODE_A..Z
        for (index in 1..9) put(7 + index, 29 + index) // KEYCODE_1..9 -> 30..38
        put(7, 39) // KEYCODE_0
        for (index in 0..11) put(131 + index, 58 + index) // F1..F12
        putAll(
            mapOf(
                66 to 40, 111 to 41, 67 to 42, 61 to 43, 62 to 44, 69 to 45, 70 to 46, 71 to 47, 72 to 48, 73 to 49, 74 to 51, 75 to 52,
                68 to 53, 55 to 54, 56 to 55, 76 to 56, 115 to 57, 124 to 73, 122 to 74, 92 to 75, 112 to 76, 123 to 77, 93 to 78,
                22 to 79, 21 to 80, 20 to 81, 19 to 82, 113 to 224, 59 to 225, 57 to 226, 117 to 227, 114 to 228, 60 to 229, 58 to 230, 118 to 231,
            ),
        )
    }

    fun hid(keyCode: Int): Int? = table[keyCode]
}

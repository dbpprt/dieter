package com.getdieter.core.screens

import com.getdieter.api.v1.RemoteDesktopCursor
import com.getdieter.api.v1.RemoteDesktopInput
import com.getdieter.api.v1.RemoteDesktopPointerButton
import com.getdieter.api.v1.RemoteDesktopSessionState
import com.getdieter.client.v1.ScreenCommand
import kotlin.time.Clock
import kotlin.time.Duration
import kotlin.time.Instant
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

/**
 * The input of a screen session: keys, buttons, scrolls, and text in order on the reliable input
 * channel, pointer moves coalesced onto the lossy pointer channel, clipboard shortcuts, and the
 * host's cursor, which follows the host unless local input moved it last. Input flows only while
 * this client controls the host. [ScreenSession] owns it; confined to the core dispatcher.
 */
internal class ScreenInput(
    private val scope: CoroutineScope,
    private val clock: Clock,
    private val view: MutableStateFlow<ScreenView>,
    private val engine: () -> ScreenMediaEngine?,
    private val state: () -> RemoteDesktopSessionState?,
    private val recover: (String) -> Unit,
    /** Runs a clipboard operation ("copy", "cut", "paste") a shortcut asked for. */
    private val clipboard: (String) -> Unit,
) {
    /** Numbers and orders the session's input; set once its binding is verified. */
    var encoder: ScreenInputEncoder? = null

    /** When the last pointer move was sent. */
    var lastPointerAt: Instant? = null
        private set

    /**
     * Set by the gesture layer while a finger holds the cursor, so host updates do not fight it.
     */
    var holdingCursor = false

    private var pendingPointer: Pair<Double, Double>? = null
    private var pointerFlush: Job? = null
    private val cursors = CursorCache()

    private fun now() = clock.now()

    private fun sendReliable(input: RemoteDesktopInput?) {
        input ?: return
        val current = engine() ?: return
        if (!view.value.controlActive && input.release_all == null) return
        val bytes = RemoteDesktopInput.ADAPTER.encode(input)
        if (bytes.size > ScreenChannels.MAX_INPUT_BYTES) return
        pendingPointer = null
        if (
            !current.isOpen(ScreenChannels.INPUT) ||
                current.bufferedAmount(ScreenChannels.INPUT) >= ScreenChannels.BACKPRESSURE_BYTES
        ) {
            if (input.release_all == null) recover("Remote input stalled")
            return
        }
        if (!current.send(ScreenChannels.INPUT, bytes) && input.release_all == null) {
            view.update { it.copy(controlActive = false) }
            recover("Remote input could not be delivered")
        }
    }

    private fun generations(): Pair<Long, Long>? {
        val current = state() ?: return null
        return current.display_generation to current.control_generation
    }

    /**
     * The input [command] carries: a pointer move, button, scroll, key, text, or input release;
     * other members are ignored.
     */
    fun apply(command: ScreenCommand) {
        command.pointer?.let { pointer(it.x, it.y) }
        command.button?.let { button(it.button, it.down, it.clicks, it.x, it.y, it.modifiers) }
        command.scroll?.let {
            scroll(it.dx, it.dy, it.phase, it.momentum, it.modifiers, it.precise)
        }
        command.key?.let { key(it.hid, it.down, it.repeat, it.modifiers) }
        command.text?.let { text(it.text, it.modifiers) }
        command.release_input?.let { release() }
    }

    /**
     * Moves the remote pointer; moves within 4 ms of the last one are coalesced (the latest wins).
     */
    fun pointer(x: Double, y: Double) {
        if (!view.value.controlActive) return
        pendingPointer = x to y
        val last = lastPointerAt
        val elapsed = last?.let { now() - it } ?: ScreenSessionPolicy.POINTER_INTERVAL
        if (elapsed >= ScreenSessionPolicy.POINTER_INTERVAL) return flushPointer()
        if (pointerFlush?.isActive == true) return
        pointerFlush = scope.launch {
            delay(ScreenSessionPolicy.POINTER_INTERVAL - elapsed)
            flushPointer()
        }
    }

    private fun flushPointer() {
        val (x, y) = pendingPointer ?: return
        pendingPointer = null
        val (display, control) = generations() ?: return
        val current = engine() ?: return
        val input = encoder?.move(x, y, display, control) ?: return
        lastPointerAt = now()
        if (
            current.isOpen(ScreenChannels.POINTER) &&
                current.bufferedAmount(ScreenChannels.POINTER) < ScreenChannels.BACKPRESSURE_BYTES
        ) {
            current.send(ScreenChannels.POINTER, RemoteDesktopInput.ADAPTER.encode(input))
        }
    }

    /** [clicks] counts up to a triple click; the host ignores more. */
    fun button(
        button: RemoteDesktopPointerButton.Button,
        down: Boolean,
        clicks: Int,
        x: Double,
        y: Double,
        modifiers: Int,
    ) {
        val (display, control) = generations() ?: return
        sendReliable(
            encoder?.button(button, down, clicks.coerceIn(0, 3), x, y, modifiers, display, control)
        )
    }

    fun scroll(
        dx: Double,
        dy: Double,
        phase: Int,
        momentum: Int,
        modifiers: Int,
        precise: Boolean,
    ) {
        val (display, control) = generations() ?: return
        sendReliable(encoder?.scroll(dx, dy, phase, momentum, modifiers, precise, display, control))
    }

    /**
     * A physical key by USB HID usage; Command-C/X/V become clipboard operations when sharing is
     * on.
     */
    fun key(hid: Int, down: Boolean, repeat: Boolean, modifiers: Int) {
        val shortcut = ScreenInputEncoder.clipboardShortcut(hid, modifiers)
        if (
            shortcut != null &&
                down &&
                !repeat &&
                view.value.clipboardEnabled &&
                view.value.capabilities?.clipboard_supported == true
        ) {
            clipboard(shortcut)
            return
        }
        val (display, control) = generations() ?: return
        sendReliable(encoder?.key(hid, down, repeat, modifiers, display, control))
    }

    /**
     * Committed text; a single ASCII character with Control, Option, or Command held becomes a key
     * stroke.
     */
    fun text(value: String, modifiers: Int) {
        val (display, control) = generations() ?: return
        if ((modifiers and (Modifiers.CONTROL or Modifiers.OPTION or Modifiers.COMMAND)) != 0) {
            ScreenInputEncoder.stroke(value)?.let { (hid, shift) ->
                val held = modifiers or if (shift) Modifiers.SHIFT else 0
                sendReliable(encoder?.key(hid, true, false, held, display, control))
                sendReliable(encoder?.key(hid, false, false, held, display, control))
                return
            }
        }
        val chunks =
            ScreenInputEncoder.textChunks(value)
                ?: return view.update {
                    it.copy(clipboardError = "Text input is limited to 8 KB per insertion")
                }
        for (chunk in chunks) sendReliable(encoder?.text(chunk, display, control))
    }

    /** Releases every held key and button on the host. */
    fun release() {
        pointerFlush?.cancel()
        pendingPointer = null
        lastPointerAt = null
        val (display, control) = generations() ?: return
        if (!view.value.controlActive) return
        sendReliable(encoder?.releaseAll(display, control))
    }

    /**
     * The host's cursor for the current display: its shape, and its position unless local input
     * moved the pointer more recently or a finger holds it.
     */
    fun cursor(value: RemoteDesktopCursor) {
        val current = state() ?: return
        if (value.display_generation != current.display_generation) return
        val image = cursors.accept(value)
        val adopt =
            CursorCache.adoptHostPosition(
                false,
                holdingCursor,
                false,
                value.last_input_ordinal,
                encoder?.lastPointerOrdinal ?: 0,
                lastPointerAt?.let { now() - it } ?: Duration.INFINITE,
            )
        view.update {
            it.copy(
                cursorImage = image,
                cursorVisible = value.visible,
                cursorWidth = value.width,
                cursorHeight = value.height,
                cursorHotspotX = value.hotspot_x,
                cursorHotspotY = value.hotspot_y,
                cursorX = if (adopt) value.normalized_x / 1_000_000.0 else it.cursorX,
                cursorY = if (adopt) value.normalized_y / 1_000_000.0 else it.cursorY,
            )
        }
    }

    /** The display changed: cursor shapes of the old one no longer apply. */
    fun forgetCursors() {
        cursors.clear()
    }

    /** Forgets the stopped session's input; [release] frees what the host still holds. */
    fun reset() {
        pointerFlush?.cancel()
        pendingPointer = null
        lastPointerAt = null
        encoder = null
        cursors.clear()
    }
}

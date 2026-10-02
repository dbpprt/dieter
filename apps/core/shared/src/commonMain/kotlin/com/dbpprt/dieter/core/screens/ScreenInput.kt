package com.dbpprt.dieter.core.screens

import com.dbpprt.dieter.api.v1.RemoteDesktopInput
import com.dbpprt.dieter.api.v1.RemoteDesktopPointerButton
import com.dbpprt.dieter.api.v1.RemoteDesktopSessionState
import kotlin.time.Clock
import kotlin.time.Instant
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

/**
 * The input of a screen session: keys, buttons, scrolls, and text in order on
 * the reliable input channel, and pointer moves coalesced onto the lossy
 * pointer channel. Input flows only while this client controls the host.
 * [ScreenSession] owns it; confined to the core dispatcher.
 */
internal class ScreenInput(
    private val scope: CoroutineScope,
    private val clock: Clock,
    private val view: MutableStateFlow<ScreenView>,
    private val engine: () -> ScreenMediaEngine?,
    private val state: () -> RemoteDesktopSessionState?,
    private val recover: (String) -> Unit,
) {
    /** Numbers and orders the session's input; set once its binding is verified. */
    var encoder: ScreenInputEncoder? = null

    /** When the last pointer move was sent. */
    var lastPointerAt: Instant? = null
        private set
    private var pendingPointer: Pair<Double, Double>? = null
    private var pointerFlush: Job? = null

    private fun now() = clock.now()

    private fun sendReliable(input: RemoteDesktopInput?) {
        input ?: return
        val current = engine() ?: return
        if (!view.value.controlActive && input.release_all == null) return
        val bytes = RemoteDesktopInput.ADAPTER.encode(input)
        if (bytes.size > ScreenChannels.MAX_INPUT_BYTES) return
        pendingPointer = null
        if (!current.isOpen(ScreenChannels.INPUT) || current.bufferedAmount(ScreenChannels.INPUT) >= ScreenChannels.BACKPRESSURE_BYTES) {
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

    /** Moves the remote pointer; moves within 4 ms of the last one are coalesced (the latest wins). */
    fun pointer(x: Double, y: Double) {
        if (!view.value.controlActive) return
        pendingPointer = x to y
        val last = lastPointerAt
        val elapsed = last?.let { now() - it } ?: ScreenSession.POINTER_INTERVAL
        if (elapsed >= ScreenSession.POINTER_INTERVAL) return flushPointer()
        if (pointerFlush?.isActive == true) return
        pointerFlush = scope.launch {
            delay(ScreenSession.POINTER_INTERVAL - elapsed)
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
        if (current.isOpen(ScreenChannels.POINTER) && current.bufferedAmount(ScreenChannels.POINTER) < ScreenChannels.BACKPRESSURE_BYTES) {
            current.send(ScreenChannels.POINTER, RemoteDesktopInput.ADAPTER.encode(input))
        }
    }

    fun button(button: RemoteDesktopPointerButton.Button, down: Boolean, clicks: Int, x: Double, y: Double, modifiers: Int) {
        val (display, control) = generations() ?: return
        sendReliable(encoder?.button(button, down, clicks, x, y, modifiers, display, control))
    }

    fun scroll(dx: Double, dy: Double, phase: Int, momentum: Int, modifiers: Int, precise: Boolean) {
        val (display, control) = generations() ?: return
        sendReliable(encoder?.scroll(dx, dy, phase, momentum, modifiers, precise, display, control))
    }

    /** A physical key by USB HID usage. */
    fun key(hid: Int, down: Boolean, repeat: Boolean, modifiers: Int) {
        val (display, control) = generations() ?: return
        sendReliable(encoder?.key(hid, down, repeat, modifiers, display, control))
    }

    /** Committed text; a single ASCII character with Control, Option, or Command held becomes a key stroke. */
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
        val chunks = ScreenInputEncoder.textChunks(value) ?: return view.update { it.copy(clipboardError = "Text input is limited to 8 KB per insertion") }
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

    /** Forgets the stopped session's input; [release] frees what the host still holds. */
    fun reset() {
        pointerFlush?.cancel()
        pendingPointer = null
        lastPointerAt = null
        encoder = null
    }
}

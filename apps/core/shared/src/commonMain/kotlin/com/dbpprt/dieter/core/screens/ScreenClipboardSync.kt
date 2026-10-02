package com.dbpprt.dieter.core.screens

import com.dbpprt.dieter.api.v1.RemoteDesktopClipboardFrame
import com.dbpprt.dieter.api.v1.RemoteDesktopClipboardItem
import com.dbpprt.dieter.api.v1.RemoteDesktopClipboardRequest
import com.dbpprt.dieter.api.v1.RemoteDesktopClipboardResponse
import com.dbpprt.dieter.api.v1.RemoteDesktopSessionBinding
import com.dbpprt.dieter.api.v1.RemoteDesktopSessionState
import com.dbpprt.dieter.core.runtime.withDeadline
import kotlin.coroutines.cancellation.CancellationException
import kotlin.time.Duration.Companion.milliseconds
import kotlin.uuid.Uuid
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import okio.ByteString.Companion.toByteString

/**
 * The clipboard of a screen session: user copy, cut, and paste, the sharing
 * switch, and the background sync that keeps both clipboards in step, each a
 * framed exchange on the clipboard channel. [ScreenSession] owns it;
 * confined to the core dispatcher.
 */
internal class ScreenClipboardSync(
    private val localClipboard: LocalClipboard?,
    private val view: MutableStateFlow<ScreenView>,
    private val engine: () -> ScreenMediaEngine?,
    private val binding: () -> RemoteDesktopSessionBinding?,
    private val state: () -> RemoteDesktopSessionState?,
    private val sessionId: () -> String,
    /** The input barrier a clipboard operation is ordered after. */
    private val inputBarrier: () -> Long,
) {
    private var assembler: ClipboardFraming.Assembler? = null
    private var reply: CompletableDeferred<RemoteDesktopClipboardResponse>? = null
    private var revision = ""
    private var localStamp: Long? = null
    private var grant = -1L

    /** One clipboard exchange at a time; the background sync skips while one runs. */
    private val exchangeLock = Mutex()

    /** A user copy, cut, paste, or sharing change is pending; a second one is refused. */
    private var operationPending = false

    /** A frame on the clipboard channel; a complete reply answers the exchange in flight. */
    fun message(bytes: ByteArray) {
        val current = assembler ?: return
        try {
            val payload = current.accept(bytes.toByteString()) ?: return
            assembler = null
            reply?.complete(RemoteDesktopClipboardResponse.ADAPTER.decode(payload))
        } catch (error: Throwable) {
            assembler = null
            reply?.completeExceptionally(error)
            engine()?.let { runCatching { it.send(ScreenChannels.CLIPBOARD, ByteArray(0)) } }
        }
    }

    private suspend fun exchange(request: RemoteDesktopClipboardRequest): RemoteDesktopClipboardResponse {
        val current = engine() ?: throw IllegalStateException("Clipboard channel closed")
        val operationId = request.operation_id
        val pending = CompletableDeferred<RemoteDesktopClipboardResponse>()
        reply = pending
        assembler = ClipboardFraming.Assembler(operationId)
        for (frame in ClipboardFraming.frames(operationId, RemoteDesktopClipboardRequest.ADAPTER.encodeByteString(request))) {
            while (current.bufferedAmount(ScreenChannels.CLIPBOARD) > ClipboardFraming.BUFFER_LIMIT) delay(5.milliseconds)
            if (!current.send(ScreenChannels.CLIPBOARD, RemoteDesktopClipboardFrame.ADAPTER.encode(frame))) throw IllegalStateException("Clipboard transfer failed")
        }
        val response = withDeadline(ScreenSession.CLIPBOARD_TIMEOUT, "Clipboard transfer timed out") { pending.await() }
        if (response.error.isNotEmpty()) throw IllegalStateException(response.error)
        return response
    }

    private fun newRequest(action: RemoteDesktopClipboardRequest.Action, text: String = "", items: List<RemoteDesktopClipboardItem> = emptyList()): RemoteDesktopClipboardRequest? {
        val bound = binding() ?: return null
        val current = state() ?: return null
        return RemoteDesktopClipboardRequest(
            session_id = sessionId(), operation_id = Uuid.random().toString(), input_epoch = bound.input_epoch, control_generation = current.control_generation,
            action = action, text = text, known_revision = revision, enabled = view.value.clipboardEnabled,
            input_barrier = inputBarrier(), items = items, accept_binary = view.value.capabilities?.binary_clipboard_supported == true,
        )
    }

    /** Copy, cut, or paste on the host; waits for a background exchange in flight, then reads the current clipboard. */
    suspend fun perform(operation: String) {
        val local = localClipboard ?: return
        if (operationPending) return view.update { it.copy(clipboardError = "A clipboard operation is still in progress") }
        operationPending = true
        view.update { it.copy(clipboardBusy = true) }
        try {
            exchangeLock.withLock {
                val binary = view.value.capabilities?.binary_clipboard_supported == true
                val request = when (operation) {
                    "paste" -> {
                        val (text, items) = local.read(binary = true) ?: ("" to emptyList())
                        if (items.isNotEmpty() && !binary) return view.update { it.copy(clipboardError = "Update the daemon to paste images and files") }
                        ClipboardContent.validate(text, items)?.let { return view.update { shown -> shown.copy(clipboardError = it) } }
                        newRequest(RemoteDesktopClipboardRequest.Action.PASTE, text, items)
                    }
                    "cut" -> newRequest(RemoteDesktopClipboardRequest.Action.CUT)
                    else -> newRequest(RemoteDesktopClipboardRequest.Action.COPY)
                } ?: return
                val stamp = local.stamp()
                val response = exchange(request)
                if (operation != "paste" && (response.has_text || response.items.isNotEmpty()) && view.value.clipboardEnabled && local.stamp() == stamp) {
                    local.apply(response.text, response.items)
                    localStamp = local.stamp()
                }
                if (response.revision.isNotEmpty()) revision = response.revision
                view.update { it.copy(clipboardError = null, clipboardOperations = it.clipboardOperations + 1) }
            }
        } catch (error: Throwable) {
            if (error is CancellationException) throw error
            view.update { it.copy(clipboardError = error.message ?: "Clipboard transfer failed") }
        } finally {
            operationPending = false
            view.update { it.copy(clipboardBusy = false) }
        }
    }

    /** Asks the host to turn sharing on or off. */
    suspend fun setEnabled(enabled: Boolean) {
        if (operationPending) return view.update { it.copy(clipboardError = "A clipboard operation is still in progress") }
        newRequest(RemoteDesktopClipboardRequest.Action.CONFIGURE) ?: return
        operationPending = true
        view.update { it.copy(clipboardBusy = true) }
        try {
            exchangeLock.withLock {
                val request = newRequest(RemoteDesktopClipboardRequest.Action.CONFIGURE)?.copy(enabled = enabled) ?: return
                exchange(request)
                view.update { it.copy(clipboardEnabled = enabled, clipboardError = null) }
            }
        } catch (error: Throwable) {
            if (error is CancellationException) throw error
            view.update { it.copy(clipboardError = error.message ?: "Clipboard sharing could not be updated") }
        } finally {
            operationPending = false
            view.update { it.copy(clipboardBusy = false) }
        }
    }

    /**
     * Keeps both clipboards in step every 250 ms while this client controls
     * the host, until [active] turns false. A failed or unanswered exchange
     * is shown and the next poll tries again.
     */
    suspend fun sync(active: () -> Boolean) {
        val local = localClipboard ?: return
        while (active()) {
            delay(ScreenSession.CLIPBOARD_POLL)
            val current = state() ?: continue
            if (!view.value.clipboardEnabled || !view.value.controlActive || operationPending || engine()?.isOpen(ScreenChannels.CLIPBOARD) != true) continue
            if (grant != current.control_generation) {
                grant = current.control_generation
                revision = ""
                localStamp = local.stamp()
            }
            if (!exchangeLock.tryLock()) continue
            try {
                val stamp = local.stamp()
                if (localStamp != null && stamp != localStamp) {
                    localStamp = stamp
                    val (text, items) = local.read(binary = view.value.capabilities?.binary_clipboard_supported == true) ?: continue
                    if (text.isEmpty() && items.isEmpty() || ClipboardContent.validate(text, items) != null) continue
                    val response = exchange(newRequest(RemoteDesktopClipboardRequest.Action.WRITE, text, items) ?: continue)
                    revision = response.revision
                } else {
                    val previous = revision
                    val response = exchange(newRequest(RemoteDesktopClipboardRequest.Action.READ) ?: continue)
                    if (grant != (state()?.control_generation ?: -1)) continue
                    revision = response.revision
                    if (previous.isNotEmpty() && response.changed && (response.has_text || response.items.isNotEmpty()) && local.stamp() == stamp) {
                        local.apply(response.text, response.items)
                        localStamp = local.stamp()
                    }
                    if (localStamp == null) localStamp = stamp
                }
            } catch (error: Throwable) {
                if (error is CancellationException) throw error
                view.update { it.copy(clipboardError = error.message) }
            } finally {
                exchangeLock.unlock()
            }
        }
    }

    /** The host's clipboard generation changed: the sync takes a new baseline. */
    fun rebase() {
        revision = ""
        localStamp = null
    }

    /**
     * Forgets the stopped session's clipboard. An exchange waiting for its
     * reply is cancelled now, releasing the exchange lock, rather than
     * holding the next session until it times out.
     */
    fun reset() {
        reply?.cancel()
        reply = null
        assembler = null
        revision = ""
        localStamp = null
        grant = -1
        operationPending = false
    }
}

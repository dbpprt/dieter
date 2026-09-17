package com.dbpprt.dieter.screens

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import com.dbpprt.dieter.v1.*
import kotlinx.coroutines.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import org.webrtc.DataChannel
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.util.UUID

/** Independent reliable channel; payloads never enter the video/input queues. */
class ScreenClipboard(context: Context, private val scope: CoroutineScope) {
    companion object { const val LIMIT = 1 shl 20 }
    private val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
    var request: (() -> RemoteDesktopClipboardRequest.Builder?)? = null
    var onBusy: (Boolean) -> Unit = {}
    var onOperationFinished: (Boolean) -> Unit = {}
    var isCurrentGrant: ((Long) -> Boolean)? = null
    var onError: (String) -> Unit = {}
    var enabled = true
        set(value) {
            if (field != value) { revision = ""; localTimestamp = clipboard.primaryClipDescription?.timestamp ?: 0 }
            field = value
        }
    var completedOperations = 0; private set
    var operationPending = false; private set
    private var channel: DataChannel? = null
    private var polling: Job? = null
    private var response: CompletableDeferred<RemoteDesktopClipboardResponse>? = null
    private var requestId = ""
    private val buffer = ByteArrayOutputStream()
    private val mutex = Mutex()
    private var token = 0L
    private var revision = ""
    private var grant = 0L
    private var localTimestamp = 0L

    fun attach(value: DataChannel) {
        close(); channel = value
        localTimestamp = clipboard.primaryClipDescription?.timestamp ?: 0
        val current = token
        value.registerObserver(object : DataChannel.Observer {
            override fun onBufferedAmountChange(previousAmount: Long) = Unit
            override fun onStateChange() = Unit
            override fun onMessage(message: DataChannel.Buffer) {
                if (!message.binary || message.data.remaining() > 16 * 1024 + 128) return
                val raw = ByteArray(message.data.remaining()); message.data.get(raw)
                scope.launch {
                    if (current != token || response == null) return@launch
                    try {
                        val frame = RemoteDesktopClipboardFrame.parseFrom(raw)
                        require(frame.operationId == requestId && frame.data.size() <= 16 * 1024 && buffer.size() + frame.data.size() <= LIMIT + 4096)
                        buffer.write(frame.data.toByteArray())
                        if (frame.end) response?.complete(RemoteDesktopClipboardResponse.parseFrom(buffer.toByteArray()))
                    } catch (e: Exception) { response?.completeExceptionally(e); value.close() }
                }
            }
        })
        polling = scope.launch {
            while (isActive && current == token) {
                delay(250)
                val context = request?.invoke() ?: continue
                if (!enabled || value.state() != DataChannel.State.OPEN || mutex.isLocked || operationPending) continue
                if (grant != context.controlGeneration) { grant = context.controlGeneration; revision = ""; localTimestamp = clipboard.primaryClipDescription?.timestamp ?: 0 }
                try {
                    val stamp = clipboard.primaryClipDescription?.timestamp ?: 0
                    if (stamp != localTimestamp) {
                        localTimestamp = stamp
                        val text = localText()
                        if (text != null) revision = exchange(RemoteDesktopClipboardRequest.Action.WRITE, text).revision
                    } else {
                        val previous = revision
                        val result = exchange(RemoteDesktopClipboardRequest.Action.READ)
                        if (request?.invoke()?.controlGeneration != context.controlGeneration) continue
                        revision = result.revision
                        if (previous.isNotEmpty() && result.changed && result.hasText && (clipboard.primaryClipDescription?.timestamp ?: 0) == stamp && localText() != result.text) {
                            clipboard.setPrimaryClip(ClipData.newPlainText("Remote screen", result.text))
                            localTimestamp = clipboard.primaryClipDescription?.timestamp ?: 0
                        }
                    }
                } catch (e: TimeoutCancellationException) { onError("Clipboard timed out; reconnect to resume sharing")
                } catch (e: CancellationException) { throw e
                } catch (e: Exception) { onError(e.message ?: "Clipboard unavailable") }
            }
        }
    }
    private fun localText(): String? = clipboard.primaryClip?.getItemAt(0)?.text?.toString()
    fun paste() {
        val text = localText()
        if (text == null) { onError("Clipboard has no text"); return }
        perform(RemoteDesktopClipboardRequest.Action.PASTE, text)
    }
    fun copy() = perform(RemoteDesktopClipboardRequest.Action.COPY)
    fun configure(value: Boolean) {
        enabled = value
        val current = token
        val context = request?.invoke()
        scope.launch {
            if (current != token) return@launch
            try { exchange(RemoteDesktopClipboardRequest.Action.CONFIGURE, enabled = value, initial = context); revision = ""; localTimestamp = clipboard.primaryClipDescription?.timestamp ?: 0 }
            catch (e: TimeoutCancellationException) { if (current == token) onError("Clipboard timed out; sharing could not be updated") }
            catch (e: CancellationException) { throw e }
            catch (e: Exception) { if (current == token) onError(e.message ?: "Clipboard unavailable") }
        }
    }
    fun perform(action: RemoteDesktopClipboardRequest.Action, text: String = "") {
        if (!enabled) return
        if (operationPending) { onError("A clipboard operation is still in progress"); return }
        val context = request?.invoke() ?: return
        operationPending = true; onBusy(true)
        val current = token
        val stamp = clipboard.primaryClipDescription?.timestamp ?: 0
        scope.launch {
            var succeeded = false
            try {
                val result = exchange(action, text, initial = context)
                if (current == token) {
                    revision = result.revision
                    if ((action == RemoteDesktopClipboardRequest.Action.COPY || action == RemoteDesktopClipboardRequest.Action.CUT) && result.hasText && enabled && (clipboard.primaryClipDescription?.timestamp ?: 0) == stamp) {
                        clipboard.setPrimaryClip(ClipData.newPlainText("Remote screen", result.text))
                        localTimestamp = clipboard.primaryClipDescription?.timestamp ?: 0
                    } else { localTimestamp = stamp }
                    completedOperations++; succeeded = true; onError("")
                }
            } catch (e: TimeoutCancellationException) { if (current == token) onError("Clipboard timed out; shortcut was not retried")
            } catch (e: CancellationException) { throw e
            } catch (e: Exception) { if (current == token) onError(e.message ?: "Clipboard unavailable")
            } finally { if (current == token) { operationPending = false; onBusy(false); onOperationFinished(succeeded) } }
        }
    }
    suspend fun exchange(action: RemoteDesktopClipboardRequest.Action, text: String = "", enabled: Boolean = true, initial: RemoteDesktopClipboardRequest.Builder? = null): RemoteDesktopClipboardResponse {
        require(text.toByteArray().size <= LIMIT) { "Clipboard text exceeds 1 MiB" }
        val current = token
        return withTimeout(5000) { mutex.withLock {
            val value = channel ?: error("Clipboard unavailable")
            val builder = initial ?: request?.invoke() ?: error("Clipboard requires the active controller")
            check(current == token && value.state() == DataChannel.State.OPEN && (isCurrentGrant?.invoke(builder.controlGeneration) ?: true))
            val req = builder.setOperationId(UUID.randomUUID().toString()).setAction(action).setText(text).setKnownRevision(revision).setEnabled(enabled).build()
            requestId = req.operationId; buffer.reset()
            val pending = CompletableDeferred<RemoteDesktopClipboardResponse>(); response = pending
            try {
                val raw = req.toByteArray()
                var offset = 0
                while (offset < raw.size) {
                    while (value.bufferedAmount() > 32 * 1024) delay(5)
                    check(current == token)
                    val end = minOf(offset + 16 * 1024, raw.size)
                    val frame = RemoteDesktopClipboardFrame.newBuilder().setOperationId(req.operationId)
                        .setData(com.google.protobuf.ByteString.copyFrom(raw, offset, end - offset)).setEnd(end == raw.size).build()
                    check(value.send(DataChannel.Buffer(ByteBuffer.wrap(frame.toByteArray()), true))) { "Clipboard transfer failed" }
                    offset = end; delay(1)
                }
                val result = pending.await()
                check(current == token && (isCurrentGrant?.invoke(req.controlGeneration) ?: (request?.invoke()?.controlGeneration == req.controlGeneration))) { "Clipboard control changed" }
                check(result.error.isEmpty()) { result.error }
                result
            } catch (e: TimeoutCancellationException) { value.close(); throw e
            } finally { if (current == token) { response = null; requestId = ""; buffer.reset() } }
        } }
    }
    fun close() {
        token++; polling?.cancel(); polling = null
        response?.cancel(); response = null
        channel?.unregisterObserver(); channel?.close(); channel?.dispose(); channel = null
        revision = ""; grant = 0; buffer.reset(); operationPending = false
    }
}

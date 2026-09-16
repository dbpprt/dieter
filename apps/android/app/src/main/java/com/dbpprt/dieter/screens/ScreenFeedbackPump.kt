package com.dbpprt.dieter.screens

import android.os.SystemClock
import com.dbpprt.dieter.v1.RemoteDesktopReceiverFeedback
import kotlinx.coroutines.*
import org.webrtc.DataChannel
import java.nio.ByteBuffer

/** Receiver liveness must not await signaling, getStats, rendering, or the UI. */
internal class ScreenFeedbackPump(
    private val clock: () -> Long = SystemClock::elapsedRealtime,
    private val sendFeedback: ((RemoteDesktopReceiverFeedback) -> Unit)? = null,
) {
    private val lock = Any()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private var job: Job? = null
    private var channel: DataChannel? = null
    private var feedback = RemoteDesktopReceiverFeedback.getDefaultInstance()
    private var sequence = 0L
    private var generation = 0L
    private var inputActive = false
    private var inputUpdatedAt = 0L

    fun start(channel: DataChannel?, initial: RemoteDesktopReceiverFeedback) = synchronized(lock) {
        job?.cancel()
        val current = ++generation
        this.channel = channel
        feedback = initial
        sequence = 0L
        job = scope.launch {
            while (isActive) {
                delay(500)
                synchronized(lock) {
                    val target = this@ScreenFeedbackPump.channel
                    if (current == generation && (sendFeedback != null || target != null && target.state() == DataChannel.State.OPEN && target.bufferedAmount() < 16384)) {
                        val value = feedback.toBuilder().setSequence(++sequence)
                            .setInputActive(inputActive && clock() - inputUpdatedAt < 1_000).build()
                        if (sendFeedback != null) sendFeedback.invoke(value)
                        else target?.send(DataChannel.Buffer(ByteBuffer.wrap(value.toByteArray()), true))
                    }
                }
            }
        }
    }

    fun update(value: RemoteDesktopReceiverFeedback) = synchronized(lock) { feedback = value }
    fun input(active: Boolean) = synchronized(lock) {
        inputActive = active
        inputUpdatedAt = clock()
    }

    // Serialize with sends before the controller disposes the native channel.
    fun stop() = synchronized(lock) {
        generation++; job?.cancel(); job = null; channel = null; inputActive = false
    }
}

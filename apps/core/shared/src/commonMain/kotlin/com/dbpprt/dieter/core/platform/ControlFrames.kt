package com.dbpprt.dieter.core.platform

import kotlin.concurrent.atomics.AtomicInt
import kotlin.concurrent.atomics.ExperimentalAtomicApi

/**
 * The control data channel's framing, shared by every [ControlChannel]: a
 * data frame is `0x00` followed by up to [MAX_PAYLOAD] bytes of the TLS
 * stream, and each delivered data frame is acknowledged by a lone `0x01`.
 * A sender keeps at most [WINDOW] data frames unacknowledged. Anything else
 * is a protocol violation and closes the channel.
 */
object ControlFrames {
    const val LABEL = "dieter-control-tls-v1"
    const val MAX_FRAME = 16_384
    const val MAX_PAYLOAD = MAX_FRAME - 1
    const val WINDOW = 16

    /** Largest SDP either side may send. */
    const val MAX_SDP_BYTES = 65_536

    private const val DATA: Byte = 0
    private const val ACK: Byte = 1

    val ack: ByteArray get() = byteArrayOf(ACK)

    sealed interface Frame {
        class Data(val payload: ByteArray) : Frame
        data object Ack : Frame
    }

    /** A data frame of [payload]'s first [count] bytes. */
    fun data(payload: ByteArray, count: Int = payload.size): ByteArray {
        require(count in 1..MAX_PAYLOAD) { "control frame payload must be 1..$MAX_PAYLOAD bytes" }
        return ByteArray(count + 1).also { payload.copyInto(it, 1, 0, count) }
    }

    /** The frame in [message], or null for a protocol violation. */
    fun decode(message: ByteArray, binary: Boolean = true): Frame? = when {
        !binary || message.size !in 1..MAX_FRAME -> null
        message[0] == ACK && message.size == 1 -> Frame.Ack
        message[0] == DATA && message.size > 1 -> Frame.Data(message.copyOfRange(1, message.size))
        else -> null
    }
}

/**
 * The send window's accounting: a data frame may go out only while fewer
 * than [ControlFrames.WINDOW] are unacknowledged, and an acknowledgement for
 * a frame never sent is a violation. Safe from any thread.
 */
@OptIn(ExperimentalAtomicApi::class)
class ControlWindow {
    private val outstanding = AtomicInt(0)

    /** Reserves room for one data frame; false when the window is full. */
    fun reserve(): Boolean {
        while (true) {
            val current = outstanding.load()
            if (current >= ControlFrames.WINDOW) return false
            if (outstanding.compareAndSet(current, current + 1)) return true
        }
    }

    /** Records an acknowledgement; false when nothing was outstanding. */
    fun acknowledge(): Boolean {
        while (true) {
            val current = outstanding.load()
            if (current <= 0) return false
            if (outstanding.compareAndSet(current, current - 1)) return true
        }
    }

    val inFlight: Int get() = outstanding.load()
}

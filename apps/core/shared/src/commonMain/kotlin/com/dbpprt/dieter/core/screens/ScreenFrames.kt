package com.dbpprt.dieter.core.screens

import com.dbpprt.dieter.api.v1.RemoteDesktopReceiverFeedback
import com.dbpprt.dieter.api.v1.RemoteDesktopRenderMeasurement
import com.dbpprt.dieter.core.runtime.CoreLock
import kotlin.math.max

/**
 * Holds one decoded frame while reliable generation metadata catches up.
 * Video can beat SCTP; dropping that sole frame would freeze an idle new
 * display. Safe for decoder callbacks on any thread.
 */
class ScreenFrameGate<F>(
    private val timestamp: (F) -> UInt,
    private val retain: (F) -> Unit,
    private val release: (F) -> Unit,
    private val millisecondQuantized: Boolean = true,
    private val emit: (F, Long) -> Unit,
) {
    private val lock = CoreLock()
    private var epoch = -1L
    private var display = 0L
    private var media = 0L
    private var boundary = 0u
    private var pending: F? = null

    /**
     * Reliable display metadata can follow the first decoded frame. That frame
     * is kept across display changes; the RTP boundary decides whether it
     * belongs. Only a session change ([token]) invalidates it outright.
     */
    fun update(token: Long, display: Long, media: Long, boundary: UInt) = lock.locked {
        if (token != epoch) discard()
        epoch = token
        this.display = display
        this.media = media
        this.boundary = boundary
        if (ready()) {
            pending?.let { frame ->
                pending = null
                try {
                    if (belongs(frame)) emit(frame, epoch)
                } finally {
                    release(frame)
                }
            }
        }
    }

    fun offer(frame: F, token: Long) = lock.locked {
        if (token != epoch) return@locked
        if (ready()) {
            if (belongs(frame)) emit(frame, token)
        } else {
            retain(frame)
            discard()
            pending = frame
        }
    }

    fun clear() = lock.locked {
        discard()
        epoch = -1
        display = 0
        media = 0
    }

    private fun belongs(frame: F) = ScreenStates.belongsToGeneration(timestamp(frame), boundary, millisecondQuantized)

    private fun ready() = display > 0 && media == display

    private fun discard() {
        pending?.let(release)
        pending = null
    }

    companion object {
        /** A decoder timestamp carrying RTP time as floor(timestamp / 90) milliseconds, back on the 32-bit RTP clock. */
        fun rtp(decoderNanos: Long): UInt = ((decoderNanos / 1_000_000L) * 90L).toUInt()
    }
}

/** Cumulative receiver counters the media engine reports, sampled at [atMillis]. */
data class ReceiverSample(
    val atMillis: Long,
    val framesDecoded: Double,
    val totalDecodeTime: Double,
    val jitterBufferEmittedCount: Double,
    val jitterBufferDelay: Double,
    val packetsLost: Double,
    val packetsReceived: Double,
    val presented: Long,
    val renderMs: Double,
    val jitterSeconds: Double,
    val roundTripSeconds: Double,
    val measurement: RemoteDesktopRenderMeasurement,
)

/** How the platform decoder was configured. */
data class DecoderReport(val implementation: String, val hardware: Boolean, val lowLatencyAccepted: Boolean, val reason: String)

/** Turns successive samples into the feedback the host adapts its stream to. */
class ReceiverStatistics {
    private var previous: ReceiverSample? = null
    private var samples = 0

    /** The feedback and presented frame rate since the previous sample. */
    fun next(sample: ReceiverSample, decoder: DecoderReport?): Pair<RemoteDesktopReceiverFeedback, Double> {
        val before = previous ?: sample
        samples++
        fun delta(read: (ReceiverSample) -> Double) = max(0.0, read(sample) - read(before))
        val elapsed = max(0.001, (sample.atMillis - before.atMillis) / 1000.0)
        val presented = delta { it.presented.toDouble() }
        val decoded = delta { it.framesDecoded }
        val emitted = delta { it.jitterBufferEmittedCount }
        val lost = delta { it.packetsLost }
        val fps = presented / elapsed
        previous = sample
        val feedback = RemoteDesktopReceiverFeedback(
            frames_per_second = fps,
            rendered_frames = sample.presented.coerceAtMost(Int.MAX_VALUE.toLong()).toInt(),
            decode_ms = if (decoded > 0) delta { it.totalDecodeTime } * 1000 / decoded else 0.0,
            render_ms = delta { it.renderMs } / max(1.0, presented),
            render_measurement = sample.measurement,
            jitter_ms = sample.jitterSeconds * 1000,
            jitter_buffer_ms = if (emitted > 0) delta { it.jitterBufferDelay } * 1000 / emitted else 0.0,
            rtt_ms = sample.roundTripSeconds * 1000,
            loss_fraction = lost / max(1.0, lost + delta { it.packetsReceived }),
            decoder_implementation = decoder?.implementation?.take(256).orEmpty(),
            decoder_hardware = decoder?.hardware,
            decoder_low_latency_accepted = decoder?.lowLatencyAccepted,
            decoder_configuration_reason = decoder?.reason?.take(256).orEmpty(),
        )
        return feedback to fps
    }

    /**
     * Frames decode but none were ever presented: the decoder does not report
     * rendering to its output surface (some vendor codecs), so that surface
     * should be retired once.
     */
    fun presentationMissing(sample: ReceiverSample): Boolean = sample.presented == 0L && samples >= 6 && sample.framesDecoded > 0
}

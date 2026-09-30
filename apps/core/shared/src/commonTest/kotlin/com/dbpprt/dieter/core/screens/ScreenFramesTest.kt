package com.dbpprt.dieter.core.screens

import com.dbpprt.dieter.api.v1.RemoteDesktopRenderMeasurement
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class ScreenFramesTest {
    private class Frame(val ns: Long, var references: Int = 0)

    private fun gate(shown: MutableList<Frame>) =
        ScreenFrameGate<Frame>({ ScreenFrameGate.rtp(it.ns) }, { it.references++ }, { it.references-- }) { frame, _ -> shown.add(frame) }

    @Test fun decoderTimestampsMapBackOntoTheRtpClock() {
        assertEquals(180u, ScreenFrameGate.rtp(2_000_000))
        assertEquals(90u, ScreenFrameGate.rtp(1_999_999))
    }

    @Test fun frameCanArriveBeforeDisplayMetadata() {
        val shown = mutableListOf<Frame>()
        val gate = gate(shown)
        gate.update(1, 0, 0, 0u)
        val frame = Frame(2_000_000)
        gate.offer(frame, 1)
        gate.update(1, 1, 0, 0u)
        assertEquals(1, frame.references)
        gate.update(1, 1, 1, 180u)
        assertEquals(listOf(frame), shown)
        assertEquals(0, frame.references)
    }

    @Test fun firstIdleFrameWaitsForMetadataAndLateEpochsCannotShow() {
        val shown = mutableListOf<Frame>()
        val gate = gate(shown)
        gate.update(1, 1, 0, 0u)
        val old = Frame(1_000_000)
        val first = Frame(2_000_000)
        gate.offer(old, 1)
        gate.offer(first, 1)
        assertEquals(0, old.references)
        assertEquals(1, first.references)
        assertTrue(shown.isEmpty())
        gate.update(1, 1, 1, 180u)
        assertEquals(listOf(first), shown)
        assertEquals(0, first.references)
        gate.update(1, 2, 1, 180u)
        gate.offer(old, 1)
        gate.update(1, 2, 2, 270u)
        assertEquals(listOf(first), shown)
        assertEquals(0, old.references)
        gate.update(2, 1, 0, 0u)
        gate.offer(first, 1)
        assertEquals(0, first.references)
        gate.offer(first, 2)
        gate.clear()
        gate.clear()
        assertEquals(0, first.references)
    }

    @Test fun receiverStatisticsReportRatesSinceThePreviousSample() {
        fun sample(at: Long, presented: Long, decoded: Double, decodeTime: Double, lost: Double, received: Double) = ReceiverSample(
            atMillis = at, framesDecoded = decoded, totalDecodeTime = decodeTime, jitterBufferEmittedCount = decoded, jitterBufferDelay = decoded * 0.02,
            packetsLost = lost, packetsReceived = received, presented = presented, renderMs = presented * 2.0, jitterSeconds = 0.004, roundTripSeconds = 0.03,
            measurement = RemoteDesktopRenderMeasurement.entries.last(),
        )
        val statistics = ReceiverStatistics()
        val (first, firstFps) = statistics.next(sample(0, 0, 0.0, 0.0, 0.0, 0.0), DecoderReport("c2.qti.avc.decoder", hardware = true, lowLatencyAccepted = true, reason = ""))
        assertEquals(0.0, firstFps)
        assertEquals("c2.qti.avc.decoder", first.decoder_implementation)
        val (feedback, fps) = statistics.next(sample(1_000, 60, 60.0, 0.3, 1.0, 99.0), null)
        assertEquals(60.0, fps)
        assertEquals(60, feedback.rendered_frames)
        assertEquals(5.0, feedback.decode_ms, 1e-9)
        assertEquals(2.0, feedback.render_ms, 1e-9)
        assertEquals(20.0, feedback.jitter_buffer_ms, 1e-9)
        assertEquals(0.01, feedback.loss_fraction, 1e-9)
        assertEquals(30.0, feedback.rtt_ms, 1e-9)
        assertEquals("", feedback.decoder_implementation)
    }

    @Test fun missingPresentationIsReportedOnlyAfterSteadyDecoding() {
        val statistics = ReceiverStatistics()
        fun sample(at: Long, decoded: Double) = ReceiverSample(at, decoded, 0.0, 0.0, 0.0, 0.0, 0.0, presented = 0, renderMs = 0.0, jitterSeconds = 0.0, roundTripSeconds = 0.0, measurement = RemoteDesktopRenderMeasurement.entries.first())
        repeat(5) { statistics.next(sample(it * 1_000L, it * 30.0), null) }
        assertFalse(statistics.presentationMissing(sample(5_000, 150.0)))
        statistics.next(sample(5_000, 150.0), null)
        assertTrue(statistics.presentationMissing(sample(6_000, 180.0)))
        assertFalse(statistics.presentationMissing(sample(6_000, 180.0).copy(presented = 1)))
    }
}

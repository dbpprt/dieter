package com.dbpprt.dieter.screens

import com.dbpprt.dieter.v1.RemoteDesktopReference
import org.junit.Assert.*
import org.junit.Test

class ScreenReferenceReceiverTest {
    private fun reference(frame: Long, timestamp: Int, generation: Long = 1) = RemoteDesktopReference.newBuilder()
        .setGeneration(generation).setFrameId(frame).setRtpTimestamp(timestamp).build()

    @Test fun acknowledgesOnlyActualDecoderOutputInEitherOrder() {
        var now = 10L
        val acknowledgments = mutableListOf<RemoteDesktopReference>()
        val receiver = ScreenReferenceReceiver({ now }) { acknowledgments.addAll(it) }
        val first = reference(1, 90_025)
        receiver.expect(first)
        receiver.decoded(999_000_000)
        assertTrue(acknowledgments.isEmpty())
        receiver.decoded(1_000_000_000)
        assertEquals(listOf(first), acknowledgments)
        // Android decoders expose the millisecond-quantized unsigned RTP clock.
        val wrapped = reference(2, -1234)
        receiver.decoded(((wrapped.rtpTimestamp.toLong() and 0xffff_ffffL) / 90L) * 1_000_000L)
        receiver.expect(wrapped)
        assertEquals(listOf(first, wrapped), acknowledgments)
        now += 2_001
        receiver.expect(reference(3, 90_025))
        assertEquals(2, acknowledgments.size)
        receiver.stop()
        receiver.decoded(1_000_000_000)
        receiver.expect(reference(4, 90_025))
        assertEquals(2, acknowledgments.size)
    }

    @Test fun expiresChallengesAndRejectsOldGenerationsWithBoundedHistory() {
        var now = 1L
        val acknowledgments = mutableListOf<RemoteDesktopReference>()
        val receiver = ScreenReferenceReceiver({ now }) { acknowledgments.addAll(it) }
        receiver.expect(reference(1, 90))
        now += 2_001
        receiver.decoded(1_000_000)
        assertTrue(acknowledgments.isEmpty())
        for (id in 2L..10L) receiver.expect(reference(id, (id * 90).toInt(), 2))
        receiver.decoded(2_000_000)
        receiver.expect(reference(11, 180, 1))
        assertTrue(acknowledgments.isEmpty())
        receiver.decoded(10_000_000)
        assertEquals(listOf(10L), acknowledgments.map { it.frameId })
        receiver.expect(reference(12, 270, 3))
        receiver.decoded(3_000_000)
        assertEquals(listOf(10L, 12L), acknowledgments.map { it.frameId })
    }

    @Test fun dequeueAndTextureCallbacksDoNotHalveReferenceHistory() {
        var now = 1L
        val acknowledgments = mutableListOf<RemoteDesktopReference>()
        val receiver = ScreenReferenceReceiver({ now }) { acknowledgments.addAll(it) }
        for (frame in 1L..128L) {
            receiver.decoded(frame * 1_000_000)
            receiver.decoded(frame * 1_000_000)
        }
        val first = reference(1, 90)
        receiver.expect(first)
        assertEquals(listOf(first), acknowledgments)
        now += 1_000
        receiver.decoded(1_000_000)
        now += 1_001
        receiver.expect(reference(2, 90))
        assertEquals("A duplicate output cannot refresh decode age", listOf(first), acknowledgments)
    }
}

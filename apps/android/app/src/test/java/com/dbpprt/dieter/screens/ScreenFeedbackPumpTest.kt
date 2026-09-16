package com.dbpprt.dieter.screens

import com.dbpprt.dieter.v1.RemoteDesktopReceiverFeedback
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.CopyOnWriteArrayList
import org.junit.Assert.*
import org.junit.Test

class ScreenFeedbackPumpTest {
    @Test fun feedbackSurvivesMissingStatisticsAndInputExpiresSafely() {
        val sent = CopyOnWriteArrayList<RemoteDesktopReceiverFeedback>()
        val latch = CountDownLatch(3)
        val pump = ScreenFeedbackPump(clock = { System.nanoTime() / 1_000_000 }, sendFeedback = {
            sent += it
            latch.countDown()
        })
        try {
            pump.start(null, RemoteDesktopReceiverFeedback.newBuilder().setProtocolVersion(2).build())
            pump.input(true)
            // The controller/statistics/lease never run again during this wait.
            assertTrue("Receiver liveness stalled with its controller", latch.await(3, TimeUnit.SECONDS))
            assertEquals(listOf(1L, 2L, 3L), sent.take(3).map { it.sequence })
            assertFalse("Stale UI focus kept input active", sent.last().inputActive)
            pump.stop()
            val count = sent.size
            Thread.sleep(600)
            assertEquals(count, sent.size)
        } finally { pump.stop() }
    }
    @Test fun heartbeatsPreserveMeasurementIdentityAndAge() {
        val sent = CopyOnWriteArrayList<RemoteDesktopReceiverFeedback>()
        val repeated = CountDownLatch(2)
        val fresh = CountDownLatch(1)
        val clock = { System.nanoTime() / 1_000_000 }
        val pump = ScreenFeedbackPump(clock = clock, sendFeedback = {
            sent += it
            if (it.measurementSequence == 2L) repeated.countDown()
            if (it.measurementSequence == 3L) fresh.countDown()
        })
        try {
            pump.start(null, RemoteDesktopReceiverFeedback.getDefaultInstance())
            pump.update(RemoteDesktopReceiverFeedback.newBuilder().setDecodeMs(100.0).setFramesPerSecond(30.0).build(), clock() - 3_000)
            assertTrue(repeated.await(3, TimeUnit.SECONDS))
            val old = sent.filter { it.measurementSequence == 2L }
            assertTrue(old.all { it.measurementAgeMs >= 3_000 && it.decodeMs == 100.0 })
            assertTrue(old.last().sequence > old.first().sequence)
            assertTrue(old.last().measurementAgeMs > old.first().measurementAgeMs)
            pump.update(RemoteDesktopReceiverFeedback.newBuilder().setDecodeMs(4.0).build())
            assertTrue(fresh.await(2, TimeUnit.SECONDS))
            assertEquals(3L, sent.last().measurementSequence)
            assertTrue(sent.last().measurementAgeMs < 1_000)
            assertEquals(4.0, sent.last().decodeMs, 0.0)
        } finally { pump.stop() }
    }
}

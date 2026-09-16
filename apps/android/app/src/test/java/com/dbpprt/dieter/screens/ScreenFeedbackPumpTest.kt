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
}

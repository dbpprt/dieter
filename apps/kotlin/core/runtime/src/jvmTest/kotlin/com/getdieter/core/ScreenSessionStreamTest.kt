package com.getdieter.core

import com.getdieter.api.v1.RemoteDesktopSignal
import com.getdieter.core.runtime.Deadlines
import com.getdieter.core.screens.ScreenPhase
import com.getdieter.core.screens.ScreenSessionPolicy
import com.getdieter.core.screens.ViewportPolicy
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest

/**
 * The stream a screen session asks for and control of the host: configuration retries, virtual
 * displays, viewport changes, and control transfer.
 */
class ScreenSessionStreamTest : ScreenSessionHarness() {
    @Test
    fun aControlTransferThatTimesOutClearsTheTransferAndReportsIt() = runTest {
        val engines = Engines()
        val daemon = FakeDaemon()
        val session = virtualSession(engines)
        streaming(session, daemon, engines)
        daemon.unanswered += "SetRemoteDesktopControl"
        val transfer = launch { session.transferControl(take = false) }
        runCurrent()
        assertTrue(session.view.value.controlTransferring)
        advanceTimeBy(Deadlines.CALL)
        runCurrent()
        assertTrue(transfer.isCompleted)
        val failed = session.view.value
        assertFalse(failed.controlTransferring, "a timed-out transfer can be tried again")
        assertEquals("The machine did not answer in time.", failed.controlError)
        assertEquals(1, daemon.controls.size)
        session.disconnect()
    }

    @Test
    fun aStreamConfigurationThatTimesOutRetriesOnTheExistingSession() = runTest {
        val engines = Engines()
        val daemon = FakeDaemon()
        val session = virtualSession(engines)
        streaming(session, daemon, engines)
        daemon.unanswered += "UpdateRemoteDesktopSession"
        session.configure()
        runCurrent()
        advanceTimeBy(Deadlines.CALL)
        runCurrent()
        assertEquals(ScreenPhase.Streaming, session.view.value.phase)
        advanceTimeBy(ScreenSessionPolicy.CONFIGURATION_RETRY)
        runCurrent()
        assertEquals(2, daemon.updates.size, "desired configuration is retried")
        assertEquals(1, daemon.starts.size, "healthy video keeps its session")
        session.disconnect()
    }

    @Test
    fun virtualDisplayUsesDrawablePixelsAndWaitsForItsPresentedGeneration() = runTest {
        val engines = Engines()
        val daemon = FakeDaemon()
        daemon.caps =
            daemon.caps.copy(
                virtual_display_supported = true,
                virtual_display_disable_supported = true,
            )
        val session = virtualSession(engines)
        val engine = streaming(session, daemon, engines)
        session.viewport(1280.0, 720.0, 2.0)
        session.setPreferences {
            it.copy(virtualDisplay = true, disablePhysical = true, virtualScale = 2)
        }
        runCurrent()
        val request = daemon.virtualCreates.single()
        assertEquals(2560, request.pixel_width)
        assertEquals(1440, request.pixel_height)
        assertEquals(2, request.scale)
        assertEquals("virtual", daemon.updates.last().configuration?.display_id)
        assertTrue(
            daemon.virtualConfirms.isEmpty(),
            "old screen presentation cannot disable the physical display",
        )
        engine.events.presented(1200u)
        runCurrent()
        assertTrue(
            daemon.virtualConfirms.isEmpty(),
            "stale frame cannot acknowledge a new generation",
        )
        engine.events.presented(2100u)
        runCurrent()
        assertEquals(2L, daemon.virtualConfirms.single().display_generation)
        assertEquals("virtual", daemon.virtualConfirms.single().display_id)
        session.viewport(1000.0, 600.0, 2.0)
        advanceTimeBy(351)
        runCurrent()
        assertTrue(
            session.preferences.virtualDisplay,
            "our resize restoration keeps virtual mode enabled",
        )
        assertEquals(2000, daemon.virtualCreates.last().pixel_width)
        assertEquals(1200, daemon.virtualCreates.last().pixel_height)
        session.setPreferences { it.copy(virtualDisplay = false) }
        runCurrent()
        assertEquals(2, daemon.virtualRestores.get())
        assertEquals("primary", daemon.updates.last().configuration?.display_id)
        session.disconnect()
    }

    @Test
    fun hostVirtualRestorationClearsPreferenceWithoutRecreatingDisplay() = runTest {
        val engines = Engines()
        val daemon = FakeDaemon()
        daemon.caps = daemon.caps.copy(virtual_display_supported = true)
        val session = virtualSession(engines)
        streaming(session, daemon, engines)
        session.setPreferences { it.copy(virtualDisplay = true) }
        runCurrent()
        daemon.virtual = null
        daemon.signals.send(
            RemoteDesktopSignal(
                session_id = daemon.sessionId,
                state = daemon.state(3, 3000).copy(control_generation = 3),
            )
        )
        runCurrent()
        assertFalse(session.preferences.virtualDisplay)
        assertEquals(1, daemon.virtualCreates.size)
        session.disconnect()
    }

    @Test
    fun lostVirtualCreateReplyRetriesTheSameDesiredLease() = runTest {
        val engines = Engines()
        val daemon = FakeDaemon()
        daemon.caps = daemon.caps.copy(virtual_display_supported = true)
        val session = virtualSession(engines)
        streaming(session, daemon, engines)
        daemon.unanswered += "SetRemoteDesktopVirtualDisplay"
        session.setPreferences { it.copy(virtualDisplay = true) }
        runCurrent()
        advanceTimeBy(Deadlines.CALL + ScreenSessionPolicy.CONFIGURATION_RETRY)
        advanceTimeBy(1)
        runCurrent()
        assertEquals(2, daemon.virtualCreates.size)
        assertEquals(daemon.virtualCreates.first(), daemon.virtualCreates.last())
        assertEquals(0, daemon.virtualRestores.get(), "an identical server request is idempotent")
        assertEquals("virtual", daemon.updates.last().configuration?.display_id)
        session.disconnect()
    }

    @Test
    fun finishedAttemptWorkIsNotHeld() = runTest {
        val engines = Engines()
        val daemon = FakeDaemon()
        val session = virtualSession(engines, viewport = ViewportPolicy.Desktop)
        streaming(session, daemon, engines)
        fun resize(step: Int) {
            session.viewport(800.0 + step, 600.0, 2.0)
            advanceTimeBy(ScreenSessionPolicy.VIEWPORT_DEBOUNCE)
            runCurrent()
        }
        resize(0)
        val held = session.heldJobs
        repeat(100) { resize(it + 1) }
        assertEquals(101, daemon.updates.size, "every resize reconfigures the stream")
        assertTrue(
            session.heldJobs <= held,
            "held ${session.heldJobs} jobs after 101 resizes, $held after one",
        )
        session.disconnect()
        assertEquals(0, session.heldJobs)
    }
}

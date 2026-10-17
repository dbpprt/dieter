package com.getdieter.core

import com.getdieter.api.v1.RemoteDesktopSignal
import com.getdieter.core.screens.ScreenPhase
import com.squareup.wire.GrpcException
import com.squareup.wire.GrpcStatus
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.time.Duration.Companion.seconds
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest

class ScreenSessionCancellationTest : ScreenSessionHarness() {
    @Test
    fun serverCancellationDuringConnectRetriesWithoutAnotherClick() = runTest {
        val engines = Engines()
        val daemon = FakeDaemon()
        daemon.startFailures.addLast(GrpcStatus.CANCELLED)
        val session = virtualSession(engines)
        session.connect { daemon.route() }
        runCurrent()
        advanceTimeBy(1.seconds)
        runCurrent()
        assertEquals(2, daemon.starts.size)
        assertEquals(1, daemon.starts.distinct().size)
        assertEquals(1, engines.created.size)
        assertFalse(engines.created.single().closed)
        val engine = engines.created.single()
        engine.connect()
        daemon.signals.send(
            RemoteDesktopSignal(session_id = daemon.sessionId, state = daemon.state(1, 1000))
        )
        runCurrent()
        engine.events.presented(1200u)
        runCurrent()
        assertEquals(ScreenPhase.Streaming, session.view.value.phase)
        session.disconnect()
        advanceTimeBy(30.seconds)
        runCurrent()
        assertEquals(2, daemon.starts.size, "user disconnect must not retry")
    }

    @Test
    fun serverCancellationPreservesStreamingAndResubscribes() = runTest {
        val engines = Engines()
        val daemon = FakeDaemon()
        val session = virtualSession(engines)
        val engine = streaming(session, daemon, engines)
        daemon.streamFailures.send(GrpcException(GrpcStatus.CANCELLED, "context canceled"))
        runCurrent()
        assertEquals(ScreenPhase.Streaming, session.view.value.phase)
        advanceTimeBy(1.seconds)
        runCurrent()
        assertEquals(2, daemon.starts.size)
        assertEquals(1, daemon.starts.distinct().size)
        assertEquals(1, engines.created.size)
        assertFalse(engine.closed)
        assertEquals(ScreenPhase.Streaming, session.view.value.phase)
        session.disconnect()
    }
}

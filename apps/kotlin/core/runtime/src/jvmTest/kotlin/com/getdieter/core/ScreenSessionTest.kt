package com.getdieter.core

import com.getdieter.api.gateway.v1.RTCConfiguration
import com.getdieter.api.v1.RemoteDesktopHostEvent
import com.getdieter.api.v1.RemoteDesktopReceiverFeedback
import com.getdieter.api.v1.RemoteDesktopSessionBinding
import com.getdieter.api.v1.RemoteDesktopSessionDescription
import com.getdieter.api.v1.RemoteDesktopSignal
import com.getdieter.api.v1.StartRemoteDesktopRequest
import com.getdieter.core.runtime.Deadlines
import com.getdieter.core.screens.PeerState
import com.getdieter.core.screens.ScreenChannels
import com.getdieter.core.screens.ScreenPhase
import com.getdieter.core.screens.ScreenRoute
import com.getdieter.core.screens.ScreenSessionPolicy
import com.getdieter.core.screens.ScreenTrust
import com.getdieter.core.testing.JcaSignatureVerifier
import com.getdieter.core.testing.await
import com.squareup.wire.GrpcException
import com.squareup.wire.GrpcStatus
import java.util.Base64
import java.util.Properties
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlin.time.Duration.Companion.seconds
import kotlin.time.Instant
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import okio.ByteString.Companion.encodeUtf8
import okio.ByteString.Companion.toByteString

/**
 * The screen-session lifecycle: trust, streaming readiness, input routing, feedback, the
 * session-replacement guard, signaling recovery, fatal failures, unanswered calls, and video that
 * never starts or freezes.
 */
class ScreenSessionTest : ScreenSessionHarness() {
    @Test
    fun verifiedSessionStreamsAndRoutesInput() = runBlocking {
        val engines = Engines()
        val daemon = FakeDaemon()
        val session = session(engines)
        onCore { session.connect { daemon.route() } }
        session.view.await(describe = { "connecting: ${session.view.value}" }) {
            it.phase == ScreenPhase.Connecting && it.sessionId == "rd_test"
        }
        val engine = engines.created.single()
        // The host's candidate follows its answer; the stream runs on the core dispatcher, so wait
        // for both.
        eventually { engine.answer != null && engine.candidates.isNotEmpty() }
        assertEquals(1, engine.candidates.size)
        assertEquals(0, engine.candidatesBeforeAnswer, "candidates are applied after the answer")

        onCore { engine.connect() }
        daemon.signals.send(
            RemoteDesktopSignal(session_id = "rd_test", state = daemon.state(1, 1000))
        )
        session.view.await { it.state?.display_generation == 1L }
        onCore { engine.events.presented(1200u) }
        val streaming =
            session.view.await(describe = { "streaming: ${session.view.value}" }) {
                it.phase == ScreenPhase.Streaming && it.controlActive
            }
        assertTrue(streaming.ready)

        onCore {
            session.key(4, down = true)
            session.pointer(0.25, 0.75)
        }
        eventually { engine.inputs(ScreenChannels.POINTER).isNotEmpty() }
        val pressed = engine.inputs(ScreenChannels.INPUT).single { it.key != null }
        assertEquals(daemon.epoch, pressed.input_epoch)
        assertEquals(1L, pressed.display_generation)
        assertEquals(4, pressed.key?.physical_key)
        val move = engine.inputs(ScreenChannels.POINTER).single()
        assertEquals(250_000, move.pointer_move?.normalized_x)
        assertEquals(pressed.state_barrier, move.state_barrier, "the move is ordered after the key")
        eventually { engine.sent.any { it.first == ScreenChannels.SESSION } }
        val feedback =
            RemoteDesktopReceiverFeedback.ADAPTER.decode(
                engine.sent.first { it.first == ScreenChannels.SESSION }.second
            )
        assertEquals(daemon.epoch, feedback.input_epoch)

        // A host event on the session channel acknowledges input like any state.
        onCore {
            engine.events.channelMessage(
                ScreenChannels.SESSION,
                RemoteDesktopHostEvent.ADAPTER.encode(RemoteDesktopHostEvent(input_ack = 9)),
            )
        }

        onCore { session.disconnect() }
        eventually({ "closed: ${daemon.closes}" }) {
            daemon.closes.contains("rd_test") && engine.closed
        }
        Unit
    }

    @Test
    fun replacedSessionIsClosedAndRecovered() = runBlocking {
        val engines = Engines()
        val daemon = FakeDaemon()
        val session = session(engines)
        onCore { session.connect { daemon.route() } }
        session.view.await { it.sessionId == "rd_test" }
        daemon.signals.send(
            RemoteDesktopSignal(session_id = "rd_other", state = daemon.state(1, 1000))
        )
        eventually({ "restarted: ${daemon.starts.size} closes ${daemon.closes}" }) {
            daemon.starts.size >= 2 && "rd_other" in daemon.closes
        }
        assertTrue(engines.created.first().closed, "the replaced peer is torn down")
        onCore { session.disconnect() }
    }

    @Test
    fun forgedBindingFailsWithoutRetrying() = runBlocking {
        val engines = Engines()
        val daemon = FakeDaemon(forge = true)
        val session = session(engines)
        onCore { session.connect { daemon.route() } }
        val failed = session.view.await { it.phase is ScreenPhase.Failed }
        assertEquals(
            ScreenPhase.Failed("The screen session was not signed by the enrolled machine."),
            failed.phase,
        )
        delay(600)
        assertEquals(1, daemon.starts.size)
        assertEquals(null, engines.created.single().answer, "an unverified answer is never applied")
    }

    @Test
    fun nonRetryableClosureFailsAndRetryableRecovers() = runBlocking {
        val engines = Engines()
        val daemon = FakeDaemon()
        val session = session(engines)
        onCore { session.connect { daemon.route() } }
        session.view.await { it.sessionId == "rd_test" }
        daemon.signals.send(
            RemoteDesktopSignal(
                session_id = "rd_test",
                state = daemon.state(1, 1000, phase = "closed", reason = "session lease expired"),
            )
        )
        eventually({ "retry: ${daemon.starts.size}" }) { daemon.starts.size >= 2 }
        session.view.await { it.sessionId == "rd_test" && it.phase == ScreenPhase.Connecting }
        daemon.signals.send(
            RemoteDesktopSignal(
                session_id = "rd_test",
                state = daemon.state(1, 1000, phase = "closed", reason = "closed by host"),
            )
        )
        assertEquals(
            ScreenPhase.Failed("closed by host"),
            session.view.await { it.phase is ScreenPhase.Failed }.phase,
        )
    }

    @Test
    fun unavailableHostReportsPermissionOrUnsupported() = runBlocking {
        val engines = Engines()
        val daemon = FakeDaemon()
        daemon.caps = daemon.caps.copy(ready = false, unavailable_reason = "No graphical session")
        val session = session(engines)
        onCore { session.connect { daemon.route() } }
        assertEquals(
            ScreenPhase.Unsupported("No graphical session"),
            session.view.await { it.phase is ScreenPhase.Unsupported }.phase,
        )
        assertTrue(engines.created.isEmpty())
    }

    @Test
    fun capabilitiesThatNeverAnswerAreRetriedInsteadOfLoadingForever() = runTest {
        val engines = Engines()
        val daemon = FakeDaemon()
        daemon.unanswered += "GetRemoteDesktopCapabilities"
        val session = virtualSession(engines)
        session.connect { daemon.route() }
        runCurrent()
        assertEquals(ScreenPhase.Loading, session.view.value.phase)
        advanceTimeBy(Deadlines.CALL)
        runCurrent()
        assertEquals(
            ScreenPhase.Reconnecting("The machine did not answer in time."),
            session.view.value.phase,
        )
        advanceTimeBy(1.seconds)
        runCurrent()
        assertEquals(
            2,
            daemon.capabilityReads.get(),
            "the next attempt reads the capabilities again",
        )
        assertEquals("rd_test", session.view.value.sessionId)
        session.disconnect()
    }

    @Test
    fun aLeaseHeartbeatThatTimesOutDoesNotEndRenewal() = runTest {
        val engines = Engines()
        val daemon = FakeDaemon()
        val session = virtualSession(engines)
        streaming(session, daemon, engines)
        daemon.unanswered += "SendRemoteDesktopSignal"
        advanceTimeBy(ScreenSessionPolicy.LEASE_INTERVAL)
        runCurrent()
        assertEquals(1, daemon.heartbeats.get())
        advanceTimeBy(Deadlines.CALL + ScreenSessionPolicy.LEASE_INTERVAL)
        runCurrent()
        assertEquals(2, daemon.heartbeats.get(), "the renewal after a timed-out one still runs")
        assertEquals(
            ScreenPhase.Streaming,
            session.view.value.phase,
            "a healthy peer survives a missed renewal",
        )
        session.disconnect()
    }

    @Test
    fun disconnectedPeerHealsWithoutReplacingTheSessionOrKeepingAnOldTimer() = runTest {
        val engines = Engines()
        val daemon = FakeDaemon()
        val session = virtualSession(engines)
        val engine = streaming(session, daemon, engines)
        advanceTimeBy(18.seconds)
        engine.events.peerState(PeerState.DISCONNECTED)
        runCurrent()
        assertFalse(session.view.value.ready)
        assertFalse(session.view.value.controlActive)
        advanceTimeBy(8.seconds) // Beyond both the old grace and the initial connection watchdog.
        runCurrent()
        assertFalse(engine.closed)
        engine.events.peerState(PeerState.CONNECTED)
        runCurrent()
        assertTrue(daemon.updates.any { it.refresh }, "repair the decoder on the existing peer")
        assertTrue(session.view.value.ready)
        advanceTimeBy(2.seconds)
        engine.events.peerState(PeerState.DISCONNECTED)
        runCurrent()
        advanceTimeBy(8.seconds) // The first interruption's timer must have been cancelled.
        runCurrent()
        assertFalse(engine.closed)
        engine.events.peerState(PeerState.CONNECTED)
        runCurrent()
        assertEquals(1, engines.created.size)
        assertEquals(1, daemon.starts.size)
        session.disconnect()
    }

    @Test
    fun repeatedDisconnectNotificationsCannotExtendRecoveryForever() = runTest {
        val engines = Engines()
        val daemon = FakeDaemon()
        val session = virtualSession(engines)
        val engine = streaming(session, daemon, engines)
        engine.events.peerState(PeerState.DISCONNECTED)
        runCurrent()
        advanceTimeBy(10.seconds)
        engine.events.peerState(PeerState.DISCONNECTED)
        runCurrent()
        advanceTimeBy(6.seconds)
        runCurrent()
        assertTrue(engine.closed)
        assertEquals(2, engines.created.size)
        session.disconnect()
    }

    @Test
    fun signalingRetriesKeepTheOfferNonceAndPeerThroughSeveralFailures() = runTest {
        val engines = Engines()
        val daemon = FakeDaemon()
        val session = virtualSession(engines)
        val engine = streaming(session, daemon, engines)
        repeat(3) { daemon.startFailures.addLast(GrpcStatus.UNAVAILABLE) }
        daemon.streamFailures.send(GrpcException(GrpcStatus.UNAVAILABLE, "route interrupted"))
        runCurrent()
        advanceTimeBy(13.seconds)
        runCurrent()
        assertEquals(5, daemon.starts.size)
        assertEquals(
            5,
            daemon.routeReads.get(),
            "replace failed control routes without replacing video",
        )
        assertEquals(1, daemon.starts.distinct().size, "resubscribe to the admitted session")
        assertEquals(1, engines.created.size)
        assertFalse(engine.closed)
        assertEquals(ScreenPhase.Streaming, session.view.value.phase)
        session.disconnect()
    }

    @Test
    fun disconnectCancelsSignalingRecoveryWithoutOpeningAnotherRoute() = runTest {
        val engines = Engines()
        val daemon = FakeDaemon()
        val session = virtualSession(engines)
        val engine = streaming(session, daemon, engines)
        daemon.streamFailures.send(GrpcException(GrpcStatus.UNAVAILABLE, "offline"))
        runCurrent()
        session.disconnect()
        runCurrent()
        advanceTimeBy(60.seconds)
        runCurrent()
        assertTrue(engine.closed)
        assertEquals(ScreenPhase.Idle, session.view.value.phase)
        assertEquals(1, daemon.starts.size)
        assertEquals(1, daemon.routeReads.get())
    }

    @Test
    fun routeRecoveryCannotChangeThePinnedMachineIdentity() = runTest {
        val engines = Engines()
        val daemon = FakeDaemon()
        val session = virtualSession(engines)
        var routes = 0
        session.connect {
            if (routes++ == 0) daemon.route()
            else ScreenRoute(daemon.client, "another machine", RTCConfiguration(), "relay")
        }
        runCurrent()
        val engine = engines.created.single()
        daemon.streamFailures.send(GrpcException(GrpcStatus.UNAVAILABLE, "route interrupted"))
        runCurrent()
        advanceTimeBy(1.seconds)
        runCurrent()
        assertTrue(engine.closed)
        assertTrue(session.view.value.phase is ScreenPhase.Failed)
        assertEquals(1, daemon.starts.size)
        advanceTimeBy(30.seconds)
        runCurrent()
        assertEquals(2, routes)
        session.disconnect()
    }

    @Test
    fun permanentSignalingFailureStopsImmediately() = runTest {
        val engines = Engines()
        val daemon = FakeDaemon()
        val session = virtualSession(engines)
        val engine = streaming(session, daemon, engines)
        daemon.streamFailures.send(GrpcException(GrpcStatus.PERMISSION_DENIED, "access revoked"))
        runCurrent()
        assertTrue(engine.closed)
        assertTrue(session.view.value.phase is ScreenPhase.Failed)
        advanceTimeBy(30.seconds)
        runCurrent()
        assertEquals(1, daemon.starts.size)
        session.disconnect()
    }

    @Test
    fun anUnrecoverablePeerOrSignalingOutageStillFallsBackToANewSession() = runTest {
        for (peerFailure in listOf(true, false)) {
            val engines = Engines()
            val daemon = FakeDaemon()
            val session = virtualSession(engines)
            val engine = streaming(session, daemon, engines)
            if (peerFailure) {
                engine.events.peerState(PeerState.FAILED)
            } else {
                repeat(20) { daemon.startFailures.addLast(GrpcStatus.UNAVAILABLE) }
                daemon.streamFailures.send(GrpcException(GrpcStatus.UNAVAILABLE, "offline"))
            }
            runCurrent()
            advanceTimeBy(if (peerFailure) 1.seconds else 16.seconds)
            runCurrent()
            assertTrue(engine.closed)
            assertEquals(2, engines.created.size)
            session.disconnect()
        }
    }

    @Test
    fun unfocusedViewsDoNotReconnectBecausePresentationIsSuspended() = runTest {
        val engines = Engines()
        val daemon = FakeDaemon()
        val session = virtualSession(engines)
        val engine = streaming(session, daemon, engines)
        session.setFocused(false)
        engine.presenting = false
        advanceTimeBy(60.seconds)
        runCurrent()
        assertFalse(engine.closed)
        assertTrue(daemon.updates.isEmpty())
        session.setFocused(true)
        advanceTimeBy(11.seconds)
        runCurrent()
        assertEquals(1, daemon.updates.count { it.refresh })
        session.disconnect()
    }

    @Test
    fun frozenVideoRefreshesTheExistingSessionBeforeReplacingIt() = runTest {
        val engines = Engines()
        val daemon = FakeDaemon()
        val session = virtualSession(engines)
        val engine = streaming(session, daemon, engines)
        engine.presenting = false
        advanceTimeBy(11.seconds)
        runCurrent()
        assertEquals(1, daemon.updates.count { it.refresh })
        assertNull(
            daemon.updates.single().configuration,
            "refresh must preserve bandwidth adaptation",
        )
        assertFalse(engine.closed)
        // Presentation of the same cached frame is not evidence of recovery.
        engine.events.presented(1200u)
        runCurrent()
        advanceTimeBy(10.seconds)
        runCurrent()
        assertEquals(1, daemon.updates.count { it.refresh })
        engine.presenting = true
        advanceTimeBy(10.seconds)
        runCurrent()
        assertFalse(engine.closed)
        assertEquals(1, engines.created.size)
        session.disconnect()
    }

    @Test
    fun aRefreshThatCannotRestoreVideoEventuallyReplacesThePeer() = runTest {
        val engines = Engines()
        val daemon = FakeDaemon()
        val session = virtualSession(engines)
        val engine = streaming(session, daemon, engines)
        engine.presenting = false
        advanceTimeBy(31.seconds)
        runCurrent()
        assertEquals(1, daemon.updates.count { it.refresh })
        assertTrue(engine.closed)
        assertEquals(2, engines.created.size)
        session.disconnect()
    }

    @Test
    fun daemonGoldenBindingVerifiesWithTheJdk() {
        // Written by internal/remotedesktop's TestScreenTrustFixture.
        val fixture =
            Properties().apply {
                checkNotNull(
                        ScreenSessionTest::class
                            .java
                            .getResourceAsStream("/screen-trust.properties")
                    ) {
                        "the screen trust fixture is missing"
                    }
                    .use { load(it) }
            }
        fun bytes(name: String) =
            Base64.getDecoder().decode(fixture.getProperty(name)).toByteString()
        val offer = "test offer"
        val request =
            StartRemoteDesktopRequest(
                client_nonce = "nonce",
                offer = RemoteDesktopSessionDescription(type = "offer", sdp = offer),
                control = true,
                display_id = "primary",
                input_protocol_version = 3,
            )
        val binding =
            RemoteDesktopSessionBinding(
                client_nonce = "nonce",
                helper_dtls_fingerprint = "sha-256 01:23:45",
                expires_at = "2100-01-01T00:00:00Z",
                offer_sha256 = offer.encodeUtf8().sha256(),
                daemon_signature = bytes("signature"),
                control_granted = true,
                display_id = "primary",
                input_protocol_version = 3,
                input_epoch = bytes("epoch"),
            )
        val pem = bytes("certificate").utf8()
        val now = Instant.parse("2026-09-30T00:00:00Z")
        fun verify(
            value: RemoteDesktopSessionBinding = binding,
            answer: String = "a=fingerprint:sha-256 01:23:45\r\n",
            sdp: String = offer,
        ) =
            ScreenTrust.verify(
                value,
                "session",
                request.copy(offer = RemoteDesktopSessionDescription(type = "offer", sdp = sdp)),
                answer,
                pem,
                now,
                JcaSignatureVerifier,
            )
        verify()
        assertFailsWith<IllegalStateException> { verify(sdp = "other offer") }
        assertFailsWith<IllegalStateException> {
            verify(answer = "a=fingerprint:sha-256 01:23:45\na=fingerprint:sha-256 99:99")
        }
        listOf(
                binding.copy(control_granted = false),
                binding.copy(display_id = "secondary"),
                binding.copy(input_epoch = ByteArray(16).toByteString()),
                binding.copy(input_protocol_version = 0),
                binding.copy(expires_at = "2020-01-01T00:00:00Z"),
                binding.copy(daemon_signature = ByteArray(64).toByteString()),
            )
            .forEach { value -> assertFailsWith<IllegalStateException> { verify(value) } }
    }
}

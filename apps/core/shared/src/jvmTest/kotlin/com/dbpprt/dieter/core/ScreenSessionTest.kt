package com.dbpprt.dieter.core

import com.dbpprt.dieter.api.gateway.v1.RTCConfiguration
import com.dbpprt.dieter.api.v1.DieterServiceClient
import com.dbpprt.dieter.api.v1.RemoteDesktopCapabilities
import com.dbpprt.dieter.api.v1.RemoteDesktopClipboardFrame
import com.dbpprt.dieter.api.v1.RemoteDesktopClipboardRequest
import com.dbpprt.dieter.api.v1.RemoteDesktopClipboardResponse
import com.dbpprt.dieter.api.v1.RemoteDesktopHostEvent
import com.dbpprt.dieter.api.v1.RemoteDesktopICECandidate
import com.dbpprt.dieter.api.v1.RemoteDesktopInput
import com.dbpprt.dieter.api.v1.RemoteDesktopReceiverFeedback
import com.dbpprt.dieter.api.v1.RemoteDesktopRef
import com.dbpprt.dieter.api.v1.RemoteDesktopSessionBinding
import com.dbpprt.dieter.api.v1.RemoteDesktopSessionDescription
import com.dbpprt.dieter.api.v1.RemoteDesktopSessionState
import com.dbpprt.dieter.api.v1.RemoteDesktopSignal
import com.dbpprt.dieter.api.v1.StartRemoteDesktopRequest
import com.dbpprt.dieter.api.v1.UpdateRemoteDesktopSessionRequest
import com.dbpprt.dieter.core.screens.ClipboardFraming
import com.dbpprt.dieter.core.screens.PeerState
import com.dbpprt.dieter.core.screens.RtpCodec
import com.dbpprt.dieter.core.screens.ScreenChannels
import com.dbpprt.dieter.core.screens.ScreenConfig
import com.dbpprt.dieter.core.screens.ScreenMediaCapabilities
import com.dbpprt.dieter.core.screens.ScreenMediaConfig
import com.dbpprt.dieter.core.screens.ScreenMediaEngine
import com.dbpprt.dieter.core.screens.ScreenMediaEngineFactory
import com.dbpprt.dieter.core.screens.ScreenMediaEvents
import com.dbpprt.dieter.core.screens.ScreenPhase
import com.dbpprt.dieter.core.screens.ScreenRoute
import com.dbpprt.dieter.core.screens.ScreenSession
import com.dbpprt.dieter.core.screens.ScreenTrust
import com.dbpprt.dieter.core.screens.ViewportPolicy
import com.dbpprt.dieter.core.testing.JcaSignatureVerifier
import com.dbpprt.dieter.core.testing.PrintLogger
import com.dbpprt.dieter.core.testing.TestMachineKey
import com.dbpprt.dieter.core.testing.await
import com.squareup.wire.GrpcCall
import com.squareup.wire.GrpcServerStreamingCall
import java.lang.reflect.Proxy
import java.util.Base64
import java.util.Properties
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.CopyOnWriteArrayList
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue
import kotlin.time.Clock
import kotlin.time.Duration.Companion.hours
import kotlin.time.Duration.Companion.seconds
import kotlin.time.Instant
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.delay
import kotlinx.coroutines.cancel
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import okio.ByteString.Companion.encodeUtf8
import okio.ByteString.Companion.toByteString

/**
 * The screen-session controller against a scripted daemon and a scripted
 * media engine: trust, streaming readiness, input routing, feedback, the
 * session-replacement guard, and fatal failures.
 */
class ScreenSessionTest {
    private val core = Dispatchers.Default.limitedParallelism(1)
    private val scope = CoroutineScope(SupervisorJob() + core)
    private val key = TestMachineKey()

    @AfterTest
    fun tearDown() = scope.cancel()

    private class FakeEngine(val events: ScreenMediaEvents) : ScreenMediaEngine {
        val open = mutableSetOf<String>()
        val sent = ConcurrentLinkedQueue<Pair<String, ByteArray>>()
        var answer: String? = null
        val candidates = CopyOnWriteArrayList<RemoteDesktopICECandidate>()
        var closed = false

        override suspend fun createOffer() = "v=0\r\no=- 1 1 IN IP4 127.0.0.1\r\n"
        override suspend fun applyAnswer(sdp: String) { answer = sdp }
        override suspend fun addRemoteCandidate(candidate: RemoteDesktopICECandidate) { candidates += candidate }
        override fun send(label: String, bytes: ByteArray): Boolean = (label in open).also { if (it) sent += label to bytes }
        override fun isOpen(label: String) = label in open
        override fun bufferedAmount(label: String) = 0L
        override suspend fun statistics(): RemoteDesktopReceiverFeedback? = RemoteDesktopReceiverFeedback(frames_per_second = 60.0)
        override fun updateFrameGate(token: Long, displayGeneration: Long, mediaGeneration: Long, mediaTimestamp: UInt) = Unit
        override fun resetVideo() = Unit
        override fun close() { closed = true }

        fun connect() {
            open += listOf(ScreenChannels.POINTER, ScreenChannels.INPUT, ScreenChannels.SESSION)
            open.forEach { events.channelState(it, true) }
            events.peerState(PeerState.CONNECTED)
        }

        fun inputs(label: String) = sent.filter { it.first == label }.map { RemoteDesktopInput.ADAPTER.decode(it.second) }
    }

    private class Engines : ScreenMediaEngineFactory {
        val created = CopyOnWriteArrayList<FakeEngine>()
        override val capabilities = ScreenMediaCapabilities(listOf(RtpCodec("H264", "640c1f")), hevcDecoder = false, referenceDependencies = false, millisecondTimestamps = false)
        override fun create(config: ScreenMediaConfig, events: ScreenMediaEvents): ScreenMediaEngine = FakeEngine(events).also { created += it }
    }

    /** A scripted daemon: each start opens a stream the test drives through [signals]. */
    private inner class FakeDaemon(val sessionId: String = "rd_test", val forge: Boolean = false) {
        val starts = CopyOnWriteArrayList<StartRemoteDesktopRequest>()
        val closes = CopyOnWriteArrayList<String>()
        val updates = CopyOnWriteArrayList<UpdateRemoteDesktopSessionRequest>()
        val signals = Channel<RemoteDesktopSignal>(Channel.UNLIMITED)
        val epoch = ByteArray(16) { 7 }.toByteString()
        var caps = RemoteDesktopCapabilities(
            platform = "darwin", ready = true, input_protocol_version = 3, control_supported = true, control_permission = "granted",
            cursor_supported = true, max_fps = 60,
        )

        fun state(generation: Long, timestamp: Int, phase: String = "streaming", reason: String = "") = RemoteDesktopSessionState(
            phase = phase, reason = reason, display_id = "primary", display_generation = generation, media_generation = generation,
            media_timestamp = timestamp, control_active = true, control_generation = 1, codec = "H264",
        )

        val client: DieterServiceClient = Proxy.newProxyInstance(DieterServiceClient::class.java.classLoader, arrayOf(DieterServiceClient::class.java)) { _, method, _ ->
            when (method.name) {
                "GetRemoteDesktopCapabilities" -> GrpcCall<Unit, RemoteDesktopCapabilities> { caps }
                "SendRemoteDesktopSignal" -> GrpcCall<RemoteDesktopSignal, Unit> { }
                "CloseRemoteDesktop" -> GrpcCall<RemoteDesktopRef, Unit> { closes += it.session_id }
                "UpdateRemoteDesktopSession" -> GrpcCall<UpdateRemoteDesktopSessionRequest, RemoteDesktopSessionState> { updates += it; state(1, 1000) }
                "StartRemoteDesktop" -> GrpcServerStreamingCall<StartRemoteDesktopRequest, RemoteDesktopSignal> { request ->
                    starts += request
                    val binding = RemoteDesktopSessionBinding(
                        client_nonce = request.client_nonce, helper_dtls_fingerprint = "sha-256 01:23", expires_at = (Clock.System.now() + 1.hours).toString(),
                        offer_sha256 = request.offer!!.sdp.encodeUtf8().sha256(), control_granted = request.control, display_id = "primary",
                        input_protocol_version = 3, input_epoch = epoch,
                    )
                    val signature = key.sign(ScreenTrust.message(sessionId, binding).toByteArray()).also { if (forge) it[0] = (it[0] + 1).toByte() }
                    send(RemoteDesktopSignal(session_id = sessionId, binding = binding.copy(daemon_signature = signature.toByteString())))
                    send(RemoteDesktopSignal(session_id = sessionId, description = RemoteDesktopSessionDescription(type = "answer", sdp = "v=0\r\na=fingerprint:sha-256 01:23\r\n")))
                    send(RemoteDesktopSignal(session_id = sessionId, candidate = RemoteDesktopICECandidate(candidate = "candidate:1 1 udp 1 127.0.0.1 9 typ host")))
                    for (signal in signals) send(signal)
                    awaitCancellation()
                }
                else -> error("unexpected RPC ${method.name}")
            }
        } as DieterServiceClient

        fun route() = ScreenRoute(client, key.certificatePem, RTCConfiguration(), "direct")
    }

    private fun session(engines: Engines) = ScreenSession(
        engines, JcaSignatureVerifier, ScreenConfig("Test", ViewportPolicy.Fixed), Clock.System, scope, PrintLogger,
    )

    private suspend fun <T> onCore(block: () -> T): T = withContext(core) { block() }

    /** Polls a condition that is not published through the view. */
    private suspend fun eventually(describe: () -> String = { "condition" }, condition: () -> Boolean) {
        withTimeoutOrNull(10.seconds) { while (!onCore(condition)) delay(20) } ?: error("timed out waiting for ${describe()}")
    }

    @Test
    fun verifiedSessionStreamsAndRoutesInput() = runBlocking {
        val engines = Engines()
        val daemon = FakeDaemon()
        val session = session(engines)
        onCore { session.connect { daemon.route() } }
        session.view.await(describe = { "connecting: ${session.view.value}" }) { it.phase == ScreenPhase.Connecting && it.sessionId == "rd_test" }
        val engine = engines.created.single()
        eventually { engine.answer != null }
        assertEquals(1, engine.candidates.size, "candidates that arrive with the answer are applied after it")

        onCore { engine.connect() }
        daemon.signals.send(RemoteDesktopSignal(session_id = "rd_test", state = daemon.state(1, 1000)))
        session.view.await { it.state?.display_generation == 1L }
        onCore { engine.events.presented(1200u) }
        val streaming = session.view.await(describe = { "streaming: ${session.view.value}" }) { it.phase == ScreenPhase.Streaming && it.controlActive }
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
        val feedback = RemoteDesktopReceiverFeedback.ADAPTER.decode(engine.sent.first { it.first == ScreenChannels.SESSION }.second)
        assertEquals(daemon.epoch, feedback.input_epoch)

        // A host event on the session channel acknowledges input like any state.
        onCore { engine.events.channelMessage(ScreenChannels.SESSION, RemoteDesktopHostEvent.ADAPTER.encode(RemoteDesktopHostEvent(input_ack = 9))) }

        onCore { session.disconnect() }
        eventually({ "closed: ${daemon.closes}" }) { daemon.closes.contains("rd_test") && engine.closed }
        Unit
    }

    @Test
    fun clipboardSharingToggleIsConfiguredOnTheHost() = runBlocking {
        val engines = Engines()
        val daemon = FakeDaemon()
        daemon.caps = daemon.caps.copy(clipboard_supported = true)
        val session = session(engines)
        onCore { session.connect { daemon.route() } }
        session.view.await { it.sessionId == "rd_test" }
        val engine = engines.created.single()
        eventually { engine.answer != null }
        onCore { engine.open += ScreenChannels.CLIPBOARD; engine.connect() }
        daemon.signals.send(RemoteDesktopSignal(session_id = "rd_test", state = daemon.state(1, 1000).copy(clipboard_enabled = true, clipboard_generation = 1)))
        onCore { engine.events.presented(1200u) }
        session.view.await { it.controlActive && it.clipboardEnabled }

        val toggle = scope.async { session.setClipboardEnabled(false) }
        eventually { engine.sent.any { it.first == ScreenChannels.CLIPBOARD } }
        val frame = RemoteDesktopClipboardFrame.ADAPTER.decode(engine.sent.first { it.first == ScreenChannels.CLIPBOARD }.second)
        val request = RemoteDesktopClipboardRequest.ADAPTER.decode(frame.data_)
        assertEquals(RemoteDesktopClipboardRequest.Action.CONFIGURE, request.action)
        assertEquals(false, request.enabled)
        assertEquals(daemon.epoch, request.input_epoch)
        val response = RemoteDesktopClipboardResponse.ADAPTER.encodeByteString(RemoteDesktopClipboardResponse(operation_id = request.operation_id, enabled = false))
        ClipboardFraming.frames(request.operation_id, response).forEach { reply ->
            onCore { engine.events.channelMessage(ScreenChannels.CLIPBOARD, RemoteDesktopClipboardFrame.ADAPTER.encode(reply)) }
        }
        toggle.await()
        val off = session.view.await { !it.clipboardEnabled }
        assertEquals(null, off.clipboardError)
        assertEquals(false, onCore { session.preferences.clipboard })
        onCore { session.disconnect() }
    }

    @Test
    fun replacedSessionIsClosedAndRecovered() = runBlocking {
        val engines = Engines()
        val daemon = FakeDaemon()
        val session = session(engines)
        onCore { session.connect { daemon.route() } }
        session.view.await { it.sessionId == "rd_test" }
        daemon.signals.send(RemoteDesktopSignal(session_id = "rd_other", state = daemon.state(1, 1000)))
        eventually({ "restarted: ${daemon.starts.size} closes ${daemon.closes}" }) { daemon.starts.size >= 2 && "rd_other" in daemon.closes }
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
        assertEquals(ScreenPhase.Failed("The screen session was not signed by the enrolled machine."), failed.phase)
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
        daemon.signals.send(RemoteDesktopSignal(session_id = "rd_test", state = daemon.state(1, 1000, phase = "closed", reason = "session lease expired")))
        eventually({ "retry: ${daemon.starts.size}" }) { daemon.starts.size >= 2 }
        session.view.await { it.sessionId == "rd_test" && it.phase == ScreenPhase.Connecting }
        daemon.signals.send(RemoteDesktopSignal(session_id = "rd_test", state = daemon.state(1, 1000, phase = "closed", reason = "closed by host")))
        assertEquals(ScreenPhase.Failed("closed by host"), session.view.await { it.phase is ScreenPhase.Failed }.phase)
    }

    @Test
    fun unavailableHostReportsPermissionOrUnsupported() = runBlocking {
        val engines = Engines()
        val daemon = FakeDaemon()
        daemon.caps = daemon.caps.copy(ready = false, unavailable_reason = "No graphical session")
        val session = session(engines)
        onCore { session.connect { daemon.route() } }
        assertEquals(ScreenPhase.Unsupported("No graphical session"), session.view.await { it.phase is ScreenPhase.Unsupported }.phase)
        assertTrue(engines.created.isEmpty())
    }

    @Test
    fun daemonGoldenBindingVerifiesWithTheJdk() {
        val fixture = Properties().apply {
            load(java.io.File("../../android/app/src/test/resources/screen-trust.properties").inputStream())
        }
        fun bytes(name: String) = Base64.getDecoder().decode(fixture.getProperty(name)).toByteString()
        val offer = "test offer"
        val request = StartRemoteDesktopRequest(
            client_nonce = "nonce", offer = RemoteDesktopSessionDescription(type = "offer", sdp = offer), control = true, display_id = "primary", input_protocol_version = 3,
        )
        val binding = RemoteDesktopSessionBinding(
            client_nonce = "nonce", helper_dtls_fingerprint = "sha-256 01:23:45", expires_at = "2100-01-01T00:00:00Z",
            offer_sha256 = offer.encodeUtf8().sha256(), daemon_signature = bytes("signature"), control_granted = true, display_id = "primary",
            input_protocol_version = 3, input_epoch = bytes("epoch"),
        )
        val pem = bytes("certificate").utf8()
        val now = Instant.parse("2026-09-30T00:00:00Z")
        fun verify(value: RemoteDesktopSessionBinding = binding, answer: String = "a=fingerprint:sha-256 01:23:45\r\n", sdp: String = offer) =
            ScreenTrust.verify(value, "session", request.copy(offer = RemoteDesktopSessionDescription(type = "offer", sdp = sdp)), answer, pem, now, JcaSignatureVerifier)
        verify()
        assertFailsWith<IllegalStateException> { verify(sdp = "other offer") }
        assertFailsWith<IllegalStateException> { verify(answer = "a=fingerprint:sha-256 01:23:45\na=fingerprint:sha-256 99:99") }
        listOf(
            binding.copy(control_granted = false), binding.copy(display_id = "secondary"), binding.copy(input_epoch = ByteArray(16).toByteString()),
            binding.copy(input_protocol_version = 0), binding.copy(expires_at = "2020-01-01T00:00:00Z"), binding.copy(daemon_signature = ByteArray(64).toByteString()),
        ).forEach { value -> assertFailsWith<IllegalStateException> { verify(value) } }
    }
}

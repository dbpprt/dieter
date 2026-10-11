package com.getdieter.core

import com.getdieter.api.gateway.v1.RTCConfiguration
import com.getdieter.api.v1.ConfirmRemoteDesktopVirtualDisplayRequest
import com.getdieter.api.v1.RemoteDesktopCapabilities
import com.getdieter.api.v1.RemoteDesktopControlRequest
import com.getdieter.api.v1.RemoteDesktopICECandidate
import com.getdieter.api.v1.RemoteDesktopInput
import com.getdieter.api.v1.RemoteDesktopReceiverFeedback
import com.getdieter.api.v1.RemoteDesktopRef
import com.getdieter.api.v1.RemoteDesktopSessionBinding
import com.getdieter.api.v1.RemoteDesktopSessionDescription
import com.getdieter.api.v1.RemoteDesktopSessionState
import com.getdieter.api.v1.RemoteDesktopSignal
import com.getdieter.api.v1.RemoteDesktopVirtualDisplay
import com.getdieter.api.v1.SetRemoteDesktopVirtualDisplayRequest
import com.getdieter.api.v1.StartRemoteDesktopRequest
import com.getdieter.api.v1.UpdateRemoteDesktopSessionRequest
import com.getdieter.core.api.DaemonApi
import com.getdieter.core.screens.LocalClipboard
import com.getdieter.core.screens.PeerState
import com.getdieter.core.screens.RtpCodec
import com.getdieter.core.screens.ScreenChannels
import com.getdieter.core.screens.ScreenConfig
import com.getdieter.core.screens.ScreenMediaCapabilities
import com.getdieter.core.screens.ScreenMediaConfig
import com.getdieter.core.screens.ScreenMediaEngine
import com.getdieter.core.screens.ScreenMediaEngineFactory
import com.getdieter.core.screens.ScreenMediaEvents
import com.getdieter.core.screens.ScreenPhase
import com.getdieter.core.screens.ScreenRoute
import com.getdieter.core.screens.ScreenSession
import com.getdieter.core.screens.ScreenTrust
import com.getdieter.core.screens.ViewportPolicy
import com.getdieter.core.testing.JcaSignatureVerifier
import com.getdieter.core.testing.PrintLogger
import com.getdieter.core.testing.TestMachineKey
import com.squareup.wire.GrpcCall
import com.squareup.wire.GrpcException
import com.squareup.wire.GrpcServerStreamingCall
import com.squareup.wire.GrpcStatus
import java.lang.reflect.Proxy
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicInteger
import kotlin.test.AfterTest
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import kotlin.time.Clock
import kotlin.time.Duration.Companion.hours
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.seconds
import kotlin.time.Instant
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.cancel
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.channels.ReceiveChannel
import kotlinx.coroutines.channels.SendChannel
import kotlinx.coroutines.channels.produce
import kotlinx.coroutines.delay
import kotlinx.coroutines.selects.select
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import okio.ByteString.Companion.encodeUtf8
import okio.ByteString.Companion.toByteString

/**
 * A screen session against a scripted daemon and a scripted media engine, shared by the session's
 * tests. Tests of timers run the session on the test scheduler, in virtual time.
 */
abstract class ScreenSessionHarness {
    protected val core = Dispatchers.Default.limitedParallelism(1)
    protected val scope = CoroutineScope(SupervisorJob() + core)
    protected val key = TestMachineKey()

    @AfterTest fun tearDown() = scope.cancel()

    protected class FakeEngine(val events: ScreenMediaEvents) : ScreenMediaEngine {
        val open = mutableSetOf<String>()
        val sent = ConcurrentLinkedQueue<Pair<String, ByteArray>>()
        var answer: String? = null
        val candidates = CopyOnWriteArrayList<RemoteDesktopICECandidate>()
        var candidatesBeforeAnswer = 0
        var closed = false
        var presenting = false
        private var timestamp = 1200u

        override suspend fun createOffer() = "v=0\r\no=- 1 1 IN IP4 127.0.0.1\r\n"

        override suspend fun applyAnswer(sdp: String) {
            answer = sdp
        }

        override suspend fun addRemoteCandidate(candidate: RemoteDesktopICECandidate) {
            if (answer == null) candidatesBeforeAnswer++
            candidates += candidate
        }

        override fun send(label: String, bytes: ByteArray): Boolean =
            (label in open).also { if (it) sent += label to bytes }

        override fun isOpen(label: String) = label in open

        override fun bufferedAmount(label: String) = 0L

        override suspend fun statistics(): RemoteDesktopReceiverFeedback? {
            if (presenting) events.presented(++timestamp)
            return RemoteDesktopReceiverFeedback(frames_per_second = if (presenting) 60.0 else 0.0)
        }

        override fun updateFrameGate(
            token: Long,
            displayGeneration: Long,
            mediaGeneration: Long,
            mediaTimestamp: UInt,
        ) = Unit

        override fun resetVideo() = Unit

        override fun close() {
            closed = true
        }

        fun connect() {
            open += listOf(ScreenChannels.POINTER, ScreenChannels.INPUT, ScreenChannels.SESSION)
            open.forEach { events.channelState(it, true) }
            events.peerState(PeerState.CONNECTED)
        }

        fun inputs(label: String) =
            sent.filter { it.first == label }.map { RemoteDesktopInput.ADAPTER.decode(it.second) }
    }

    protected class Engines : ScreenMediaEngineFactory {
        val created = CopyOnWriteArrayList<FakeEngine>()
        override val capabilities =
            ScreenMediaCapabilities(
                listOf(RtpCodec("H264", "640c1f")),
                hevcDecoder = false,
                referenceDependencies = false,
                millisecondTimestamps = false,
            )

        override fun create(
            config: ScreenMediaConfig,
            events: ScreenMediaEvents,
        ): ScreenMediaEngine = FakeEngine(events).also { created += it }
    }

    /** A scripted daemon: each start opens a stream the test drives through [signals]. */
    protected inner class FakeDaemon(
        val sessionId: String = "rd_test",
        val forge: Boolean = false,
    ) {
        val virtualCreates = CopyOnWriteArrayList<SetRemoteDesktopVirtualDisplayRequest>()
        val virtualConfirms = CopyOnWriteArrayList<ConfirmRemoteDesktopVirtualDisplayRequest>()
        val virtualRestores = AtomicInteger()
        var virtual: RemoteDesktopVirtualDisplay? = null
        var virtualGeneration = 1L
        val starts = CopyOnWriteArrayList<StartRemoteDesktopRequest>()
        val closes = CopyOnWriteArrayList<String>()
        val updates = CopyOnWriteArrayList<UpdateRemoteDesktopSessionRequest>()
        val controls = CopyOnWriteArrayList<RemoteDesktopControlRequest>()
        val routeReads = AtomicInteger()
        val capabilityReads = AtomicInteger()
        val heartbeats = AtomicInteger()

        /**
         * RPC names whose next call is never answered, like a daemon that stopped responding; each
         * entry holds one call.
         */
        val unanswered = CopyOnWriteArrayList<String>()
        val signals = Channel<RemoteDesktopSignal>(Channel.UNLIMITED)
        val streamFailures = Channel<Throwable>(Channel.UNLIMITED)
        val startFailures = ArrayDeque<GrpcStatus>()
        private val bindings = mutableMapOf<String, RemoteDesktopSessionBinding>()
        val epoch = ByteArray(16) { 7 }.toByteString()
        var caps =
            RemoteDesktopCapabilities(
                platform = "darwin",
                ready = true,
                input_protocol_version = 3,
                control_supported = true,
                control_permission = "granted",
                cursor_supported = true,
                max_fps = 60,
            )

        fun state(
            generation: Long,
            timestamp: Int,
            phase: String = "streaming",
            reason: String = "",
        ) =
            RemoteDesktopSessionState(
                phase = phase,
                reason = reason,
                display_id = "primary",
                display_generation = generation,
                media_generation = generation,
                media_timestamp = timestamp,
                control_active = true,
                control_generation = 1,
                codec = "H264",
            )

        val client: DaemonApi =
            Proxy.newProxyInstance(
                DaemonApi::class.java.classLoader,
                arrayOf(DaemonApi::class.java),
            ) { _, method, _ ->
                when (method.name) {
                    "SetRemoteDesktopVirtualDisplay" ->
                        unary<SetRemoteDesktopVirtualDisplayRequest, RemoteDesktopVirtualDisplay>(
                            method.name
                        ) {
                            virtualCreates += it
                            virtualGeneration++
                            RemoteDesktopVirtualDisplay(
                                    active = true,
                                    display_id = "virtual",
                                    pixel_width = it.pixel_width,
                                    pixel_height = it.pixel_height,
                                    scale = it.scale,
                                    awaiting_presentation = it.disable_physical,
                                )
                                .also { result -> virtual = result }
                        }
                    "ConfirmRemoteDesktopVirtualDisplay" ->
                        unary<
                            ConfirmRemoteDesktopVirtualDisplayRequest,
                            RemoteDesktopVirtualDisplay,
                        >(
                            method.name
                        ) {
                            virtualConfirms += it
                            virtual!!.copy(awaiting_presentation = false, physical_disabled = true)
                        }
                    "RestoreRemoteDesktopVirtualDisplay" ->
                        unary<RemoteDesktopRef, RemoteDesktopVirtualDisplay>(method.name) {
                            virtualRestores.incrementAndGet()
                            virtual = null
                            virtualGeneration++
                            signals.trySend(
                                RemoteDesktopSignal(
                                    session_id = sessionId,
                                    state =
                                        state(virtualGeneration, 3000)
                                            .copy(control_generation = virtualGeneration),
                                )
                            )
                            RemoteDesktopVirtualDisplay()
                        }
                    "GetRemoteDesktopCapabilities" ->
                        unary<Unit, RemoteDesktopCapabilities>(method.name) {
                            capabilityReads.incrementAndGet()
                            caps
                        }
                    "SendRemoteDesktopSignal" ->
                        unary<RemoteDesktopSignal, Unit>(method.name) {
                            if (it.lease_heartbeat != null) heartbeats.incrementAndGet()
                        }
                    "CloseRemoteDesktop" ->
                        unary<RemoteDesktopRef, Unit>(method.name) { closes += it.session_id }
                    "UpdateRemoteDesktopSession" ->
                        unary<UpdateRemoteDesktopSessionRequest, RemoteDesktopSessionState>(
                            method.name
                        ) {
                            updates += it
                            if (virtual != null)
                                state(virtualGeneration, 2000)
                                    .copy(
                                        display_id = "virtual",
                                        virtual_display = virtual,
                                        control_generation = virtualGeneration,
                                    )
                            else
                                state(virtualGeneration, 1000)
                                    .copy(control_generation = virtualGeneration)
                        }
                    "SetRemoteDesktopControl" ->
                        unary<RemoteDesktopControlRequest, RemoteDesktopSessionState>(method.name) {
                            controls += it
                            state(1, 1000)
                        }
                    "StartRemoteDesktop" ->
                        stream<StartRemoteDesktopRequest, RemoteDesktopSignal> { request ->
                            starts += request
                            if (startFailures.isNotEmpty())
                                throw GrpcException(
                                    startFailures.removeFirst(),
                                    "scripted signaling failure",
                                )
                            val binding =
                                bindings.getOrPut(request.client_nonce) {
                                    RemoteDesktopSessionBinding(
                                        client_nonce = request.client_nonce,
                                        helper_dtls_fingerprint = "sha-256 01:23",
                                        expires_at = (Clock.System.now() + 1.hours).toString(),
                                        offer_sha256 = request.offer!!.sdp.encodeUtf8().sha256(),
                                        control_granted = request.control,
                                        display_id = "primary",
                                        input_protocol_version = 3,
                                        input_epoch = epoch,
                                    )
                                }
                            val signature =
                                key.sign(ScreenTrust.message(sessionId, binding).toByteArray())
                                    .also { if (forge) it[0] = (it[0] + 1).toByte() }
                            send(
                                RemoteDesktopSignal(
                                    session_id = sessionId,
                                    binding =
                                        binding.copy(daemon_signature = signature.toByteString()),
                                )
                            )
                            send(
                                RemoteDesktopSignal(
                                    session_id = sessionId,
                                    description =
                                        RemoteDesktopSessionDescription(
                                            type = "answer",
                                            sdp = "v=0\r\na=fingerprint:sha-256 01:23\r\n",
                                        ),
                                )
                            )
                            send(
                                RemoteDesktopSignal(
                                    session_id = sessionId,
                                    candidate =
                                        RemoteDesktopICECandidate(
                                            candidate = "candidate:1 1 udp 1 127.0.0.1 9 typ host"
                                        ),
                                )
                            )
                            while (true) select<Unit> {
                                signals.onReceive { send(it) }
                                streamFailures.onReceive { throw it }
                            }
                        }
                    else -> error("unexpected RPC ${method.name}")
                }
            } as DaemonApi

        fun route(): ScreenRoute {
            routeReads.incrementAndGet()
            return ScreenRoute(client, key.certificatePem, RTCConfiguration(), "direct")
        }

        /**
         * A unary call that records its request through [answer], then replies unless the test left
         * it unanswered.
         */
        private fun <S : Any, R : Any> unary(name: String, answer: (S) -> R): GrpcCall<S, R> =
            object : GrpcCall<S, R> by GrpcCall(answer) {
                override suspend fun execute(request: S): R {
                    val reply = answer(request)
                    if (unanswered.remove(name)) awaitCancellation()
                    return reply
                }
            }

        /**
         * A server stream produced in the caller's scope, so a session on the test scheduler sees
         * each signal in virtual time.
         */
        private fun <S : Any, R : Any> stream(
            body: suspend SendChannel<R>.(S) -> Unit
        ): GrpcServerStreamingCall<S, R> =
            object : GrpcServerStreamingCall<S, R> by GrpcServerStreamingCall(body) {
                private var produced: ReceiveChannel<R>? = null

                override suspend fun executeIn(
                    scope: CoroutineScope,
                    request: S,
                ): ReceiveChannel<R> {
                    val channel = scope.produce<R> { body(this, request) }
                    produced = channel
                    return channel
                }

                override fun cancel() {
                    produced?.cancel()
                }
            }
    }

    protected fun session(engines: Engines) =
        ScreenSession(
            engines,
            JcaSignatureVerifier,
            ScreenConfig("Test", ViewportPolicy.Fixed),
            Clock.System,
            scope,
            PrintLogger,
        )

    /** A session on the test scheduler: its lease, deadlines, and recovery run in virtual time. */
    protected fun TestScope.virtualSession(
        engines: Engines,
        viewport: ViewportPolicy = ViewportPolicy.Fixed,
        clipboard: LocalClipboard? = null,
    ): ScreenSession {
        val start = Clock.System.now()
        val clock =
            object : Clock {
                override fun now(): Instant = start + testScheduler.currentTime.milliseconds
            }
        return ScreenSession(
            engines,
            JcaSignatureVerifier,
            ScreenConfig("Test", viewport),
            clock,
            backgroundScope,
            PrintLogger,
            clipboard,
        )
    }

    /** Connects [session] in virtual time until it streams under this client's control. */
    protected suspend fun TestScope.streaming(
        session: ScreenSession,
        daemon: FakeDaemon,
        engines: Engines,
        clipboard: Boolean = false,
    ): FakeEngine {
        session.connect { daemon.route() }
        runCurrent()
        val engine = engines.created.single()
        if (clipboard) engine.open += ScreenChannels.CLIPBOARD
        engine.connect()
        val state = daemon.state(1, 1000)
        daemon.signals.send(
            RemoteDesktopSignal(
                session_id = "rd_test",
                state =
                    if (clipboard) state.copy(clipboard_enabled = true, clipboard_generation = 1)
                    else state,
            )
        )
        runCurrent()
        engine.presenting = true
        engine.events.presented(1200u)
        runCurrent()
        val view = session.view.value
        assertEquals(ScreenPhase.Streaming, view.phase)
        assertTrue(view.controlActive)
        return engine
    }

    protected suspend fun <T> onCore(block: () -> T): T = withContext(core) { block() }

    /** Polls a condition that is not published through the view. */
    protected suspend fun eventually(
        describe: () -> String = { "condition" },
        condition: () -> Boolean,
    ) {
        withTimeoutOrNull(10.seconds) { while (!onCore(condition)) delay(20) }
            ?: error("timed out waiting for ${describe()}")
    }
}

package com.dbpprt.dieter.core

import com.dbpprt.dieter.api.gateway.v1.RTCConfiguration
import com.dbpprt.dieter.api.v1.ConfirmRemoteDesktopVirtualDisplayRequest
import com.dbpprt.dieter.api.v1.DieterServiceClient
import com.dbpprt.dieter.api.v1.RemoteDesktopCapabilities
import com.dbpprt.dieter.api.v1.RemoteDesktopClipboardFrame
import com.dbpprt.dieter.api.v1.RemoteDesktopClipboardItem
import com.dbpprt.dieter.api.v1.RemoteDesktopClipboardRequest
import com.dbpprt.dieter.api.v1.RemoteDesktopClipboardResponse
import com.dbpprt.dieter.api.v1.RemoteDesktopControlRequest
import com.dbpprt.dieter.api.v1.RemoteDesktopHostEvent
import com.dbpprt.dieter.api.v1.RemoteDesktopICECandidate
import com.dbpprt.dieter.api.v1.RemoteDesktopInput
import com.dbpprt.dieter.api.v1.RemoteDesktopReceiverFeedback
import com.dbpprt.dieter.api.v1.RemoteDesktopRef
import com.dbpprt.dieter.api.v1.RemoteDesktopSessionBinding
import com.dbpprt.dieter.api.v1.RemoteDesktopSessionDescription
import com.dbpprt.dieter.api.v1.RemoteDesktopSessionState
import com.dbpprt.dieter.api.v1.RemoteDesktopSignal
import com.dbpprt.dieter.api.v1.RemoteDesktopVirtualDisplay
import com.dbpprt.dieter.api.v1.SetRemoteDesktopVirtualDisplayRequest
import com.dbpprt.dieter.api.v1.StartRemoteDesktopRequest
import com.dbpprt.dieter.api.v1.UpdateRemoteDesktopSessionRequest
import com.dbpprt.dieter.core.runtime.Deadlines
import com.dbpprt.dieter.core.screens.ClipboardFraming
import com.dbpprt.dieter.core.screens.LocalClipboard
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
import com.squareup.wire.GrpcException
import com.squareup.wire.GrpcServerStreamingCall
import com.squareup.wire.GrpcStatus
import java.lang.reflect.Proxy
import java.util.Base64
import java.util.Properties
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicInteger
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlin.time.Clock
import kotlin.time.Duration.Companion.hours
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.seconds
import kotlin.time.Instant
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.cancel
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.channels.ReceiveChannel
import kotlinx.coroutines.channels.SendChannel
import kotlinx.coroutines.channels.produce
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.selects.select
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import okio.ByteString.Companion.encodeUtf8
import okio.ByteString.Companion.toByteString

/**
 * The screen-session controller against a scripted daemon and a scripted media engine: trust,
 * streaming readiness, input routing, feedback, the session-replacement guard, fatal failures,
 * unanswered calls, and held work. Tests of timers run the session on the test scheduler, in
 * virtual time.
 */
class ScreenSessionTest {
    private val core = Dispatchers.Default.limitedParallelism(1)
    private val scope = CoroutineScope(SupervisorJob() + core)
    private val key = TestMachineKey()

    @AfterTest fun tearDown() = scope.cancel()

    private class FakeEngine(val events: ScreenMediaEvents) : ScreenMediaEngine {
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

    private class Engines : ScreenMediaEngineFactory {
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
    private inner class FakeDaemon(val sessionId: String = "rd_test", val forge: Boolean = false) {
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

        val client: DieterServiceClient =
            Proxy.newProxyInstance(
                DieterServiceClient::class.java.classLoader,
                arrayOf(DieterServiceClient::class.java),
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
            } as DieterServiceClient

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

    private fun session(engines: Engines) =
        ScreenSession(
            engines,
            JcaSignatureVerifier,
            ScreenConfig("Test", ViewportPolicy.Fixed),
            Clock.System,
            scope,
            PrintLogger,
        )

    /** A session on the test scheduler: its lease, deadlines, and recovery run in virtual time. */
    private fun TestScope.virtualSession(
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
    private suspend fun TestScope.streaming(
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

    private suspend fun <T> onCore(block: () -> T): T = withContext(core) { block() }

    /** Polls a condition that is not published through the view. */
    private suspend fun eventually(
        describe: () -> String = { "condition" },
        condition: () -> Boolean,
    ) {
        withTimeoutOrNull(10.seconds) { while (!onCore(condition)) delay(20) }
            ?: error("timed out waiting for ${describe()}")
    }

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
    fun clipboardSharingToggleIsConfiguredOnTheHost() = runBlocking {
        val engines = Engines()
        val daemon = FakeDaemon()
        daemon.caps = daemon.caps.copy(clipboard_supported = true)
        val session = session(engines)
        onCore { session.connect { daemon.route() } }
        session.view.await { it.sessionId == "rd_test" }
        val engine = engines.created.single()
        eventually { engine.answer != null }
        onCore {
            engine.open += ScreenChannels.CLIPBOARD
            engine.connect()
        }
        daemon.signals.send(
            RemoteDesktopSignal(
                session_id = "rd_test",
                state =
                    daemon.state(1, 1000).copy(clipboard_enabled = true, clipboard_generation = 1),
            )
        )
        onCore { engine.events.presented(1200u) }
        session.view.await { it.controlActive && it.clipboardEnabled }

        val toggle = scope.async { session.setClipboardEnabled(false) }
        eventually { engine.sent.any { it.first == ScreenChannels.CLIPBOARD } }
        val frame =
            RemoteDesktopClipboardFrame.ADAPTER.decode(
                engine.sent.first { it.first == ScreenChannels.CLIPBOARD }.second
            )
        val request = RemoteDesktopClipboardRequest.ADAPTER.decode(frame.data_)
        assertEquals(RemoteDesktopClipboardRequest.Action.CONFIGURE, request.action)
        assertEquals(false, request.enabled)
        assertEquals(daemon.epoch, request.input_epoch)
        val response =
            RemoteDesktopClipboardResponse.ADAPTER.encodeByteString(
                RemoteDesktopClipboardResponse(operation_id = request.operation_id, enabled = false)
            )
        ClipboardFraming.frames(request.operation_id, response).forEach { reply ->
            onCore {
                engine.events.channelMessage(
                    ScreenChannels.CLIPBOARD,
                    RemoteDesktopClipboardFrame.ADAPTER.encode(reply),
                )
            }
        }
        toggle.await()
        val off = session.view.await { !it.clipboardEnabled }
        assertEquals(null, off.clipboardError)
        assertEquals(false, onCore { session.preferences.clipboard })
        onCore { session.disconnect() }
    }

    @Test
    fun aUserPasteWaitsForTheBackgroundSyncAndASecondOperationIsRefused() = runBlocking {
        val engines = Engines()
        val daemon = FakeDaemon()
        daemon.caps = daemon.caps.copy(clipboard_supported = true)
        val local =
            object : LocalClipboard {
                override fun stamp() = 1L

                override fun read(binary: Boolean) =
                    "pasted text" to emptyList<RemoteDesktopClipboardItem>()

                override fun apply(text: String, items: List<RemoteDesktopClipboardItem>) = Unit
            }
        val session =
            ScreenSession(
                engines,
                JcaSignatureVerifier,
                ScreenConfig("Test", ViewportPolicy.Fixed),
                Clock.System,
                scope,
                PrintLogger,
                local,
            )
        onCore { session.connect { daemon.route() } }
        session.view.await { it.sessionId == "rd_test" }
        val engine = engines.created.single()
        eventually { engine.answer != null }
        onCore {
            engine.open += ScreenChannels.CLIPBOARD
            engine.connect()
        }
        daemon.signals.send(
            RemoteDesktopSignal(
                session_id = "rd_test",
                state =
                    daemon.state(1, 1000).copy(clipboard_enabled = true, clipboard_generation = 1),
            )
        )
        onCore { engine.events.presented(1200u) }
        session.view.await { it.controlActive && it.clipboardEnabled }
        fun requests() =
            engine.sent
                .filter { it.first == ScreenChannels.CLIPBOARD }
                .map {
                    RemoteDesktopClipboardRequest.ADAPTER.decode(
                        RemoteDesktopClipboardFrame.ADAPTER.decode(it.second).data_
                    )
                }
        suspend fun answer(request: RemoteDesktopClipboardRequest, revision: String) {
            val response =
                RemoteDesktopClipboardResponse.ADAPTER.encodeByteString(
                    RemoteDesktopClipboardResponse(
                        operation_id = request.operation_id,
                        revision = revision,
                    )
                )
            ClipboardFraming.frames(request.operation_id, response).forEach { reply ->
                onCore {
                    engine.events.channelMessage(
                        ScreenChannels.CLIPBOARD,
                        RemoteDesktopClipboardFrame.ADAPTER.encode(reply),
                    )
                }
            }
        }

        // The background sync's read is in flight and unanswered.
        eventually({ "a background read" }) { requests().isNotEmpty() }
        val read = requests().single()
        assertEquals(RemoteDesktopClipboardRequest.Action.READ, read.action)
        val paste = scope.async { session.performClipboard("paste") }
        session.view.await { it.clipboardBusy }
        onCore {}
        assertEquals(1, requests().size, "the paste waits for the exchange in flight")
        assertEquals(null, session.view.value.clipboardError)
        withContext(core) { session.performClipboard("copy") }
        assertEquals(
            "A clipboard operation is still in progress",
            session.view.value.clipboardError,
        )

        answer(read, "r1")
        eventually({ "the paste request" }) { requests().size == 2 }
        val pasted = requests()[1]
        assertEquals(RemoteDesktopClipboardRequest.Action.PASTE, pasted.action)
        assertEquals("pasted text", pasted.text)
        assertEquals("r1", pasted.known_revision)
        answer(pasted, "r2")
        paste.await()
        val done = session.view.await { !it.clipboardBusy && it.clipboardOperations == 1 }
        assertEquals(null, done.clipboardError)
        onCore { session.disconnect() }
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
        advanceTimeBy(ScreenSession.LEASE_INTERVAL)
        runCurrent()
        assertEquals(1, daemon.heartbeats.get())
        advanceTimeBy(Deadlines.CALL + ScreenSession.LEASE_INTERVAL)
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
        advanceTimeBy(ScreenSession.CONFIGURATION_RETRY)
        runCurrent()
        assertEquals(2, daemon.updates.size, "desired configuration is retried")
        assertEquals(1, daemon.starts.size, "healthy video keeps its session")
        session.disconnect()
    }

    @Test
    fun aClipboardExchangeThatTimesOutDoesNotEndTheSync() = runTest {
        val engines = Engines()
        val daemon = FakeDaemon()
        daemon.caps = daemon.caps.copy(clipboard_supported = true)
        val local =
            object : LocalClipboard {
                override fun stamp() = 1L

                override fun read(binary: Boolean) = "" to emptyList<RemoteDesktopClipboardItem>()

                override fun apply(text: String, items: List<RemoteDesktopClipboardItem>) = Unit
            }
        val session = virtualSession(engines, clipboard = local)
        val engine = streaming(session, daemon, engines, clipboard = true)
        fun reads() = engine.sent.count { it.first == ScreenChannels.CLIPBOARD }
        // The background sync reads the host's clipboard; the host never answers.
        advanceTimeBy(ScreenSession.CLIPBOARD_POLL)
        runCurrent()
        assertEquals(1, reads())
        advanceTimeBy(ScreenSession.CLIPBOARD_TIMEOUT + ScreenSession.CLIPBOARD_POLL)
        runCurrent()
        assertEquals("Clipboard transfer timed out", session.view.value.clipboardError)
        assertEquals(2, reads(), "the next poll reads again")
        session.disconnect()
    }

    @Test
    fun admittedClipboardWorkDoesNotHoldDisconnectAndCannotOutliveItsSession() = runTest {
        for (toggle in listOf(false, true)) {
            val engines = Engines()
            val daemon = FakeDaemon()
            daemon.caps = daemon.caps.copy(clipboard_supported = true)
            val local =
                object : LocalClipboard {
                    override fun stamp() = 1L

                    override fun read(binary: Boolean) =
                        "owned clipboard" to emptyList<RemoteDesktopClipboardItem>()

                    override fun apply(text: String, items: List<RemoteDesktopClipboardItem>) = Unit
                }
            val session = virtualSession(engines, clipboard = local)
            val engine = streaming(session, daemon, engines, clipboard = true)
            if (toggle) session.requestClipboardEnabled(false)
            else session.requestClipboard("paste")
            runCurrent()
            assertTrue(
                session.view.value.clipboardBusy,
                "the admitted operation awaits the unanswered host",
            )
            assertTrue(engine.sent.any { it.first == ScreenChannels.CLIPBOARD })

            session.disconnect()
            runCurrent()
            assertEquals(ScreenPhase.Idle, session.view.value.phase)
            assertFalse(session.view.value.controlActive)
            assertFalse(session.view.value.clipboardBusy)
            assertTrue(engine.closed)
            assertEquals(0, session.heldJobs)
            val sent = engine.sent.size
            advanceTimeBy(ScreenSession.CLIPBOARD_TIMEOUT + ScreenSession.CLIPBOARD_POLL)
            runCurrent()
            assertEquals(sent, engine.sent.size, "cancelled work cannot send on the stopped peer")
            assertEquals(
                null,
                session.view.value.clipboardError,
                "the old timeout cannot alter the idle view",
            )
        }
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
        advanceTimeBy(Deadlines.CALL + ScreenSession.CONFIGURATION_RETRY)
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
            advanceTimeBy(ScreenSession.VIEWPORT_DEBOUNCE)
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

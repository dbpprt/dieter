package com.dbpprt.dieter.core.screens

import com.dbpprt.dieter.api.v1.RemoteDesktopCapabilities
import com.dbpprt.dieter.api.v1.RemoteDesktopClipboardItem
import com.dbpprt.dieter.api.v1.RemoteDesktopClipboardRequest
import com.dbpprt.dieter.api.v1.RemoteDesktopClipboardResponse
import com.dbpprt.dieter.api.v1.RemoteDesktopCodecPreference
import com.dbpprt.dieter.api.v1.RemoteDesktopControlRequest
import com.dbpprt.dieter.api.v1.RemoteDesktopCursor
import com.dbpprt.dieter.api.v1.RemoteDesktopHostEvent
import com.dbpprt.dieter.api.v1.RemoteDesktopICECandidate
import com.dbpprt.dieter.api.v1.RemoteDesktopInput
import com.dbpprt.dieter.api.v1.RemoteDesktopPointerButton
import com.dbpprt.dieter.api.v1.RemoteDesktopQuality
import com.dbpprt.dieter.api.v1.RemoteDesktopRef
import com.dbpprt.dieter.api.v1.RemoteDesktopSessionBinding
import com.dbpprt.dieter.api.v1.RemoteDesktopSessionState
import com.dbpprt.dieter.api.v1.RemoteDesktopSignal
import com.dbpprt.dieter.api.v1.RemoteDesktopStreamConfiguration
import com.dbpprt.dieter.api.v1.StartRemoteDesktopRequest
import com.dbpprt.dieter.api.v1.UpdateRemoteDesktopSessionRequest
import com.dbpprt.dieter.core.platform.SignatureVerifier
import com.dbpprt.dieter.core.runtime.CoreLogger
import com.dbpprt.dieter.core.runtime.Failures
import com.squareup.wire.GrpcException
import com.squareup.wire.GrpcStatus
import kotlin.coroutines.cancellation.CancellationException
import kotlin.time.Clock
import kotlin.time.Duration
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.seconds
import kotlin.time.Instant
import kotlin.uuid.Uuid
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.withTimeoutOrNull
import okio.ByteString
import okio.ByteString.Companion.toByteString

sealed interface ScreenPhase {
    data object Idle : ScreenPhase
    data object Loading : ScreenPhase
    data class PermissionRequired(val reason: String) : ScreenPhase
    data class Unsupported(val reason: String) : ScreenPhase
    data object Connecting : ScreenPhase
    data object WaitingForHostApproval : ScreenPhase
    data object Streaming : ScreenPhase
    data class Reconnecting(val reason: String? = null) : ScreenPhase
    data class Failed(val message: String) : ScreenPhase

    /** Holding or establishing a session, as opposed to resting or blocked. */
    val active: Boolean get() = this !is Idle && this !is Failed && this !is PermissionRequired && this !is Unsupported

    /** Why no session can run, when blocked. */
    val problem: String?
        get() = when (this) {
            is Failed -> message
            is PermissionRequired -> reason
            is Unsupported -> reason
            else -> null
        }

    val label: String
        get() = when (this) {
            Idle -> "Idle"
            Loading -> "Loading"
            is PermissionRequired -> "Permission required"
            is Unsupported -> "Unsupported"
            Connecting -> "Connecting"
            WaitingForHostApproval -> "Waiting for approval on Linux host"
            Streaming -> "Streaming"
            is Reconnecting -> "Reconnecting"
            is Failed -> "Failed"
        }
}

/** What local input a view change invalidates. */
enum class InputReset {
    NONE,

    /** The display changed: drop the gesture and pressed buttons. */
    GESTURE,

    /** Control was lost: drop everything held, including modifiers. */
    ALL,
    ;

    companion object {
        fun between(previous: ScreenView, next: ScreenView): InputReset = when {
            previous.controlActive && !next.controlActive -> ALL
            previous.state?.display_generation != next.state?.display_generation -> GESTURE
            else -> NONE
        }
    }
}

data class ScreenView(
    val phase: ScreenPhase = ScreenPhase.Idle,
    val capabilities: RemoteDesktopCapabilities? = null,
    val state: RemoteDesktopSessionState? = null,
    val sessionId: String = "",
    val ready: Boolean = false,
    val controlActive: Boolean = false,
    val canTransferControl: Boolean = false,
    val codecFallbackReason: String? = null,
    val clipboardEnabled: Boolean = false,
    val clipboardError: String? = null,
    /** A user copy, cut, paste, or sharing change is in flight. */
    val clipboardBusy: Boolean = false,
    /** User clipboard operations that completed successfully in this session. */
    val clipboardOperations: Int = 0,
    /** The host cursor: image and normalized position, when the host draws it separately. */
    val cursorImage: ByteString? = null,
    val cursorX: Double = 0.5,
    val cursorY: Double = 0.5,
    val cursorVisible: Boolean = false,
    /** The image's size and hotspot in host points; the image is drawn at this size. */
    val cursorWidth: Double = 0.0,
    val cursorHeight: Double = 0.0,
    val cursorHotspotX: Double = 0.0,
    val cursorHotspotY: Double = 0.0,
    val routeLabel: String = "",
    /** A take or release of control is in flight. */
    val controlTransferring: Boolean = false,
    /** Why the last take or release failed. */
    val controlError: String? = null,
)

data class ScreenConfig(
    val clientName: String,
    val viewport: ViewportPolicy,
    val fpsCeiling: Int = 120,
)

/**
 * One screen-sharing session with a machine. The native media engine only
 * moves pixels and packets; this controller owns signaling, trust, the lease,
 * recovery, configuration, input, and clipboard sync. Confined to the core
 * dispatcher; engine events hop onto it.
 */
class ScreenSession(
    private val engines: ScreenMediaEngineFactory,
    private val verifier: SignatureVerifier,
    private val config: ScreenConfig,
    private val clock: Clock,
    private val scope: CoroutineScope,
    private val logger: CoreLogger,
    private val localClipboard: LocalClipboard? = null,
) {
    private val mutableView = MutableStateFlow(ScreenView())
    val view: StateFlow<ScreenView> = mutableView.asStateFlow()

    // Controller scope: survives recovery.
    private var factory: ScreenRouteFactory? = null
    private val recovery = ScreenRecovery()
    private var hevcFailed = false
    private var certificatePin: String? = null
    var preferences = ScreenPreferences()
        private set
    private var focused = true
    private var recoveryJob: Job? = null
    private var closing: CompletableDeferred<Unit>? = null

    // Attempt scope: reset by stopSession.
    private var token = 0L
    private var attempt: Job? = null
    private val jobs = mutableListOf<Job>()
    private var route: ScreenRoute? = null
    private var engine: ScreenMediaEngine? = null
    private var request: StartRemoteDesktopRequest? = null
    private var binding: RemoteDesktopSessionBinding? = null
    private var answer: String? = null
    private var authorized = false
    private var remoteApplied = false
    private var sessionId = ""
    private val localCandidates = ArrayDeque<RemoteDesktopICECandidate>()
    private val remoteCandidates = ArrayDeque<RemoteDesktopICECandidate>()
    private var peerConnected = false
    private var presentedGeneration = 0L
    private var lastPresented: UInt? = null
    private var state: RemoteDesktopSessionState? = null
    private var encoder: ScreenInputEncoder? = null
    private var feedback: ScreenFeedback? = null
    private var references: ScreenReferences? = null
    private val cursors = CursorCache()
    private var peerSinceTicks = 0
    private var refreshedForNoFrame = false
    private var pendingPointer: Pair<Double, Double>? = null
    private var lastPointerAt: Instant? = null
    private var pointerFlush: Job? = null
    private var configuring = false
    private var configurationPending = false
    private var refreshPending = false
    private var clipboardAssembler: ClipboardFraming.Assembler? = null
    private var clipboardReply: CompletableDeferred<RemoteDesktopClipboardResponse>? = null
    private var clipboardRevision = ""
    private var clipboardStamp: Long? = null
    private var clipboardGrant = -1L
    /** One clipboard exchange at a time; the background sync skips while one runs. */
    private val clipboardExchange = Mutex()
    /** A user copy, cut, paste, or sharing change is pending; a second one is refused. */
    private var clipboardOperation = false

    private fun now() = clock.now()

    // --- Lifecycle --------------------------------------------------------------------

    /** Starts a new session through [routes]; an earlier session is closed first. */
    fun connect(routes: ScreenRouteFactory) {
        disconnect()
        factory = routes
        hevcFailed = false
        certificatePin = null
        mutableView.update { it.copy(codecFallbackReason = null) }
        beginAttempt()
    }

    /** The signaling route's client while a session runs, e.g. for resolution matching. */
    fun routeClient(): com.dbpprt.dieter.api.v1.DieterServiceClient? = route?.client

    fun disconnect() {
        recoveryJob?.cancel()
        recoveryJob = null
        factory = null
        stopSession()
        mutableView.update { ScreenView(phase = ScreenPhase.Idle) }
    }

    fun setPreferences(change: (ScreenPreferences) -> ScreenPreferences) {
        val previous = preferences
        preferences = change(preferences)
        when {
            previous.codec != preferences.codec -> {
                hevcFailed = false
                recover("Switching codec…", immediate = true)
            }
            previous != preferences && sessionId.isNotEmpty() -> configure()
        }
    }

    /** The device woke or the app returned to the foreground: start over at once. */
    fun resume() {
        focused = true
        if (factory != null) recover("Resuming…", immediate = true)
    }

    fun sleep() {
        releaseInput()
    }

    fun setFocused(value: Boolean) {
        if (!value) releaseInput()
        focused = value
        publishReadiness()
    }

    private fun beginAttempt() {
        val routes = factory ?: return
        val attemptToken = ++token
        mutableView.update { it.copy(phase = if (it.phase is ScreenPhase.Reconnecting) it.phase else ScreenPhase.Loading) }
        attempt = scope.launch {
            try {
                closing?.await()
                var watchdog = WATCHDOG
                val opened = withTimeoutOrNull(ROUTE_TIMEOUT) { routes() } ?: return@launch recover("Connection attempt timed out")
                if (attemptToken != token) return@launch opened.close()
                route = opened
                val pin = certificatePin
                if (pin != null && pin != opened.certificatePem) return@launch fail("The enrolled machine identity changed. Reconnect to verify it.")
                certificatePin = opened.certificatePem
                mutableView.update { it.copy(routeLabel = opened.label) }
                val caps = withTimeout(UNARY) { opened.client.GetRemoteDesktopCapabilities().execute(Unit) }
                if (attemptToken != token) return@launch
                mutableView.update { it.copy(capabilities = caps) }
                if (!caps.ready) {
                    val reason = caps.unavailable_reason.ifEmpty { "Screen sharing is unavailable on this machine." }
                    stopSession()
                    mutableView.update {
                        it.copy(phase = if (caps.availability == com.dbpprt.dieter.api.v1.RemoteDesktopAvailability.REMOTE_DESKTOP_AVAILABILITY_PERMISSION_REQUIRED) ScreenPhase.PermissionRequired(reason) else ScreenPhase.Unsupported(reason))
                    }
                    return@launch
                }
                if (caps.input_protocol_version != SCREEN_INPUT_PROTOCOL) return@launch fail("Update the Dieter daemon and client together")
                if (caps.platform == "linux") watchdog += LINUX_APPROVAL
                startWatchdog(attemptToken, watchdog)
                val media = engines.capabilities
                media.initializationFailure?.let { return@launch fail(it) }
                val effective = ScreenCodecs.effective(preferences.codec, hevcFailed)
                val fps = ScreenCapabilities.maxFps(preferences.maxFps, caps, config.fpsCeiling)
                val canHevc = ScreenCodecs.canHevc(caps, preferences.width, preferences.height, fps, media.hevcDecoder)
                val codecs = ScreenCodecs.receiveCodecs(media.receiveCodecs, RtpCodec::name, RtpCodec::profile, effective, canHevc)
                if (codecs.isEmpty()) return@launch fail("Selected codec unavailable. HEVC requires hardware decoding and an updated host at up to 1080p60.")
                val channels = buildList {
                    add(ScreenChannelSpec(ScreenChannels.POINTER, ordered = false, maxRetransmits = 0))
                    add(ScreenChannelSpec(ScreenChannels.INPUT, ordered = true))
                    add(ScreenChannelSpec(ScreenChannels.SESSION, ordered = true))
                    if (caps.clipboard_supported) add(ScreenChannelSpec(ScreenChannels.CLIPBOARD, ordered = true))
                }
                val created = engines.create(ScreenMediaConfig(opened.rtc, codecs, media.referenceDependencies, channels), Events(attemptToken))
                engine = created
                references = ScreenReferences(media.millisecondTimestamps)
                val offer = created.createOffer()
                if (attemptToken != token) return@launch
                val start = ScreenRequests.start(
                    Uuid.random().toString(), opened.rtc, offer, caps, preferences, effective, config.clientName,
                    referenceRecovery = media.referenceDependencies && offer.contains(GENERIC_FRAME_DESCRIPTOR), fpsCeiling = config.fpsCeiling,
                )
                request = start
                mutableView.update { it.copy(phase = if (ScreenCapabilities.needsHostApproval(caps)) ScreenPhase.WaitingForHostApproval else ScreenPhase.Connecting) }
                signal(attemptToken, opened, start)
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Throwable) {
                if (attemptToken != token) return@launch
                route?.failed(error)
                val message = error.message ?: Failures.message(error)
                if (error is ScreenTrustException || !ScreenFailures.retryable(error)) fail(message) else recover(message)
            }
        }
    }

    private fun startWatchdog(attemptToken: Long, timeout: Duration) {
        jobs += scope.launch {
            delay(timeout)
            val phase = view.value.phase
            if (attemptToken == token && !peerConnected && (phase is ScreenPhase.Loading || phase is ScreenPhase.Connecting || phase is ScreenPhase.WaitingForHostApproval || phase is ScreenPhase.Reconnecting)) {
                recover("Screen connection attempt timed out")
            }
        }
    }

    /** Receives signaling; a dropped stream resubscribes twice (after 1 s and 2 s) before recovering. */
    private suspend fun signal(attemptToken: Long, opened: ScreenRoute, start: StartRemoteDesktopRequest) {
        var retries = 0
        while (attemptToken == token) {
            val started = now()
            var failure: Throwable
            try {
                coroutineScope {
                    val call = opened.client.StartRemoteDesktop()
                    val signals = call.executeIn(this, start)
                    try {
                        for (received in signals) {
                            if (attemptToken != token) return@coroutineScope
                            handleSignal(attemptToken, received)
                        }
                    } finally {
                        call.cancel()
                    }
                }
                failure = GrpcException(GrpcStatus.UNAVAILABLE, "Screen-sharing signaling ended")
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (untrusted: ScreenTrustException) {
                // A forged or mismatched binding is fatal; resubscribing cannot fix it.
                return fail(untrusted.message ?: "The screen session could not be verified.")
            } catch (error: Throwable) {
                failure = error
            }
            if (attemptToken != token) return
            if (now() - started >= 10.seconds) retries = 0
            retries++
            if (retries > 2) {
                opened.failed(failure)
                val message = failure.message ?: Failures.message(failure)
                if (ScreenFailures.retryable(failure)) recover(message) else fail(message)
                return
            }
            if (!(peerConnected && presentedGeneration > 0)) mutableView.update { it.copy(phase = ScreenPhase.Reconnecting(null)) }
            delay(retries.seconds)
        }
    }

    private suspend fun handleSignal(attemptToken: Long, received: RemoteDesktopSignal) {
        if (received.session_id.isEmpty()) return fail("The screen session has no identity.")
        if (sessionId.isEmpty()) {
            sessionId = received.session_id
            mutableView.update { it.copy(sessionId = sessionId) }
            while (localCandidates.isNotEmpty()) sendCandidate(localCandidates.removeFirst())
            startLease(attemptToken)
            startMonitor(attemptToken)
        } else if (received.session_id != sessionId) {
            // The daemon replaced an expired session; never apply its answer to this peer.
            val replacement = received.session_id
            route?.let { current -> scope.launch { runCatching { withTimeout(CLOSE_TIMEOUT) { current.client.CloseRemoteDesktop().execute(RemoteDesktopRef(session_id = replacement)) } } } }
            return recover("The previous screen session expired")
        }
        received.binding?.let { incoming ->
            val stored = binding
            if (stored != null && stored != incoming) return fail("The screen session binding changed.")
            binding = incoming
        }
        received.description?.let { description ->
            if (description.type != "answer") return fail("The screen host sent an invalid answer.")
            val stored = answer
            if (stored != null && stored != description.sdp) return fail("The screen host changed its answer.")
            answer = description.sdp
        }
        received.candidate?.let { candidate ->
            if (remoteApplied) {
                engine?.addRemoteCandidate(candidate)
            } else {
                if (remoteCandidates.size >= MAX_CANDIDATES) return fail("The screen host sent too many network candidates.")
                remoteCandidates.addLast(candidate)
            }
        }
        received.state?.let { applyState(it) }
        received.error?.let { error ->
            when {
                error.code == "hevc_unavailable" -> hevcFallback()
                ScreenFailures.retryableError(error.code, error.message, error.recoverable) -> recover(error.message.ifEmpty { "The screen session was interrupted" })
                else -> fail(error.message.ifEmpty { "The screen session failed" })
            }
        }
        authorize()
    }

    /** Once both the binding and the answer arrived: verify, apply, and start feedback. */
    private suspend fun authorize() {
        if (authorized) return
        val boundSession = binding ?: return
        val sdp = answer ?: return
        val start = request ?: return
        val current = route ?: return
        ScreenTrust.verify(boundSession, sessionId, start, sdp, current.certificatePem, now(), verifier)
        authorized = true
        encoder = ScreenInputEncoder(boundSession.input_epoch)
        feedback = ScreenFeedback(boundSession.input_epoch).also { it.start(now()) }
        engine?.applyAnswer(sdp)
        remoteApplied = true
        while (remoteCandidates.isNotEmpty()) engine?.addRemoteCandidate(remoteCandidates.removeFirst())
        startFeedback(token)
        if (localClipboard != null && view.value.capabilities?.clipboard_supported == true) startClipboardSync(token)
        publishReadiness()
    }

    private fun startLease(attemptToken: Long) {
        jobs += scope.launch {
            while (attemptToken == token) {
                delay(LEASE_INTERVAL)
                val current = route ?: return@launch
                try {
                    withTimeout(UNARY) { current.client.SendRemoteDesktopSignal().execute(RemoteDesktopSignal(session_id = sessionId, lease_heartbeat = Unit)) }
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (error: Throwable) {
                    // A healthy peer survives missed renewals; feedback also renews the lease.
                    logger.debug(TAG, "lease renewal failed: ${Failures.message(error)}")
                    if (!peerConnected && attemptToken == token) mutableView.update { it.copy(phase = ScreenPhase.Reconnecting(null)) }
                }
            }
        }
    }

    private fun startMonitor(attemptToken: Long) {
        jobs += scope.launch {
            while (attemptToken == token) {
                delay(ScreenFeedback.INTERVAL)
                val current = engine ?: continue
                current.statistics()?.let { feedback?.update(it, now()) }
                feedback?.input(focused && view.value.controlActive, now())
                if (peerConnected && presentedGeneration == 0L && view.value.phase !is ScreenPhase.WaitingForHostApproval) {
                    peerSinceTicks++
                    if (peerSinceTicks == NO_FRAME_REFRESH_TICKS && !refreshedForNoFrame) {
                        refreshedForNoFrame = true
                        configure(refresh = true)
                    }
                    if (peerSinceTicks >= NO_FRAME_GIVE_UP_TICKS) {
                        if (state?.codec == ScreenCodecs.H265) hevcFallback() else recover("No screen frame was displayed")
                        return@launch
                    }
                }
            }
        }
    }

    private fun startFeedback(attemptToken: Long) {
        jobs += scope.launch {
            while (attemptToken == token) {
                sendFeedback()
                delay(ScreenFeedback.INTERVAL)
            }
        }
    }

    private fun sendFeedback() {
        val current = engine ?: return
        val pump = feedback ?: return
        if (!current.isOpen(ScreenChannels.SESSION) || current.bufferedAmount(ScreenChannels.SESSION) >= ScreenFeedback.SKIP_BUFFERED_BYTES) return
        current.send(ScreenChannels.SESSION, RemoteDesktopReceiverFeedbackAdapter.encode(pump.next(now())))
    }

    private fun sendCandidate(candidate: RemoteDesktopICECandidate) {
        val current = route ?: return
        val id = sessionId
        scope.launch {
            runCatching { withTimeout(UNARY) { current.client.SendRemoteDesktopSignal().execute(RemoteDesktopSignal(session_id = id, candidate = candidate)) } }
                .onFailure { if (it is CancellationException) throw it }
        }
    }

    // --- State ------------------------------------------------------------------------

    private fun applyState(incoming: RemoteDesktopSessionState) {
        if (incoming.phase == "closed") {
            val reason = incoming.reason
            return when {
                reason == ScreenFailures.HEVC_UNAVAILABLE -> hevcFallback()
                ScreenFailures.retryableClosure(reason) -> recover(reason)
                else -> fail(reason.ifEmpty { "The screen session closed" })
            }
        }
        val merged = ScreenStates.merge(state, incoming) ?: return
        if (merged.displayChanged) {
            releaseInput()
            presentedGeneration = 0
            engine?.resetVideo()
            cursors.clear()
            if (view.value.phase is ScreenPhase.Streaming) mutableView.update { it.copy(phase = ScreenPhase.Connecting) }
        }
        state = merged.state
        if (merged.clipboardChanged) {
            clipboardRevision = ""
            clipboardStamp = null
        }
        engine?.updateFrameGate(token, merged.state.display_generation, merged.state.media_generation, merged.state.media_timestamp.toUInt())
        mutableView.update { it.copy(state = merged.state, clipboardEnabled = merged.state.clipboard_enabled) }
        lastPresented?.let(::markPresented)
        publishReadiness()
    }

    private fun markPresented(timestamp: UInt) {
        val current = state ?: return
        val media = current.media_generation
        if (media > 0 && media == current.display_generation &&
            ScreenStates.belongsToGeneration(timestamp, current.media_timestamp.toUInt(), engines.capabilities.millisecondTimestamps)
        ) {
            if (presentedGeneration != current.display_generation) {
                presentedGeneration = current.display_generation
                recovery.streaming(now())
            }
            if (peerConnected) mutableView.update { it.copy(phase = ScreenPhase.Streaming) }
            publishReadiness()
        }
    }

    private fun publishReadiness() {
        val current = state
        val bound = binding
        val ready = authorized && peerConnected && presentedGeneration > 0 && current != null && presentedGeneration == current.display_generation &&
            (preferences.displayId == null || preferences.displayId == current.display_id)
        val channels = engine?.let { it.isOpen(ScreenChannels.POINTER) && it.isOpen(ScreenChannels.INPUT) && it.isOpen(ScreenChannels.SESSION) } == true
        val control = ready && channels && bound?.control_granted == true && current.control_active && focused
        feedback?.input(focused && control, now())
        mutableView.update { it.copy(ready = ready, controlActive = control, canTransferControl = bound?.control_granted == true) }
    }

    private fun hostEvent(bytes: ByteArray) {
        if (!authorized || bytes.size > ScreenChannels.MAX_HOST_EVENT_BYTES) return
        val event = runCatching { RemoteDesktopHostEvent.ADAPTER.decode(bytes) }.getOrElse { return fail("The screen host sent an invalid event.") }
        event.state?.let(::applyState)
        event.input_ack?.let { ack -> state = state?.copy(last_input_ordinal = ack) }
        event.reference?.let { reference ->
            val acked = references?.expect(reference, now()).orEmpty()
            if (acked.isNotEmpty()) {
                feedback?.acknowledge(acked)
                sendFeedback()
            }
        }
        event.cursor?.let(::cursor)
    }

    private fun cursor(value: RemoteDesktopCursor) {
        val current = state ?: return
        if (value.display_generation != current.display_generation) return
        val image = cursors.accept(value)
        val adopt = CursorCache.adoptHostPosition(false, holdingCursor, false, value.last_input_ordinal, encoder?.lastPointerOrdinal ?: 0, lastPointerAt?.let { now() - it } ?: Duration.INFINITE)
        mutableView.update {
            it.copy(
                cursorImage = image, cursorVisible = value.visible,
                cursorWidth = value.width, cursorHeight = value.height, cursorHotspotX = value.hotspot_x, cursorHotspotY = value.hotspot_y,
                cursorX = if (adopt) value.normalized_x / 1_000_000.0 else it.cursorX,
                cursorY = if (adopt) value.normalized_y / 1_000_000.0 else it.cursorY,
            )
        }
    }

    /** Set by the gesture layer while a finger holds the cursor, so host updates do not fight it. */
    var holdingCursor = false

    // --- Recovery ---------------------------------------------------------------------

    private fun hevcFallback() {
        if (preferences.codec == RemoteDesktopCodecPreference.REMOTE_DESKTOP_CODEC_PREFERENCE_AUTO && !hevcFailed) {
            hevcFailed = true
            mutableView.update { it.copy(codecFallbackReason = "HEVC unavailable; using H.264") }
            recover("HEVC unavailable; using H.264", immediate = true)
        } else {
            fail("HEVC hardware codec could not initialize")
        }
    }

    private fun recover(reason: String, immediate: Boolean = false) {
        if (factory == null) return fail(reason)
        stopSession()
        mutableView.update { it.copy(phase = ScreenPhase.Reconnecting(reason), ready = false, controlActive = false) }
        val wait = if (immediate) Duration.ZERO else recovery.nextDelay(now())
        val expected = token
        recoveryJob?.cancel()
        recoveryJob = scope.launch {
            delay(wait)
            if (expected == token && factory != null) beginAttempt()
        }
    }

    private fun fail(message: String) {
        stopSession()
        mutableView.update { it.copy(phase = ScreenPhase.Failed(message), ready = false, controlActive = false) }
    }

    private fun stopSession() {
        token++
        authorized = false
        releaseInput()
        attempt?.cancel()
        attempt = null
        jobs.forEach(Job::cancel)
        jobs.clear()
        pointerFlush?.cancel()
        references?.stop()
        clipboardReply?.cancel()
        runCatching { engine?.close() }
        engine = null
        val oldRoute = route
        val oldSession = sessionId
        if (oldRoute != null) {
            val done = CompletableDeferred<Unit>()
            closing = done
            scope.launch {
                try {
                    if (oldSession.isNotEmpty()) withTimeoutOrNull(CLOSE_TIMEOUT) { runCatching { oldRoute.client.CloseRemoteDesktop().execute(RemoteDesktopRef(session_id = oldSession)) } }
                } finally {
                    oldRoute.close()
                    done.complete(Unit)
                }
            }
        }
        route = null
        request = null
        binding = null
        answer = null
        remoteApplied = false
        sessionId = ""
        mutableView.update { it.copy(sessionId = "") }
        localCandidates.clear()
        remoteCandidates.clear()
        peerConnected = false
        presentedGeneration = 0
        lastPresented = null
        state = null
        encoder = null
        feedback = null
        references = null
        cursors.clear()
        peerSinceTicks = 0
        refreshedForNoFrame = false
        pendingPointer = null
        lastPointerAt = null
        configuring = false
        configurationPending = false
        refreshPending = false
        clipboardAssembler = null
        // An exchange waiting for this session's reply fails now, releasing the
        // exchange lock, rather than holding the next session until it times out.
        clipboardReply?.completeExceptionally(IllegalStateException("Clipboard transfer interrupted"))
        clipboardReply = null
        clipboardRevision = ""
        clipboardStamp = null
        clipboardGrant = -1
        clipboardOperation = false
    }

    // --- Engine events ------------------------------------------------------------------

    private inner class Events(private val attemptToken: Long) : ScreenMediaEvents {
        private fun onCore(block: () -> Unit) {
            scope.launch { if (attemptToken == token) block() }
        }

        override fun localCandidate(candidate: RemoteDesktopICECandidate) = onCore {
            if (sessionId.isEmpty()) {
                if (localCandidates.size < MAX_CANDIDATES) localCandidates.addLast(candidate)
            } else {
                sendCandidate(candidate)
            }
        }

        override fun peerState(state: PeerState) = onCore {
            when (state) {
                PeerState.CONNECTED -> {
                    peerConnected = true
                    peerSinceTicks = 0
                    mutableView.update { it.copy(phase = if (presentedGeneration > 0) ScreenPhase.Streaming else ScreenPhase.Connecting) }
                    publishReadiness()
                }
                PeerState.DISCONNECTED, PeerState.FAILED -> {
                    releaseInput()
                    peerConnected = false
                    recovery.interrupted(now())
                    mutableView.update { it.copy(phase = ScreenPhase.Reconnecting(null), controlActive = false) }
                    val expected = token
                    jobs += scope.launch {
                        delay(PEER_GRACE)
                        if (expected == token && !peerConnected) recover("The peer did not recover after losing connectivity")
                    }
                }
                PeerState.CLOSED -> if (view.value.phase !is ScreenPhase.Failed && view.value.phase !is ScreenPhase.Idle) recover("The video connection closed")
                else -> Unit
            }
        }

        override fun channelState(label: String, open: Boolean) = onCore {
            if (!open && label == ScreenChannels.CLIPBOARD && authorized) return@onCore recover("Clipboard channel closed")
            publishReadiness()
        }

        override fun channelMessage(label: String, bytes: ByteArray) = onCore {
            when (label) {
                ScreenChannels.SESSION -> hostEvent(bytes)
                ScreenChannels.CLIPBOARD -> clipboardMessage(bytes)
            }
        }

        override fun decoded(rtpTimestamp: UInt) = onCore {
            val acked = references?.decoded(rtpTimestamp, now()).orEmpty()
            if (acked.isNotEmpty()) {
                feedback?.acknowledge(acked)
                sendFeedback()
            }
        }

        override fun presented(rtpTimestamp: UInt) = onCore {
            lastPresented = rtpTimestamp
            markPresented(rtpTimestamp)
        }

        override fun hevcUnavailable(reason: String) = onCore { hevcFallback() }

        override fun failure(message: String) = onCore { fail(message) }
    }

    // --- Configuration ------------------------------------------------------------------

    /** Sends the desired stream configuration; overlapping requests coalesce into one in flight. */
    fun configure(refresh: Boolean = false) {
        if (sessionId.isEmpty()) return
        configurationPending = true
        refreshPending = refreshPending || refresh
        if (configuring) return
        configuring = true
        val attemptToken = token
        jobs += scope.launch {
            try {
                while ((configurationPending || refreshPending) && attemptToken == token) {
                    val wantsRefresh = refreshPending
                    configurationPending = false
                    refreshPending = false
                    val caps = view.value.capabilities ?: return@launch
                    val fps = ScreenCapabilities.maxFps(preferences.maxFps, caps, config.fpsCeiling)
                    if (state?.codec == ScreenCodecs.H265 && (fps > 60 || preferences.width > 1920 || preferences.height > 1080)) {
                        return@launch recover("Switching stream mode…", immediate = true)
                    }
                    val control = request?.control == true
                    val configuration = RemoteDesktopStreamConfiguration(
                        display_id = preferences.displayId ?: "primary", max_width = preferences.width, max_height = preferences.height, max_fps = fps,
                        max_bitrate_kbps = ScreenRequests.MAX_BITRATE_KBPS, quality = preferences.quality, embedded_cursor = ScreenCapabilities.embedCursor(caps, control),
                    )
                    releaseInput()
                    val current = route ?: return@launch
                    val updated = withTimeout(UNARY) {
                        current.client.UpdateRemoteDesktopSession().execute(UpdateRemoteDesktopSessionRequest(session_id = sessionId, configuration = configuration, refresh = wantsRefresh))
                    }
                    if (attemptToken == token) applyState(updated)
                }
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Throwable) {
                if (attemptToken == token) {
                    if (ScreenFailures.retryable(error)) recover(Failures.message(error)) else fail(Failures.message(error))
                }
            } finally {
                if (attemptToken == token) configuring = false
            }
        }
    }

    /** Sets the requested stream size for this view; debounced by 350 ms. */
    fun viewport(widthPoints: Double, heightPoints: Double, scale: Double) {
        val size = config.viewport.size(widthPoints, heightPoints, scale) ?: return
        if (size == preferences.width to preferences.height) return
        preferences = preferences.copy(width = size.first, height = size.second)
        val expected = token
        jobs += scope.launch {
            delay(VIEWPORT_DEBOUNCE)
            if (expected == token && preferences.width == size.first && preferences.height == size.second) configure()
        }
    }

    fun setQuality(quality: RemoteDesktopQuality) = setPreferences { it.copy(quality = quality) }

    /** Takes or hands back control; the host's reply is merged like any other state. */
    suspend fun setControl(take: Boolean) {
        val current = route ?: return
        releaseInput()
        val updated = withTimeout(UNARY) { current.client.SetRemoteDesktopControl().execute(RemoteDesktopControlRequest(session_id = sessionId, take_control = take)) }
        applyState(updated)
    }

    /** Takes or releases control once at a time; a failure is shown in the view instead of thrown. */
    suspend fun transferControl(take: Boolean) {
        if (view.value.controlTransferring) return
        mutableView.update { it.copy(controlTransferring = true, controlError = null) }
        val error = try {
            setControl(take)
            null
        } catch (cancelled: kotlin.coroutines.cancellation.CancellationException) {
            throw cancelled
        } catch (failure: Throwable) {
            com.dbpprt.dieter.core.runtime.Failures.message(failure)
        }
        mutableView.update { it.copy(controlTransferring = false, controlError = error) }
    }

    // --- Input --------------------------------------------------------------------------

    private fun sendReliable(input: RemoteDesktopInput?) {
        input ?: return
        val current = engine ?: return
        if (!view.value.controlActive && input.release_all == null) return
        val bytes = RemoteDesktopInput.ADAPTER.encode(input)
        if (bytes.size > ScreenChannels.MAX_INPUT_BYTES) return
        pendingPointer = null
        if (!current.isOpen(ScreenChannels.INPUT) || current.bufferedAmount(ScreenChannels.INPUT) >= ScreenChannels.BACKPRESSURE_BYTES) {
            if (input.release_all == null) recover("Remote input stalled")
            return
        }
        if (!current.send(ScreenChannels.INPUT, bytes) && input.release_all == null) {
            mutableView.update { it.copy(controlActive = false) }
            recover("Remote input could not be delivered")
        }
    }

    private fun generations(): Pair<Long, Long>? {
        val current = state ?: return null
        return current.display_generation to current.control_generation
    }

    /** Moves the remote pointer; moves within 4 ms of the last one are coalesced (the latest wins). */
    fun pointer(x: Double, y: Double) {
        if (!view.value.controlActive) return
        pendingPointer = x to y
        val last = lastPointerAt
        val elapsed = last?.let { now() - it } ?: POINTER_INTERVAL
        if (elapsed >= POINTER_INTERVAL) return flushPointer()
        if (pointerFlush?.isActive == true) return
        pointerFlush = scope.launch {
            delay(POINTER_INTERVAL - elapsed)
            flushPointer()
        }
    }

    private fun flushPointer() {
        val (x, y) = pendingPointer ?: return
        pendingPointer = null
        val (display, control) = generations() ?: return
        val current = engine ?: return
        val input = encoder?.move(x, y, display, control) ?: return
        lastPointerAt = now()
        if (current.isOpen(ScreenChannels.POINTER) && current.bufferedAmount(ScreenChannels.POINTER) < ScreenChannels.BACKPRESSURE_BYTES) {
            current.send(ScreenChannels.POINTER, RemoteDesktopInput.ADAPTER.encode(input))
        }
    }

    fun button(button: RemoteDesktopPointerButton.Button, down: Boolean, clicks: Int, x: Double, y: Double, modifiers: Int = 0) {
        val (display, control) = generations() ?: return
        sendReliable(encoder?.button(button, down, clicks, x, y, modifiers, display, control))
    }

    fun scroll(dx: Double, dy: Double, phase: Int, momentum: Int = 0, modifiers: Int = 0, precise: Boolean = true) {
        val (display, control) = generations() ?: return
        sendReliable(encoder?.scroll(dx, dy, phase, momentum, modifiers, precise, display, control))
    }

    /** A physical key by USB HID usage; Command-C/X/V become clipboard operations when sharing is on. */
    fun key(hid: Int, down: Boolean, repeat: Boolean = false, modifiers: Int = 0) {
        val shortcut = ScreenInputEncoder.clipboardShortcut(hid, modifiers)
        if (shortcut != null && down && !repeat && view.value.clipboardEnabled && view.value.capabilities?.clipboard_supported == true) {
            scope.launch { performClipboard(shortcut) }
            return
        }
        val (display, control) = generations() ?: return
        sendReliable(encoder?.key(hid, down, repeat, modifiers, display, control))
    }

    /** Committed text; a single ASCII character with Control, Option, or Command held becomes a key stroke. */
    fun text(value: String, modifiers: Int = 0) {
        val (display, control) = generations() ?: return
        if ((modifiers and (Modifiers.CONTROL or Modifiers.OPTION or Modifiers.COMMAND)) != 0) {
            ScreenInputEncoder.stroke(value)?.let { (hid, shift) ->
                val held = modifiers or if (shift) Modifiers.SHIFT else 0
                sendReliable(encoder?.key(hid, true, false, held, display, control))
                sendReliable(encoder?.key(hid, false, false, held, display, control))
                return
            }
        }
        val chunks = ScreenInputEncoder.textChunks(value) ?: return mutableView.update { it.copy(clipboardError = "Text input is limited to 8 KB per insertion") }
        for (chunk in chunks) sendReliable(encoder?.text(chunk, display, control))
    }

    /** Releases every held key and button on the host. */
    fun releaseInput() {
        pointerFlush?.cancel()
        pendingPointer = null
        lastPointerAt = null
        val (display, control) = generations() ?: return
        if (!view.value.controlActive) return
        sendReliable(encoder?.releaseAll(display, control))
    }

    // --- Clipboard ----------------------------------------------------------------------

    private fun clipboardMessage(bytes: ByteArray) {
        val assembler = clipboardAssembler ?: return
        try {
            val payload = assembler.accept(bytes.toByteString()) ?: return
            clipboardAssembler = null
            clipboardReply?.complete(RemoteDesktopClipboardResponse.ADAPTER.decode(payload))
        } catch (error: Throwable) {
            clipboardAssembler = null
            clipboardReply?.completeExceptionally(error)
            engine?.let { runCatching { it.send(ScreenChannels.CLIPBOARD, ByteArray(0)) } }
        }
    }

    private suspend fun exchange(request: RemoteDesktopClipboardRequest): RemoteDesktopClipboardResponse {
        val current = engine ?: throw IllegalStateException("Clipboard channel closed")
        val operationId = request.operation_id
        val reply = CompletableDeferred<RemoteDesktopClipboardResponse>()
        clipboardReply = reply
        clipboardAssembler = ClipboardFraming.Assembler(operationId)
        for (frame in ClipboardFraming.frames(operationId, RemoteDesktopClipboardRequest.ADAPTER.encodeByteString(request))) {
            while (current.bufferedAmount(ScreenChannels.CLIPBOARD) > ClipboardFraming.BUFFER_LIMIT) delay(5.milliseconds)
            if (!current.send(ScreenChannels.CLIPBOARD, RemoteDesktopClipboardFrameAdapter.encode(frame))) throw IllegalStateException("Clipboard transfer failed")
        }
        val response = withTimeout(CLIPBOARD_TIMEOUT) { reply.await() }
        if (response.error.isNotEmpty()) throw IllegalStateException(response.error)
        return response
    }

    private fun clipboardRequest(action: RemoteDesktopClipboardRequest.Action, text: String = "", items: List<RemoteDesktopClipboardItem> = emptyList()): RemoteDesktopClipboardRequest? {
        val bound = binding ?: return null
        val current = state ?: return null
        return RemoteDesktopClipboardRequest(
            session_id = sessionId, operation_id = Uuid.random().toString(), input_epoch = bound.input_epoch, control_generation = current.control_generation,
            action = action, text = text, known_revision = clipboardRevision, enabled = view.value.clipboardEnabled,
            input_barrier = encoder?.stateBarrier ?: 0, items = items, accept_binary = view.value.capabilities?.binary_clipboard_supported == true,
        )
    }

    /**
     * Copy, cut, or paste on the host, as Command-C/X/V would. It waits for a
     * background sync exchange in flight, then reads the current clipboard.
     */
    suspend fun performClipboard(operation: String) {
        val local = localClipboard ?: return
        if (clipboardOperation) return mutableView.update { it.copy(clipboardError = "A clipboard operation is still in progress") }
        clipboardOperation = true
        mutableView.update { it.copy(clipboardBusy = true) }
        try {
            clipboardExchange.withLock {
                val binary = view.value.capabilities?.binary_clipboard_supported == true
                val request = when (operation) {
                    "paste" -> {
                        val (text, items) = local.read(binary = true) ?: ("" to emptyList())
                        if (items.isNotEmpty() && !binary) return mutableView.update { it.copy(clipboardError = "Update the daemon to paste images and files") }
                        ClipboardContent.validate(text, items)?.let { return mutableView.update { state -> state.copy(clipboardError = it) } }
                        clipboardRequest(RemoteDesktopClipboardRequest.Action.PASTE, text, items)
                    }
                    "cut" -> clipboardRequest(RemoteDesktopClipboardRequest.Action.CUT)
                    else -> clipboardRequest(RemoteDesktopClipboardRequest.Action.COPY)
                } ?: return
                val stamp = local.stamp()
                val response = exchange(request)
                if (operation != "paste" && (response.has_text || response.items.isNotEmpty()) && view.value.clipboardEnabled && local.stamp() == stamp) {
                    local.apply(response.text, response.items)
                    clipboardStamp = local.stamp()
                }
                if (response.revision.isNotEmpty()) clipboardRevision = response.revision
                mutableView.update { it.copy(clipboardError = null, clipboardOperations = it.clipboardOperations + 1) }
            }
        } catch (error: Throwable) {
            if (error is CancellationException) throw error
            mutableView.update { it.copy(clipboardError = error.message ?: "Clipboard transfer failed") }
        } finally {
            clipboardOperation = false
            mutableView.update { it.copy(clipboardBusy = false) }
        }
    }

    /**
     * Turns clipboard sharing on or off for the session. The host confirms
     * with a new clipboard generation, which resets the sync baseline.
     */
    suspend fun setClipboardEnabled(enabled: Boolean) {
        preferences = preferences.copy(clipboard = enabled)
        if (clipboardOperation) return mutableView.update { it.copy(clipboardError = "A clipboard operation is still in progress") }
        clipboardRequest(RemoteDesktopClipboardRequest.Action.CONFIGURE) ?: return
        clipboardOperation = true
        mutableView.update { it.copy(clipboardBusy = true) }
        try {
            clipboardExchange.withLock {
                val request = clipboardRequest(RemoteDesktopClipboardRequest.Action.CONFIGURE)?.copy(enabled = enabled) ?: return
                exchange(request)
                mutableView.update { it.copy(clipboardEnabled = enabled, clipboardError = null) }
            }
        } catch (error: Throwable) {
            if (error is CancellationException) throw error
            mutableView.update { it.copy(clipboardError = error.message ?: "Clipboard sharing could not be updated") }
        } finally {
            clipboardOperation = false
            mutableView.update { it.copy(clipboardBusy = false) }
        }
    }

    /** Keeps both clipboards in step every 250 ms while this client controls the host. */
    private fun startClipboardSync(attemptToken: Long) {
        val local = localClipboard ?: return
        jobs += scope.launch {
            while (attemptToken == token) {
                delay(CLIPBOARD_POLL)
                val current = state ?: continue
                if (!view.value.clipboardEnabled || !view.value.controlActive || clipboardOperation || engine?.isOpen(ScreenChannels.CLIPBOARD) != true) continue
                if (clipboardGrant != current.control_generation) {
                    clipboardGrant = current.control_generation
                    clipboardRevision = ""
                    clipboardStamp = local.stamp()
                }
                if (!clipboardExchange.tryLock()) continue
                try {
                    val stamp = local.stamp()
                    if (clipboardStamp != null && stamp != clipboardStamp) {
                        clipboardStamp = stamp
                        val (text, items) = local.read(binary = view.value.capabilities?.binary_clipboard_supported == true) ?: continue
                        if (text.isEmpty() && items.isEmpty() || ClipboardContent.validate(text, items) != null) continue
                        val response = exchange(clipboardRequest(RemoteDesktopClipboardRequest.Action.WRITE, text, items) ?: continue)
                        clipboardRevision = response.revision
                    } else {
                        val previous = clipboardRevision
                        val response = exchange(clipboardRequest(RemoteDesktopClipboardRequest.Action.READ) ?: continue)
                        if (clipboardGrant != (state?.control_generation ?: -1)) continue
                        clipboardRevision = response.revision
                        if (previous.isNotEmpty() && response.changed && (response.has_text || response.items.isNotEmpty()) && local.stamp() == stamp) {
                            local.apply(response.text, response.items)
                            clipboardStamp = local.stamp()
                        }
                        if (clipboardStamp == null) clipboardStamp = stamp
                    }
                } catch (error: Throwable) {
                    if (error is CancellationException) throw error
                    mutableView.update { it.copy(clipboardError = error.message) }
                } finally {
                    clipboardExchange.unlock()
                }
            }
        }
    }

    companion object {
        const val GENERIC_FRAME_DESCRIPTOR = "http://www.webrtc.org/experiments/rtp-hdrext/generic-frame-descriptor-00"
        const val MAX_CANDIDATES = 256
        val ROUTE_TIMEOUT = 20.seconds
        val WATCHDOG = 20.seconds
        val LINUX_APPROVAL = 150.seconds
        val PEER_GRACE = 3.seconds
        val LEASE_INTERVAL = 5.seconds
        val UNARY = 15.seconds
        val CLOSE_TIMEOUT = 3.seconds
        val VIEWPORT_DEBOUNCE = 350.milliseconds
        val POINTER_INTERVAL = 4.milliseconds
        val CLIPBOARD_POLL = 250.milliseconds
        val CLIPBOARD_TIMEOUT = 30.seconds
        const val NO_FRAME_REFRESH_TICKS = 6
        const val NO_FRAME_GIVE_UP_TICKS = 40
        private const val TAG = "Screens"
    }
}

private object RemoteDesktopReceiverFeedbackAdapter {
    fun encode(value: com.dbpprt.dieter.api.v1.RemoteDesktopReceiverFeedback): ByteArray = com.dbpprt.dieter.api.v1.RemoteDesktopReceiverFeedback.ADAPTER.encode(value)
}

private object RemoteDesktopClipboardFrameAdapter {
    fun encode(value: com.dbpprt.dieter.api.v1.RemoteDesktopClipboardFrame): ByteArray = com.dbpprt.dieter.api.v1.RemoteDesktopClipboardFrame.ADAPTER.encode(value)
}

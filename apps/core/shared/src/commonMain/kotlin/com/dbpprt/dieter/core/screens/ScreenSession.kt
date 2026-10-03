package com.dbpprt.dieter.core.screens

import com.dbpprt.dieter.api.v1.DieterServiceClient
import com.dbpprt.dieter.api.v1.RemoteDesktopAvailability
import com.dbpprt.dieter.api.v1.RemoteDesktopCodecPreference
import com.dbpprt.dieter.api.v1.RemoteDesktopControlRequest
import com.dbpprt.dieter.api.v1.RemoteDesktopCursor
import com.dbpprt.dieter.api.v1.RemoteDesktopHostEvent
import com.dbpprt.dieter.api.v1.RemoteDesktopICECandidate
import com.dbpprt.dieter.api.v1.RemoteDesktopPointerButton
import com.dbpprt.dieter.api.v1.RemoteDesktopQuality
import com.dbpprt.dieter.api.v1.RemoteDesktopReceiverFeedback
import com.dbpprt.dieter.api.v1.RemoteDesktopSessionBinding
import com.dbpprt.dieter.api.v1.RemoteDesktopSessionState
import com.dbpprt.dieter.api.v1.RemoteDesktopSignal
import com.dbpprt.dieter.api.v1.RemoteDesktopStreamConfiguration
import com.dbpprt.dieter.api.v1.StartRemoteDesktopRequest
import com.dbpprt.dieter.api.v1.UpdateRemoteDesktopSessionRequest
import com.dbpprt.dieter.client.v1.ScreenCommand
import com.dbpprt.dieter.core.platform.SignatureVerifier
import com.dbpprt.dieter.core.runtime.CoreLogger
import com.dbpprt.dieter.core.runtime.Deadlines
import com.dbpprt.dieter.core.runtime.Failures
import com.dbpprt.dieter.core.runtime.withDeadline
import kotlin.coroutines.cancellation.CancellationException
import kotlin.time.Clock
import kotlin.time.Duration
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.seconds
import kotlin.uuid.Uuid
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull

/**
 * One screen-sharing session with a machine. The native media engine only
 * moves pixels and packets; this controller owns signaling, trust, the lease,
 * recovery, configuration, input, and clipboard sync. The signaling RPCs,
 * input, and clipboard sync run in helpers it owns ([ScreenSignaling],
 * [ScreenInput], [ScreenClipboardSync]). Confined to the core dispatcher,
 * helpers included; engine events hop onto it.
 */
class ScreenSession(
    private val engines: ScreenMediaEngineFactory,
    private val verifier: SignatureVerifier,
    private val config: ScreenConfig,
    private val clock: Clock,
    private val scope: CoroutineScope,
    logger: CoreLogger,
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

    // Attempt scope: reset by stopSession, together with the helpers below.
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
    private val remoteCandidates = ArrayDeque<RemoteDesktopICECandidate>()
    private var peerConnected = false
    private var presentedGeneration = 0L
    private var lastPresented: UInt? = null
    private var state: RemoteDesktopSessionState? = null
    private var feedback: ScreenFeedback? = null
    private var references: ScreenReferences? = null
    private val cursors = CursorCache()
    private var peerSinceTicks = 0
    private var refreshedForNoFrame = false
    private var configuring = false
    private var configurationPending = false
    private var refreshPending = false

    private val signaling = ScreenSignaling(scope, clock, logger)
    private val input = ScreenInput(scope, clock, mutableView, engine = { engine }, state = { state }, recover = { recover(it) })
    private val clipboard = ScreenClipboardSync(
        localClipboard, mutableView, engine = { engine }, binding = { binding }, state = { state }, sessionId = { sessionId },
        inputBarrier = { input.encoder?.stateBarrier ?: 0L },
    )

    /** Attempt jobs held for [stopSession] to cancel; finished ones are dropped as others start. */
    internal val heldJobs: Int get() = jobs.size

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
    fun routeClient(): DieterServiceClient? = route?.client

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
                val caps = withDeadline(Deadlines.CALL) { opened.client.GetRemoteDesktopCapabilities().execute(Unit) }
                if (attemptToken != token) return@launch
                mutableView.update { it.copy(capabilities = caps) }
                if (!caps.ready) {
                    val reason = caps.unavailable_reason.ifEmpty { "Screen sharing is unavailable on this machine." }
                    stopSession()
                    mutableView.update {
                        it.copy(phase = if (caps.availability == RemoteDesktopAvailability.REMOTE_DESKTOP_AVAILABILITY_PERMISSION_REQUIRED) ScreenPhase.PermissionRequired(reason) else ScreenPhase.Unsupported(reason))
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
        track(scope.launch {
            delay(timeout)
            val phase = view.value.phase
            if (attemptToken == token && !peerConnected && (phase is ScreenPhase.Loading || phase is ScreenPhase.Connecting || phase is ScreenPhase.WaitingForHostApproval || phase is ScreenPhase.Reconnecting)) {
                recover("Screen connection attempt timed out")
            }
        })
    }

    /** Holds [job] for [stopSession] to cancel; finished jobs are dropped, so only running work is held. */
    private fun track(job: Job) {
        jobs.removeAll { it.isCompleted }
        jobs += job
    }

    // --- Signaling ----------------------------------------------------------------------

    /** Receives signaling; a stream that keeps dropping recovers the session, or fails it when retrying cannot help. */
    private suspend fun signal(attemptToken: Long, opened: ScreenRoute, start: StartRemoteDesktopRequest) {
        val failure = signaling.receive(
            opened, start,
            active = { attemptToken == token },
            dropped = { if (!(peerConnected && presentedGeneration > 0)) mutableView.update { it.copy(phase = ScreenPhase.Reconnecting(null)) } },
        ) { received -> handleSignal(attemptToken, received) } ?: return
        if (failure is ScreenTrustException) return fail(failure.message ?: "The screen session could not be verified.")
        opened.failed(failure)
        val message = failure.message ?: Failures.message(failure)
        if (ScreenFailures.retryable(failure)) recover(message) else fail(message)
    }

    private suspend fun handleSignal(attemptToken: Long, received: RemoteDesktopSignal) {
        if (received.session_id.isEmpty()) return fail("The screen session has no identity.")
        if (sessionId.isEmpty()) {
            sessionId = received.session_id
            mutableView.update { it.copy(sessionId = sessionId) }
            signaling.sendHeldCandidates(route, sessionId)
            startLease(attemptToken)
            startMonitor(attemptToken)
        } else if (received.session_id != sessionId) {
            // The daemon replaced an expired session; never apply its answer to this peer.
            route?.let { current -> signaling.closeReplaced(current, received.session_id) }
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
        input.encoder = ScreenInputEncoder(boundSession.input_epoch)
        feedback = ScreenFeedback(boundSession.input_epoch).also { it.start(now()) }
        engine?.applyAnswer(sdp)
        remoteApplied = true
        while (remoteCandidates.isNotEmpty()) engine?.addRemoteCandidate(remoteCandidates.removeFirst())
        startFeedback(token)
        if (localClipboard != null && view.value.capabilities?.clipboard_supported == true) startClipboardSync(token)
        publishReadiness()
    }

    private fun startLease(attemptToken: Long) {
        val current = route ?: return
        val id = sessionId
        track(scope.launch {
            signaling.renewLease(current, id, active = { attemptToken == token }) {
                if (!peerConnected && attemptToken == token) mutableView.update { it.copy(phase = ScreenPhase.Reconnecting(null)) }
            }
        })
    }

    private fun startMonitor(attemptToken: Long) {
        track(scope.launch {
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
        })
    }

    private fun startFeedback(attemptToken: Long) {
        track(scope.launch {
            while (attemptToken == token) {
                sendFeedback()
                delay(ScreenFeedback.INTERVAL)
            }
        })
    }

    private fun sendFeedback() {
        val current = engine ?: return
        val pump = feedback ?: return
        if (!current.isOpen(ScreenChannels.SESSION) || current.bufferedAmount(ScreenChannels.SESSION) >= ScreenFeedback.SKIP_BUFFERED_BYTES) return
        current.send(ScreenChannels.SESSION, RemoteDesktopReceiverFeedback.ADAPTER.encode(pump.next(now())))
    }

    private fun startClipboardSync(attemptToken: Long) {
        track(scope.launch { clipboard.sync(active = { attemptToken == token }) })
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
        if (merged.clipboardChanged) clipboard.rebase()
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
        val adopt = CursorCache.adoptHostPosition(
            false, holdingCursor, false, value.last_input_ordinal, input.encoder?.lastPointerOrdinal ?: 0, input.lastPointerAt?.let { now() - it } ?: Duration.INFINITE,
        )
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
        input.reset()
        references?.stop()
        clipboard.reset()
        runCatching { engine?.close() }
        engine = null
        val oldRoute = route
        if (oldRoute != null) closing = signaling.close(oldRoute, sessionId)
        route = null
        request = null
        binding = null
        answer = null
        remoteApplied = false
        sessionId = ""
        mutableView.update { it.copy(sessionId = "") }
        signaling.reset()
        remoteCandidates.clear()
        peerConnected = false
        presentedGeneration = 0
        lastPresented = null
        state = null
        feedback = null
        references = null
        cursors.clear()
        peerSinceTicks = 0
        refreshedForNoFrame = false
        configuring = false
        configurationPending = false
        refreshPending = false
    }

    // --- Engine events ------------------------------------------------------------------

    private inner class Events(private val attemptToken: Long) : ScreenMediaEvents {
        private fun onCore(block: () -> Unit) {
            scope.launch { if (attemptToken == token) block() }
        }

        override fun localCandidate(candidate: RemoteDesktopICECandidate) = onCore { signaling.localCandidate(route, sessionId, candidate) }

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
                    track(scope.launch {
                        delay(PEER_GRACE)
                        if (expected == token && !peerConnected) recover("The peer did not recover after losing connectivity")
                    })
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
                ScreenChannels.CLIPBOARD -> clipboard.message(bytes)
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
        track(scope.launch {
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
                    val updated = withDeadline(Deadlines.CALL) {
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
        })
    }

    /** Sets the requested stream size for this view; debounced by 350 ms. */
    fun viewport(widthPoints: Double, heightPoints: Double, scale: Double) {
        val size = config.viewport.size(widthPoints, heightPoints, scale) ?: return
        if (size == preferences.width to preferences.height) return
        preferences = preferences.copy(width = size.first, height = size.second)
        val expected = token
        track(scope.launch {
            delay(VIEWPORT_DEBOUNCE)
            if (expected == token && preferences.width == size.first && preferences.height == size.second) configure()
        })
    }

    fun setQuality(quality: RemoteDesktopQuality) = setPreferences { it.copy(quality = quality) }

    /** Takes or hands back control; the host's reply is merged like any other state. */
    suspend fun setControl(take: Boolean) {
        val current = route ?: return
        releaseInput()
        val updated = withDeadline(Deadlines.CALL) { current.client.SetRemoteDesktopControl().execute(RemoteDesktopControlRequest(session_id = sessionId, take_control = take)) }
        applyState(updated)
    }

    /** Takes or releases control once at a time; a failure, including no answer in time, is shown in the view instead of thrown. */
    suspend fun transferControl(take: Boolean) {
        if (view.value.controlTransferring) return
        mutableView.update { it.copy(controlTransferring = true, controlError = null) }
        val error = try {
            setControl(take)
            null
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (failure: Throwable) {
            Failures.message(failure)
        }
        mutableView.update { it.copy(controlTransferring = false, controlError = error) }
    }

    // --- Input --------------------------------------------------------------------------

    /** Moves the remote pointer; moves within 4 ms of the last one are coalesced (the latest wins). */
    fun pointer(x: Double, y: Double) = input.pointer(x, y)

    fun button(button: RemoteDesktopPointerButton.Button, down: Boolean, clicks: Int, x: Double, y: Double, modifiers: Int = 0) =
        input.button(button, down, clicks, x, y, modifiers)

    fun scroll(dx: Double, dy: Double, phase: Int, momentum: Int = 0, modifiers: Int = 0, precise: Boolean = true) =
        input.scroll(dx, dy, phase, momentum, modifiers, precise)

    /** A physical key by USB HID usage; Command-C/X/V become clipboard operations when sharing is on. */
    fun key(hid: Int, down: Boolean, repeat: Boolean = false, modifiers: Int = 0) {
        val shortcut = ScreenInputEncoder.clipboardShortcut(hid, modifiers)
        if (shortcut != null && down && !repeat && view.value.clipboardEnabled && view.value.capabilities?.clipboard_supported == true) {
            scope.launch { performClipboard(shortcut) }
            return
        }
        input.key(hid, down, repeat, modifiers)
    }

    /** Committed text; a single ASCII character with Control, Option, or Command held becomes a key stroke. */
    fun text(value: String, modifiers: Int = 0) = input.text(value, modifiers)

    /** Releases every held key and button on the host. */
    fun releaseInput() = input.release()

    /** The input [command] carries: a pointer move, button, scroll, key, text, or input release; other members are ignored. */
    fun applyInput(command: ScreenCommand) {
        command.pointer?.let { pointer(it.x, it.y) }
        command.button?.let { button(it.button, it.down, it.clicks, it.x, it.y, it.modifiers) }
        command.scroll?.let { scroll(it.dx, it.dy, it.phase, it.momentum, it.modifiers, it.precise) }
        command.key?.let { key(it.hid, it.down, it.repeat, it.modifiers) }
        command.text?.let { text(it.text, it.modifiers) }
        command.release_input?.let { releaseInput() }
    }

    // --- Clipboard ----------------------------------------------------------------------

    /**
     * Copy, cut, or paste on the host, as Command-C/X/V would. It waits for a
     * background sync exchange in flight, then reads the current clipboard.
     */
    suspend fun performClipboard(operation: String) = clipboard.perform(operation)

    /**
     * Turns clipboard sharing on or off for the session. The host confirms
     * with a new clipboard generation, which resets the sync baseline.
     */
    suspend fun setClipboardEnabled(enabled: Boolean) {
        preferences = preferences.copy(clipboard = enabled)
        clipboard.setEnabled(enabled)
    }

    companion object {
        const val GENERIC_FRAME_DESCRIPTOR = "http://www.webrtc.org/experiments/rtp-hdrext/generic-frame-descriptor-00"
        const val MAX_CANDIDATES = 256
        val ROUTE_TIMEOUT = 20.seconds
        val WATCHDOG = 20.seconds
        val LINUX_APPROVAL = 150.seconds
        val PEER_GRACE = 3.seconds
        val LEASE_INTERVAL = 5.seconds
        val CLOSE_TIMEOUT = 3.seconds
        val VIEWPORT_DEBOUNCE = 350.milliseconds
        val POINTER_INTERVAL = 4.milliseconds
        val CLIPBOARD_POLL = 250.milliseconds
        val CLIPBOARD_TIMEOUT = 30.seconds
        const val NO_FRAME_REFRESH_TICKS = 6
        const val NO_FRAME_GIVE_UP_TICKS = 40
    }
}

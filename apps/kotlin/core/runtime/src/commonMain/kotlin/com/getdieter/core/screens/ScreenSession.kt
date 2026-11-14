package com.getdieter.core.screens

import com.getdieter.api.v1.RemoteDesktopCapabilities
import com.getdieter.api.v1.RemoteDesktopControlRequest
import com.getdieter.api.v1.RemoteDesktopHostEvent
import com.getdieter.api.v1.RemoteDesktopICECandidate
import com.getdieter.api.v1.RemoteDesktopPointerButton
import com.getdieter.api.v1.RemoteDesktopQuality
import com.getdieter.api.v1.RemoteDesktopSessionState
import com.getdieter.api.v1.RemoteDesktopSignal
import com.getdieter.api.v1.StartRemoteDesktopRequest
import com.getdieter.client.v1.ScreenCommand
import com.getdieter.core.api.DaemonApi
import com.getdieter.core.platform.SignatureVerifier
import com.getdieter.core.runtime.CoreLogger
import com.getdieter.core.runtime.Deadlines
import com.getdieter.core.runtime.Failures
import com.getdieter.core.runtime.withDeadline
import kotlin.coroutines.cancellation.CancellationException
import kotlin.math.roundToLong
import kotlin.time.Clock
import kotlin.time.Duration
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
import okio.ByteString

/**
 * One screen-sharing session with a machine. The native media engine only moves pixels and packets;
 * this controller owns the session's lifecycle: connecting, the offer, the lease, readiness,
 * recovery, and teardown. Helpers it owns do the rest: [ScreenSignaling] runs the signaling RPCs,
 * [ScreenNegotiation] verifies and applies the answer, [ScreenStreamControl] keeps the stream it
 * asks for, [ScreenReceiverReports] reports to the host's encoder, [ScreenInput] sends input and
 * follows the host cursor, and [ScreenClipboardSync] syncs the clipboard; [ScreenSessionPolicy]
 * makes the decisions. Confined to the core dispatcher, helpers included; engine events hop onto
 * it.
 */
class ScreenSession(
    private val engines: ScreenMediaEngineFactory,
    verifier: SignatureVerifier,
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
    private var keyPin: ByteString? = null
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
    private var sessionId = ""
    private var peerConnected = false
    private var peerConnectedOnce = false
    private var peerRecoveryJob: Job? = null
    private var presentedGeneration = 0L
    private var lastPresented: UInt? = null
    private var state: RemoteDesktopSessionState? = null
    private val frames = ScreenFrameWatch()

    private val signaling = ScreenSignaling(scope, clock, logger)
    private val negotiation = ScreenNegotiation(verifier, clock)
    private val reports = ScreenReceiverReports(clock) { engine }
    private val stream =
        ScreenStreamControl(
            scope,
            config,
            object : ScreenStreamHost {
                override val token: Long
                    get() = this@ScreenSession.token

                override val sessionId: String
                    get() = this@ScreenSession.sessionId

                override val route: ScreenRoute?
                    get() = this@ScreenSession.route

                override val capabilities: RemoteDesktopCapabilities?
                    get() = view.value.capabilities

                override val state: RemoteDesktopSessionState?
                    get() = this@ScreenSession.state

                override val controlRequested: Boolean
                    get() = request?.control == true

                override fun track(job: Job) = this@ScreenSession.track(job)

                override fun releaseInput() = this@ScreenSession.releaseInput()

                override fun applyState(state: RemoteDesktopSessionState) =
                    this@ScreenSession.applyState(state)

                override fun recover(reason: String, immediate: Boolean) =
                    this@ScreenSession.recover(reason, immediate)

                override fun fail(message: String) = this@ScreenSession.fail(message)
            },
        )
    private val input =
        ScreenInput(
            scope,
            clock,
            mutableView,
            engine = { engine },
            state = { state },
            recover = { recover(it) },
            clipboard = ::requestClipboard,
        )
    private val clipboard =
        ScreenClipboardSync(
            localClipboard,
            mutableView,
            engine = { engine },
            binding = { negotiation.binding },
            state = { state },
            sessionId = { sessionId },
            inputBarrier = { input.encoder?.stateBarrier ?: 0L },
        )

    /** The desired stream configuration; it survives recovery. */
    val preferences: ScreenPreferences
        get() = stream.preferences

    /**
     * Set by the gesture layer while a finger holds the cursor, so host updates do not fight it.
     */
    var holdingCursor: Boolean
        get() = input.holdingCursor
        set(value) {
            input.holdingCursor = value
        }

    /** Attempt jobs held for [stopSession] to cancel; finished ones are dropped as others start. */
    internal val heldJobs: Int
        get() = jobs.size

    private fun now() = clock.now()

    // --- Lifecycle --------------------------------------------------------------------

    /**
     * Starts a new session with [machineId] through [routes]; an earlier session is closed first.
     */
    fun connect(machineId: String = "", routes: ScreenRouteFactory) {
        disconnect()
        factory = routes
        hevcFailed = false
        keyPin = null
        mutableView.update { it.copy(codecFallbackReason = null, machineId = machineId) }
        beginAttempt()
    }

    /** The signaling route's client while a session runs, e.g. for resolution matching. */
    fun routeClient(): DaemonApi? = route?.client

    fun disconnect() {
        recoveryJob?.cancel()
        recoveryJob = null
        factory = null
        stopSession()
        mutableView.update { ScreenView(phase = ScreenPhase.Idle) }
    }

    fun setPreferences(change: (ScreenPreferences) -> ScreenPreferences) {
        val previous = stream.change(change)
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
        setFocused(false)
    }

    fun setFocused(value: Boolean) {
        if (!value) releaseInput()
        if (focused != value) frames.reset()
        focused = value
        publishReadiness()
    }

    private fun beginAttempt() {
        val routes = factory ?: return
        val attemptToken = ++token
        mutableView.update {
            it.copy(
                phase = if (it.phase is ScreenPhase.Reconnecting) it.phase else ScreenPhase.Loading
            )
        }
        attempt = scope.launch {
            try {
                closing?.await()
                val opened =
                    withTimeoutOrNull(ScreenSessionPolicy.ROUTE_TIMEOUT) { routes() }
                        ?: return@launch recover("Connection attempt timed out")
                if (attemptToken != token) return@launch opened.close()
                route = opened
                val pin = keyPin
                if (pin != null && pin != opened.daemonPublicKey)
                    return@launch fail(IDENTITY_CHANGED)
                keyPin = opened.daemonPublicKey
                mutableView.update { it.copy(routeLabel = opened.label) }
                val caps =
                    withDeadline(Deadlines.CALL) {
                        opened.client.GetRemoteDesktopCapabilities().execute(Unit)
                    }
                if (attemptToken != token) return@launch
                mutableView.update { it.copy(capabilities = caps) }
                if (!caps.ready) {
                    val blocked = ScreenSessionPolicy.unavailable(caps)
                    stopSession()
                    mutableView.update { it.copy(phase = blocked) }
                    return@launch
                }
                if (caps.input_protocol_version != SCREEN_INPUT_PROTOCOL)
                    return@launch fail("Update the Dieter daemon and client together")
                startWatchdog(attemptToken, ScreenSessionPolicy.watchdog(caps))
                val media = engines.capabilities
                media.initializationFailure?.let {
                    return@launch fail(it)
                }
                val offer =
                    ScreenSessionPolicy.offer(
                        media,
                        caps,
                        preferences,
                        hevcFailed,
                        config.fpsCeiling,
                    )
                if (offer.codecs.isEmpty()) return@launch fail(ScreenCodecs.UNAVAILABLE)
                val created =
                    engines.create(
                        ScreenMediaConfig(
                            opened.rtc,
                            offer.codecs,
                            media.referenceDependencies,
                            ScreenSessionPolicy.channels(caps),
                        ),
                        Events(attemptToken),
                    )
                engine = created
                reports.prepare(media.millisecondTimestamps)
                val sdp = created.createOffer()
                if (attemptToken != token) return@launch
                val start =
                    ScreenRequests.start(
                        Uuid.random().toString(),
                        opened.rtc,
                        sdp,
                        caps,
                        preferences,
                        offer.effective,
                        config.clientName,
                        referenceRecovery = ScreenSessionPolicy.referenceRecovery(media, sdp),
                        fpsCeiling = config.fpsCeiling,
                    )
                request = start
                mutableView.update { it.copy(phase = ScreenSessionPolicy.negotiating(caps)) }
                signal(attemptToken, opened, start)
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Throwable) {
                if (attemptToken != token) return@launch
                route?.failed(error)
                val message = error.message ?: Failures.message(error)
                if (error is ScreenTrustException || !ScreenFailures.retryable(error)) fail(message)
                else recover(message)
            }
        }
    }

    private fun startWatchdog(attemptToken: Long, timeout: Duration) {
        track(
            scope.launch {
                delay(timeout)
                if (
                    attemptToken == token &&
                        !peerConnectedOnce &&
                        ScreenSessionPolicy.connecting(view.value.phase)
                ) {
                    recover("Screen connection attempt timed out")
                }
            }
        )
    }

    /**
     * Holds [job] for [stopSession] to cancel; finished jobs are dropped, so only running work is
     * held.
     */
    private fun track(job: Job) {
        jobs.removeAll { it.isCompleted }
        jobs += job
    }

    // --- Signaling ----------------------------------------------------------------------

    /**
     * Receives signaling; a stream that keeps dropping recovers the session, or fails it when
     * retrying cannot help.
     */
    private suspend fun signal(
        attemptToken: Long,
        opened: ScreenRoute,
        start: StartRemoteDesktopRequest,
    ) {
        var renewRoute = false
        val failure =
            signaling.receive(
                route = {
                    if (renewRoute) {
                        val routes = factory ?: throw CancellationException("Screen disconnected")
                        val renewed =
                            withDeadline(ScreenSessionPolicy.CONFIGURATION_RETRY) { routes() }
                        if (attemptToken != token) {
                            renewed.close()
                            throw CancellationException("Screen replaced")
                        }
                        if (renewed.daemonPublicKey != keyPin) {
                            renewed.close()
                            throw ScreenTrustException(IDENTITY_CHANGED)
                        }
                        route?.close()
                        route = renewed
                        mutableView.update { it.copy(routeLabel = renewed.label) }
                        renewRoute = false
                    }
                    route ?: opened
                },
                start = start,
                active = { attemptToken == token },
                dropped = { error ->
                    route?.failed(error)
                    renewRoute = true
                    if (!(peerConnected && presentedGeneration > 0))
                        mutableView.update { it.copy(phase = ScreenPhase.Reconnecting(null)) }
                },
            ) { received ->
                handleSignal(attemptToken, received)
            } ?: return
        if (failure is ScreenTrustException)
            return fail(failure.message ?: "The screen session could not be verified.")
        route?.failed(failure)
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
        negotiation.receive(received, engine)?.let {
            return fail(it)
        }
        received.state?.let { applyState(it) }
        received.error?.let { error ->
            settle(ScreenSessionPolicy.hostError(error.code, error.message, error.recoverable))
        }
        authorize()
    }

    /** Once both the binding and the answer arrived: verify, apply, and start feedback. */
    private suspend fun authorize() {
        val verified = negotiation.verify(sessionId, request, route) ?: return
        input.encoder = ScreenInputEncoder(verified.input_epoch)
        reports.start(verified.input_epoch)
        negotiation.applyAnswer(engine)
        startFeedback(token)
        if (localClipboard != null && view.value.capabilities?.clipboard_supported == true)
            startClipboardSync(token)
        publishReadiness()
    }

    private fun startLease(attemptToken: Long) {
        val id = sessionId
        track(
            scope.launch {
                signaling.renewLease({ route }, id, active = { attemptToken == token }) {
                    if (!peerConnected && attemptToken == token)
                        mutableView.update { it.copy(phase = ScreenPhase.Reconnecting(null)) }
                }
            }
        )
    }

    /**
     * Samples the receiver every feedback interval and watches for video that never starts or
     * freezes ([ScreenFrameWatch]).
     */
    private fun startMonitor(attemptToken: Long) {
        track(
            scope.launch {
                while (attemptToken == token) {
                    delay(ScreenFeedback.INTERVAL)
                    val current = engine ?: continue
                    current.statistics()?.let { sample ->
                        reports.measured(sample)
                        val fps = sample.frames_per_second.roundToLong().toDouble()
                        if (fps != view.value.mediaFps)
                            mutableView.update { it.copy(mediaFps = fps) }
                    }
                    reports.input(focused && view.value.controlActive)
                    val presentedAny = presentedGeneration != 0L
                    if (frames.watching(peerConnected, focused, presentedAny, view.value.phase)) {
                        val tick = frames.tick(presentedAny)
                        if (tick.refresh) configure(refresh = true)
                        if (tick.replace) {
                            if (state?.codec == ScreenCodecs.H265) hevcFallback()
                            else recover("No screen frame was displayed")
                            return@launch
                        }
                    }
                }
            }
        )
    }

    private fun startFeedback(attemptToken: Long) {
        track(
            scope.launch {
                while (attemptToken == token) {
                    reports.send()
                    delay(ScreenFeedback.INTERVAL)
                }
            }
        )
    }

    private fun startClipboardSync(attemptToken: Long) {
        track(scope.launch { clipboard.sync(active = { attemptToken == token }) })
    }

    // --- State ------------------------------------------------------------------------

    private fun applyState(incoming: RemoteDesktopSessionState) {
        if (incoming.phase == "closed") return settle(ScreenSessionPolicy.closure(incoming.reason))
        val merged = ScreenStates.merge(state, incoming) ?: return
        if (merged.displayChanged) {
            releaseInput()
            presentedGeneration = 0
            stream.displayChanged()
            engine?.resetVideo()
            input.forgetCursors()
            if (view.value.phase is ScreenPhase.Streaming)
                mutableView.update { it.copy(phase = ScreenPhase.Connecting) }
        }
        stream.followHost(state, merged.state)
        state = merged.state
        if (merged.clipboardChanged) clipboard.rebase()
        engine?.updateFrameGate(
            token,
            merged.state.display_generation,
            merged.state.media_generation,
            merged.state.media_timestamp.toUInt(),
        )
        mutableView.update {
            it.copy(state = merged.state, clipboardEnabled = merged.state.clipboard_enabled)
        }
        stream.stateApplied(merged.state)
        lastPresented?.let(::markPresented)
        publishReadiness()
    }

    private fun markPresented(timestamp: UInt) {
        val current = state ?: return
        val media = current.media_generation
        if (
            media > 0 &&
                media == current.display_generation &&
                ScreenStates.belongsToGeneration(
                    timestamp,
                    current.media_timestamp.toUInt(),
                    engines.capabilities.millisecondTimestamps,
                )
        ) {
            presentedGeneration = current.display_generation
            stream.presented(current)
            if (peerConnected) {
                recovery.streaming(now())
                mutableView.update { it.copy(phase = ScreenPhase.Streaming) }
            }
            publishReadiness()
        }
    }

    private fun publishReadiness() {
        val readiness =
            ScreenSessionPolicy.readiness(
                negotiation.authorized,
                peerConnected,
                presentedGeneration,
                state,
                negotiation.binding,
                preferences.displayId,
                ScreenSessionPolicy.inputChannelsOpen(engine),
                focused,
            )
        reports.input(focused && readiness.control)
        mutableView.update {
            it.copy(
                ready = readiness.ready,
                controlActive = readiness.control,
                canTransferControl = readiness.canTransferControl,
            )
        }
    }

    private fun hostEvent(bytes: ByteArray) {
        if (!negotiation.authorized || bytes.size > ScreenChannels.MAX_HOST_EVENT_BYTES) return
        val event = runCatching {
            RemoteDesktopHostEvent.ADAPTER.decode(bytes)
        }
            .getOrElse {
                return fail("The screen host sent an invalid event.")
            }
        event.state?.let(::applyState)
        event.input_ack?.let { ack -> state = state?.copy(last_input_ordinal = ack) }
        event.reference?.let(reports::expect)
        event.cursor?.let(input::cursor)
    }

    // --- Recovery ---------------------------------------------------------------------

    private fun settle(outcome: ScreenSessionPolicy.Outcome) =
        when (outcome) {
            ScreenSessionPolicy.Outcome.HevcFallback -> hevcFallback()
            is ScreenSessionPolicy.Outcome.Recover -> recover(outcome.reason)
            is ScreenSessionPolicy.Outcome.Fail -> fail(outcome.message)
        }

    private fun hevcFallback() {
        if (ScreenSessionPolicy.canFallBackFromHevc(preferences, hevcFailed)) {
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
        mutableView.update {
            it.copy(phase = ScreenPhase.Reconnecting(reason), ready = false, controlActive = false)
        }
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
        mutableView.update {
            it.copy(phase = ScreenPhase.Failed(message), ready = false, controlActive = false)
        }
    }

    private fun stopSession() {
        token++
        negotiation.reset()
        releaseInput()
        attempt?.cancel()
        attempt = null
        jobs.forEach(Job::cancel)
        jobs.clear()
        input.reset()
        reports.stop()
        clipboard.reset()
        runCatching { engine?.close() }
        engine = null
        val oldRoute = route
        if (oldRoute != null) closing = signaling.close(oldRoute, sessionId)
        route = null
        request = null
        sessionId = ""
        mutableView.update { it.copy(sessionId = "", mediaFps = 0.0, mediaRelayed = null) }
        signaling.reset()
        peerConnected = false
        peerConnectedOnce = false
        peerRecoveryJob?.cancel()
        peerRecoveryJob = null
        stream.reset()
        presentedGeneration = 0
        lastPresented = null
        state = null
        frames.reset()
    }

    // --- Engine events ------------------------------------------------------------------

    private inner class Events(private val attemptToken: Long) : ScreenMediaEvents {
        private fun onCore(block: () -> Unit) {
            scope.launch { if (attemptToken == token) block() }
        }

        override fun localCandidate(candidate: RemoteDesktopICECandidate) = onCore {
            signaling.localCandidate(route, sessionId, candidate)
        }

        override fun peerState(state: PeerState) = onCore {
            when (state) {
                PeerState.CONNECTED -> {
                    val wasInterrupted = peerRecoveryJob != null
                    peerRecoveryJob?.cancel()
                    peerRecoveryJob = null
                    peerConnected = true
                    peerConnectedOnce = true
                    frames.reset()
                    if (wasInterrupted) configure(refresh = true)
                    mutableView.update {
                        it.copy(
                            phase =
                                if (presentedGeneration > 0) ScreenPhase.Streaming
                                else ScreenPhase.Connecting
                        )
                    }
                    publishReadiness()
                }
                PeerState.DISCONNECTED -> {
                    releaseInput()
                    peerConnected = false
                    recovery.interrupted(now())
                    mutableView.update {
                        it.copy(
                            phase = ScreenPhase.Reconnecting(null),
                            ready = false,
                            controlActive = false,
                        )
                    }
                    val expected = token
                    if (peerRecoveryJob == null) {
                        peerRecoveryJob = scope.launch {
                            delay(ScreenSessionPolicy.PEER_GRACE)
                            if (expected == token && !peerConnected)
                                recover("The peer did not recover after losing connectivity")
                        }
                    }
                }
                PeerState.FAILED -> recover("The video connection failed")
                PeerState.CLOSED ->
                    if (
                        view.value.phase !is ScreenPhase.Failed &&
                            view.value.phase !is ScreenPhase.Idle
                    )
                        recover("The video connection closed")
                else -> Unit
            }
        }

        override fun channelState(label: String, open: Boolean) = onCore {
            if (!open && label == ScreenChannels.CLIPBOARD && negotiation.authorized)
                return@onCore recover("Clipboard channel closed")
            publishReadiness()
        }

        override fun channelMessage(label: String, bytes: ByteArray) = onCore {
            when (label) {
                ScreenChannels.SESSION -> hostEvent(bytes)
                ScreenChannels.CLIPBOARD -> clipboard.message(bytes)
            }
        }

        override fun decoded(rtpTimestamp: UInt) = onCore { reports.decoded(rtpTimestamp) }

        override fun presented(rtpTimestamp: UInt) = onCore {
            if (lastPresented != rtpTimestamp) frames.reset()
            lastPresented = rtpTimestamp
            markPresented(rtpTimestamp)
        }

        override fun mediaPath(relayed: Boolean) = onCore {
            if (view.value.mediaRelayed != relayed)
                mutableView.update { it.copy(mediaRelayed = relayed) }
        }

        override fun hevcUnavailable(reason: String) = onCore { hevcFallback() }

        override fun failure(message: String) = onCore { fail(message) }
    }

    // --- Stream and control -------------------------------------------------------------

    /** Sends the desired stream configuration; overlapping requests coalesce into one in flight. */
    fun configure(refresh: Boolean = false) = stream.configure(refresh)

    /** Sets the requested stream size for this view; debounced by 350 ms. */
    fun viewport(widthPoints: Double, heightPoints: Double, scale: Double) =
        stream.viewport(widthPoints, heightPoints, scale)

    fun setQuality(quality: RemoteDesktopQuality) = setPreferences { it.copy(quality = quality) }

    /** Takes or hands back control; the host's reply is merged like any other state. */
    suspend fun setControl(take: Boolean) {
        val current = route ?: return
        releaseInput()
        val updated =
            withDeadline(Deadlines.CALL) {
                current.client
                    .SetRemoteDesktopControl()
                    .execute(
                        RemoteDesktopControlRequest(session_id = sessionId, take_control = take)
                    )
            }
        applyState(updated)
    }

    /**
     * Takes or releases control once at a time; a failure, including no answer in time, is shown in
     * the view instead of thrown.
     */
    suspend fun transferControl(take: Boolean) {
        if (view.value.controlTransferring) return
        mutableView.update { it.copy(controlTransferring = true, controlError = null) }
        val error =
            try {
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

    /**
     * Moves the remote pointer; moves within 4 ms of the last one are coalesced (the latest wins).
     */
    fun pointer(x: Double, y: Double) = input.pointer(x, y)

    fun button(
        button: RemoteDesktopPointerButton.Button,
        down: Boolean,
        clicks: Int,
        x: Double,
        y: Double,
        modifiers: Int = 0,
    ) = input.button(button, down, clicks, x, y, modifiers)

    fun scroll(
        dx: Double,
        dy: Double,
        phase: Int,
        momentum: Int = 0,
        modifiers: Int = 0,
        precise: Boolean = true,
    ) = input.scroll(dx, dy, phase, momentum, modifiers, precise)

    /**
     * A physical key by USB HID usage; Command-C/X/V become clipboard operations when sharing is
     * on.
     */
    fun key(hid: Int, down: Boolean, repeat: Boolean = false, modifiers: Int = 0) =
        input.key(hid, down, repeat, modifiers)

    /**
     * Committed text; a single ASCII character with Control, Option, or Command held becomes a key
     * stroke.
     */
    fun text(value: String, modifiers: Int = 0) = input.text(value, modifiers)

    /** Releases every held key and button on the host. */
    fun releaseInput() = input.release()

    /**
     * The input [command] carries: a pointer move, button, scroll, key, text, or input release;
     * other members are ignored.
     */
    fun applyInput(command: ScreenCommand) = input.apply(command)

    // --- Clipboard ----------------------------------------------------------------------

    /** Admit clipboard work without holding later input or disconnect commands behind its reply. */
    fun requestClipboard(operation: String) {
        track(scope.launch { performClipboard(operation) })
    }

    /** The sharing exchange belongs to this attempt and is cancelled when the session ends. */
    fun requestClipboardEnabled(enabled: Boolean) {
        track(scope.launch { setClipboardEnabled(enabled) })
    }

    /**
     * Copy, cut, or paste on the host, as Command-C/X/V would. It waits for a background sync
     * exchange in flight, then reads the current clipboard.
     */
    suspend fun performClipboard(operation: String) = clipboard.perform(operation)

    /**
     * Turns clipboard sharing on or off for the session. The host confirms with a new clipboard
     * generation, which resets the sync baseline.
     */
    suspend fun setClipboardEnabled(enabled: Boolean) {
        stream.preferences = preferences.copy(clipboard = enabled)
        clipboard.setEnabled(enabled)
    }

    private companion object {
        const val IDENTITY_CHANGED =
            "The enrolled machine identity changed. Reconnect to verify it."
    }
}

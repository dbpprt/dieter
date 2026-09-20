package com.dbpprt.dieter.screens

import com.dbpprt.dieter.data.DIETER_PROTOCOL_VERSION

import android.content.Context
import android.os.SystemClock
import com.dbpprt.dieter.v1.*
import com.google.protobuf.Empty
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import org.webrtc.*
import java.nio.ByteBuffer
import java.util.UUID
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlin.math.max
import kotlin.math.roundToInt

data class ScreenState(
    val clipboardBusy: Boolean = false, val clipboardEnabled: Boolean = true, val clipboardError: String = "",
    val codecFallbackReason: String = "", val phase: String = "idle", val error: String = "", val control: Boolean = false,
    val capabilities: RemoteDesktopCapabilities = RemoteDesktopCapabilities.getDefaultInstance(),
    val session: RemoteDesktopSessionState = RemoteDesktopSessionState.getDefaultInstance(),
    val cursor: RemoteDesktopCursor = RemoteDesktopCursor.getDefaultInstance(),
    val canTransferControl: Boolean = false, val controlTransferPending: Boolean = false, val controlError: String = "",
    val signalingRoute: String = "", val mediaRoute: String = "", val receivedFps: Double = 0.0,
    val decodedFrames: Long = 0,
)

internal fun shouldRequestScreenControl(capabilities: RemoteDesktopCapabilities): Boolean {
    val portalCanRequestControl = capabilities.platform == "linux" && capabilities.controlPermission == "not_requested"
    return capabilities.controlSupported && (capabilities.controlPermission == "granted" || portalCanRequestControl)
}

internal fun shouldEmbedScreenCursor(capabilities: RemoteDesktopCapabilities) = !capabilities.cursorSupported

internal fun screenConnectionPhase(capabilities: RemoteDesktopCapabilities) =
    if (capabilities.platform == "linux" && capabilities.capturePermission == "not_requested")
        "waiting for approval on Linux host"
    else "connecting"

class ScreenController(context: Context) : AutoCloseable {
    // Keep fixture-only until a physical codec advertising this feature has
    // passed latency and lifecycle qualification (acceptance is insufficient).
    var lowLatencyDecoding = false
    // Fixture-only A/B until physical cadence/composition qualification. Both
    // paths retain the real WebRTC decoded-frame and reference contract.
    var surfacePresentation = false
    var directSurfacePresentation = false
    @Volatile internal var decoderSurface: DecoderSurface? = null
    private var decoderSurfaceAttached = false
    private var renderMeasurement = RemoteDesktopRenderMeasurement.REMOTE_DESKTOP_RENDER_MEASUREMENT_UNSPECIFIED
    @Volatile var decoderStatus: ScreenDecoderStatus? = null
        private set
    val egl: EglBase = EglBase.create()
    val canvasModel = ScreenCanvasModel()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val clipboardInput = ArrayDeque<RemoteDesktopInput>()
    val clipboard = ScreenClipboard(context.applicationContext, scope)
    private val mutable = MutableStateFlow(ScreenState())
    val state = mutable.asStateFlow()
    @Volatile var videoSink: ((VideoFrame, Long) -> Unit)? = null
    @Volatile internal var decodedOutputObserver: ((Long) -> Unit)? = null
    var onVideoReset: (() -> Unit)? = null
    private val videoFrames = ScreenFrameGate<VideoFrame>({ it.timestampNs }, { it.retain() }, { it.release() }) { frame, epoch ->
        if (authorized && epoch == token) videoSink?.invoke(frame, epoch)
    }
    @Volatile private var authorized = false
    @Volatile private var token = 0L
    private var disconnecting = false
    private var closed = false
    private var totalRenderMs = 0.0
    private var connection: ScreenConnection? = null
    private var reopen: (suspend () -> ScreenConnection)? = null
    private var peer: PeerConnection? = null
    private var peerConnected = false
    private var factory: PeerConnectionFactory? = null
    private var pointer: DataChannel? = null
    private var input: DataChannel? = null
    private var host: DataChannel? = null
    private var binding: RemoteDesktopSessionBinding? = null
    private var request: StartRemoteDesktopRequest? = null
    private var answer: String? = null
    private var remoteApplied = false
    private var sessionId = ""
    private val localCandidates = mutableListOf<IceCandidate>()
    private val remoteCandidates = mutableListOf<IceCandidate>()
    private var signaling: Job? = null
    private var monitoring: Job? = null
    private var configuring: Job? = null
    private var peerWatchdog: Job? = null
    private var recovering: Job? = null
    private var closing: Job? = null
    private var recovery = ScreenRecovery()
    private var certificate: ByteArray? = null
    private var pointerFlush: Job? = null
    private var pointerLastSent: Long? = null
    var preferredMaxFPS: Int = 60
        private set
    var codecPreference = RemoteDesktopCodecPreference.REMOTE_DESKTOP_CODEC_PREFERENCE_H264
        private set
    private var hevcFailed = false
    private var codecFallbackReason = ""
    private val effectiveCodec get() = if (hevcFailed && codecPreference == RemoteDesktopCodecPreference.REMOTE_DESKTOP_CODEC_PREFERENCE_AUTO)
        RemoteDesktopCodecPreference.REMOTE_DESKTOP_CODEC_PREFERENCE_H264 else codecPreference
    private var pendingPointer: Pair<Float, Float>? = null
    internal var pointerSequence = 0L
        private set
    private var stateSequence = 0L
    private var ordinal = 0L
    private val feedbackPump = ScreenFeedbackPump()
    private var referenceReceiver: ScreenReferenceReceiver? = null
    private var leaseRenewal: Job? = null
    private var presentedGeneration = 0L
    private var lastPresentedTimestamp: Long? = null
    private val framesPresented = AtomicLong()
    private var configuration = RemoteDesktopStreamConfiguration.getDefaultInstance()
    private var focused = true
    var onCursor: ((RemoteDesktopCursor) -> Unit)? = null
    var lastPointerOrdinal = 0L; private set
    val id get() = sessionId
    internal fun acceptsFrame(sessionToken: Long) = authorized && token == sessionToken

    init {
        initialize(context.applicationContext)
        clipboard.request = {
            if (!mutable.value.control || !focused || binding == null) null else
                RemoteDesktopClipboardRequest.newBuilder().setSessionId(sessionId).setInputEpoch(binding!!.inputEpoch)
                    .setControlGeneration(mutable.value.session.controlGeneration).setInputBarrier(stateSequence)
        }
        clipboard.onBusy = { mutable.value = mutable.value.copy(clipboardBusy = it) }
        clipboard.onOperationFinished = { succeeded ->
            val pending = clipboardInput.toList(); clipboardInput.clear()
            if (succeeded && mutable.value.control && focused) pending.forEach { send(it.toBuilder()) } else releaseInput()
        }
        clipboard.isCurrentGrant = { mutable.value.session.controlActive && mutable.value.session.controlGeneration == it }
        clipboard.onError = { mutable.value = mutable.value.copy(clipboardError = it) }
        clipboard.onUnavailable = { recover("Clipboard channel closed") }
    }

    fun connect(open: suspend () -> ScreenConnection) {
        check(!closed) { "Screen controller is closed" }
        disconnect()
        reopen = open
        hevcFailed = false; codecFallbackReason = ""
        recovery = ScreenRecovery()
        certificate = null
        configuration = RemoteDesktopStreamConfiguration.getDefaultInstance()
        startConnection()
    }

    private fun startConnection() {
        val open = reopen ?: return
        val current = token
        mutable.value = ScreenState(clipboardEnabled = clipboard.enabled, codecFallbackReason = codecFallbackReason, phase = if (recovering == null) "connecting" else "reconnecting")
        signaling = scope.launch {
            try {
                // A rapid Retry must not race the previous session's asynchronous Close RPC.
                closing?.join()
                val route = withTimeout(20_000) { openRoute(open) }
                if (current != token) { route.close(); return@launch }
                connection = route
                require(certificate?.contentEquals(route.certificate) != false) { "The enrolled machine identity changed. Reconnect to verify it." }
                certificate = route.certificate.copyOf()
                val caps = rpc().getRemoteDesktopCapabilities(Empty.getDefaultInstance())
                mutable.value = mutable.value.copy(capabilities = caps, signalingRoute = route.route)
                if (!caps.ready) {
                    mutable.value = mutable.value.copy(
                        phase = if (caps.availability == RemoteDesktopAvailability.REMOTE_DESKTOP_AVAILABILITY_PERMISSION_REQUIRED) "permission required" else "unsupported",
                        error = caps.unavailableReason.ifBlank { "Screen sharing is unavailable on this machine" },
                    )
                    return@launch
                }
                require(caps.inputProtocolVersion == DIETER_PROTOCOL_VERSION) { "Update the Dieter daemon and client together" }
                clipboard.binarySupported = caps.binaryClipboardSupported
                val references = ScreenReferenceReceiver { feedbackPump.acknowledge(it) }
                referenceReceiver?.stop(); referenceReceiver = references
                val decoders = ScreenDecoderFactory(egl.eglBaseContext,
                    enableHEVC = effectiveCodec != RemoteDesktopCodecPreference.REMOTE_DESKTOP_CODEC_PREFERENCE_H264,
                    lowLatency = lowLatencyDecoding,
                    directSurface = { if (directSurfacePresentation) decoderSurface else null },
                    outputDecoded = { timestamp ->
                        references.decoded(timestamp)
                        if (authorized && token == current) decodedOutputObserver?.invoke(timestamp)
                    },
                    configured = { status -> if (current == token) decoderStatus = status },
                    unavailable = { scope.launch { if (current == token) hevcUnavailable() } }) { frame ->
                    if (authorized && token == current) videoFrames.offer(frame, current)
                }
                require(decoders.supportedCodecs.isNotEmpty()) { "This device has no H.264 MediaCodec decoder" }
                factory = PeerConnectionFactory.builder().setFieldTrials("WebRTC-GenericDescriptorAdvertised/Enabled/").setVideoDecoderFactory(decoders).createPeerConnectionFactory()
                val rtc = PeerConnection.RTCConfiguration(route.rtc.iceServersList.map {
                    PeerConnection.IceServer.builder(it.urlsList).setUsername(it.username).setPassword(it.credential).createIceServer()
                }).apply {
                    sdpSemantics = PeerConnection.SdpSemantics.UNIFIED_PLAN
                    continualGatheringPolicy = PeerConnection.ContinualGatheringPolicy.GATHER_CONTINUALLY
                }
                val pc = requireNotNull(factory!!.createPeerConnection(rtc, observer(current)))
                peer = pc
                pointer = pc.createDataChannel("dieter-pointer-v$DIETER_PROTOCOL_VERSION", DataChannel.Init().apply { ordered = false; maxRetransmits = 0 })
                input = pc.createDataChannel("dieter-input-state-v$DIETER_PROTOCOL_VERSION", DataChannel.Init())
                host = pc.createDataChannel("dieter-session-v$DIETER_PROTOCOL_VERSION", DataChannel.Init())
                if (caps.clipboardSupported) clipboard.attach(pc.createDataChannel("dieter-clipboard-v1", DataChannel.Init()))
                listOfNotNull(pointer, input, host).forEach { channel -> channel.registerObserver(channelObserver(channel, current)) }
                val video = pc.addTransceiver(MediaStreamTrack.MediaType.MEDIA_TYPE_VIDEO,
                    RtpTransceiver.RtpTransceiverInit(RtpTransceiver.RtpTransceiverDirection.RECV_ONLY))
                val canHEVC = caps.codecModesList.any { it.codec == "H265" && it.profile == "main" &&
                    it.maxWidth >= 1920 && it.maxHeight >= 1080 && it.maxFps >= preferredMaxFPS }
                val codecs = factory!!.getRtpReceiverCapabilities(MediaStreamTrack.MediaType.MEDIA_TYPE_VIDEO).codecs
                    .filter { it.name.equals("flexfec-03", true) || (it.name.equals("H265", true) && canHEVC && effectiveCodec != RemoteDesktopCodecPreference.REMOTE_DESKTOP_CODEC_PREFERENCE_H264) ||
                        (it.name.equals("H264", true) && effectiveCodec != RemoteDesktopCodecPreference.REMOTE_DESKTOP_CODEC_PREFERENCE_HEVC) }
                    .sortedByDescending { if (it.name.equals("H265", true)) 2 else if (it.parameters["profile-level-id"]?.startsWith("64") == true) 1 else 0 }
                require(codecs.isNotEmpty()) { "Selected codec unavailable. HEVC requires hardware decoding and an updated host at up to 1080p60." }
                video.setCodecPreferences(codecs)
                val offer = createOffer(pc)
                setDescription(pc, offer, local = true)
                if (current != token) return@launch
                val display = caps.displaysList.firstOrNull { it.id == configuration.displayId }
                    ?: caps.displaysList.firstOrNull { it.primary } ?: caps.displaysList.first()
                val start = StartRemoteDesktopRequest.newBuilder().setReferenceRecovery(offer.description.contains(SCREEN_GENERIC_DESCRIPTOR_URI)).setCodecPreference(effectiveCodec).setClipboard(caps.clipboardSupported && clipboard.enabled).setClientNonce(UUID.randomUUID().toString())
                    .setRtcConfiguration(route.rtc).setDisplayId(display.id)
                    .setInputProtocolVersion(DIETER_PROTOCOL_VERSION).setClientName("Android")
                    .setControl(shouldRequestScreenControl(caps))
                    .setEmbeddedCursor(shouldEmbedScreenCursor(caps))
                    .setMaxWidth(1920).setMaxHeight(1080).setMaxFps(minOf(preferredMaxFPS, caps.maxFps.takeIf { it > 0 } ?: 60)).setMaxBitrateKbps(12000).setQuality(configuration.quality)
                    .setOffer(RemoteDesktopSessionDescription.newBuilder().setType("offer").setSdp(offer.description)).build()
                request = start
                mutable.value = mutable.value.copy(phase = screenConnectionPhase(caps))
                configuration = RemoteDesktopStreamConfiguration.newBuilder().setDisplayId(display.id)
                    .setMaxWidth(start.maxWidth).setMaxHeight(start.maxHeight).setMaxFps(start.maxFps).setMaxBitrateKbps(12000)
                    .setQuality(start.quality).setEmbeddedCursor(start.embeddedCursor).build()
                while (isActive && current == token) {
                    val sourceRoute = requireNotNull(connection)
                    try {
                        sourceRoute.rpc.startRemoteDesktop(start).collect { signal ->
                            if (current != token) throw CancellationException()
                            receive(signal)
                        }
                        throw io.grpc.Status.UNAVAILABLE.withDescription("Screen-sharing signaling ended").asException()
                    } catch (e: CancellationException) { throw e
                    } catch (e: Exception) {
                        // A planned credential refresh must resubscribe immediately, without
                        // treating the retired route as a network failure or disabling input.
                        if (sourceRoute !== connection && current == token) continue
                        throw e
                    }
                }
            } catch (e: TimeoutCancellationException) { if (current == token) recover("Connection attempt timed out")
            } catch (e: CancellationException) { throw e
            } catch (e: Exception) { if (current == token) connectionFailure(e) }
        }
    }

    private fun rpc() = requireNotNull(connection).rpc.withDeadlineAfter(15, TimeUnit.SECONDS)
    private suspend fun receive(signal: RemoteDesktopSignal) {
        require(signal.sessionId.isNotBlank()) { "Missing screen session identity" }
        if (sessionId.isEmpty()) {
            sessionId = signal.sessionId
            localCandidates.toList().forEach(::sendCandidate); localCandidates.clear()
            monitor()
        }
        if (signal.sessionId != sessionId) {
            // The daemon may have expired the old session while a refreshed route was opening.
            // Never apply a new answer to the old peer; authenticate a completely new offer.
            throw io.grpc.Status.NOT_FOUND.withDescription("The previous screen session expired").asException()
        }
        when (signal.payloadCase) {
            RemoteDesktopSignal.PayloadCase.BINDING -> {
                require(binding == null || binding == signal.binding) { "Screen binding changed" }
                binding = signal.binding; applyAnswer()
            }
            RemoteDesktopSignal.PayloadCase.DESCRIPTION -> {
                require(signal.description.type == "answer") { "Invalid screen answer" }
                require(answer == null || answer == signal.description.sdp) { "Screen answer changed" }
                answer = signal.description.sdp; applyAnswer()
            }
            RemoteDesktopSignal.PayloadCase.CANDIDATE -> {
                val c = signal.candidate
                val ice = IceCandidate(c.sdpMid, c.sdpMlineIndex, c.candidate)
                if (remoteApplied) require(peer?.addIceCandidate(ice) == true) { "Invalid ICE candidate" }
                else { require(remoteCandidates.size < 256); remoteCandidates.add(ice) }
            }
            RemoteDesktopSignal.PayloadCase.STATE -> applyState(signal.state)
            RemoteDesktopSignal.PayloadCase.ERROR -> if (signal.error.code == "hevc_unavailable") {
                hevcUnavailable()
            } else if (signal.error.recoverable ||
                (signal.error.code == "capture_failed" && ScreenRecovery.retryableClosure(signal.error.message))) {
                recover(signal.error.message)
            } else fail(signal.error.message)
            else -> Unit
        }
    }
    private suspend fun applyAnswer() {
        if (remoteApplied) return
        val b = binding ?: return; val sdp = answer ?: return; val req = request ?: return
        ScreenTrust.verify(b, sessionId, req.clientNonce, req.offer.sdp, sdp, requireNotNull(connection).certificate,
            req.control, req.displayId, req.inputProtocolVersion)
        authorized = true
        mutable.value = mutable.value.copy(canTransferControl = b.controlGranted)
        feedbackPump.start(host, RemoteDesktopReceiverFeedback.newBuilder().setProtocolVersion(DIETER_PROTOCOL_VERSION).setInputEpoch(b.inputEpoch).build())
        setDescription(requireNotNull(peer), SessionDescription(SessionDescription.Type.ANSWER, sdp), local = false)
        remoteApplied = true
        remoteCandidates.forEach { require(peer?.addIceCandidate(it) == true) }; remoteCandidates.clear()
        readiness()
    }
    private fun observer(current: Long) = object : PeerConnection.Observer {
        override fun onIceCandidate(candidate: IceCandidate) { scope.launch {
            if (token != current) return@launch
            if (sessionId.isEmpty()) { if (localCandidates.size < 256) localCandidates.add(candidate) }
            else sendCandidate(candidate)
        } }
        override fun onConnectionChange(value: PeerConnection.PeerConnectionState) { scope.launch {
            if (token != current) return@launch
            when (value) {
                PeerConnection.PeerConnectionState.FAILED, PeerConnection.PeerConnectionState.CLOSED -> recover("The video connection failed")
                PeerConnection.PeerConnectionState.DISCONNECTED -> {
                    releaseInput(); peerConnected = false; recovery.interrupted(SystemClock.elapsedRealtime())
                    mutable.value = mutable.value.copy(phase = "reconnecting", control = false)
                    peerWatchdog?.cancel()
                    peerWatchdog = scope.launch {
                        delay(3_000)
                        if (token == current && !peerConnected) recover("The peer did not recover after losing connectivity")
                    }
                }
                PeerConnection.PeerConnectionState.CONNECTED -> { peerWatchdog?.cancel(); peerWatchdog = null; peerConnected = true; readiness() }
                else -> Unit
            }
        } }
        override fun onSignalingChange(state: PeerConnection.SignalingState) = Unit
        override fun onIceConnectionChange(state: PeerConnection.IceConnectionState) = Unit
        override fun onIceConnectionReceivingChange(receiving: Boolean) = Unit
        override fun onIceGatheringChange(state: PeerConnection.IceGatheringState) = Unit
        override fun onIceCandidatesRemoved(candidates: Array<out IceCandidate>) = Unit
        override fun onAddStream(stream: MediaStream) = Unit
        override fun onRemoveStream(stream: MediaStream) = Unit
        override fun onDataChannel(channel: DataChannel) { channel.close() }
        override fun onRenegotiationNeeded() = Unit
    }
    private fun sendCandidate(candidate: IceCandidate) {
        val current = token
        scope.launch { try {
            if (current != token || sessionId.isEmpty()) return@launch
            rpc().sendRemoteDesktopSignal(RemoteDesktopSignal.newBuilder().setSessionId(sessionId)
                .setCandidate(RemoteDesktopICECandidate.newBuilder().setCandidate(candidate.sdp)
                    .setSdpMid(candidate.sdpMid ?: "").setSdpMlineIndex(candidate.sdpMLineIndex)).build())
        } catch (_: Exception) { /* ICE can still use the other candidates; the lease detects route loss. */ } }
    }
    private fun channelObserver(channel: DataChannel, current: Long) = object : DataChannel.Observer {
        override fun onBufferedAmountChange(previousAmount: Long) = Unit
        override fun onStateChange() { scope.launch { if (current == token) readiness() } }
        override fun onMessage(buffer: DataChannel.Buffer) {
            if (channel !== host || !buffer.binary || buffer.data.remaining() > 300_000) return
            val bytes = ByteArray(buffer.data.remaining()); buffer.data.get(bytes)
            scope.launch {
                if (current != token || !authorized) return@launch
                try {
                    val event = RemoteDesktopHostEvent.parseFrom(bytes)
                    when (event.payloadCase) {
                        RemoteDesktopHostEvent.PayloadCase.REFERENCE -> referenceReceiver?.expect(event.reference)
                        RemoteDesktopHostEvent.PayloadCase.STATE -> applyState(event.state)
                        RemoteDesktopHostEvent.PayloadCase.CURSOR -> if (event.cursor.displayGeneration == mutable.value.session.displayGeneration) {
                            onCursor?.invoke(event.cursor)
                        }
                        RemoteDesktopHostEvent.PayloadCase.INPUT_ACK -> mutable.value = mutable.value.copy(
                            session = mutable.value.session.toBuilder().setLastInputOrdinal(event.inputAck).build())
                        else -> Unit
                    }
                } catch (e: Exception) { fail(e.message ?: "Invalid host event") }
            }
        }
    }
    private fun applyState(value: RemoteDesktopSessionState) {
        if (value.phase == "closed") {
            if (value.reason == "HEVC encoder unavailable") { hevcUnavailable(); return }
            if (ScreenRecovery.retryableClosure(value.reason)) recover(value.reason)
            else fail(value.reason.ifBlank { "The screen session closed" })
            return
        }
        val previous = mutable.value.session
        if (value.displayGeneration < previous.displayGeneration) return
        var next = value
        if (value.displayGeneration != previous.displayGeneration) {
            releaseInput(); presentedGeneration = 0
            videoFrames.update(token, value.displayGeneration, 0, 0)
            onVideoReset?.invoke()
        } else if (value.mediaGeneration < previous.mediaGeneration) {
            next = value.toBuilder().setMediaGeneration(previous.mediaGeneration).setMediaTimestamp(previous.mediaTimestamp).build()
        }
        if (next.controlGeneration < previous.controlGeneration) {
            next = next.toBuilder().setControlGeneration(previous.controlGeneration).setControlActive(previous.controlActive)
                .setControllerName(previous.controllerName).build()
        }
        if (next.clipboardGeneration < previous.clipboardGeneration) {
            next = next.toBuilder().setClipboardGeneration(previous.clipboardGeneration).setClipboardEnabled(previous.clipboardEnabled).build()
        } else if (next.clipboardGeneration > previous.clipboardGeneration) {
            clipboard.enabled = next.clipboardEnabled
            mutable.value = mutable.value.copy(clipboardEnabled = next.clipboardEnabled)
        }
        mutable.value = mutable.value.copy(session = next)
        videoFrames.update(token, next.displayGeneration, next.mediaGeneration, next.mediaTimestamp)
        lastPresentedTimestamp?.let(::markPresented)
        readiness()
    }
    /** A presentation endpoint is explicit; EGL swap and MediaCodec callback differ. */
    fun presented(timestampNs: Long, sessionToken: Long, renderMs: Double,
        measurement: RemoteDesktopRenderMeasurement = RemoteDesktopRenderMeasurement.REMOTE_DESKTOP_RENDER_MEASUREMENT_EGL_SUBMITTED) {
        scope.launch { if (authorized && token == sessionToken) {
            if (measurement != renderMeasurement) { framesPresented.set(0); totalRenderMs = 0.0; renderMeasurement = measurement }
            framesPresented.incrementAndGet(); totalRenderMs += renderMs
            lastPresentedTimestamp = timestampNs; markPresented(timestampNs); readiness()
        } }
    }
    internal fun attachDecoderSurface(surface: DecoderSurface) {
        decoderSurface?.close()
        decoderSurface = surface
        val reconnect = decoderSurfaceAttached
        decoderSurfaceAttached = true
        if (reconnect && reopen != null) resumeConnection()
    }
    internal fun detachDecoderSurface(surface: DecoderSurface) {
        if (decoderSurface === surface) decoderSurface = null
        surface.close()
    }
    private fun markPresented(timestampNs: Long) {
        val s = mutable.value.session
        if (s.mediaGeneration > 0 && s.mediaGeneration == s.displayGeneration && belongsToGeneration(timestampNs, s.mediaTimestamp)) {
            presentedGeneration = s.displayGeneration
        }
    }
    private fun readiness() {
        val ready = authorized && peerConnected && presentedGeneration > 0 && presentedGeneration == mutable.value.session.displayGeneration
            && configuration.displayId == mutable.value.session.displayId
        if (ready) recovery.streaming(SystemClock.elapsedRealtime())
        val channels = listOf(pointer, input, host).all { it?.state() == DataChannel.State.OPEN }
        mutable.value = mutable.value.copy(control = ready && peerConnected && channels && binding?.controlGranted == true && focused
            && mutable.value.session.controlActive,
            phase = if (ready) "streaming" else mutable.value.phase)
        feedbackPump.input(focused && mutable.value.control)
    }

    fun pointer(x: Float, y: Float) {
        if (!mutable.value.control) return
        pendingPointer = x to y
        if (pointerFlush != null) return
        val wait = pointerLastSent?.let { (4 - (SystemClock.uptimeMillis() - it)).coerceAtLeast(0) } ?: 0
        if (wait == 0L) { flushPointer(); return }
        pointerFlush = scope.launch {
            delay(wait); pointerFlush = null
            flushPointer()
        }
    }
    private fun flushPointer() {
        val point = pendingPointer ?: return
        pendingPointer = null
        if (!mutable.value.control) return
        pointerLastSent = SystemClock.uptimeMillis()
        send(RemoteDesktopInput.newBuilder().setPointerMove(RemoteDesktopPointerMove.newBuilder()
            .setNormalizedX(normalize(point.first)).setNormalizedY(normalize(point.second))), reliable = false)
    }
    fun button(button: RemoteDesktopPointerButton.Button, down: Boolean, x: Float, y: Float, count: Int = 1, modifiers: Int = 0) =
        send(RemoteDesktopInput.newBuilder().setPointerButton(RemoteDesktopPointerButton.newBuilder()
            .setButton(button).setDown(down).setNormalizedX(normalize(x)).setNormalizedY(normalize(y))
            .setClickCount(count).setModifiers(modifiers)))
    fun scroll(dx: Float, dy: Float, phase: Int) = send(RemoteDesktopInput.newBuilder().setScroll(
        RemoteDesktopScroll.newBuilder().setPrecise(true).setPreciseDeltaX(dx.toDouble()).setPreciseDeltaY(dy.toDouble())
            .setDeltaX(dx.roundToInt()).setDeltaY(dy.roundToInt()).setPhase(phase)))
    fun key(hid: Int, down: Boolean, modifiers: Int = 0, repeat: Boolean = false) {
        if (hid in listOf(6, 25, 27) && modifiers and 15 == 8 && mutable.value.capabilities.clipboardSupported && clipboard.enabled) {
            if (down && !repeat) when (hid) {
                6 -> clipboard.copy()
                27 -> clipboard.perform(RemoteDesktopClipboardRequest.Action.CUT)
                else -> clipboard.paste()
            }
            return
        }
        send(RemoteDesktopInput.newBuilder().setKey(RemoteDesktopKey.newBuilder().setPhysicalKey(hid).setDown(down).setModifiers(modifiers).setRepeat(repeat)))
    }
    fun text(text: String) {
        if (text.toByteArray().size > 8192) return
        // Bound the host's UTF-16 input without splitting a surrogate pair.
        var chunk = StringBuilder()
        text.codePoints().forEach { point ->
            val chars = Character.toChars(point)
            if (chunk.length + chars.size > 512) { sendText(chunk.toString()); chunk = StringBuilder() }
            chunk.append(chars)
        }
        if (chunk.isNotEmpty()) sendText(chunk.toString())
    }
    private fun sendText(value: String) = send(RemoteDesktopInput.newBuilder().setText(RemoteDesktopText.newBuilder().setText(value)))
    fun releaseInput() {
        pointerFlush?.cancel(); pointerFlush = null; pendingPointer = null; pointerLastSent = null
        if (mutable.value.control) send(RemoteDesktopInput.newBuilder().setReleaseAll(RemoteDesktopReleaseAll.getDefaultInstance()))
    }
    fun focus(value: Boolean) { if (!value) releaseInput(); focused = value; readiness() }
    private fun send(builder: RemoteDesktopInput.Builder, reliable: Boolean = true) {
        if (!mutable.value.control) return
        if (builder.hasReleaseAll()) clipboardInput.clear()
        else if (reliable && clipboard.operationPending) {
            if (clipboardInput.size >= 128) { mutable.value = mutable.value.copy(clipboardError = "Input paused while clipboard transfer finishes"); releaseInput(); return }
            clipboardInput.addLast(builder.build()); return
        }
        val channel = if (reliable) input else pointer
        if (channel?.state() != DataChannel.State.OPEN || channel.bufferedAmount() >= 65536) {
            if (reliable && !builder.hasReleaseAll()) recover("Remote input stalled")
            return
        }
        if (reliable) { pendingPointer = null; stateSequence++ } else pointerSequence++
        ordinal++
        if (!reliable || builder.hasPointerButton()) lastPointerOrdinal = ordinal
        val raw = builder.setProtocolVersion(binding!!.inputProtocolVersion).setControlGeneration(mutable.value.session.controlGeneration).setInputEpoch(binding!!.inputEpoch)
            .setSequence(if (reliable) stateSequence else pointerSequence).setStateBarrier(stateSequence)
            .setEventOrdinal(ordinal).setDisplayGeneration(mutable.value.session.displayGeneration).build().toByteArray()
        if (raw.size > 4096 || !channel.send(DataChannel.Buffer(ByteBuffer.wrap(raw), true))) {
            if (reliable && !builder.hasReleaseAll()) recover("Remote input could not be delivered")
        }
    }
    fun selectCodec(value: RemoteDesktopCodecPreference) {
        codecPreference = value; hevcFailed = false; codecFallbackReason = ""
        if (reopen != null) recover("Changing video codec", immediate = true)
    }

    internal fun hevcUnavailable() {
        if (codecPreference != RemoteDesktopCodecPreference.REMOTE_DESKTOP_CODEC_PREFERENCE_AUTO || hevcFailed) {
            fail("HEVC hardware codec could not initialize"); return
        }
        hevcFailed = true; codecFallbackReason = "HEVC unavailable; using H.264"
        recover(codecFallbackReason, immediate = true)
    }

    fun configure(display: String? = null, quality: RemoteDesktopQuality? = null, maxFPS: Int? = null, refresh: Boolean = false) {
        if (sessionId.isEmpty()) return
        if (display != null && display != configuration.displayId) { releaseInput(); mutable.value = mutable.value.copy(control = false) }
        if (maxFPS != null) preferredMaxFPS = maxFPS.coerceIn(1, minOf(120, mutable.value.capabilities.maxFps.takeIf { it > 0 } ?: 60))
        configuration = configuration.toBuilder().apply {
            display?.let(::setDisplayId); quality?.let(::setQuality)
            if (maxFPS != null) setMaxFps(preferredMaxFPS)
        }.build()
        if (mutable.value.session.codec == "H265" && preferredMaxFPS > 60) {
            recover("Frame rate exceeds HEVC mode", immediate = true); return
        }
        configuring?.cancel()
        val current = token
        configuring = scope.launch {
            try {
                val result = rpc().updateRemoteDesktopSession(UpdateRemoteDesktopSessionRequest.newBuilder()
                    .setSessionId(sessionId).setConfiguration(configuration).setRefresh(refresh).build())
                if (current == token) applyState(result)
            } catch (e: TimeoutCancellationException) { if (current == token) recover("Connection attempt timed out")
            } catch (e: CancellationException) { throw e
            } catch (e: Exception) { if (current == token) connectionFailure(e) }
        }
    }

    fun transferControl(take: Boolean) {
        if (!mutable.value.canTransferControl || mutable.value.controlTransferPending) return
        val current = token
        val id = sessionId
        releaseInput()
        mutable.value = mutable.value.copy(controlTransferPending = true, controlError = "")
        scope.launch {
            try {
                val result = rpc().setRemoteDesktopControl(RemoteDesktopControlRequest.newBuilder().setSessionId(id).setTakeControl(take).build())
                if (current == token) applyState(result)
            } catch (e: CancellationException) { throw e
            } catch (e: Exception) {
                if (current == token) mutable.value = mutable.value.copy(controlError = e.message ?: "Control handoff failed")
            } finally {
                if (current == token) mutable.value = mutable.value.copy(controlTransferPending = false)
            }
        }
    }

    private fun monitor() {
        monitoring?.cancel()
        val current = token
        leaseRenewal?.cancel()
        leaseRenewal = scope.launch {
            while (isActive && current == token) {
                delay(5_000)
                try {
                    connection?.refreshAtMillis?.let { if (System.currentTimeMillis() >= it) refreshRoute(current) }
                    rpc().sendRemoteDesktopSignal(RemoteDesktopSignal.newBuilder()
                        .setSessionId(sessionId).setLeaseHeartbeat(Empty.getDefaultInstance()).build())
                } catch (e: CancellationException) { throw e
                } catch (e: Exception) { if (current == token) connectionFailure(e); return@launch }
            }
        }
        monitoring = scope.launch {
            var previous = emptyMap<String, Double>(); var previousTime = SystemClock.elapsedRealtime(); var ticks = 0
            while (isActive && current == token) {
                delay(500)
                try {
                    ticks++
                    val pc = peer ?: continue
                    val measurementStarted = SystemClock.elapsedRealtime()
                    val stats = suspendCancellableCoroutine<RTCStatsReport> { continuation ->
                        pc.getStats { if (continuation.isActive) continuation.resume(it) }
                    }
                    val incoming = stats.statsMap.values.firstOrNull { it.type == "inbound-rtp" && it.members["kind"] == "video" }?.members.orEmpty()
                    val pair = stats.statsMap.values.firstOrNull { it.type == "candidate-pair" && it.members["state"] == "succeeded" && it.members["nominated"] == true }?.members.orEmpty()
                    fun number(key: String) = (incoming[key] as? Number)?.toDouble() ?: 0.0
                    val values = listOf("framesDecoded", "totalDecodeTime", "jitterBufferEmittedCount", "jitterBufferDelay", "packetsLost", "packetsReceived", "framesReceived")
                        .associateWith(::number) + mapOf("presented" to framesPresented.get().toDouble(), "renderMs" to totalRenderMs)
                    fun delta(key: String) = max(0.0, values.getValue(key) - (previous[key] ?: values.getValue(key)))
                    val now = SystemClock.elapsedRealtime(); val elapsed = max(0.001, (now - previousTime) / 1000.0)
                    val fps = delta("presented") / elapsed
                    val feedback = RemoteDesktopReceiverFeedback.newBuilder().setProtocolVersion(DIETER_PROTOCOL_VERSION)
                        .setInputEpoch(binding?.inputEpoch ?: com.google.protobuf.ByteString.EMPTY)
                        .setFramesPerSecond(fps).setRenderedFrames(framesPresented.get().coerceAtMost(Int.MAX_VALUE.toLong()).toInt())
                        .setDecodeMs(if (delta("framesDecoded") > 0) delta("totalDecodeTime") * 1000 / delta("framesDecoded") else 0.0)
                        .setRenderMs(delta("renderMs") / max(1.0, delta("presented")))
                        .setRenderMeasurement(renderMeasurement)
                        .setJitterMs(number("jitter") * 1000)
                        .setJitterBufferMs(if (delta("jitterBufferEmittedCount") > 0) delta("jitterBufferDelay") * 1000 / delta("jitterBufferEmittedCount") else 0.0)
                        .setRttMs(((pair["currentRoundTripTime"] as? Number)?.toDouble() ?: 0.0) * 1000)
                        .setLossFraction(delta("packetsLost") / max(1.0, delta("packetsLost") + delta("packetsReceived")))
                        .setInputActive(focused && mutable.value.control).apply {
                            decoderStatus?.let {
                                setDecoderImplementation(it.implementation.take(256))
                                setDecoderHardware(it.hardware)
                                setDecoderLowLatencyAccepted(it.lowLatencyAccepted)
                                setDecoderConfigurationReason(it.reason.take(256))
                            }
                        }.build()
                    feedbackPump.update(feedback, measuredAt = measurementStarted)
                    val relayed = listOf("localCandidateId", "remoteCandidateId").any { key ->
                        stats.statsMap[pair[key]]?.members?.get("candidateType") == "relay"
                    }
                    mutable.value = mutable.value.copy(receivedFps = fps, decodedFrames = number("framesDecoded").toLong(),
                        mediaRoute = if (pair.isEmpty()) "" else if (relayed) "Relayed media" else "Direct media")
                    previous = values; previousTime = now
                    if (framesPresented.get() == 0L && ticks >= 6 && number("framesDecoded") > 0 && decoderSurface?.isOpen == true) {
                        // Older/vendor codecs may omit frame-render callbacks.
                        // Retire this optional target once; the next decoder
                        // uses textures until a genuinely new holder is attached.
                        decoderSurface?.close()
                        recover("Direct surface did not report presentation", immediate = true)
                        return@launch
                    }
                    if (framesPresented.get() == 0L && ticks == 6) configure(refresh = true)
                    if (framesPresented.get() == 0L && ticks >= 40) {
                        if (mutable.value.session.codec == "H265" && peerConnected && (values["framesReceived"] ?: 0.0) > 0 && (values["framesDecoded"] ?: 0.0) == 0.0)
                            hevcUnavailable() else recover("No screen frame was displayed")
                        return@launch
                    }
                } catch (e: CancellationException) { throw e
                } catch (e: Exception) { if (current == token) connectionFailure(e); return@launch }
            }
        }
    }
    private suspend fun refreshRoute(current: Long) {
        val open = reopen ?: return
        val old = connection ?: return
        val fresh = openRoute(open)
        if (current != token) { fresh.close(); return }
        if (!fresh.certificate.contentEquals(old.certificate)) {
            fresh.close(); error("The enrolled machine identity changed. Reconnect to verify it.")
        }
        connection = fresh
        mutable.value = mutable.value.copy(signalingRoute = fresh.route)
        old.close() // The idempotent signaling loop resubscribes using the same nonce and offer.
    }

    private suspend fun openRoute(open: suspend () -> ScreenConnection): ScreenConnection {
        // withContext may discard a successful result when cancellation wins the dispatch
        // back to Main. Retain ownership so leaving Screens cannot leak that channel.
        var opened: ScreenConnection? = null
        try { return withContext(Dispatchers.IO) { open().also { opened = it } } }
        catch (error: Exception) { opened?.close(); throw error }
    }

    fun setClipboardEnabled(value: Boolean) { clipboard.configure(value); mutable.value = mutable.value.copy(clipboardEnabled = value) }

    fun disconnect() {
        recovering?.cancel(); recovering = null
        reopen = null
        stopSession()
        mutable.value = mutable.value.copy(phase = "idle", error = "", control = false)
    }

    private fun stopSession() {
        if (disconnecting) return
        disconnecting = true
        peerWatchdog?.cancel(); peerWatchdog = null
        releaseInput(); token++; authorized = false
        videoFrames.clear()
        referenceReceiver?.stop(); referenceReceiver = null; feedbackPump.stop(); leaseRenewal?.cancel(); leaseRenewal = null
        signaling?.cancel(); signaling = null; monitoring?.cancel(); monitoring = null; configuring?.cancel(); configuring = null
        val old = connection; val id = sessionId
        connection = null; sessionId = ""
        listOfNotNull(pointer, input, host).forEach { it.unregisterObserver(); it.close(); it.dispose() }
        clipboard.close(); clipboardInput.clear(); mutable.value = mutable.value.copy(clipboardBusy = false)
        pointer = null; input = null; host = null
        peer?.close(); peer?.dispose(); peer = null; peerConnected = false; factory?.dispose(); factory = null
        if (old != null) closing = scope.launch(Dispatchers.IO) {
            try { if (id.isNotBlank()) old.rpc.withDeadlineAfter(3, TimeUnit.SECONDS).closeRemoteDesktop(RemoteDesktopRef.newBuilder().setSessionId(id).build()) }
            catch (_: Exception) {} finally { old.close() }
        }
        binding = null; request = null; answer = null; remoteApplied = false
        localCandidates.clear(); remoteCandidates.clear(); presentedGeneration = 0; lastPresentedTimestamp = null
        pointerSequence = 0; stateSequence = 0; ordinal = 0; lastPointerOrdinal = 0; framesPresented.set(0); totalRenderMs = 0.0
        decoderStatus = null
        renderMeasurement = RemoteDesktopRenderMeasurement.REMOTE_DESKTOP_RENDER_MEASUREMENT_UNSPECIFIED
        canvasModel.reset(); canvasModel.cursor(.5f, .5f)
        mutable.value = mutable.value.copy(control = false, canTransferControl = false, controlTransferPending = false, controlError = "")
        disconnecting = false
    }
    private fun connectionFailure(error: Exception) {
        if (ScreenRecovery.retryable(error)) recover(error.message ?: "Screen connection lost")
        else fail(error.message ?: "Screen connection failed")
    }
    fun resumeConnection() {
        focus(true)
        if (reopen != null) recover("Resuming connection", immediate = true)
    }

    private fun recover(message: String, immediate: Boolean = false) {
        if (closed || reopen == null) return
        val delayMillis = if (immediate) 0L else recovery.nextDelay(SystemClock.elapsedRealtime())
        recovering?.cancel()
        stopSession()
        val current = token
        mutable.value = ScreenState(phase = "reconnecting")
        recovering = scope.launch {
            delay(delayMillis)
            if (current == token && !closed) startConnection()
        }
    }
    private fun fail(message: String) { disconnect(); mutable.value = mutable.value.copy(phase = "failed", error = message) }
    override fun close() {
        if (closed) return
        closed = true; videoSink = null; decodedOutputObserver = null; disconnect(); egl.release()
        scope.launch { delay(3500); scope.cancel() }
    }

    companion object {
        private var initialized = false
        @Synchronized private fun initialize(context: Context) {
            if (!initialized) {
                PeerConnectionFactory.initialize(PeerConnectionFactory.InitializationOptions.builder(context).createInitializationOptions())
                initialized = true
            }
        }
        private fun normalize(value: Float) = (value.coerceIn(0f, 1f) * 1_000_000).roundToInt()
        private suspend fun createOffer(peer: PeerConnection): SessionDescription = suspendCancellableCoroutine { continuation ->
            peer.createOffer(object : SdpObserver {
                override fun onCreateSuccess(value: SessionDescription) { if (continuation.isActive) continuation.resume(value) }
                override fun onCreateFailure(message: String) { if (continuation.isActive) continuation.resumeWithException(IllegalStateException(message)) }
                override fun onSetSuccess() = Unit
                override fun onSetFailure(message: String) = Unit
            }, MediaConstraints())
        }
        private suspend fun setDescription(peer: PeerConnection, value: SessionDescription, local: Boolean): Unit = suspendCancellableCoroutine { continuation ->
            val observer = object : SdpObserver {
                override fun onSetSuccess() { if (continuation.isActive) continuation.resume(Unit) }
                override fun onSetFailure(message: String) { if (continuation.isActive) continuation.resumeWithException(IllegalStateException(message)) }
                override fun onCreateSuccess(value: SessionDescription) = Unit
                override fun onCreateFailure(message: String) = Unit
            }
            if (local) peer.setLocalDescription(observer, value) else peer.setRemoteDescription(observer, value)
        }
    }
}

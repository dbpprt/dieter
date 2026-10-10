package com.dbpprt.dieter.screens

import android.content.Context
import android.os.SystemClock
import com.dbpprt.dieter.BuildConfig
import com.dbpprt.dieter.api.v1.RemoteDesktopICECandidate
import com.dbpprt.dieter.api.v1.RemoteDesktopReceiverFeedback
import com.dbpprt.dieter.api.v1.RemoteDesktopRenderMeasurement
import com.dbpprt.dieter.core.screens.DecoderReport
import com.dbpprt.dieter.core.screens.PeerState
import com.dbpprt.dieter.core.screens.ReceiverSample
import com.dbpprt.dieter.core.screens.ReceiverStatistics
import com.dbpprt.dieter.core.screens.RtpCodec
import com.dbpprt.dieter.core.screens.ScreenCodecs
import com.dbpprt.dieter.core.screens.ScreenFrameGate
import com.dbpprt.dieter.core.screens.ScreenMediaCapabilities
import com.dbpprt.dieter.core.screens.ScreenMediaConfig
import com.dbpprt.dieter.core.screens.ScreenMediaEngine
import com.dbpprt.dieter.core.screens.ScreenMediaEngineFactory
import com.dbpprt.dieter.core.screens.ScreenMediaEvents
import java.nio.ByteBuffer
import java.util.concurrent.atomic.AtomicLong
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.suspendCancellableCoroutine
import org.webrtc.DataChannel
import org.webrtc.DecoderSurface
import org.webrtc.EglBase
import org.webrtc.IceCandidate
import org.webrtc.MediaConstraints
import org.webrtc.MediaStream
import org.webrtc.MediaStreamTrack
import org.webrtc.PeerConnection
import org.webrtc.PeerConnectionFactory
import org.webrtc.RTCStatsReport
import org.webrtc.RtpTransceiver
import org.webrtc.SdpObserver
import org.webrtc.SessionDescription
import org.webrtc.VideoFrame

/** What the Screens footer shows about the media path. */
data class ScreenMediaStats(val fps: Double = 0.0, val decodedFrames: Long = 0)

/**
 * The Android WebRTC stack for screen sharing: one peer connection per attempt, MediaCodec decoders
 * into a shared EGL context, data channels, and receiver statistics. The shared core's
 * ScreenSession drives it and owns signaling, trust, recovery, input, and clipboard sync. The
 * renderer ([ScreenCanvasView]) attaches through [videoSink] and reports presentation.
 */
class AndroidScreenMedia(context: Context) : ScreenMediaEngineFactory, AutoCloseable {
    // Keep fixture-only until a physical codec advertising this feature has
    // passed latency and lifecycle qualification (acceptance is insufficient).
    var lowLatencyDecoding = false
    // Fixture-only A/B until physical cadence/composition qualification. Both
    // paths retain the real WebRTC decoded-frame and reference contract.
    var surfacePresentation = false
    var directSurfacePresentation = false
    val egl: EglBase = EglBase.create()
    @Volatile var videoSink: ((VideoFrame, Long) -> Unit)? = null
    @Volatile var decodedOutputObserver: ((Long) -> Unit)? = null
    /** The video restarted (new display or session); called on any thread. */
    @Volatile var onVideoReset: (() -> Unit)? = null
    /** A replaced decoder surface needs a new decoder, so the session must reconnect. */
    @Volatile var onDecoderSurfaceReplaced: (() -> Unit)? = null
    @Volatile internal var decoderSurface: DecoderSurface? = null
    @Volatile
    var decoderStatus: ScreenDecoderStatus? = null
        private set

    private val decoderTargetLock = Any()
    @Volatile private var active: Engine? = null
    private val mutableStats = MutableStateFlow(ScreenMediaStats())
    val stats: StateFlow<ScreenMediaStats> = mutableStats.asStateFlow()
    private val sentCounts = java.util.concurrent.ConcurrentHashMap<String, AtomicLong>()

    /**
     * Messages delivered on data channel [label] since this factory was created (diagnostics and
     * tests).
     */
    fun sentMessages(label: String): Long = sentCounts[label]?.get() ?: 0

    init {
        initialize(context.applicationContext)
    }

    override val capabilities: ScreenMediaCapabilities by lazy(::probe)

    private fun probe(): ScreenMediaCapabilities {
        val decoders = ScreenDecoderFactory(egl.eglBaseContext, enableHEVC = true) {}
        val supported = decoders.supportedCodecs
        if (supported.none { it.name.equals("H264", true) }) {
            return ScreenMediaCapabilities(
                emptyList(),
                false,
                false,
                true,
                "This device has no H.264 MediaCodec decoder",
            )
        }
        val factory =
            PeerConnectionFactory.builder()
                .setFieldTrials(FIELD_TRIALS)
                .setVideoDecoderFactory(decoders)
                .createPeerConnectionFactory()
        try {
            val codecs =
                factory
                    .getRtpReceiverCapabilities(MediaStreamTrack.MediaType.MEDIA_TYPE_VIDEO)
                    .codecs
                    .map { RtpCodec(it.name, it.parameters["profile-level-id"]) }
            return ScreenMediaCapabilities(
                receiveCodecs = codecs,
                hevcDecoder = supported.any { it.name.equals("H265", true) },
                referenceDependencies = true,
                millisecondTimestamps = true,
            )
        } finally {
            factory.dispose()
        }
    }

    override fun create(config: ScreenMediaConfig, events: ScreenMediaEvents): ScreenMediaEngine =
        Engine(config, events).also { active = it }

    /** Whether a frame of [token] still belongs to the current, open peer. */
    fun acceptsFrame(token: Long): Boolean = active?.let { !it.closed && it.token == token } == true

    /** A presentation endpoint is explicit; EGL swap and MediaCodec callback differ. */
    fun presented(
        timestampNs: Long,
        token: Long,
        renderMs: Double,
        measurement: RemoteDesktopRenderMeasurement =
            RemoteDesktopRenderMeasurement.REMOTE_DESKTOP_RENDER_MEASUREMENT_EGL_SUBMITTED,
    ) {
        val engine = active?.takeIf { !it.closed && it.token == token } ?: return
        engine.presented(timestampNs, renderMs, measurement)
    }

    /** Reports HEVC decoder failure as the native decoder does (fixture tests inject it). */
    internal fun reportHevcUnavailable() {
        active?.takeIf { !it.closed }?.hevcUnavailable()
    }

    internal fun attachDecoderSurface(surface: DecoderSurface) {
        val (previous, replaced) =
            synchronized(decoderTargetLock) {
                val previous = decoderSurface
                decoderSurface = surface
                previous to (active?.needsDecoderSurface(surface) == true)
            }
        if (previous !== surface) previous?.close()
        // A holder can arrive while the next peer is still selecting its
        // decoder. Only replace an already selected target; restarting an
        // unfinished attempt can leave an unobserved host control grant.
        if (replaced) onDecoderSurfaceReplaced?.invoke()
    }

    internal fun detachDecoderSurface(surface: DecoderSurface) {
        if (decoderSurface === surface) decoderSurface = null
        surface.close()
    }

    override fun close() {
        videoSink = null
        decodedOutputObserver = null
        onVideoReset = null
        onDecoderSurfaceReplaced = null
        active?.close()
        active = null
        egl.release()
    }

    /**
     * One attempt's peer connection. Core calls arrive on its dispatcher; WebRTC calls back on its
     * own threads.
     */
    inner class Engine(
        private val config: ScreenMediaConfig,
        private val events: ScreenMediaEvents,
    ) : ScreenMediaEngine {
        val token = tokens.incrementAndGet()
        @Volatile
        var closed = false
            private set

        private val framesPresented = AtomicLong()
        private val renderLock = Any()
        private var totalRenderMs = 0.0
        private var renderMeasurement =
            RemoteDesktopRenderMeasurement.REMOTE_DESKTOP_RENDER_MEASUREMENT_UNSPECIFIED
        private val statistics = ReceiverStatistics()
        private val frames =
            ScreenFrameGate<VideoFrame>(
                { ScreenFrameGate.rtp(it.timestampNs) },
                { it.retain() },
                { it.release() },
            ) { frame, epoch ->
                if (!closed && epoch == token) videoSink?.invoke(frame, epoch)
            }
        private val factory: PeerConnectionFactory
        private val peer: PeerConnection
        private val channels = LinkedHashMap<String, DataChannel>()
        private var decoderTargetSelected = false
        private var selectedDecoderSurface: DecoderSurface? = null

        internal fun needsDecoderSurface(surface: DecoderSurface): Boolean =
            !closed &&
                directSurfacePresentation &&
                decoderTargetSelected &&
                selectedDecoderSurface !== surface

        init {
            decoderStatus = null
            val hevc = config.codecs.any { it.name.equals(ScreenCodecs.H265, true) }
            val decoders =
                ScreenDecoderFactory(
                    egl.eglBaseContext,
                    enableHEVC = hevc,
                    lowLatency = lowLatencyDecoding,
                    directSurface = {
                        synchronized(decoderTargetLock) {
                            (if (directSurfacePresentation) decoderSurface?.takeIf { it.isOpen }
                                else null)
                                .also {
                                    selectedDecoderSurface = it
                                    decoderTargetSelected = true
                                }
                        }
                    },
                    outputDecoded = { timestamp ->
                        if (!closed) {
                            events.decoded(rtp(timestamp))
                            decodedOutputObserver?.invoke(timestamp)
                        }
                    },
                    configured = { status -> if (!closed) decoderStatus = status },
                    unavailable = { if (!closed) hevcUnavailable() },
                ) { frame ->
                    if (!closed) frames.offer(frame, token)
                }
            factory =
                PeerConnectionFactory.builder()
                    .setFieldTrials(if (config.enableReferenceDependencies) FIELD_TRIALS else "")
                    .setVideoDecoderFactory(decoders)
                    .createPeerConnectionFactory()
            val rtc =
                PeerConnection.RTCConfiguration(
                        config.rtc.ice_servers.map {
                            PeerConnection.IceServer.builder(it.urls)
                                .setUsername(it.username)
                                .setPassword(it.credential)
                                .createIceServer()
                        }
                    )
                    .apply {
                        sdpSemantics = PeerConnection.SdpSemantics.UNIFIED_PLAN
                        if (
                            config.relayOnly ||
                                (BuildConfig.DEBUG &&
                                    java.lang.Boolean.getBoolean("dieter.test.forceTURN"))
                        ) {
                            iceTransportsType = PeerConnection.IceTransportsType.RELAY
                        }
                        continualGatheringPolicy =
                            PeerConnection.ContinualGatheringPolicy.GATHER_CONTINUALLY
                    }
            peer =
                requireNotNull(factory.createPeerConnection(rtc, observer())) {
                    "The video connection could not be created"
                }
            for (spec in config.channels) {
                val channel =
                    peer.createDataChannel(
                        spec.label,
                        DataChannel.Init().apply {
                            ordered = spec.ordered
                            spec.maxRetransmits?.let { maxRetransmits = it }
                        },
                    )
                channel.registerObserver(channelObserver(spec.label, channel))
                channels[spec.label] = channel
            }
            val video =
                peer.addTransceiver(
                    MediaStreamTrack.MediaType.MEDIA_TYPE_VIDEO,
                    RtpTransceiver.RtpTransceiverInit(
                        RtpTransceiver.RtpTransceiverDirection.RECV_ONLY
                    ),
                )
            // The core chose and ordered the codecs; map them onto this factory's capabilities.
            val available =
                factory
                    .getRtpReceiverCapabilities(MediaStreamTrack.MediaType.MEDIA_TYPE_VIDEO)
                    .codecs
            val chosen =
                available
                    .mapNotNull { capability ->
                        val rank =
                            config.codecs.indexOfFirst { codec ->
                                codec.name.equals(capability.name, true) &&
                                    (codec.profile == null ||
                                        codec.profile == capability.parameters["profile-level-id"])
                            }
                        if (rank < 0) null else rank to capability
                    }
                    .sortedBy { it.first }
                    .map { it.second }
            require(chosen.isNotEmpty()) { ScreenCodecs.UNAVAILABLE }
            video.setCodecPreferences(chosen)
        }

        override suspend fun createOffer(): String {
            val offer = suspendCancellableCoroutine { continuation ->
                peer.createOffer(
                    object : SdpObserver {
                        override fun onCreateSuccess(value: SessionDescription) {
                            if (continuation.isActive) continuation.resume(value)
                        }

                        override fun onCreateFailure(message: String) {
                            if (continuation.isActive)
                                continuation.resumeWithException(IllegalStateException(message))
                        }

                        override fun onSetSuccess() = Unit

                        override fun onSetFailure(message: String) = Unit
                    },
                    MediaConstraints(),
                )
            }
            setDescription(offer, local = true)
            return offer.description
        }

        override suspend fun applyAnswer(sdp: String) =
            setDescription(SessionDescription(SessionDescription.Type.ANSWER, sdp), local = false)

        override suspend fun addRemoteCandidate(candidate: RemoteDesktopICECandidate) {
            check(
                peer.addIceCandidate(
                    IceCandidate(candidate.sdp_mid, candidate.sdp_mline_index, candidate.candidate)
                )
            ) {
                "Invalid ICE candidate"
            }
        }

        private suspend fun setDescription(value: SessionDescription, local: Boolean): Unit =
            suspendCancellableCoroutine { continuation ->
                val observer =
                    object : SdpObserver {
                        override fun onSetSuccess() {
                            if (continuation.isActive) continuation.resume(Unit)
                        }

                        override fun onSetFailure(message: String) {
                            if (continuation.isActive)
                                continuation.resumeWithException(IllegalStateException(message))
                        }

                        override fun onCreateSuccess(value: SessionDescription) = Unit

                        override fun onCreateFailure(message: String) = Unit
                    }
                if (local) peer.setLocalDescription(observer, value)
                else peer.setRemoteDescription(observer, value)
            }

        override fun send(label: String, bytes: ByteArray): Boolean {
            val channel =
                channels[label]?.takeIf { !closed && it.state() == DataChannel.State.OPEN }
                    ?: return false
            val sent = channel.send(DataChannel.Buffer(ByteBuffer.wrap(bytes), true))
            if (sent) sentCounts.getOrPut(label, ::AtomicLong).incrementAndGet()
            return sent
        }

        override fun isOpen(label: String): Boolean =
            !closed && channels[label]?.state() == DataChannel.State.OPEN

        override fun bufferedAmount(label: String): Long = channels[label]?.bufferedAmount() ?: 0

        fun presented(
            timestampNs: Long,
            renderMs: Double,
            measurement: RemoteDesktopRenderMeasurement,
        ) {
            synchronized(renderLock) {
                if (measurement != renderMeasurement) {
                    framesPresented.set(0)
                    totalRenderMs = 0.0
                    renderMeasurement = measurement
                }
                totalRenderMs += renderMs
            }
            framesPresented.incrementAndGet()
            events.presented(rtp(timestampNs))
        }

        override suspend fun statistics(): RemoteDesktopReceiverFeedback? {
            if (closed) return null
            val stats =
                suspendCancellableCoroutine<RTCStatsReport> { continuation ->
                    peer.getStats { if (continuation.isActive) continuation.resume(it) }
                }
            val incoming =
                stats.statsMap.values
                    .firstOrNull { it.type == "inbound-rtp" && it.members["kind"] == "video" }
                    ?.members
                    .orEmpty()
            val pair =
                stats.statsMap.values
                    .firstOrNull {
                        it.type == "candidate-pair" &&
                            it.members["state"] == "succeeded" &&
                            it.members["nominated"] == true
                    }
                    ?.members
                    .orEmpty()
            fun number(key: String) = (incoming[key] as? Number)?.toDouble() ?: 0.0
            val (renderTotal, measurement) =
                synchronized(renderLock) { totalRenderMs to renderMeasurement }
            val sample =
                ReceiverSample(
                    atMillis = SystemClock.elapsedRealtime(),
                    framesDecoded = number("framesDecoded"),
                    totalDecodeTime = number("totalDecodeTime"),
                    jitterBufferEmittedCount = number("jitterBufferEmittedCount"),
                    jitterBufferDelay = number("jitterBufferDelay"),
                    packetsLost = number("packetsLost"),
                    packetsReceived = number("packetsReceived"),
                    presented = framesPresented.get(),
                    renderMs = renderTotal,
                    jitterSeconds = number("jitter"),
                    roundTripSeconds = (pair["currentRoundTripTime"] as? Number)?.toDouble() ?: 0.0,
                    measurement = measurement,
                )
            val (feedback, fps) =
                statistics.next(
                    sample,
                    decoderStatus?.let {
                        DecoderReport(
                            it.implementation,
                            it.hardware,
                            it.lowLatencyAccepted,
                            it.reason,
                        )
                    },
                )
            val relayed =
                listOf("localCandidateId", "remoteCandidateId").any { key ->
                    stats.statsMap[pair[key]]?.members?.get("candidateType") == "relay"
                }
            if (!closed) {
                mutableStats.value = ScreenMediaStats(fps, sample.framesDecoded.toLong())
                if (pair.isNotEmpty()) events.mediaPath(relayed)
            }
            if (statistics.presentationMissing(sample) && decoderSurface?.isOpen == true) {
                // Older/vendor codecs may omit frame-render callbacks. Retire this
                // optional target once; the next decoder uses textures until a
                // genuinely new holder is attached.
                decoderSurface?.close()
                events.peerState(PeerState.CLOSED)
            }
            return feedback
        }

        override fun updateFrameGate(
            token: Long,
            displayGeneration: Long,
            mediaGeneration: Long,
            mediaTimestamp: UInt,
        ) {
            // One engine serves one attempt, so its own token scopes the gate.
            frames.update(
                this.token,
                displayGeneration,
                mediaGeneration,
                mediaTimestamp.toInt().toUInt(),
            )
        }

        fun hevcUnavailable() = events.hevcUnavailable("HEVC decoder unavailable")

        override fun resetVideo() {
            onVideoReset?.invoke()
        }

        override fun close() {
            if (closed) return
            closed = true
            frames.clear()
            channels.values.forEach {
                it.unregisterObserver()
                it.close()
                it.dispose()
            }
            channels.clear()
            peer.close()
            peer.dispose()
            factory.dispose()
            decoderStatus = null
            mutableStats.value = ScreenMediaStats()
            if (active === this) onVideoReset?.invoke()
        }

        private fun observer() =
            object : PeerConnection.Observer {
                override fun onIceCandidate(candidate: IceCandidate) {
                    if (!closed)
                        events.localCandidate(
                            RemoteDesktopICECandidate(
                                candidate = candidate.sdp,
                                sdp_mid = candidate.sdpMid.orEmpty(),
                                sdp_mline_index = candidate.sdpMLineIndex,
                            )
                        )
                }

                override fun onConnectionChange(value: PeerConnection.PeerConnectionState) {
                    if (closed) return
                    events.peerState(
                        when (value) {
                            PeerConnection.PeerConnectionState.NEW -> PeerState.NEW
                            PeerConnection.PeerConnectionState.CONNECTING -> PeerState.CONNECTING
                            PeerConnection.PeerConnectionState.CONNECTED -> PeerState.CONNECTED
                            PeerConnection.PeerConnectionState.DISCONNECTED ->
                                PeerState.DISCONNECTED
                            PeerConnection.PeerConnectionState.FAILED -> PeerState.FAILED
                            PeerConnection.PeerConnectionState.CLOSED -> PeerState.CLOSED
                        }
                    )
                }

                override fun onSignalingChange(state: PeerConnection.SignalingState) = Unit

                override fun onIceConnectionChange(state: PeerConnection.IceConnectionState) = Unit

                override fun onIceConnectionReceivingChange(receiving: Boolean) = Unit

                override fun onIceGatheringChange(state: PeerConnection.IceGatheringState) = Unit

                override fun onIceCandidatesRemoved(candidates: Array<out IceCandidate>) = Unit

                override fun onAddStream(stream: MediaStream) = Unit

                override fun onRemoveStream(stream: MediaStream) = Unit

                override fun onDataChannel(channel: DataChannel) {
                    channel.close()
                }

                override fun onRenegotiationNeeded() = Unit
            }

        private fun channelObserver(label: String, channel: DataChannel) =
            object : DataChannel.Observer {
                override fun onBufferedAmountChange(previousAmount: Long) = Unit

                override fun onStateChange() {
                    if (closed) return
                    when (channel.state()) {
                        DataChannel.State.OPEN -> events.channelState(label, true)
                        DataChannel.State.CLOSED -> events.channelState(label, false)
                        else -> Unit
                    }
                }

                override fun onMessage(buffer: DataChannel.Buffer) {
                    if (closed || !buffer.binary || buffer.data.remaining() > MAX_MESSAGE_BYTES)
                        return
                    val bytes = ByteArray(buffer.data.remaining()).also(buffer.data::get)
                    events.channelMessage(label, bytes)
                }
            }
    }

    companion object {
        private const val FIELD_TRIALS = "WebRTC-GenericDescriptorAdvertised/Enabled/"
        private const val MAX_MESSAGE_BYTES = 1 shl 20
        private val tokens = AtomicLong()
        private var initialized = false

        @Synchronized
        private fun initialize(context: Context) {
            if (!initialized) {
                PeerConnectionFactory.initialize(
                    PeerConnectionFactory.InitializationOptions.builder(context)
                        .createInitializationOptions()
                )
                initialized = true
            }
        }

        /** The Android decoder API carries RTP time as floor(timestamp / 90) milliseconds. */
        internal fun rtp(timestampNs: Long): UInt =
            ((timestampNs / 1_000_000L * 90L) and 0xffff_ffffL).toUInt()
    }
}

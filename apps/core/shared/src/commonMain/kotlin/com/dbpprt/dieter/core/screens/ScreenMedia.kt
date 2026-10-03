package com.dbpprt.dieter.core.screens

import com.dbpprt.dieter.api.gateway.v1.RTCConfiguration
import com.dbpprt.dieter.api.v1.DieterServiceClient
import com.dbpprt.dieter.api.v1.RemoteDesktopClipboardItem
import com.dbpprt.dieter.api.v1.RemoteDesktopICECandidate
import com.dbpprt.dieter.api.v1.RemoteDesktopReceiverFeedback

/** An RTP codec the native stack can receive; [profile] is its `profile-level-id` when known. */
data class RtpCodec(val name: String, val profile: String? = null)

data class ScreenMediaCapabilities(
    val receiveCodecs: List<RtpCodec>,
    /** A hardware HEVC Main decoder is available. */
    val hevcDecoder: Boolean,
    /** Generic frame descriptors can be negotiated, enabling reference recovery. */
    val referenceDependencies: Boolean,
    /** Decoder timestamps are millisecond-quantized (Android) rather than exact 90 kHz. */
    val millisecondTimestamps: Boolean,
    /** A renderer or decoder that cannot start at all; the session fails before offering. */
    val initializationFailure: String? = null,
)

data class ScreenChannelSpec(val label: String, val ordered: Boolean, val maxRetransmits: Int? = null)

data class ScreenMediaConfig(
    val rtc: RTCConfiguration,
    val codecs: List<RtpCodec>,
    val enableReferenceDependencies: Boolean,
    val channels: List<ScreenChannelSpec>,
    /** Test switch: relay candidates only. */
    val relayOnly: Boolean = false,
)

enum class PeerState { NEW, CONNECTING, CONNECTED, DISCONNECTED, FAILED, CLOSED }

/** Events from the native media stack; they may arrive on any thread. */
interface ScreenMediaEvents {
    fun localCandidate(candidate: RemoteDesktopICECandidate)
    fun peerState(state: PeerState)
    fun channelState(label: String, open: Boolean)
    fun channelMessage(label: String, bytes: ByteArray)
    fun decoded(rtpTimestamp: UInt)
    fun presented(rtpTimestamp: UInt)

    /** The selected candidate pair runs through a TURN relay ([relayed]) or directly. */
    fun mediaPath(relayed: Boolean)
    fun hevcUnavailable(reason: String)
    fun failure(message: String)
}

/**
 * The native peer connection, tracks, decoders, and renderer
 * (`ScreenMediaEngine` on Android and Apple). The core drives it and owns
 * every policy decision.
 */
interface ScreenMediaEngine {
    /** Creates and applies the local offer; returns its SDP. */
    suspend fun createOffer(): String
    suspend fun applyAnswer(sdp: String)
    suspend fun addRemoteCandidate(candidate: RemoteDesktopICECandidate)

    /** Thread-safe; false when the channel is not open or the send failed. */
    fun send(label: String, bytes: ByteArray): Boolean
    fun isOpen(label: String): Boolean
    fun bufferedAmount(label: String): Long

    /** A receiver measurement from the transport's statistics, or null before media flows. */
    suspend fun statistics(): RemoteDesktopReceiverFeedback?
    fun updateFrameGate(token: Long, displayGeneration: Long, mediaGeneration: Long, mediaTimestamp: UInt)
    fun resetVideo()
    fun close()
}

interface ScreenMediaEngineFactory {
    val capabilities: ScreenMediaCapabilities
    fun create(config: ScreenMediaConfig, events: ScreenMediaEvents): ScreenMediaEngine
}

/** The authenticated signaling route to the screen's machine, with its trust anchor. */
class ScreenRoute(
    val client: DieterServiceClient,
    val certificatePem: String,
    val rtc: RTCConfiguration,
    val label: String,
    private val onFailure: (Throwable) -> Unit = {},
    private val onClose: () -> Unit = {},
) {
    /** Signaling over this route failed; a shared transport may need selecting again. */
    fun failed(error: Throwable) = onFailure(error)

    fun close() = onClose()
}

typealias ScreenRouteFactory = suspend () -> ScreenRoute

/** The native pasteboard, as the clipboard sync needs it. */
interface LocalClipboard {
    /** Changes whenever the local clipboard changes. */
    fun stamp(): Long

    /** Text or files currently on the clipboard; binary items only when [binary]. */
    fun read(binary: Boolean): Pair<String, List<RemoteDesktopClipboardItem>>?
    fun apply(text: String, items: List<RemoteDesktopClipboardItem>)
}

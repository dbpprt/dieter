package com.dbpprt.dieter.core.screens

import com.dbpprt.dieter.api.gateway.v1.RTCConfiguration
import com.dbpprt.dieter.api.v1.RemoteDesktopCapabilities
import com.dbpprt.dieter.api.v1.RemoteDesktopCodecPreference
import com.dbpprt.dieter.api.v1.RemoteDesktopDisplayMode
import com.dbpprt.dieter.api.v1.RemoteDesktopQuality
import com.dbpprt.dieter.api.v1.RemoteDesktopSessionDescription
import com.dbpprt.dieter.api.v1.RemoteDesktopSessionState
import com.dbpprt.dieter.api.v1.StartRemoteDesktopRequest
import com.squareup.wire.GrpcException
import com.squareup.wire.GrpcStatus
import kotlin.math.abs
import kotlin.math.floor
import kotlin.math.ln
import kotlin.math.roundToInt
import kotlin.time.Duration
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.seconds
import kotlin.time.Instant

/** Retry timing for a screen session: 250 ms doubling to 5 s, reset after 10 s of stable streaming, no cap. */
class ScreenRecovery {
    private var attempts = 0
    private var streamingSince: Instant? = null

    fun streaming(now: Instant) {
        if (streamingSince == null) streamingSince = now
    }

    fun interrupted(now: Instant) {
        val since = streamingSince
        if (since != null && now - since >= STABLE) attempts = 0
        streamingSince = null
    }

    fun nextDelay(now: Instant): Duration {
        interrupted(now)
        val delay = minOf(5_000L, 250L shl attempts)
        attempts = minOf(attempts + 1, 5)
        return delay.milliseconds
    }

    companion object {
        val STABLE = 10.seconds
    }
}

object ScreenFailures {
    private val retryableCodes = setOf(
        GrpcStatus.NOT_FOUND, GrpcStatus.UNAVAILABLE, GrpcStatus.DEADLINE_EXCEEDED, GrpcStatus.RESOURCE_EXHAUSTED,
        GrpcStatus.ABORTED, GrpcStatus.UNAUTHENTICATED,
    )

    /** Closure reasons after which a new session can succeed. */
    val RETRYABLE_CLOSURES = setOf(
        "session lease expired", "signaling observer did not reconnect", "WebRTC peer did not reconnect", "peer connection failed",
        "peer connection closed", "daemon shutdown", "remote desktop data channel closed", "remote desktop input channel failed",
        "remote input queue overflow", "remote input delivery failed", "native capture rendition stopped", "native daemon heartbeat expired",
        "native capture helper unresponsive", "native capture helper stopped",
    )

    const val HEVC_UNAVAILABLE = "HEVC encoder unavailable"

    fun retryable(error: Throwable): Boolean = when (error) {
        is ScreenTrustException -> false
        is GrpcException -> error.grpcStatus in retryableCodes
        else -> com.dbpprt.dieter.core.runtime.Failures.isRetryableRead(error)
    }

    fun retryableClosure(reason: String): Boolean = reason in RETRYABLE_CLOSURES

    /** Daemon errors that are safe to retry; `peer_failed` precedes a retryable close. */
    fun retryableError(code: String, message: String, recoverable: Boolean): Boolean =
        recoverable || code == "peer_failed" || (code == "capture_failed" && message in RETRYABLE_CLOSURES)
}

/** What the host offers and what this client may ask for. */
object ScreenCapabilities {
    fun shouldRequestControl(caps: RemoteDesktopCapabilities): Boolean =
        caps.control_supported && (caps.control_permission == "granted" || (caps.platform == "linux" && caps.control_permission == "not_requested"))

    fun needsHostApproval(caps: RemoteDesktopCapabilities): Boolean = caps.platform == "linux" && caps.capture_permission == "not_requested"

    /** The cursor is drawn locally while controlling a Linux host, otherwise by the host when it cannot send shapes. */
    fun embedCursor(caps: RemoteDesktopCapabilities, control: Boolean): Boolean =
        if (caps.platform == "linux" && control) false else !caps.cursor_supported

    fun controlUnavailableReason(caps: RemoteDesktopCapabilities): String = when {
        shouldRequestControl(caps) -> ""
        caps.platform == "linux" -> "Remote-control permission is required from the Linux desktop portal"
        else -> "Accessibility permission is required on the host"
    }

    fun frameRates(caps: RemoteDesktopCapabilities, ceiling: Int = 120): List<Int> =
        listOf(30, 60, 90, 120).filter { it <= minOf(ceiling, caps.max_fps.takeIf { fps -> fps > 0 } ?: 60) }

    fun maxFps(preferred: Int, caps: RemoteDesktopCapabilities, ceiling: Int = 120): Int =
        preferred.coerceIn(1, minOf(ceiling, caps.max_fps.takeIf { it > 0 } ?: 60))
}

/** Codec choice: H.264 by default; HEVC only with a hardware decoder, a fitting host mode, and no earlier failure. */
object ScreenCodecs {
    const val H264 = "H264"
    const val H265 = "H265"
    const val FLEXFEC = "flexfec-03"

    fun effective(preference: RemoteDesktopCodecPreference, hevcFailed: Boolean): RemoteDesktopCodecPreference =
        if (hevcFailed && preference == RemoteDesktopCodecPreference.REMOTE_DESKTOP_CODEC_PREFERENCE_AUTO) RemoteDesktopCodecPreference.REMOTE_DESKTOP_CODEC_PREFERENCE_H264 else preference

    fun canHevc(caps: RemoteDesktopCapabilities, width: Int, height: Int, fps: Int, hardwareDecoder: Boolean): Boolean =
        hardwareDecoder && caps.codec_modes.any { it.codec == H265 && it.profile == "main" && it.max_width >= width && it.max_height >= height && it.max_fps >= fps }

    /** Receive codecs to offer, HEVC first, then H.264 High; empty when the selection cannot be met. */
    fun <C> receiveCodecs(available: List<C>, name: (C) -> String, profile: (C) -> String?, effective: RemoteDesktopCodecPreference, canHevc: Boolean): List<C> {
        val allowed = available.filter { codec ->
            when (name(codec).uppercase()) {
                FLEXFEC.uppercase() -> true
                H265 -> effective != RemoteDesktopCodecPreference.REMOTE_DESKTOP_CODEC_PREFERENCE_H264 && canHevc
                H264 -> effective != RemoteDesktopCodecPreference.REMOTE_DESKTOP_CODEC_PREFERENCE_HEVC
                else -> false
            }
        }
        if (allowed.none { name(it).uppercase() == H264 || name(it).uppercase() == H265 }) return emptyList()
        return allowed.sortedBy { codec ->
            when {
                name(codec).uppercase() == H265 -> 0
                name(codec).uppercase() == H264 && profile(codec)?.startsWith("64") == true -> 1
                else -> 2
            }
        }
    }
}

/** The stream size a client asks for, per platform. */
sealed interface ViewportPolicy {
    fun size(widthPoints: Double, heightPoints: Double, scale: Double): Pair<Int, Int>?

    /** macOS: even pixel sizes within 640x360..3840x2160. */
    data object Desktop : ViewportPolicy {
        override fun size(widthPoints: Double, heightPoints: Double, scale: Double): Pair<Int, Int>? {
            if (!(widthPoints > 0 && heightPoints > 0 && scale > 0)) return null
            val width = (floor(widthPoints * scale / 2) * 2).toInt().coerceIn(640, 3840)
            val height = (floor(heightPoints * scale / 2) * 2).toInt().coerceIn(360, 2160)
            return width to height
        }
    }

    /** iOS: a coarse grid within 640x360..1920x1080, so rotation does not thrash the encoder. */
    data object Tablet : ViewportPolicy {
        override fun size(widthPoints: Double, heightPoints: Double, scale: Double): Pair<Int, Int>? {
            if (!(widthPoints > 0 && heightPoints > 0 && scale > 0)) return null
            val width = (kotlin.math.ceil(widthPoints * scale / 160) * 160).toInt().coerceIn(640, 1920)
            val height = (kotlin.math.ceil(heightPoints * scale / 90) * 90).toInt().coerceIn(360, 1080)
            return width to height
        }
    }

    /** Android: a fixed 1080p request. */
    data object Fixed : ViewportPolicy {
        override fun size(widthPoints: Double, heightPoints: Double, scale: Double): Pair<Int, Int> = 1920 to 1080
    }
}

/** Matching the remote display mode to this screen (macOS fullscreen). */
object DisplayMatching {
    data class Target(val width: Double, val height: Double, val scale: Double, val refresh: Double = 0.0)

    fun score(mode: RemoteDesktopDisplayMode, target: Target): Double {
        val w = mode.logical_width.toDouble()
        val h = mode.logical_height.toDouble()
        val pw = mode.pixel_width.toDouble()
        val ph = mode.pixel_height.toDouble()
        val aspect = abs(ln((w / h) / (target.width / target.height)))
        val size = abs(ln(w / target.width)) + abs(ln(h / target.height))
        val pixels = abs(ln(pw / (target.width * target.scale))) + abs(ln(ph / (target.height * target.scale)))
        val refresh = if (mode.refresh_rate > 0 && target.refresh > 0) abs(mode.refresh_rate - target.refresh) / maxOf(target.refresh, 1.0) else 0.0
        return 10 * aspect + 3 * size + pixels + 0.1 * refresh
    }

    fun best(modes: List<RemoteDesktopDisplayMode>, target: Target): RemoteDesktopDisplayMode? =
        modes.filter { it.logical_width > 0 && it.logical_height > 0 && it.pixel_width > 0 && it.pixel_height > 0 }
            .minWithOrNull(compareBy<RemoteDesktopDisplayMode>({ score(it, target) }, { it.id }))

    fun exact(mode: RemoteDesktopDisplayMode, target: Target): Boolean =
        mode.logical_width.toDouble() == target.width && mode.logical_height.toDouble() == target.height &&
            mode.pixel_width == (target.width * target.scale).roundToInt() && mode.pixel_height == (target.height * target.scale).roundToInt()
}

/** The desired stream configuration that survives recovery. */
data class ScreenPreferences(
    val codec: RemoteDesktopCodecPreference = RemoteDesktopCodecPreference.REMOTE_DESKTOP_CODEC_PREFERENCE_H264,
    val maxFps: Int = 60,
    val quality: RemoteDesktopQuality = RemoteDesktopQuality.REMOTE_DESKTOP_QUALITY_AUTO,
    val displayId: String? = null,
    val clipboard: Boolean = true,
    val width: Int = 1920,
    val height: Int = 1080,
)

object ScreenRequests {
    const val MAX_BITRATE_KBPS = 12_000

    fun start(
        nonce: String,
        rtc: RTCConfiguration,
        offerSdp: String,
        caps: RemoteDesktopCapabilities,
        preferences: ScreenPreferences,
        effectiveCodec: RemoteDesktopCodecPreference,
        clientName: String,
        referenceRecovery: Boolean,
        fpsCeiling: Int = 120,
    ): StartRemoteDesktopRequest {
        val control = ScreenCapabilities.shouldRequestControl(caps)
        return StartRemoteDesktopRequest(
            client_nonce = nonce, rtc_configuration = rtc, offer = RemoteDesktopSessionDescription(type = "offer", sdp = offerSdp),
            display_id = preferences.displayId ?: "primary", control = control,
            max_width = preferences.width, max_height = preferences.height,
            max_fps = ScreenCapabilities.maxFps(preferences.maxFps, caps, fpsCeiling), max_bitrate_kbps = MAX_BITRATE_KBPS,
            quality = preferences.quality, embedded_cursor = ScreenCapabilities.embedCursor(caps, control),
            input_protocol_version = SCREEN_INPUT_PROTOCOL, client_name = clientName.take(64),
            clipboard = caps.clipboard_supported && preferences.clipboard, codec_preference = effectiveCodec,
            reference_recovery = referenceRecovery,
        )
    }
}

/** Monotonic merge of session states that arrive from signaling, RPC replies, and the host channel. */
object ScreenStates {
    data class Merge(val state: RemoteDesktopSessionState, val displayChanged: Boolean, val clipboardChanged: Boolean)

    fun merge(previous: RemoteDesktopSessionState?, incoming: RemoteDesktopSessionState): Merge? {
        if (previous == null) return Merge(incoming, displayChanged = false, clipboardChanged = false)
        if (incoming.display_generation.toULong() < previous.display_generation.toULong()) return null
        val displayChanged = incoming.display_generation != previous.display_generation
        var next = incoming
        if (!displayChanged && incoming.media_generation.toULong() < previous.media_generation.toULong()) {
            next = next.copy(media_generation = previous.media_generation, media_timestamp = previous.media_timestamp)
        }
        if (incoming.control_generation.toULong() < previous.control_generation.toULong()) {
            next = next.copy(control_generation = previous.control_generation, control_active = previous.control_active, controller_name = previous.controller_name)
        }
        var clipboardChanged = false
        if (incoming.clipboard_generation.toULong() < previous.clipboard_generation.toULong()) {
            next = next.copy(clipboard_generation = previous.clipboard_generation, clipboard_enabled = previous.clipboard_enabled)
        } else if (incoming.clipboard_generation.toULong() > previous.clipboard_generation.toULong()) {
            clipboardChanged = true
        }
        return Merge(next, displayChanged, clipboardChanged)
    }

    /** Whether a presented frame belongs to the current media generation, wrap-safe in the 90 kHz clock. */
    fun belongsToGeneration(timestamp: UInt, boundary: UInt, millisecondQuantized: Boolean): Boolean =
        if (millisecondQuantized) {
            val quantizedBoundary = (boundary / 90u) * 90u
            (timestamp - quantizedBoundary) < 0x8000_0000u
        } else {
            (timestamp - boundary).toInt() >= 0
        }
}

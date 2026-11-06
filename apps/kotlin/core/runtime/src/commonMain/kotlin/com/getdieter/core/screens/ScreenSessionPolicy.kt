package com.getdieter.core.screens

import com.getdieter.api.v1.RemoteDesktopAvailability
import com.getdieter.api.v1.RemoteDesktopCapabilities
import com.getdieter.api.v1.RemoteDesktopCodecPreference
import com.getdieter.api.v1.RemoteDesktopSessionBinding
import com.getdieter.api.v1.RemoteDesktopSessionState
import com.getdieter.api.v1.RemoteDesktopStreamConfiguration
import com.getdieter.api.v1.RemoteDesktopVirtualDisplay
import com.getdieter.api.v1.SetRemoteDesktopVirtualDisplayRequest
import kotlin.time.Duration
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.seconds

/**
 * The decisions a [ScreenSession] makes along the way, without its state: timing, what a host's
 * capabilities allow, which codecs to offer, the stream it asks for, when it streams with control,
 * and whether a failure recovers or ends the session.
 */
internal object ScreenSessionPolicy {
    const val GENERIC_FRAME_DESCRIPTOR =
        "http://www.webrtc.org/experiments/rtp-hdrext/generic-frame-descriptor-00"
    const val MAX_CANDIDATES = 256
    val ROUTE_TIMEOUT = 20.seconds
    val WATCHDOG = 20.seconds
    val LINUX_APPROVAL = 150.seconds
    val PEER_GRACE = 15.seconds
    val LEASE_INTERVAL = 5.seconds
    val CLOSE_TIMEOUT = 3.seconds
    val CONFIGURATION_RETRY = 5.seconds
    val VIEWPORT_DEBOUNCE = 350.milliseconds
    val POINTER_INTERVAL = 4.milliseconds
    val CLIPBOARD_POLL = 250.milliseconds
    val CLIPBOARD_TIMEOUT = 30.seconds
    const val NO_FRAME_REFRESH_TICKS = 6
    const val STALLED_FRAME_REFRESH_TICKS = 20
    const val NO_FRAME_GIVE_UP_TICKS = 40

    /** Why a host that cannot share now is blocked: a missing permission, else unsupported. */
    fun unavailable(caps: RemoteDesktopCapabilities): ScreenPhase {
        val reason =
            caps.unavailable_reason.ifEmpty { "Screen sharing is unavailable on this machine." }
        return if (
            caps.availability ==
                RemoteDesktopAvailability.REMOTE_DESKTOP_AVAILABILITY_PERMISSION_REQUIRED
        )
            ScreenPhase.PermissionRequired(reason)
        else ScreenPhase.Unsupported(reason)
    }

    /** How long an attempt may take to connect; a Linux host waits for its user's approval. */
    fun watchdog(caps: RemoteDesktopCapabilities): Duration =
        if (caps.platform == "linux") WATCHDOG + LINUX_APPROVAL else WATCHDOG

    /** Phases of an attempt that has not connected yet, which the watchdog ends. */
    fun connecting(phase: ScreenPhase): Boolean =
        phase is ScreenPhase.Loading ||
            phase is ScreenPhase.Connecting ||
            phase is ScreenPhase.WaitingForHostApproval ||
            phase is ScreenPhase.Reconnecting

    /** The data channels to open: lossy pointer moves, ordered input and session, and clipboard. */
    fun channels(caps: RemoteDesktopCapabilities): List<ScreenChannelSpec> = buildList {
        add(ScreenChannelSpec(ScreenChannels.POINTER, ordered = false, maxRetransmits = 0))
        add(ScreenChannelSpec(ScreenChannels.INPUT, ordered = true))
        add(ScreenChannelSpec(ScreenChannels.SESSION, ordered = true))
        if (caps.clipboard_supported)
            add(ScreenChannelSpec(ScreenChannels.CLIPBOARD, ordered = true))
    }

    /** The codec preference an offer carries and the codecs it receives; none when unmet. */
    data class Offer(val effective: RemoteDesktopCodecPreference, val codecs: List<RtpCodec>)

    fun offer(
        media: ScreenMediaCapabilities,
        caps: RemoteDesktopCapabilities,
        preferences: ScreenPreferences,
        hevcFailed: Boolean,
        fpsCeiling: Int,
    ): Offer {
        val effective = ScreenCodecs.effective(preferences.codec, hevcFailed)
        val fps = ScreenCapabilities.maxFps(preferences.maxFps, caps, fpsCeiling)
        val canHevc =
            ScreenCodecs.canHevc(
                caps,
                preferences.width,
                preferences.height,
                fps,
                media.hevcDecoder,
            )
        val codecs =
            ScreenCodecs.receiveCodecs(
                media.receiveCodecs,
                RtpCodec::name,
                RtpCodec::profile,
                effective,
                canHevc,
            )
        return Offer(effective, codecs)
    }

    /** Reference recovery needs the decoder's dependencies and the offer's frame descriptors. */
    fun referenceRecovery(media: ScreenMediaCapabilities, offerSdp: String): Boolean =
        media.referenceDependencies && offerSdp.contains(GENERIC_FRAME_DESCRIPTOR)

    /** The phase while the offer is answered: a Linux host first asks its user. */
    fun negotiating(caps: RemoteDesktopCapabilities): ScreenPhase =
        if (ScreenCapabilities.needsHostApproval(caps)) ScreenPhase.WaitingForHostApproval
        else ScreenPhase.Connecting

    /** The stream size for a drawable: exact pixels for a virtual display, else the viewport's. */
    fun streamSize(
        preferences: ScreenPreferences,
        viewport: ViewportPolicy,
        width: Double,
        height: Double,
        density: Double,
    ): Pair<Int, Int>? =
        if (preferences.virtualDisplay)
            VirtualDisplaySizing.size(
                width,
                height,
                density,
                preferences.virtualScale,
                preferences.codec ==
                    RemoteDesktopCodecPreference.REMOTE_DESKTOP_CODEC_PREFERENCE_HEVC,
            )
        else viewport.size(width, height, density)

    /** An HEVC stream stays within 1080p60; asking for more needs a new session. */
    fun needsNewSession(
        state: RemoteDesktopSessionState?,
        preferences: ScreenPreferences,
        fps: Int,
    ) =
        state?.codec == ScreenCodecs.H265 &&
            (fps > 60 || preferences.width > 1920 || preferences.height > 1080)

    /** The stream configuration to ask for; a virtual display streams at most 60 fps. */
    fun configuration(
        preferences: ScreenPreferences,
        caps: RemoteDesktopCapabilities,
        virtual: RemoteDesktopVirtualDisplay?,
        control: Boolean,
        fps: Int,
    ) =
        RemoteDesktopStreamConfiguration(
            display_id = virtual?.display_id ?: preferences.displayId ?: "primary",
            max_width = preferences.width,
            max_height = preferences.height,
            max_fps = if (virtual != null) minOf(fps, 60) else fps,
            max_bitrate_kbps = ScreenRequests.MAX_BITRATE_KBPS,
            quality = preferences.quality,
            embedded_cursor = ScreenCapabilities.embedCursor(caps, control),
        )

    /**
     * The virtual display to hold: one while this client controls the host and wants it, else none.
     * Fails when the host cannot provide what the preferences ask for.
     */
    fun virtualDisplay(
        preferences: ScreenPreferences,
        state: RemoteDesktopSessionState?,
        sessionId: String,
        supported: Boolean,
        disableSupported: Boolean,
    ): SetRemoteDesktopVirtualDisplayRequest? {
        if (!preferences.virtualDisplay || state?.control_active != true) return null
        check(supported) { "Experimental virtual displays are unavailable on this host" }
        check(!preferences.disablePhysical || disableSupported) {
            "Physical display disabling is not qualified on this host"
        }
        return SetRemoteDesktopVirtualDisplayRequest(
            session_id = sessionId,
            pixel_width = preferences.width,
            pixel_height = preferences.height,
            scale = preferences.virtualScale,
            disable_physical = preferences.disablePhysical,
        )
    }

    /**
     * The host restored the physical display under a newer control grant (another client took
     * control, say), as opposed to this client's own restore or recreate.
     */
    fun hostRestoredVirtualDisplay(
        previous: RemoteDesktopSessionState?,
        next: RemoteDesktopSessionState,
        restoring: Boolean,
    ): Boolean =
        !restoring &&
            previous?.virtual_display?.active == true &&
            next.virtual_display?.active != true &&
            next.control_generation > previous.control_generation

    /** What the view shows and allows once the session's state is known. */
    data class Readiness(
        /** Frames of the current display are presented. */
        val ready: Boolean,
        /** Input reaches the host. */
        val control: Boolean,
        val canTransferControl: Boolean,
    )

    fun readiness(
        authorized: Boolean,
        peerConnected: Boolean,
        presentedGeneration: Long,
        state: RemoteDesktopSessionState?,
        binding: RemoteDesktopSessionBinding?,
        displayId: String?,
        inputChannelsOpen: Boolean,
        focused: Boolean,
    ): Readiness {
        val ready =
            authorized &&
                peerConnected &&
                presentedGeneration > 0 &&
                state != null &&
                presentedGeneration == state.display_generation &&
                (displayId == null || displayId == state.display_id)
        val granted = binding?.control_granted == true
        val control = ready && inputChannelsOpen && granted && state.control_active && focused
        return Readiness(ready, control, canTransferControl = granted)
    }

    /** The pointer, input, and session channels input needs are open. */
    fun inputChannelsOpen(engine: ScreenMediaEngine?): Boolean =
        engine?.let {
            it.isOpen(ScreenChannels.POINTER) &&
                it.isOpen(ScreenChannels.INPUT) &&
                it.isOpen(ScreenChannels.SESSION)
        } == true

    /** What a session does after a failure. */
    sealed interface Outcome {
        /** Retry without HEVC, when the codec choice allows it ([canFallBackFromHevc]). */
        data object HevcFallback : Outcome

        /** Start a new attempt after a backoff. */
        data class Recover(val reason: String) : Outcome

        /** Stop and show [message]. */
        data class Fail(val message: String) : Outcome
    }

    /** A session the host closed with [reason]. */
    fun closure(reason: String): Outcome =
        when {
            reason == ScreenFailures.HEVC_UNAVAILABLE -> Outcome.HevcFallback
            ScreenFailures.retryableClosure(reason) -> Outcome.Recover(reason)
            else -> Outcome.Fail(reason.ifEmpty { "The screen session closed" })
        }

    /** An error the daemon signaled. */
    fun hostError(code: String, message: String, recoverable: Boolean): Outcome =
        when {
            code == "hevc_unavailable" -> Outcome.HevcFallback
            ScreenFailures.retryableError(code, message, recoverable) ->
                Outcome.Recover(message.ifEmpty { "The screen session was interrupted" })
            else -> Outcome.Fail(message.ifEmpty { "The screen session failed" })
        }

    /** HEVC fails over to H.264 once, and only when the user left the codec on automatic. */
    fun canFallBackFromHevc(preferences: ScreenPreferences, hevcFailed: Boolean): Boolean =
        preferences.codec == RemoteDesktopCodecPreference.REMOTE_DESKTOP_CODEC_PREFERENCE_AUTO &&
            !hevcFailed
}

/**
 * Detects video that never starts or freezes on a connected peer, one monitor interval at a time:
 * first it asks the host to refresh the existing session, and if no frame follows, the session is
 * replaced. A new frame, a reconnected peer, or a focus change starts counting again.
 */
internal class ScreenFrameWatch {
    private var ticks = 0
    private var refreshed = false

    /** [refresh] asks the host for a new key frame; [replace] gives up on this session. */
    data class Tick(val refresh: Boolean, val replace: Boolean)

    fun reset() {
        ticks = 0
        refreshed = false
    }

    /** Whether an interval counts: a connected peer that should present frames now. */
    fun watching(
        peerConnected: Boolean,
        focused: Boolean,
        presentedAny: Boolean,
        phase: ScreenPhase,
    ): Boolean =
        peerConnected && (focused || !presentedAny) && phase !is ScreenPhase.WaitingForHostApproval

    /**
     * One interval without a new frame; [presentedAny] once a frame of the display was shown, which
     * allows longer before a refresh.
     */
    fun tick(presentedAny: Boolean): Tick {
        ticks++
        val refreshAt =
            if (presentedAny) ScreenSessionPolicy.STALLED_FRAME_REFRESH_TICKS
            else ScreenSessionPolicy.NO_FRAME_REFRESH_TICKS
        val refresh = ticks >= refreshAt && !refreshed
        if (refresh) refreshed = true
        return Tick(
            refresh,
            replace = ticks >= refreshAt + ScreenSessionPolicy.NO_FRAME_GIVE_UP_TICKS,
        )
    }
}

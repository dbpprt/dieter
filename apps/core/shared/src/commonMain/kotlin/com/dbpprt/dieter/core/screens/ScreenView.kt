package com.dbpprt.dieter.core.screens

import com.dbpprt.dieter.api.v1.RemoteDesktopCapabilities
import com.dbpprt.dieter.api.v1.RemoteDesktopSessionState
import com.dbpprt.dieter.core.presentation.Counts
import kotlin.math.roundToLong
import okio.ByteString

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

    /** The phase's name in the client contract, e.g. "waiting_for_host_approval". */
    val wire: String
        get() = when (this) {
            Idle -> "idle"
            Loading -> "loading"
            is PermissionRequired -> "permission_required"
            is Unsupported -> "unsupported"
            Connecting -> "connecting"
            WaitingForHostApproval -> "waiting_for_host_approval"
            Streaming -> "streaming"
            is Reconnecting -> "reconnecting"
            is Failed -> "failed"
        }

    /** The phase as status lines show it; phases still in progress end with "…". */
    val label: String
        get() = when (this) {
            Idle -> "Not connected"
            Loading -> "Checking machine…"
            is PermissionRequired -> "Permission required"
            is Unsupported -> "Screen sharing unavailable"
            Connecting -> "Connecting…"
            WaitingForHostApproval -> "Waiting for approval on Linux host…"
            Streaming -> "Live"
            is Reconnecting -> "Reconnecting…"
            is Failed -> "Connection failed"
        }

    /** What a screen view says in this phase while not streaming: why no session can run, else why the host cannot share ([hostReady], [hostReason]), else [label]. */
    fun waitingMessage(hostReady: Boolean, hostReason: String): String =
        problem?.takeIf { it.isNotBlank() }
            ?: (if (hostReady) null else hostReason.ifBlank { "Screen sharing is unavailable on this machine." })
            ?: label

    companion object {
        /** The phase whose [wire] name is [wire], with the [problem] a blocked or reconnecting phase carries; unknown names are idle. */
        fun of(wire: String, problem: String): ScreenPhase = when (wire) {
            "loading" -> Loading
            "permission_required" -> PermissionRequired(problem)
            "unsupported" -> Unsupported(problem)
            "connecting" -> Connecting
            "waiting_for_host_approval" -> WaitingForHostApproval
            "streaming" -> Streaming
            "reconnecting" -> Reconnecting(problem.ifEmpty { null })
            "failed" -> Failed(problem)
            else -> Idle
        }
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
) {
    /** The frame-rate choices the host allows; 30 and 60 before it reports a maximum. */
    val frameRates: List<Int> get() = ScreenCapabilities.frameRates(capabilities ?: RemoteDesktopCapabilities())

    /** Why this client cannot take control of the live session; empty while it can or is not streaming. */
    val controlUnavailableReason: String
        get() = if (phase == ScreenPhase.Streaming && !canTransferControl) ScreenCapabilities.permissionReason(capabilities?.platform.orEmpty()) else ""

    /** Copy and paste can run: this client controls the host, shares the clipboard, and no clipboard operation is in flight. */
    val clipboardActionsEnabled: Boolean get() = controlActive && clipboardEnabled && !clipboardBusy

    /** The network round trip while streaming: "12 ms RTT", "<1 ms RTT", or "— ms RTT" without a measurement. */
    val latencyLabel: String
        get() {
            val milliseconds = state?.rtt_ms ?: 0.0
            return when {
                phase != ScreenPhase.Streaming || !milliseconds.isFinite() || milliseconds <= 0 -> "— ms RTT"
                milliseconds < 1 -> "<1 ms RTT"
                else -> "${milliseconds.roundToLong()} ms RTT"
            }
        }

    /** The status line under the machine's name: "Connected · Control" or "Connected · View only" while streaming, else the phase. */
    val statusLine: String
        get() = if (phase == ScreenPhase.Streaming) "Connected · ${if (controlActive) "Control" else "View only"}" else phase.label

    /** The button that takes or releases control. */
    val controlAction: String get() = ScreenOptions.controlAction(controlActive)

    /**
     * The line above the canvas while streaming, e.g. "1920 × 1080 · H264 · 60 fps · Direct media",
     * leaving out what is unknown; [fps] and [mediaRoute] are the media engine's own measurements.
     */
    fun metadata(fps: Double, mediaRoute: String): String {
        if (phase != ScreenPhase.Streaming) return "Your view stays in place while connecting"
        val session = state
        return listOf(session?.let { "${it.width} × ${it.height}" }.orEmpty(), session?.codec.orEmpty(), rate(fps), mediaRoute).filter { it.isNotBlank() }.joinToString(" · ")
    }

    /**
     * What the canvas says while not streaming: why no session can run, else
     * why the host cannot share ([hostReady], [hostReason]), else the phase.
     */
    fun waitingMessage(hostReady: Boolean, hostReason: String): String = phase.waitingMessage(hostReady, hostReason)

    /** The connection details of a session with the machine [daemonId]; [fps] and [mediaRoute] are the media engine's own. */
    fun details(daemonId: String, fps: Double, mediaRoute: String): ScreenDetails {
        val session = state
        return ScreenDetails(
            status = "Status · ${phase.label}",
            video = "Video · ${mediaRoute.ifBlank { "Negotiating" }}",
            signaling = "Signaling · ${routeLabel.ifBlank { "Negotiating" }}",
            machine = "Machine · $daemonId",
            session = if (session == null) emptyList() else listOfNotNull(
                "Display · ${session.width} × ${session.height} · ${session.codec}",
                "${rate(fps)} · ${Counts.of(session.connected_clients, "viewer")}",
                session.controller_name.takeIf { it.isNotBlank() }?.let { "Controller · $it" },
            ),
        )
    }

    private fun rate(fps: Double): String = "${if (fps.isFinite()) fps.roundToLong() else 0} fps"
}

/** A screen session's connection details, one "Name · value" line each; [session] lists the display, rate and viewers, and controller once a session runs. */
data class ScreenDetails(val status: String, val video: String, val signaling: String, val machine: String, val session: List<String>)

data class ScreenConfig(
    val clientName: String,
    val viewport: ViewportPolicy,
    val fpsCeiling: Int = 120,
)

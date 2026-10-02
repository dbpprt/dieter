package com.dbpprt.dieter.core.screens

import com.dbpprt.dieter.api.v1.DieterServiceClient
import com.dbpprt.dieter.api.v1.RemoteDesktopRef
import com.dbpprt.dieter.api.v1.SetRemoteDesktopDisplayModeRequest
import com.dbpprt.dieter.core.runtime.Failures
import kotlin.coroutines.cancellation.CancellationException
import kotlin.time.Duration.Companion.milliseconds
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.launch

/** Resolution matching as a view shows it. */
data class DisplayMatchView(val status: String = "", val busy: Boolean = false)

/**
 * Matches the host display to this screen while the client holds control
 * (macOS fullscreen). Changes run one at a time: a new target during a change
 * is applied after its reply rather than abandoning an uncertain outcome, and
 * a temporary mode is restored when matching stops. Confined to the core
 * dispatcher.
 */
class ScreenDisplays(private val scope: CoroutineScope, private val beforeChange: () -> Unit) {
    data class Intent(val client: DieterServiceClient, val sessionId: String, val displayId: String, val target: DisplayMatching.Target) {
        fun matches(other: Intent?): Boolean =
            other != null && sessionId == other.sessionId && displayId == other.displayId && target == other.target
    }

    private val mutableView = MutableStateFlow(DisplayMatchView())
    val view: StateFlow<DisplayMatchView> = mutableView.asStateFlow()
    private var desired: Intent? = null
    private var attempted: Intent? = null
    private var leased: Intent? = null
    private var worker: Job? = null

    /** Matches [intent], or stops matching (restoring a temporary mode) when null. */
    fun update(intent: Intent?, unavailable: String = "") {
        if ((intent != null && intent.matches(desired)) || (intent == null && desired == null)) {
            if (intent == null && worker == null && unavailable.isNotEmpty()) mutableView.value = mutableView.value.copy(status = unavailable)
            return
        }
        desired = intent
        attempted = null
        if (worker?.isActive != true) worker = scope.launch { reconcile() }
    }

    private fun status(text: String) {
        mutableView.value = mutableView.value.copy(status = text)
    }

    private suspend fun reconcile() {
        mutableView.value = mutableView.value.copy(busy = true)
        try {
            while (true) {
                val lease = leased
                if (lease != null && !lease.matches(desired)) {
                    beforeChange()
                    try {
                        lease.client.RestoreRemoteDesktopDisplayMode().execute(RemoteDesktopRef(session_id = lease.sessionId))
                        status("Remote resolution restored")
                    } catch (error: Throwable) {
                        if (error is CancellationException) throw error
                        // Closing or handing off the session releases the lease independently.
                        status("Resolution restore: ${Failures.message(error)}")
                    }
                    leased = null
                }
                val intent = desired ?: return
                if (intent.matches(attempted)) return
                attempted = intent
                // Monitor moves and fullscreen transitions report several sizes.
                delay(SETTLE)
                if (!intent.matches(desired)) continue
                try {
                    val modes = intent.client.ListRemoteDesktopDisplayModes().execute(RemoteDesktopRef(session_id = intent.sessionId))
                    if (!intent.matches(desired)) continue
                    val mode = if (modes.superseded) null else DisplayMatching.best(modes.modes, intent.target)
                    if (mode == null) {
                        status(if (modes.superseded) "Remote resolution changed locally" else "No supported remote resolution")
                        continue
                    }
                    if (modes.current_mode_id != mode.id) {
                        beforeChange()
                        leased = intent
                        val result = intent.client.SetRemoteDesktopDisplayMode().execute(
                            SetRemoteDesktopDisplayModeRequest(
                                session_id = intent.sessionId, display_id = modes.display_id, mode_id = mode.id, expected_current_mode_id = modes.current_mode_id,
                            ),
                        )
                        if (!result.temporary) leased = null
                    }
                    val kind = if (DisplayMatching.exact(mode, intent.target)) "Matched" else "Closest supported"
                    status("$kind: ${mode.logical_width} × ${mode.logical_height} (${mode.pixel_width} × ${mode.pixel_height} pixels)")
                } catch (error: Throwable) {
                    if (error is CancellationException) throw error
                    val message = "Resolution matching unavailable: ${Failures.message(error)}"
                    leased?.let { held ->
                        runCatching { held.client.RestoreRemoteDesktopDisplayMode().execute(RemoteDesktopRef(session_id = held.sessionId)) }
                        leased = null
                    }
                    status(message)
                }
            }
        } finally {
            mutableView.value = mutableView.value.copy(busy = false)
            worker = null
        }
    }

    private companion object {
        val SETTLE = 350.milliseconds
    }
}

/**
 * A screen-sharing view: the session plus resolution matching, which follows
 * the session's control and display. Confined to the core dispatcher.
 */
class ScreenSurface(val session: ScreenSession, private val scope: CoroutineScope) {
    val displays = ScreenDisplays(scope) { session.releaseInput() }
    private var target: DisplayMatching.Target? = null
    private val follower: Job = scope.launch { session.view.collect { refreshDisplays(it) } }

    val view = combine(session.view, displays.view, ::Pair)

    /** Matches the host display to [target] while this client holds control; null stops matching. */
    fun matchDisplay(target: DisplayMatching.Target?) {
        this.target = target
        refreshDisplays(session.view.value)
    }

    private fun refreshDisplays(view: ScreenView) {
        val target = target
        val client = session.routeClient()
        val state = view.state
        if (target == null || client == null || view.sessionId.isEmpty() || !view.canTransferControl || state?.control_active != true) {
            displays.update(null)
            return
        }
        if (view.capabilities?.display_mode_switching_supported != true) {
            displays.update(null, unavailable = "Update the remote daemon to match desktop resolution")
            return
        }
        displays.update(ScreenDisplays.Intent(client, view.sessionId, state.configuration?.display_id.orEmpty(), target))
    }

    /** Stops matching, closes the session, and stops following it. */
    fun stop() {
        target = null
        displays.update(null)
        session.disconnect()
        follower.cancel()
    }
}

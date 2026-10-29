package com.getdieter.core.screens

import com.getdieter.api.v1.ConfirmRemoteDesktopVirtualDisplayRequest
import com.getdieter.api.v1.RemoteDesktopCapabilities
import com.getdieter.api.v1.RemoteDesktopRef
import com.getdieter.api.v1.RemoteDesktopSessionState
import com.getdieter.api.v1.RemoteDesktopVirtualDisplay
import com.getdieter.api.v1.SetRemoteDesktopVirtualDisplayRequest
import com.getdieter.api.v1.UpdateRemoteDesktopSessionRequest
import com.getdieter.core.api.DaemonApi
import com.getdieter.core.runtime.Deadlines
import com.getdieter.core.runtime.Failures
import com.getdieter.core.runtime.withDeadline
import kotlin.coroutines.cancellation.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/** The running attempt of a [ScreenSession], as [ScreenStreamControl] reads and drives it. */
internal interface ScreenStreamHost {
    /** Identifies the attempt; work started for an earlier one stops. */
    val token: Long
    val sessionId: String
    val route: ScreenRoute?
    val capabilities: RemoteDesktopCapabilities?
    val state: RemoteDesktopSessionState?

    /** The session asked to control the host. */
    val controlRequested: Boolean

    /** Holds [job] until the attempt stops. */
    fun track(job: Job)

    fun releaseInput()

    /** Merges a state the host replied with. */
    fun applyState(state: RemoteDesktopSessionState)

    fun recover(reason: String, immediate: Boolean)

    fun fail(message: String)
}

/**
 * The stream a screen session asks for: the preferences that survive recovery, the configuration
 * sent to the host, the experimental virtual display, and the viewport's size. Configuration is an
 * idempotent desired state: overlapping requests coalesce into one in flight, and a slow route
 * retries it on the same session. [ScreenSession] owns it; confined to the core dispatcher.
 */
internal class ScreenStreamControl(
    private val scope: CoroutineScope,
    private val config: ScreenConfig,
    private val attempt: ScreenStreamHost,
) {
    var preferences = ScreenPreferences()

    // Survives recovery.
    private var drawable: Triple<Double, Double, Double>? = null

    // Attempt scope: cleared by [reset].
    private var virtualRequest: SetRemoteDesktopVirtualDisplayRequest? = null
    private var virtualLease: RemoteDesktopVirtualDisplay? = null
    private var virtualConfirmed = 0L
    private var restoringVirtual = false
    private var configuring = false
    private var configurationPending = false
    private var refreshPending = false

    /** Applies [change] and sizes the result for the last drawable; returns the previous ones. */
    fun change(change: (ScreenPreferences) -> ScreenPreferences): ScreenPreferences {
        val previous = preferences
        preferences = change(preferences)
        drawable?.let { (width, height, density) ->
            ScreenSessionPolicy.streamSize(preferences, config.viewport, width, height, density)
                ?.let { preferences = preferences.copy(width = it.first, height = it.second) }
        }
        return previous
    }

    /** Sets the requested stream size for this view; debounced by 350 ms. */
    fun viewport(widthPoints: Double, heightPoints: Double, scale: Double) {
        drawable = Triple(widthPoints, heightPoints, scale)
        val size =
            ScreenSessionPolicy.streamSize(
                preferences,
                config.viewport,
                widthPoints,
                heightPoints,
                scale,
            ) ?: return
        if (size == preferences.width to preferences.height) return
        preferences = preferences.copy(width = size.first, height = size.second)
        val expected = attempt.token
        attempt.track(
            scope.launch {
                delay(ScreenSessionPolicy.VIEWPORT_DEBOUNCE)
                if (
                    expected == attempt.token &&
                        preferences.width == size.first &&
                        preferences.height == size.second
                )
                    configure()
            }
        )
    }

    /** Sends the desired stream configuration; overlapping requests coalesce into one in flight. */
    fun configure(refresh: Boolean = false) {
        if (attempt.sessionId.isEmpty()) return
        configurationPending = configurationPending || !refresh
        refreshPending = refreshPending || refresh
        if (configuring) return
        configuring = true
        val attemptToken = attempt.token
        attempt.track(
            scope.launch {
                var wantsConfiguration = false
                try {
                    while (
                        (configurationPending || refreshPending) && attemptToken == attempt.token
                    ) {
                        val wantsRefresh = refreshPending
                        wantsConfiguration = configurationPending
                        configurationPending = false
                        refreshPending = false
                        val caps = attempt.capabilities ?: return@launch
                        val fps =
                            ScreenCapabilities.maxFps(preferences.maxFps, caps, config.fpsCeiling)
                        if (ScreenSessionPolicy.needsNewSession(attempt.state, preferences, fps)) {
                            return@launch attempt.recover(
                                "Switching stream mode…",
                                immediate = true,
                            )
                        }
                        val control = attempt.controlRequested
                        val current = attempt.route ?: return@launch
                        val virtual =
                            if (wantsConfiguration)
                                withDeadline(Deadlines.CALL) {
                                    reconcileVirtual(
                                        current.client,
                                        caps.virtual_display_supported,
                                        caps.virtual_display_disable_supported,
                                    )
                                }
                            else virtualLease
                        val configuration =
                            ScreenSessionPolicy.configuration(
                                preferences,
                                caps,
                                virtual,
                                control,
                                fps,
                            )
                        if (wantsConfiguration) attempt.releaseInput()
                        val updated =
                            withDeadline(Deadlines.CALL) {
                                current.client
                                    .UpdateRemoteDesktopSession()
                                    .execute(
                                        UpdateRemoteDesktopSessionRequest(
                                            session_id = attempt.sessionId,
                                            configuration =
                                                if (wantsConfiguration) configuration else null,
                                            refresh = wantsRefresh,
                                        )
                                    )
                            }
                        if (attemptToken == attempt.token) {
                            attempt.applyState(updated)
                            restoringVirtual = false
                        }
                    }
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (error: Throwable) {
                    if (attemptToken == attempt.token) {
                        if (ScreenFailures.retryable(error)) {
                            // Configuration is an idempotent desired state. A slow signaling
                            // route must not discard a peer that can still carry video.
                            configurationPending = configurationPending || wantsConfiguration
                            refreshPending = true
                            attempt.track(
                                scope.launch {
                                    delay(ScreenSessionPolicy.CONFIGURATION_RETRY)
                                    if (
                                        attemptToken == attempt.token &&
                                            (configurationPending || refreshPending)
                                    )
                                        configure(refresh = true)
                                }
                            )
                        } else attempt.fail(Failures.message(error))
                    }
                } finally {
                    if (attemptToken == attempt.token) configuring = false
                }
            }
        )
    }

    private suspend fun reconcileVirtual(
        client: DaemonApi,
        supported: Boolean,
        disableSupported: Boolean,
    ): RemoteDesktopVirtualDisplay? {
        val desired =
            ScreenSessionPolicy.virtualDisplay(
                preferences,
                attempt.state,
                attempt.sessionId,
                supported,
                disableSupported,
            )
        if (virtualRequest == desired && (desired == null || virtualLease != null))
            return virtualLease
        if (virtualRequest != null && virtualRequest != desired) {
            // Keep the preference through our own restore/recreate notifications.
            // UpdateSession returns a monotonic state before this flag is cleared.
            restoringVirtual = true
            client
                .RestoreRemoteDesktopVirtualDisplay()
                .execute(RemoteDesktopRef(session_id = attempt.sessionId))
            virtualRequest = null
            virtualLease = null
            virtualConfirmed = 0
        }
        if (desired != null) {
            // Record intent before awaiting: state notifications may arrive before the RPC reply.
            virtualRequest = desired
            virtualLease = client.SetRemoteDesktopVirtualDisplay().execute(desired)
        }
        return virtualLease
    }

    /** The host's display changed: its virtual display is not confirmed yet. */
    fun displayChanged() {
        virtualConfirmed = 0
    }

    /**
     * Before [next] replaces [previous]: when the host restored the physical display under a newer
     * control grant, the virtual display preference is dropped instead of recreated.
     */
    fun followHost(previous: RemoteDesktopSessionState?, next: RemoteDesktopSessionState) {
        if (!ScreenSessionPolicy.hostRestoredVirtualDisplay(previous, next, restoringVirtual))
            return
        preferences = preferences.copy(virtualDisplay = false, disablePhysical = false)
        virtualRequest = null
        virtualLease = null
        virtualConfirmed = 0
    }

    /**
     * After [state] was merged: control brings up the wanted virtual display, losing it drops it.
     */
    fun stateApplied(state: RemoteDesktopSessionState) {
        if (preferences.virtualDisplay && state.control_active && virtualRequest == null)
            configure()
        if (!state.control_active) {
            virtualRequest = null
            virtualLease = null
            virtualConfirmed = 0
        }
    }

    /**
     * A frame of [current]'s display was presented. A controlled virtual display is confirmed to
     * the host once per display generation; the session fails when that confirmation fails while
     * the display is still current.
     */
    fun presented(current: RemoteDesktopSessionState) {
        val virtual = current.virtual_display
        if (
            virtual?.active != true ||
                !current.control_active ||
                virtual.display_id != current.display_id ||
                virtualConfirmed == current.display_generation
        )
            return
        virtualConfirmed = current.display_generation
        val currentRoute = attempt.route
        val attemptToken = attempt.token
        attempt.track(
            scope.launch {
                try {
                    withDeadline(Deadlines.CALL) {
                        currentRoute
                            ?.client
                            ?.ConfirmRemoteDesktopVirtualDisplay()
                            ?.execute(
                                ConfirmRemoteDesktopVirtualDisplayRequest(
                                    session_id = attempt.sessionId,
                                    display_id = virtual.display_id,
                                    display_generation = current.display_generation,
                                )
                            )
                    }
                } catch (error: Throwable) {
                    if (error is CancellationException) throw error
                    val state = attempt.state
                    if (
                        attemptToken == attempt.token &&
                            state?.display_generation == current.display_generation &&
                            state.virtual_display?.active == true &&
                            state.virtual_display?.display_id == virtual.display_id
                    )
                        attempt.fail("Virtual display presentation: ${Failures.message(error)}")
                }
            }
        )
    }

    /** Forgets the stopped attempt's virtual display and configuration in flight. */
    fun reset() {
        virtualRequest = null
        virtualLease = null
        virtualConfirmed = 0
        restoringVirtual = false
        configuring = false
        configurationPending = false
        refreshPending = false
    }
}

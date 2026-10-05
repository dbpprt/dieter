package com.dbpprt.dieter.core.connection

import com.dbpprt.dieter.client.v1.Tone
import com.dbpprt.dieter.core.navigation.Destination
import com.dbpprt.dieter.core.presentation.Ages
import kotlin.time.Duration
import kotlin.time.Duration.Companion.seconds
import kotlin.time.Instant

/** How a synchronized destination treats cached data: current, or shown but unavailable. */
enum class SurfaceTreatment {
    CURRENT,
    UNAVAILABLE,
    ;

    val showsNotice: Boolean get() = this != CURRENT
    val blocksInteraction: Boolean get() = this == UNAVAILABLE
}

/** The workspace connection notice: a title, what still works, and whether it is still trying. */
data class ConnectionNotice(val title: String, val detail: String, val working: Boolean, val offline: Boolean)

/** What each destination can do in the connection state it is in. */
object Availability {
    /**
     * Cached data stays current through a routine connection handoff
     * (connecting); anything else makes it read-only.
     */
    fun treatment(destination: Destination, hasCache: Boolean, phase: ConnectionPhase): SurfaceTreatment = when {
        !destination.synchronized || !hasCache -> SurfaceTreatment.CURRENT
        phase == ConnectionPhase.CONNECTED || phase == ConnectionPhase.CONNECTING -> SurfaceTreatment.CURRENT
        else -> SurfaceTreatment.UNAVAILABLE
    }

    /** Unavailable destinations block input unless their changes queue offline. */
    fun blocksInteraction(destination: Destination, hasCache: Boolean, phase: ConnectionPhase): Boolean =
        treatment(destination, hasCache, phase).blocksInteraction && !destination.offlineOutbox

    /** Nothing cached yet: show the first sync instead of an empty workspace. */
    fun initialSync(destination: Destination, hasCache: Boolean, loading: Boolean, desired: Boolean, phase: ConnectionPhase): Boolean =
        destination.synchronized && !hasCache && desired && (loading || phase != ConnectionPhase.CONNECTED)

    /**
     * The workspace is loading while a wanted connection has not delivered
     * any machine's view; connected with no [reachable] machine, there is
     * nothing to wait for.
     */
    fun loading(desired: Boolean, loaded: Boolean, phase: ConnectionPhase, reachable: Boolean): Boolean =
        desired && !loaded && (phase != ConnectionPhase.CONNECTED || reachable)

    /** Project-scoped destinations need at least one project whose machine is not known to be offline. */
    fun projectScopedEnabled(projectIds: List<String>, replicaOnline: (String) -> Boolean?): Boolean = projectIds.any { replicaOnline(it) != false }

    private val interrupted = setOf(ConnectionPhase.RECONNECTING, ConnectionPhase.AUTH_REQUIRED, ConnectionPhase.UPDATE_REQUIRED, ConnectionPhase.DISCONNECTED)

    fun notice(phase: ConnectionPhase, cached: Boolean, offlineOutbox: Boolean = false): ConnectionNotice {
        val cachedDetail = when {
            offlineOutbox && phase in interrupted -> "Cached conversations stay available; messages and new conversations queue until Dieter reconnects."
            phase == ConnectionPhase.CONNECTING -> "Your workspace stays available while Dieter connects."
            phase == ConnectionPhase.RECONNECTING -> "Cached data stays visible while the connection recovers."
            else -> "Cached data is read-only until Dieter reconnects."
        }
        val uncachedDetail = when (phase) {
            ConnectionPhase.CONNECTING -> "Contacting Dieter and discovering your machines."
            ConnectionPhase.RECONNECTING -> "Restoring your connection to Dieter."
            else -> "Open connection settings to continue."
        }
        return ConnectionNotice(
            title = when (phase) {
                ConnectionPhase.CONNECTED -> "Workspace is up to date"
                ConnectionPhase.CONNECTING -> "Connecting to Dieter"
                ConnectionPhase.RECONNECTING -> "Reconnecting to Dieter"
                ConnectionPhase.AUTH_REQUIRED -> "Sign in required"
                ConnectionPhase.UPDATE_REQUIRED -> "Update required"
                ConnectionPhase.DISCONNECTED -> if (cached) "Working from cached data" else "Dieter is unavailable"
            },
            detail = if (cached) cachedDetail else uncachedDetail,
            working = phase == ConnectionPhase.CONNECTING || phase == ConnectionPhase.RECONNECTING,
            offline = phase == ConnectionPhase.AUTH_REQUIRED || phase == ConnectionPhase.UPDATE_REQUIRED || phase == ConnectionPhase.DISCONNECTED,
        )
    }

    /** What the first sync shows while nothing is cached yet. */
    fun firstSync(phase: ConnectionPhase): ConnectionNotice = when (phase) {
        ConnectionPhase.DISCONNECTED -> ConnectionNotice("Preparing your workspace", "Dieter is getting ready to connect.", working = true, offline = false)
        ConnectionPhase.CONNECTING -> ConnectionNotice("Connecting to Dieter", "Discovering your enrolled machines and choosing the fastest route.", working = true, offline = false)
        ConnectionPhase.CONNECTED ->
            ConnectionNotice("Syncing your workspace", "Projects, boards, and conversations will appear together as soon as they arrive.", working = true, offline = false)
        ConnectionPhase.RECONNECTING -> ConnectionNotice("Reconnecting to Dieter", "Restoring the secure route to your workspace.", working = true, offline = false)
        ConnectionPhase.AUTH_REQUIRED -> ConnectionNotice("Sign in to continue", "Open connection settings and sign in to load your workspace.", working = false, offline = true)
        ConnectionPhase.UPDATE_REQUIRED -> ConnectionNotice("Update required", "Update Dieter before syncing this workspace.", working = false, offline = true)
    }

    /** "Updated just now", "Updated 5m ago", or "Waiting for first update". */
    fun updated(lastAppliedAt: Instant?, now: Instant): String {
        lastAppliedAt ?: return "Waiting for first update"
        return "Updated " + Ages.ago(lastAppliedAt, now)
    }

    /** "Last connected just now", "Last connected 5m ago", or "Last connected unknown". */
    fun lastConnected(at: Instant?, now: Instant): String {
        at ?: return "Last connected unknown"
        return "Last connected " + Ages.ago(at, now)
    }

    /**
     * What synchronized destinations with cached data show about the
     * connection: a notice while that data is unavailable, including while
     * connected with no [reachable] machine, else null. Chats and boards
     * queue changes offline, and the notice says so.
     */
    fun workspaceNotice(phase: ConnectionPhase, hasCache: Boolean, reachable: Boolean): ConnectionNotice? = when {
        treatment(Destination.BOARD, hasCache, phase) == SurfaceTreatment.UNAVAILABLE -> notice(phase, cached = true, offlineOutbox = true)
        // Connected, but no machine is reachable: everything shown is cached.
        phase == ConnectionPhase.CONNECTED && hasCache && !reachable ->
            ConnectionNotice("Working from cached data", "None of your machines is reachable; changes queue until one is back.", working = false, offline = true)
        else -> null
    }

    /** How [phase] reads, for its color: connected succeeds, a connection on its way or a sign-in warns, a blocked one is danger. */
    fun tone(phase: ConnectionPhase): Tone = when (phase) {
        ConnectionPhase.CONNECTED -> Tone.TONE_SUCCESS
        ConnectionPhase.CONNECTING, ConnectionPhase.RECONNECTING, ConnectionPhase.AUTH_REQUIRED -> Tone.TONE_WARNING
        ConnectionPhase.UPDATE_REQUIRED -> Tone.TONE_DANGER
        ConnectionPhase.DISCONNECTED -> Tone.TONE_NEUTRAL
    }

    /** A short connection status, e.g. for a header chip. */
    fun label(phase: ConnectionPhase): String = when (phase) {
        ConnectionPhase.CONNECTED -> "Connected"
        ConnectionPhase.RECONNECTING -> "Reconnecting"
        ConnectionPhase.UPDATE_REQUIRED -> "Update required"
        ConnectionPhase.AUTH_REQUIRED -> "Sign in required"
        ConnectionPhase.DISCONNECTED -> "Disconnected"
        ConnectionPhase.CONNECTING -> "Connecting"
    }

    /** The connection cannot work until something changes: a sign-in or an update. */
    fun blocked(phase: ConnectionPhase): Boolean =
        phase == ConnectionPhase.AUTH_REQUIRED || phase == ConnectionPhase.UPDATE_REQUIRED

    /** Phases the user must act on: sign in or update. */
    fun needsUser(phase: ConnectionPhase): Boolean = blocked(phase)
}

/**
 * When the connection sheet opens. Transport recovery is routine and shown
 * inline; the sheet only interrupts for a failure that needs the user, after
 * a grace period since the connection was lost. A sheet the user dismissed
 * stays closed until the phase changes.
 */
class ConnectionPrompt {
    var visible: Boolean = false
        private set
    private var manual = false
    private var dismissedPhase: ConnectionPhase? = null
    private var interruptedAt: Instant? = null

    /** Tracks when a working connection was lost. */
    fun phaseChanged(previous: ConnectionPhase, next: ConnectionPhase, now: Instant) {
        if (next != ConnectionPhase.CONNECTED && previous == ConnectionPhase.CONNECTED) interruptedAt = now
        if (next == ConnectionPhase.CONNECTED) interruptedAt = null
    }

    /** The user turned the connection on: forget earlier requests and dismissals. */
    fun connecting() {
        manual = false
        dismissedPhase = null
    }

    /** The user turned the connection off; the sheet stays open to turn it back on. */
    fun disconnected() {
        connecting()
        visible = true
    }

    /** The user asked for the sheet. */
    fun show() {
        manual = true
        visible = true
    }

    /** A notification asked for the sheet; it opens only when it can help. */
    fun showIfNeeded(desired: Boolean, phase: ConnectionPhase) {
        if (!desired || Availability.needsUser(phase)) {
            manual = false
            visible = true
        }
    }

    fun dismiss(desired: Boolean, phase: ConnectionPhase) {
        manual = false
        dismissedPhase = phase.takeUnless { desired && it == ConnectionPhase.CONNECTED }
        visible = false
    }

    /** Leaving for app settings counts as dismissing this phase. */
    fun leaveForSettings(phase: ConnectionPhase) {
        manual = false
        dismissedPhase = phase
        visible = false
    }

    /**
     * Applies the current state. Returns how long until the sheet should open
     * by itself (then call again), or null when no timer is needed.
     */
    fun reconcile(desired: Boolean, phase: ConnectionPhase, foreground: Boolean, now: Instant): Duration? {
        when {
            desired && phase == ConnectionPhase.CONNECTED -> {
                dismissedPhase = null
                if (!manual) visible = false
            }
            dismissedPhase != null && dismissedPhase == phase -> Unit
            !desired -> {
                manual = false
                visible = true
            }
            !foreground || visible -> Unit
            else -> {
                if (!Availability.needsUser(phase)) return null
                // Only losing a working connection interrupts; at launch the first-sync screen explains the phase.
                val since = interruptedAt ?: return null
                val remaining = GRACE - (now - since).coerceAtLeast(Duration.ZERO)
                if (remaining > Duration.ZERO) return remaining
                manual = false
                visible = true
            }
        }
        return null
    }

    companion object {
        val GRACE: Duration = 60.seconds
    }
}

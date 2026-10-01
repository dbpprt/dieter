package com.dbpprt.dieter.core.machines

import com.dbpprt.dieter.api.gateway.v1.CompatibilityStatus
import com.dbpprt.dieter.api.gateway.v1.Daemon
import com.dbpprt.dieter.api.gateway.v1.RemoteDesktopPresence
import kotlin.time.Duration
import kotlin.time.Duration.Companion.seconds
import kotlin.time.Instant

/** One enrolled daemon as the gateway reports it. */
data class Machine(
    val id: String,
    val name: String,
    /** The gateway's tunnel flag; aged by [receivedAt] in [online]. */
    val serverOnline: Boolean,
    val lastSeenAt: String,
    val releaseVersion: String,
    val minimumReleaseVersion: String,
    val compatibility: CompatibilityStatus,
    val generation: Long,
    val remoteDesktop: RemoteDesktopPresence?,
    /** When this client received the gateway's report, on the client's own clock. */
    val receivedAt: Instant,
) {
    val compatible: Boolean get() = compatibility == CompatibilityStatus.COMPATIBILITY_STATUS_COMPATIBLE

    fun online(now: Instant): Boolean = MachinePresence.online(serverOnline, receivedAt, now)

    val incompatibilityDescription: String?
        get() = if (compatible) {
            null
        } else {
            "Update required · Dieter ${releaseVersion.ifEmpty { "unknown" }} (requires ${minimumReleaseVersion.ifEmpty { "a newer release" }})"
        }

    companion object {
        fun from(daemon: Daemon, receivedAt: Instant) = Machine(
            id = daemon.id, name = daemon.name.ifBlank { daemon.id }, serverOnline = daemon.online,
            lastSeenAt = daemon.last_seen_at, releaseVersion = daemon.release_version,
            minimumReleaseVersion = daemon.minimum_release_version, compatibility = daemon.compatibility,
            generation = daemon.generation, remoteDesktop = daemon.remote_desktop, receivedAt = receivedAt,
        )
    }
}

/**
 * The gateway's online flag is authoritative: it keeps a daemon's route
 * through three missed heartbeats. The client only ages its own copy, by when
 * the report arrived on the client's clock. Never compare the gateway's
 * `last_seen_at` with the device clock: a phone a few milliseconds behind
 * would see every fresh heartbeat in the future and flap that machine offline.
 */
object MachinePresence {
    /** Three missed 15 s presence heartbeats; an older report no longer proves a machine is online. */
    val STALE_AFTER: Duration = 45.seconds

    fun online(serverOnline: Boolean, receivedAt: Instant, now: Instant): Boolean =
        serverOnline && now - receivedAt < STALE_AFTER

    /** When the next online machine's report goes stale, for re-evaluating presence. */
    fun nextExpiry(machines: List<Machine>, now: Instant): Instant? = machines
        .filter { it.serverOnline }
        .map { it.receivedAt + STALE_AFTER }
        .filter { it > now }
        .minOrNull()
}

/** Which machine the client attaches its feed to. */
object MachineSelection {
    /**
     * Online, compatible machines by name, with [preferredId] first. An
     * explicit selection is honored only while that machine is online.
     */
    fun candidates(machines: List<Machine>, preferredId: String?, explicit: Boolean, now: Instant): List<Machine> {
        val online = machines.filter { it.online(now) }
        if (explicit && preferredId != null) return online.filter { it.id == preferredId }
        val sorted = online.filter { it.compatible }
            .sortedWith(compareBy<Machine> { it.name.lowercase() }.thenBy { it.id })
        val preferred = sorted.firstOrNull { it.id == preferredId } ?: return sorted
        return listOf(preferred) + (sorted - preferred)
    }
}

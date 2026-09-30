package com.dbpprt.dieter.core.machines

import com.dbpprt.dieter.api.gateway.v1.CompatibilityStatus
import com.dbpprt.dieter.api.gateway.v1.Daemon
import com.dbpprt.dieter.api.gateway.v1.RemoteDesktopPresence
import com.dbpprt.dieter.core.runtime.Timestamps
import kotlin.time.Duration
import kotlin.time.Duration.Companion.seconds
import kotlin.time.Instant

/** One enrolled daemon as the gateway reports it. */
data class Machine(
    val id: String,
    val name: String,
    /** The gateway's tunnel flag; combined with the presence lease in [online]. */
    val serverOnline: Boolean,
    val lastSeenAt: String,
    val releaseVersion: String,
    val minimumReleaseVersion: String,
    val compatibility: CompatibilityStatus,
    val generation: Long,
    val remoteDesktop: RemoteDesktopPresence?,
) {
    val compatible: Boolean get() = compatibility == CompatibilityStatus.COMPATIBILITY_STATUS_COMPATIBLE

    fun online(now: Instant): Boolean = MachinePresence.online(serverOnline, lastSeenAt, now)

    val incompatibilityDescription: String?
        get() = if (compatible) {
            null
        } else {
            "Update required · Dieter ${releaseVersion.ifEmpty { "unknown" }} (requires ${minimumReleaseVersion.ifEmpty { "a newer release" }})"
        }

    companion object {
        fun from(daemon: Daemon) = Machine(
            id = daemon.id, name = daemon.name.ifBlank { daemon.id }, serverOnline = daemon.online,
            lastSeenAt = daemon.last_seen_at, releaseVersion = daemon.release_version,
            minimumReleaseVersion = daemon.minimum_release_version, compatibility = daemon.compatibility,
            generation = daemon.generation, remoteDesktop = daemon.remote_desktop,
        )
    }
}

/**
 * A daemon's presence is a 30 s lease renewed by its tunnel heartbeat. The
 * gateway's online flag alone can be stale; an expired lease means offline.
 */
object MachinePresence {
    val OFFLINE_AFTER: Duration = 30.seconds

    fun online(serverOnline: Boolean, lastSeenAt: String, now: Instant): Boolean {
        if (!serverOnline) return false
        val seen = Timestamps.parse(lastSeenAt) ?: return true
        val age = now - seen
        return age >= Duration.ZERO && age < OFFLINE_AFTER
    }

    /** When the next online machine's lease expires, for re-evaluating presence. */
    fun nextExpiry(machines: List<Machine>, now: Instant): Instant? = machines
        .filter { it.serverOnline }
        .mapNotNull { Timestamps.parse(it.lastSeenAt)?.plus(OFFLINE_AFTER) }
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

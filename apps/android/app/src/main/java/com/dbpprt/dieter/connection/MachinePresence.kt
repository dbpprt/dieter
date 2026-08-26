package com.dbpprt.dieter.connection

import java.time.Instant

/** The gateway already applies the daemon heartbeat lease; its presence bit is authoritative. */
internal fun machinePresenceOnline(
    serverOnline: Boolean,
    @Suppress("UNUSED_PARAMETER")
    lastSeenAt: String,
    @Suppress("UNUSED_PARAMETER")
    nowMs: Long = System.currentTimeMillis(),
): Boolean = serverOnline

internal fun machinePresenceAgeLabel(lastSeenAt: String, nowMs: Long = System.currentTimeMillis()): String? {
    val seenAtMs = runCatching { Instant.parse(lastSeenAt).toEpochMilli() }.getOrNull() ?: return null
    val seconds = ((nowMs - seenAtMs).coerceAtLeast(0L) / 1_000L)
    return when {
        seconds < 60L -> "${seconds}s ago"
        seconds < 3_600L -> "${seconds / 60L}m ago"
        seconds < 86_400L -> "${seconds / 3_600L}h ago"
        else -> "${seconds / 86_400L}d ago"
    }
}

package com.dbpprt.dieter.connection

import java.time.Instant

internal const val MACHINE_OFFLINE_AFTER_MS = 30_000L

internal fun machinePresenceOnline(
    serverOnline: Boolean,
    lastSeenAt: String,
    nowMs: Long = System.currentTimeMillis(),
): Boolean {
    if (!serverOnline) return false
    val seenAtMs = runCatching { Instant.parse(lastSeenAt).toEpochMilli() }.getOrNull() ?: return true
    val age = nowMs - seenAtMs
    return age >= 0 && age < MACHINE_OFFLINE_AFTER_MS
}

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

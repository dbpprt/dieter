package com.dbpprt.dieter.connection

import com.dbpprt.dieter.v1.PeerSyncDiagnostic
import java.time.Instant

private const val PEER_ISSUE_MAX_AGE_MS = 5 * 60_000L

/** Keep parity with Store.PeerSyncDiagnostic.IsCurrentIssue. Presence comes
 * from the authenticated directory, not the name of the reporting replica. */
internal fun PeerSyncDiagnostic.isCurrentIssue(online: Boolean, nowMs: Long): Boolean {
    if (failureCode.isEmpty()) return false
    if (recordId.isNotEmpty() || recordKind.isNotEmpty() || field.isNotEmpty()) return true
    return when (failureCode) {
        "Canceled", "canceled" -> false
        "Unavailable", "unavailable", "DeadlineExceeded", "deadline", "ResourceExhausted", "Aborted" -> {
            val attempt = runCatching { Instant.parse(lastAttemptAt).toEpochMilli() }.getOrNull()
            online && attempt != null && nowMs >= attempt && nowMs - attempt < PEER_ISSUE_MAX_AGE_MS
        }
        else -> true
    }
}

internal fun peerSyncWarnings(state: DieterConnectionState, nowMs: Long = System.currentTimeMillis()): List<String> {
    // The connection UI already explains cached/offline state. Old diagnostics
    // must not masquerade as observations made during a disconnected session.
    if (state.phase != ConnectionPhase.CONNECTED) return emptyList()
    val machines = state.endpointConnections.associateBy { it.daemonId }
    val reporters = state.endpointConnections.associateBy { it.id }
    return state.peerSyncIssues.flatMap { (source, issues) ->
        val reporter = reporters[source]?.takeIf { it.online } ?: return@flatMap emptyList()
        issues.filter { it.isCurrentIssue(machines[it.peerId]?.online == true, nowMs) }.map { issue ->
            val peer = machines[issue.peerId]?.label ?: "another machine"
            if (issue.recordId.isNotEmpty() || issue.recordKind.isNotEmpty() || issue.field.isNotEmpty()) {
                "Shared updates between ${reporter.label} and $peer are blocked by a rejected record."
            } else {
                "Shared updates between ${reporter.label} and $peer are delayed."
            }
        }
    }.distinct()
}

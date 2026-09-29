package com.dbpprt.dieter.connection

import com.dbpprt.dieter.v1.PeerSyncDiagnostic
import org.junit.Assert.*
import org.junit.Test
import java.time.Instant

class PeerSyncHealthTest {
    private val now = Instant.parse("2026-09-28T12:00:00Z").toEpochMilli()
    private fun issue(code: String = "DeadlineExceeded", ageMs: Long = 0, record: String = "") =
        PeerSyncDiagnostic.newBuilder().setPeerId("laptop").setFailureCode(code)
            .setLastAttemptAt(Instant.ofEpochMilli(now - ageMs).toString()).setRecordId(record).build()
    private fun state(issue: PeerSyncDiagnostic = issue(), peerOnline: Boolean = false) = DieterConnectionState(
        desiredConnected = true, backgroundSyncMode = BackgroundSyncMode.LIVE, activeGatewayId = "gateway",
        configuredConnections = emptyList(), phase = ConnectionPhase.CONNECTED,
        endpointConnections = listOf(
            EndpointConnection("gateway#desktop", "Desktop", "", daemonId = "desktop"),
            EndpointConnection("gateway#laptop", "Laptop", "", daemonId = "laptop", online = peerOnline),
        ),
        peerSyncIssues = mapOf("gateway#desktop" to listOf(issue)),
    )

    @Test fun offlineLaptopsDoNotWarnAgainstHealthyReporter() {
        assertTrue(peerSyncWarnings(state(), now).isEmpty())
        val warning = peerSyncWarnings(state(peerOnline = true), now).single()
        assertTrue(warning.contains("Desktop and Laptop"))
    }

    @Test fun expiredAndCancelledTransportFailuresAreNotCurrentProblems() {
        assertTrue(peerSyncWarnings(state(issue(ageMs = 300_000), true), now).isEmpty())
        assertTrue(peerSyncWarnings(state(issue("canceled"), true), now).isEmpty())
        assertTrue(peerSyncWarnings(state(issue(ageMs = -1), true), now).isEmpty())
        assertFalse(peerSyncWarnings(state(issue(ageMs = 299_999), true), now).isEmpty())
    }

    @Test fun recordAndAuthorizationFailuresRemainVisibleUntilRecovery() {
        val blocked = state(issue("invalid-record", 86_400_000, "b_one.retired"))
        assertTrue(peerSyncWarnings(blocked, now).single().contains("rejected record"))
        assertFalse(peerSyncWarnings(state(issue("PermissionDenied", 86_400_000)), now).isEmpty())
        assertTrue(peerSyncWarnings(blocked.copy(peerSyncIssues = emptyMap()), now).isEmpty())
    }

    @Test fun cachedStateDoesNotKeepLiveWarningsAfterConnectionLoss() {
        assertTrue(peerSyncWarnings(state(peerOnline = true).copy(phase = ConnectionPhase.RECONNECTING), now).isEmpty())
        val absentPeer = state(peerOnline = true).let { it.copy(endpointConnections = it.endpointConnections.take(1)) }
        assertTrue(peerSyncWarnings(absentPeer, now).isEmpty())
    }
}

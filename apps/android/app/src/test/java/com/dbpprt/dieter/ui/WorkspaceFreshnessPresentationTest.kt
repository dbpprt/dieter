package com.dbpprt.dieter.ui

import com.dbpprt.dieter.connection.ConnectionPhase
import com.dbpprt.dieter.connection.EndpointConnection
import com.dbpprt.dieter.connection.EndpointPhase
import com.dbpprt.dieter.connection.ProjectHost
import com.dbpprt.dieter.v1.Project
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class WorkspaceFreshnessPresentationTest {
    @Test
    fun connectionPhasesDescribeRecoveryInsteadOfCollapsingToOffline() {
        assertEquals("Connecting", connectionStatusPresentation(ConnectionPhase.CONNECTING).label)
        assertEquals("Syncing", connectionStatusPresentation(ConnectionPhase.SYNCING).label)
        assertEquals("Reconnecting", connectionStatusPresentation(ConnectionPhase.RECONNECTING).label)
        assertEquals("Offline", connectionStatusPresentation(ConnectionPhase.STOPPED).label)
        assertTrue(connectionStatusPresentation(ConnectionPhase.RECONNECTING).working)
        assertFalse(connectionStatusPresentation(ConnectionPhase.STOPPED).working)
    }

    @Test
    fun liveRefreshKeepsCachedWorkspaceInteractiveWhileRealOutagesMuteIt() {
        val refreshing = workspaceSurfaceTreatment(
            showsSynchronizedWorkspace = true,
            hasCachedWorkspace = true,
            phase = ConnectionPhase.SYNCING,
        )
        assertEquals(WorkspaceSurfaceTreatment.REFRESHING, refreshing)
        assertTrue(refreshing.showsNotice)
        assertFalse(refreshing.blocksInteraction)

        val unavailable = workspaceSurfaceTreatment(
            showsSynchronizedWorkspace = true,
            hasCachedWorkspace = true,
            phase = ConnectionPhase.RECONNECTING,
        )
        assertEquals(WorkspaceSurfaceTreatment.UNAVAILABLE, unavailable)
        assertTrue(unavailable.blocksInteraction)

        assertEquals(
            WorkspaceSurfaceTreatment.CURRENT,
            workspaceSurfaceTreatment(true, hasCachedWorkspace = false, ConnectionPhase.SYNCING),
        )
        assertEquals(
            WorkspaceSurfaceTreatment.CURRENT,
            workspaceSurfaceTreatment(false, hasCachedWorkspace = true, ConnectionPhase.SYNCING),
        )
    }

    @Test
    fun firstSyncReplacesTheEmptyWorkspaceUntilLiveDataArrives() {
        assertTrue(
            shouldShowInitialWorkspaceSync(
                showsSynchronizedWorkspace = true,
                hasCachedWorkspace = false,
                loading = true,
                desiredConnected = true,
                phase = ConnectionPhase.SYNCING,
            ),
        )
        assertTrue(
            shouldShowInitialWorkspaceSync(
                true,
                hasCachedWorkspace = false,
                loading = false,
                desiredConnected = true,
                phase = ConnectionPhase.UNAVAILABLE,
            ),
        )
        assertFalse(
            shouldShowInitialWorkspaceSync(
                true,
                hasCachedWorkspace = true,
                loading = true,
                desiredConnected = true,
                phase = ConnectionPhase.SYNCING,
            ),
        )
        assertFalse(
            shouldShowInitialWorkspaceSync(
                true,
                hasCachedWorkspace = false,
                loading = false,
                desiredConnected = true,
                phase = ConnectionPhase.CONNECTED,
            ),
        )

        val syncing = initialWorkspaceSyncPresentation(ConnectionPhase.SYNCING)
        assertEquals("Syncing your workspace", syncing.title)
        assertTrue(syncing.working)
    }

    @Test
    fun workspaceNoticeMatchesTheQuietMacPresentation() {
        val syncing = workspaceStatusPresentation(ConnectionPhase.SYNCING, showingCachedData = true)
        assertEquals("Refreshing workspace", syncing.title)
        assertEquals("Your current workspace stays available while changes load.", syncing.detail)
        assertTrue(syncing.working)
        assertFalse(syncing.usesOfflineAccent)

        val offline = workspaceStatusPresentation(ConnectionPhase.UNAVAILABLE, showingCachedData = true)
        assertEquals("Working from cached data", offline.title)
        assertFalse(offline.working)
        assertTrue(offline.usesOfflineAccent)
    }

    @Test
    fun cachedMachinePresenceIsNotPresentedAsLiveDuringReconnect() {
        val project = Project.newBuilder().setId("project-one").build()
        val state = DieterUiState(
            connectionPhase = ConnectionPhase.RECONNECTING,
            projects = listOf(project),
            projectHosts = mapOf(
                project.id to ProjectHost("machine-one", "daemon-one", "Studio Mac", online = true),
            ),
            endpointConnections = listOf(
                EndpointConnection(
                    id = "machine-one",
                    label = "Studio Mac",
                    address = "https://example.test",
                    phase = EndpointPhase.CONNECTED,
                    detail = "Gateway · 12 ms",
                    latencyMs = 12,
                    online = true,
                    daemonId = "daemon-one",
                ),
            ),
        )

        assertFalse(state.presentedProjectHosts.getValue(project.id).online)
        assertFalse(state.presentedEndpointConnections.single().online)
        assertEquals(EndpointPhase.PENDING, state.presentedEndpointConnections.single().phase)
        assertFalse(projectScopedNavigationEnabled(state))

        val live = state.copy(connectionPhase = ConnectionPhase.CONNECTED)
        assertTrue(live.presentedProjectHosts.getValue(project.id).online)
        assertEquals(EndpointPhase.CONNECTED, live.presentedEndpointConnections.single().phase)
        assertTrue(projectScopedNavigationEnabled(live))
    }
}

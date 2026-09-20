package com.dbpprt.dieter.connection

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ProjectRoutingTest {
    private val hosts = mapOf(
        "project-a" to ProjectReplica("gateway#mac", "mac", "Studio Mac", true),
        "project-b" to ProjectReplica("gateway#server", "server", "Build server", true),
    )

    @Test
    fun selectingUnseenProjectUsesAnAvailableReplica() {
        assertEquals("gateway#server", endpointForProjectSelection("project-b", "gateway#mac", hosts))
    }

    @Test
    fun offlineSnapshotSourceDoesNotDisplaceCurrentReplica() {
        val offline = mapOf("project-a" to hosts.getValue("project-a").copy(online = false))
        assertNull(endpointForProjectSelection("project-a", "gateway#server", offline))
    }

    @Test
    fun selectingProjectOnCurrentDaemonDoesNotReconnect() {
        assertNull(endpointForProjectSelection("project-a", "gateway#mac", hosts))
        assertNull(endpointForProjectSelection("unknown", "gateway#mac", hosts))
    }

    @Test
    fun daemonNamesDoNotCollideAcrossGateways() {
        val duplicateDaemon = mapOf(
            "other-project" to ProjectReplica("other-gateway#mac", "mac", "Studio Mac", true),
        )
        assertEquals(
            "other-gateway#mac",
            endpointForProjectSelection("other-project", "gateway#mac", duplicateDaemon),
        )
    }

    @Test
    fun currentSynchronizedRouteStaysUsableWhenAdvisoryPresenceLags() {
        assertTrue(projectRouteIsReady("gateway#mac", "gateway#mac", ConnectionPhase.SYNCING))
        assertTrue(projectRouteIsReady("gateway#mac", "gateway#mac", ConnectionPhase.CONNECTED))
    }

    @Test
    fun insecureConnectionsAreLimitedToLoopbackHosts() {
        assertEquals(true, isLoopbackHost("localhost"))
        assertEquals(true, isLoopbackHost("127.0.0.1"))
        assertEquals(true, isLoopbackHost("::1"))
        assertEquals(false, isLoopbackHost("gateway.example"))
    }
}

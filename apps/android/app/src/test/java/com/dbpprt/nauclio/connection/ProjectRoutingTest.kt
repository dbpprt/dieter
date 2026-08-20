package com.dbpprt.nauclio.connection

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ProjectRoutingTest {
    private val hosts = mapOf(
        "project-a" to ProjectHost("gateway#mac", "mac", "Studio Mac", true),
        "project-b" to ProjectHost("gateway#server", "server", "Build server", true),
    )

    @Test
    fun selectingRemoteProjectSwitchesToOwningDaemon() {
        assertEquals("server", daemonForProjectSelection("project-b", "mac", hosts))
    }

    @Test
    fun selectingProjectOnCurrentDaemonDoesNotReconnect() {
        assertNull(daemonForProjectSelection("project-a", "mac", hosts))
        assertNull(daemonForProjectSelection("unknown", "mac", hosts))
    }
}

package com.dbpprt.dieter.ui

import com.dbpprt.dieter.connection.ConnectionPhase
import com.dbpprt.dieter.connection.ProjectReplica
import com.dbpprt.dieter.v1.Project
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ProjectScopedNavigationTest {
    private val project = Project.newBuilder().setId("project").setName("Project").build()

    @Test
    fun `files and schedules stay muted when every known project host is offline`() {
        val offline = DieterUiState(
            projects = listOf(project),
            projectReplicas = mapOf(project.id to ProjectReplica("endpoint", "daemon", "machine", false)),
        )
        val online = offline.copy(
            connectionPhase = ConnectionPhase.CONNECTED,
            projectReplicas = mapOf(project.id to ProjectReplica("endpoint", "daemon", "machine", true)),
        )

        assertFalse(projectScopedNavigationEnabled(offline))
        assertTrue(projectScopedNavigationEnabled(online))
    }
}

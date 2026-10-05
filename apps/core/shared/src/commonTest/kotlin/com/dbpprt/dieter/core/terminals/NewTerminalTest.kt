package com.dbpprt.dieter.core.terminals

import com.dbpprt.dieter.api.v1.Project
import com.dbpprt.dieter.core.runtime.CoreException
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class NewTerminalTest {
    private val project = Project(id = "p", name = "Dieter", path = "/Users/me/Development/dieter")

    @Test fun theFormStartsInTheProjectDirectory() {
        val form = NewTerminal.initial(project, "Shell")
        assertEquals(NewTerminal("p", "Shell", NewTerminal.DEFAULT_SHELL, project.path), form)
        assertTrue(form.ready)
        assertFalse(form.copy(name = " ").ready)
        assertEquals("/srv/other", form.project(Project(id = "q", path = "/srv/other")).workingDirectory)
        assertFalse(NewTerminal.initial(null, "Shell").ready)
    }

    @Test fun projectDetailsNameTheHostAndItsAvailability() {
        assertEquals("Studio · ~/Development/dieter", NewTerminal.projectDetails(project, "Studio", hostOnline = true))
        assertEquals("Studio (offline) · ~/Development/dieter", NewTerminal.projectDetails(project, "Studio", hostOnline = false))
        assertEquals("Unknown machine · ~/Development/dieter", NewTerminal.projectDetails(project, " ", hostOnline = null))
        assertEquals("Unknown machine", NewTerminal.projectDetails(project.copy(path = ""), null, hostOnline = null))
    }

    @Test fun projectChoicesSortByNameIgnoringCaseThenById() {
        val projects = listOf(Project(id = "b", name = "dieter"), Project(id = "c", name = "Atlas"), Project(id = "a", name = "Dieter"))
        assertEquals(listOf("c", "a", "b"), NewTerminal.projects(projects).map { it.id })
    }

    @Test fun newTerminalsStartOnTheChosenMachineElseAReachableOne() {
        assertEquals("chosen", TerminalScope.creationMachine("chosen", listOf("local", "other")))
        assertEquals("local", TerminalScope.creationMachine(null, listOf("local", "other")))
        assertEquals("No machine is reachable.", assertFailsWith<CoreException> { TerminalScope.creationMachine(null, emptyList()) }.message)
    }

    @Test fun surfacesCountTheirPersistentSessions() {
        assertEquals("Syncing persistent sessions…", TerminalsView.status(loading = true, count = 2, streamConnected = true))
        assertEquals("Daemon-owned · survive app disconnects", TerminalsView.status(loading = false, count = 0, streamConnected = true))
        assertEquals("1 persistent session · live", TerminalsView.status(loading = false, count = 1, streamConnected = true))
        assertEquals("3 persistent sessions · reconnecting", TerminalsView.status(loading = false, count = 3, streamConnected = false))
    }
}

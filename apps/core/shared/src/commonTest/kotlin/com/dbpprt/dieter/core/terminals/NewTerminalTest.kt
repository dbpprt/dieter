package com.dbpprt.dieter.core.terminals

import com.dbpprt.dieter.api.v1.Project
import kotlin.test.Test
import kotlin.test.assertEquals
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
}

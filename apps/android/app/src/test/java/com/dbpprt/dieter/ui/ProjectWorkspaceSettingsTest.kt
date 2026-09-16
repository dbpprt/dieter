package com.dbpprt.dieter.ui

import com.dbpprt.dieter.v1.ValidationCommand
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ProjectWorkspaceSettingsTest {
    @Test
    fun validationCommandRoundTripsExactArgvEnvironmentAndTimeout() {
        val draft = ValidationCommandDraft(
            name = "Go checks",
            executable = " go ",
            arguments = "test\n./...\n-race",
            workingDirectory = " backend ",
            environment = "CGO_ENABLED=1\nGOFLAGS=-count=1",
            timeoutSeconds = "900",
        )

        assertNull(draft.validationError())
        val value = draft.value()
        assertEquals("go", value.executable)
        assertEquals(listOf("test", "./...", "-race"), value.argumentsList)
        assertEquals("backend", value.workingDirectory)
        assertEquals(mapOf("CGO_ENABLED" to "1", "GOFLAGS" to "-count=1"), value.environmentMap)
        assertEquals(900, value.timeoutSeconds)

        val restored = ValidationCommandDraft(value)
        assertEquals("test\n./...\n-race", restored.arguments)
        assertEquals("CGO_ENABLED=1\nGOFLAGS=-count=1", restored.environment)
    }

    @Test
    fun invalidWorkspaceEscapesAndEnvironmentLinesAreRejected() {
        assertTrue(ValidationCommandDraft(executable = "go", workingDirectory = "../outside").validationError() != null)
        assertTrue(ValidationCommandDraft(executable = "go", environment = "BROKEN").validationError() != null)
        assertTrue(ValidationCommandDraft(executable = "go", timeoutSeconds = "3601").validationError() != null)
        assertTrue(validationCommandsError(listOf(ValidationCommandDraft())) != null)
    }

    @Test
    fun protobufDefaultsProduceAnEditableDraft() {
        val value = ValidationCommand.newBuilder().setExecutable("just").build()
        val draft = ValidationCommandDraft(value)
        assertEquals("just", draft.executable)
        assertEquals("0", draft.timeoutSeconds)
    }
}

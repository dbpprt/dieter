package com.dbpprt.dieter.core.presentation

import com.dbpprt.dieter.api.v1.MessagePart
import com.dbpprt.dieter.api.v1.ToolOutput
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue
import okio.ByteString.Companion.encodeUtf8

class ToolsTest {
    private fun tool(state: String = "output-available", type: String = "dynamic-tool", error: String = "") =
        MessagePart(type = type, tool_name = "exec_command", tool_call_id = "call", state = state, error_text = error)

    @Test
    fun rowsNameApprovalsDenialsAndFailures() {
        assertEquals("Approval requested", Tools.statusLabel(Tools.status(tool(state = "approval-requested"))))
        assertEquals("Tool denied", Tools.statusLabel(Tools.status(tool(state = "output-denied"))))
        assertEquals("Tool failed", Tools.statusLabel(Tools.status(tool(state = "output-error"))))
        assertEquals("Tool failed", Tools.statusLabel(Tools.status(tool(error = "exit status 1"))), "an error fails the call whatever its state")
        assertNull(Tools.statusLabel(Tools.status(tool())))
        assertNull(Tools.statusLabel(Tools.status(tool(state = "input-available"))))
    }

    @Test
    fun expandedCallsShowTheirErrorInputAndOutputFromTheFullPayloadOnceLoaded() {
        val part = tool(error = "exit status 1").copy(input_json = " {\"cmd\":\"ls\"} \n".encodeUtf8(), output_json = "a.txt".encodeUtf8(), has_input = true, has_output = true)
        assertTrue(Tools.hasPayload(part))
        assertEquals(
            listOf(ToolDetail("Error", "exit status 1", error = true), ToolDetail("Input", "{\"cmd\":\"ls\"}"), ToolDetail("Output", "a.txt")),
            Tools.details(part),
        )
        val loaded = ToolOutput(input_json = "{\"cmd\":\"ls -la\"}".encodeUtf8(), output_json = "a.txt\nb.txt\n".encodeUtf8(), error_text = "killed")
        assertEquals(
            listOf(ToolDetail("Error", "killed", error = true), ToolDetail("Input", "{\"cmd\":\"ls -la\"}"), ToolDetail("Output", "a.txt\nb.txt")),
            Tools.details(part, loaded),
        )
        assertEquals("exit status 1", Tools.details(part, loaded.copy(error_text = " ")).first().text, "a loaded payload without an error keeps the transcript's")
    }

    @Test
    fun callsWithoutAPayloadShowNothingToExpand() {
        val bare = tool().copy(input_json = "  ".encodeUtf8())
        assertFalse(Tools.hasPayload(bare))
        assertTrue(Tools.details(bare).isEmpty())
        assertEquals("No additional payload", Tools.NO_DETAILS)
    }
}

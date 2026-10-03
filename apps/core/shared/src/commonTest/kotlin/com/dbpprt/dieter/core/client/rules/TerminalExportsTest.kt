package com.dbpprt.dieter.core.client.rules

import com.dbpprt.dieter.client.v1.TerminalKey
import com.dbpprt.dieter.core.terminals.TerminalsView
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class TerminalExportsTest {
    @Test
    fun keysAreAddressedByTheirContractValue() {
        assertEquals("\u001b[A", TerminalExports.key(TerminalKey.TERMINAL_KEY_UP.value, shift = false, alt = false, control = false, applicationCursor = false).decodeToString())
        assertEquals("\u001bOA", TerminalExports.key(TerminalKey.TERMINAL_KEY_UP.value, shift = false, alt = false, control = false, applicationCursor = true).decodeToString())
        assertEquals("\u001b[1;5D", TerminalExports.key(TerminalKey.TERMINAL_KEY_LEFT.value, shift = false, alt = false, control = true, applicationCursor = false).decodeToString())
        assertEquals("", TerminalExports.key(9999, shift = false, alt = false, control = false, applicationCursor = false).decodeToString(), "an unknown key sends nothing")
        assertEquals(TerminalKey.TERMINAL_KEY_F7.value, TerminalExports.functionKey(7))
        assertEquals(0, TerminalExports.functionKey(13))
        assertEquals(listOf<Byte>(3), TerminalExports.control("c".encodeToByteArray())?.toList())
        assertNull(TerminalExports.control("cd".encodeToByteArray()))
    }

    @Test
    fun statusFollowsTheStreamWhileRunningAndTheExitCodeAfter() {
        assertEquals("Connected", TerminalExports.status("running", exitCode = 0, hasExitCode = false, streamConnected = true))
        assertEquals("Reconnecting", TerminalExports.status("running", exitCode = 0, hasExitCode = false, streamConnected = false))
        assertEquals("Exited 0", TerminalExports.status("exited", exitCode = 0, hasExitCode = true, streamConnected = true))
        assertEquals("Exited 130", TerminalExports.status("exited", exitCode = 130, hasExitCode = true, streamConnected = false))
        assertEquals("Exited", TerminalExports.status("exited", exitCode = 0, hasExitCode = false, streamConnected = false))
        assertEquals("Exited 2", TerminalsView.terminalStatus("exited", exitCode = 2, streamConnected = true), "Android calls the rule directly")
    }
}

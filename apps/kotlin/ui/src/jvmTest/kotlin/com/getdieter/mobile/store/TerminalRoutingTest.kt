package com.getdieter.mobile.store

import com.getdieter.client.v1.*
import com.getdieter.mobile.navigation.*
import kotlin.test.*
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.*

@OptIn(ExperimentalCoroutinesApi::class)
class TerminalRoutingTest {
    @Test
    fun overviewCommandsReachOnlyTheOverviewEvenAboveAConversationPane() = runTest {
        val core = FakeMobileCore()
        val store = MobileStore(core, StandardTestDispatcher(testScheduler))
        try {
            store.openConversation("card")
            store.push(MobileRoute.Pane("card", CardPane.TERMINAL))
            runCurrent()
            val cardScope = core.sentOf { it.terminals }.first().scope
            assertNotNull(core.sentOf { it.terminals }.last().load)

            store.push(MobileRoute.Tool(ToolPage.TERMINALS))
            store.push(MobileRoute.TerminalSession("machine|shell"))
            runCurrent()
            val overviewScope = core.sentOf { it.terminal_overview }.first().scope
            assertNotEquals(cardScope, overviewScope)
            assertTrue(core.observing(Slice.SLICE_TERMINAL_OVERVIEW, overviewScope))
            assertFalse(core.observing(Slice.SLICE_TERMINALS, overviewScope))
            core.sent.clear()

            store.terminals.command(TerminalsCommand(active = Toggle(true)))
            store.terminals.input(byteArrayOf(1))
            store.terminals.grid(80, 24)
            store.setForeground(false)
            store.setForeground(true)
            runCurrent()
            val commands = core.sentOf { it.terminals }
            assertEquals(listOf(true, false, true), commands.mapNotNull { it.active?.on })
            assertTrue(commands.all { it.scope == overviewScope })
            assertNotNull(commands.single { it.input != null }.input)
            assertEquals(TerminalGrid(80, 24), commands.single { it.grid != null }.grid)

            // Disposal captures the surface it belonged to, even after navigation changed.
            store.pop()
            store.pop()
            store.terminals.command(TerminalsCommand(active = Toggle(false)), inCard = false)
            store.terminals.command(TerminalsCommand(active = Toggle(true)))
            store.terminals.input(byteArrayOf(2))
            runCurrent()
            assertEquals(overviewScope, core.sentOf { it.terminals }.takeLast(3).first().scope)
            assertTrue(core.sentOf { it.terminals }.takeLast(2).all { it.scope == cardScope })
        } finally {
            store.close()
        }
    }
}

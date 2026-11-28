package com.getdieter.core.board

import com.getdieter.core.runtime.CoreException
import com.getdieter.core.runtime.FailureKind
import com.getdieter.core.store.WorkspaceStore
import com.getdieter.core.testing.offlineSessions
import com.getdieter.core.testing.unreachableChoice
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNotEquals
import kotlinx.coroutines.test.runTest

/** Card mutations on a client whose machines are unreachable, so every routed call fails. */
class BoardOperationsTest {
    private val store = WorkspaceStore()
    private val board = BoardOperations(offlineSessions(), store, unreachableChoice(store))

    /**
     * A conversation that just started runs on its machine before the account view lists its card.
     * Stopping it, or sending a queued message now, must still reach that machine.
     */
    @Test
    fun stoppingACardTheAccountHasNotListedYetUsesItsConversationsMachine() = runTest {
        val unknown = assertFailsWith<CoreException> { board.cancel("c_new") }
        assertEquals("The card is no longer available.", unknown.message)

        // Routed to the known machine: the failure is that machine being unreachable here.
        val routed = assertFailsWith<CoreException> { board.cancel("c_new", knownOwner = "d1") }
        assertEquals(FailureKind.TRANSIENT, routed.kind)
        assertNotEquals("The card is no longer available.", routed.message)
        assertEquals(emptyMap(), board.view.value.operations, "the stop no longer runs")
    }
}

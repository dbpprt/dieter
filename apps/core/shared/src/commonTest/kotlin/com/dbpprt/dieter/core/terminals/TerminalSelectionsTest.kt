package com.dbpprt.dieter.core.terminals

import com.dbpprt.dieter.core.storage.CoreStorage
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import okio.Path.Companion.toPath
import okio.fakefilesystem.FakeFileSystem

class TerminalSelectionsTest {
    private val storage = CoreStorage(FakeFileSystem(), "/state".toPath())

    @Test
    fun theLeastRecentChoiceIsEvictedAlsoAfterARestart() {
        val first = TerminalSelections { storage }
        repeat(64) { first.set("surface$it", "t$it") }

        // A restarted app continues the order instead of starting it over.
        val restarted = TerminalSelections { storage }
        restarted.set("new", "a")
        restarted.set("newer", "b")
        assertEquals("a", restarted.get("new"))
        assertEquals("b", restarted.get("newer"))
        assertNull(restarted.get("surface0"))
        assertNull(restarted.get("surface1"))
        assertEquals("t2", restarted.get("surface2"))
        assertEquals("a", TerminalSelections { storage }.get("new"))
    }
}

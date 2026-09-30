package com.dbpprt.dieter.core

import com.dbpprt.dieter.core.files.FileConflictException
import com.dbpprt.dieter.core.files.FilesTarget
import com.dbpprt.dieter.core.testing.EndToEnd
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** FILES scenario: a checkout is browsed and edited; a stale save is a conflict that keeps the edits. */
class FilesEndToEndTest : EndToEnd() {
    @AfterTest
    fun tearDown() = tearDownRuntimes()

    @Test
    fun editsSaveByRevisionAndConflictsKeepTheDraft() = e2e {
        val fixture = fixture()
        val runtime = runtime(fixture)
        runtime.awaitConnected()
        runtime.awaitLoaded(fixture)
        val checkout = runtime.workspace.state.value.project(fixture.projectId)!!.checkouts.first()
        val files = runtime.files()
        val other = runtime.files()
        val target = FilesTarget(fixture.daemonId, fixture.projectId, checkout.id)
        runtime.onCore { files.bind(target); other.bind(target) }
        assertTrue(runtime.onCore { files.load("") })
        assertTrue(files.view.value.entries.any { it.name == "README.md" })

        runtime.onCore { files.create("notes", directory = true) }
        assertTrue(runtime.onCore { files.navigate("notes") })
        runtime.onCore { files.create("todo.txt", directory = false) }
        runtime.onCore { files.open("notes/todo.txt") }
        assertEquals("", files.view.value.document?.content)
        assertEquals("", files.view.value.draft)
        assertFalse(files.view.value.dirty)
        files.edit("first line\n")
        assertTrue(files.view.value.dirty)
        val saved = runtime.onCore { files.save() }!!
        assertEquals("first line\n", saved.content)
        assertFalse(files.view.value.dirty)

        // Another editor saves first; our stale save is a conflict and the draft is kept.
        runtime.onCore { other.open("notes/todo.txt") }
        runtime.onCore { other.save("from elsewhere\n") }
        files.edit("my edit\n")
        assertFailsWith<FileConflictException> { runtime.onCore { files.save() } }
        assertTrue(files.view.value.conflict)
        assertEquals("my edit\n", files.view.value.draft)
        assertTrue(files.view.value.dirty)
        runtime.onCore { files.reload() }
        assertEquals("from elsewhere\n", files.view.value.document?.content)
        assertEquals("from elsewhere\n", files.view.value.draft, "reloading takes the disk version")
        assertFalse(files.view.value.conflict)

        // Closing drops the document and draft for good; a later listing does not reopen it.
        files.edit("unsaved\n")
        runtime.onCore { files.close() }
        assertNull(files.view.value.document)
        assertEquals("", files.view.value.draft)
        assertTrue(runtime.onCore { files.load() })
        assertNull(files.view.value.document)
        runtime.onCore { files.open("notes/todo.txt") }

        assertTrue(runtime.onCore { files.goBack() })
        assertEquals("", files.view.value.directory)
        runtime.onCore { files.move("notes/todo.txt", "todo.txt") }
        assertNull(files.view.value.document, "moving the open file closes it")
        runtime.onCore { files.delete("notes", recursive = true) }
        assertTrue(files.view.value.entries.none { it.name == "notes" })
        assertTrue(files.view.value.entries.any { it.name == "todo.txt" })
    }
}

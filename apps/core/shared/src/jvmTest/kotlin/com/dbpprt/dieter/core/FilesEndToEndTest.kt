package com.dbpprt.dieter.core

import com.dbpprt.dieter.api.v1.CreateConversationRequest
import com.dbpprt.dieter.core.files.FileConflictException
import com.dbpprt.dieter.core.files.FilesTarget
import com.dbpprt.dieter.core.runtime.CoreException
import com.dbpprt.dieter.core.testing.EndToEnd
import com.dbpprt.dieter.core.testing.await
import java.io.File
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlin.time.Duration.Companion.seconds

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

        // Conversation image links name files on the remote workspace. The core resolves an
        // absolute file URL through GetWorkspace before ReadFile, so a native client never
        // interprets the path against its own filesystem.
        val local = runtime.createConversation(
            CreateConversationRequest(
                project_id = fixture.projectId, board_id = fixture.boardId, lane = "todo", title = "Workspace image", prompt = "later",
                defer_start = true, workspace_mode = "project",
            ),
            chat = false,
        )
        val cardId = runtime.outbox.view.await(45.seconds) { local.id in it.resolutions }.resolve(local.id)
        runtime.workspace.state.await(30.seconds) { it.card(cardId) != null }
        val image = File(checkout.path, "workspace-image.png")
        image.writeBytes(byteArrayOf(1, 2, 3, 4))
        runtime.onCore {
            files.bind(FilesTarget(fixture.daemonId, fixture.projectId, cardId = cardId))
            files.open("file://${image.absolutePath}")
        }
        assertEquals("workspace-image.png", files.view.value.selectedPath)
        assertEquals("workspace-image.png", files.view.value.document?.path)
        assertEquals(4L, files.view.value.document?.size)
        val outside = assertFailsWith<CoreException> { runtime.onCore { files.open("file:///elsewhere/secret.png") } }
        assertEquals("The image is outside this workspace.", outside.message)
    }
}

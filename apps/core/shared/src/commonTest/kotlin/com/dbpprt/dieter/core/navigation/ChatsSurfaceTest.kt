package com.dbpprt.dieter.core.navigation

import com.dbpprt.dieter.api.v1.Card
import com.dbpprt.dieter.api.v1.Project
import com.dbpprt.dieter.core.runtime.CoreException
import com.dbpprt.dieter.core.runtime.FailureKind
import com.dbpprt.dieter.core.store.WorkspaceView
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import okio.ByteString

class ChatsSurfaceTest {
    private val project = Project(id = "p", name = "Dieter")
    private val live = Card(id = "live", scope = "chat", project_id = "p", title = "Live chat", last_activity_at = "2026-09-01T00:00:00Z")
    private val old = Card(id = "old", scope = "chat", project_id = "p", title = "Old chat", archived = true, last_activity_at = "2026-08-01T00:00:00Z")
    private val navigation = MutableStateFlow<Map<String, ByteString>>(emptyMap())

    @Test
    fun archivedChatsLoadEachTimeTheyShowAndLeaveOnceRestored() = runTest {
        val workspace = MutableStateFlow(WorkspaceView(projects = listOf(project), chats = listOf(live)))
        var loads = 0
        val surface = ChatsSurface(workspace, navigation, backgroundScope) {
            loads++
            // A board card and a live chat are never listed as archived chats.
            listOf(old, old.copy(id = "card", board_id = "b"), live)
        }
        assertEquals(listOf("live"), surface.current().list.visible)
        surface.showArchived(true)
        assertTrue(surface.current().loading)
        runCurrent()
        val shown = surface.current()
        assertFalse(shown.loading)
        assertEquals(listOf("old"), shown.list.visible)
        assertEquals(listOf(old), shown.archivedChats)
        assertEquals(listOf("old"), shown.list.projects.single().chatIds)
        assertEquals(emptyList(), shown.list.pinned)

        workspace.value = workspace.value.copy(chats = listOf(live, old.copy(archived = false)))
        assertEquals(emptyList(), surface.current().list.visible, "a restored chat is live again")
        surface.showArchived(false)
        assertEquals(listOf("old", "live").sorted(), surface.current().list.visible.sorted())
        assertEquals(emptyList(), surface.current().archivedChats)
        surface.showArchived(true)
        runCurrent()
        assertEquals(2, loads, "each switch to archived chats loads them again")
        surface.reload()
        runCurrent()
        assertEquals(3, loads)
    }

    @Test
    fun aFailedLoadReportsWhy() = runTest {
        val surface = ChatsSurface(MutableStateFlow(WorkspaceView()), navigation, backgroundScope) { throw CoreException(FailureKind.TRANSIENT, "The machine is offline.") }
        surface.showArchived(true)
        runCurrent()
        assertEquals("The machine is offline.", surface.current().error)
        assertFalse(surface.current().loading)
        surface.showArchived(false)
        assertEquals(null, surface.current().error)
    }

    @Test
    fun theViewFollowsTheQuery() = runTest {
        val other = live.copy(id = "other", title = "Release notes", summary = "Ships the gateway")
        val surface = ChatsSurface(MutableStateFlow(WorkspaceView(projects = listOf(project), chats = listOf(live, other))), navigation, backgroundScope) { emptyList() }
        surface.search(" gateway ")
        val view = surface.view.first()
        assertEquals(" gateway ", view.target.query)
        assertEquals(listOf("other"), view.list.visible)
    }
}

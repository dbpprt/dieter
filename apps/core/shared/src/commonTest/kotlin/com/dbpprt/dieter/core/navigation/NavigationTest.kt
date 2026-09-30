package com.dbpprt.dieter.core.navigation

import com.dbpprt.dieter.api.v1.Card
import com.dbpprt.dieter.api.v1.KVEntry
import com.dbpprt.dieter.api.v1.PeerVersion
import com.dbpprt.dieter.core.platform.DaemonTokenSource
import com.dbpprt.dieter.core.platform.DirectTarget
import com.dbpprt.dieter.core.platform.GatewayAccess
import com.dbpprt.dieter.core.platform.RpcChannel
import com.dbpprt.dieter.core.platform.RpcTransport
import com.dbpprt.dieter.core.routing.RouteSelector
import com.dbpprt.dieter.core.routing.RoutingPolicy
import com.dbpprt.dieter.core.routing.WebRtcCooldown
import com.dbpprt.dieter.core.runtime.CoreException
import com.dbpprt.dieter.core.runtime.SilentLogger
import com.dbpprt.dieter.core.session.MachineSessions
import com.dbpprt.dieter.core.storage.CoreStorage
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import kotlin.time.Clock
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import okio.ByteString
import okio.ByteString.Companion.encodeUtf8
import okio.Path.Companion.toPath
import okio.fakefilesystem.FakeFileSystem

class NavigationTest {
    private object Offline : RpcTransport {
        override fun gateway(access: GatewayAccess): RpcChannel = error("offline")
        override fun relay(access: GatewayAccess, daemonId: String): RpcChannel = error("offline")
        override fun direct(target: DirectTarget, tokens: DaemonTokenSource): RpcChannel = error("offline")
    }

    private val fileSystem = FakeFileSystem()

    /** A namespace bound to an account but never connected: edits stay pending and project locally. */
    private fun offlineKv(account: String = "acct"): SharedKv {
        val storage = CoreStorage(fileSystem, "/state".toPath())
        storage.write("kv-active-navigation.pb", KvActive.ADAPTER.encode(KvActive(account = account)))
        val sessions = MachineSessions(RouteSelector(Offline, null, RoutingPolicy(false), WebRtcCooldown(Clock.System), SilentLogger), CoroutineScope(Dispatchers.Unconfined))
        return SharedKv("navigation", sessions, Clock.System, SilentLogger).also { it.bind(storage) }
    }

    private fun layout(kv: SharedKv) = NavigationLayout(kv.values.value)

    private fun position(parent: String, rank: String) = SharedKv.encodePosition(KvPosition(parent, rank))

    @Test
    fun foldersKeepSingleMembershipAndDeletionOnlyUnfiles() {
        val kv = offlineKv()
        val editor = NavigationEditor(kv)
        val work = editor.createFolder(FolderScope.PROJECTS, " Work ")
        assertFailsWith<CoreException> { editor.createFolder(FolderScope.PROJECTS, "work") }
        val home = editor.createFolder(FolderScope.PROJECTS, "Home")
        editor.moveToFolder(FolderScope.PROJECTS, "p1", work)
        editor.moveToFolder(FolderScope.PROJECTS, "p2", work)
        editor.moveToFolder(FolderScope.PROJECTS, "p1", home)
        var folders = layout(kv).folders(FolderScope.PROJECTS)
        assertEquals(listOf("Work", "Home"), folders.map { it.name })
        assertEquals(listOf("p2"), folders[0].itemIds)
        assertEquals(listOf("p1"), folders[1].itemIds)

        editor.renameFolder(FolderScope.PROJECTS, work, "Office")
        editor.setFolderExpanded(FolderScope.PROJECTS, work, false)
        editor.deleteFolder(FolderScope.PROJECTS, home)
        folders = layout(kv).folders(FolderScope.PROJECTS)
        assertEquals(listOf(NavigationFolder(work, "Office", listOf("p2"), expanded = false)), folders)
        assertEquals(listOf("p1", "p3"), layout(kv).unfiled(FolderScope.PROJECTS, listOf("p1", "p2", "p3")))
        assertEquals(12, kv.status.value.pending)
    }

    @Test
    fun recordsWrittenByOtherClientsKeepCollapsedMembershipAndOfflineItems() {
        val layout = NavigationLayout(mapOf(
            "projects-folder.mac-id.name" to "\"Research\"".encodeUtf8(),
            "projects-folder.mac-id.expanded" to "false".encodeUtf8(),
            "projects-item.offline-project.position" to position("mac-id", "a"),
            "projects-item.p1.position" to position("mac-id", "b"),
        ))
        val folder = layout.folders(FolderScope.PROJECTS).single()
        assertEquals(NavigationFolder("mac-id", "Research", listOf("offline-project", "p1"), expanded = false), folder)
        assertEquals(emptyList(), layout.folders(FolderScope.CHATS), "scopes never share folders")
        assertEquals(listOf("p2"), layout.unfiled(FolderScope.PROJECTS, listOf("p1", "p2")))
    }

    @Test
    fun folderNamesFoldCaseAndAccentsAndAreByteBounded() {
        val kv = offlineKv()
        val editor = NavigationEditor(kv)
        editor.createFolder(FolderScope.CHATS, "Café")
        assertFailsWith<CoreException> { editor.createFolder(FolderScope.CHATS, "CAFE") }
        editor.createFolder(FolderScope.CHATS, "界".repeat(85))
        assertFailsWith<CoreException> { editor.createFolder(FolderScope.CHATS, "界".repeat(86)) }
        assertFailsWith<CoreException> { editor.createFolder(FolderScope.CHATS, "   ") }
        assertEquals("cafe", Folding.fold("CAFÉ"))
        assertEquals("ø", Folding.fold("Ø"), "letters without a decomposition stay distinct")
        val folders = layout(kv).folders(FolderScope.CHATS)
        val cafe = folders.first { it.name == "Café" }
        assertEquals(false, NavigationEditor.nameAvailable(" cafe ", folders), "a dialog sees the same collision the edit rejects")
        assertEquals(true, NavigationEditor.nameAvailable("CAFE", folders, exceptId = cafe.id), "renaming a folder to itself is allowed")
        assertEquals(false, NavigationEditor.nameAvailable("界".repeat(86), folders))
        assertEquals(true, NavigationEditor.nameAvailable("Tea", folders))
    }

    @Test
    fun ordersFollowEditsAndIgnoreUnavailableIds() {
        val kv = offlineKv()
        val editor = NavigationEditor(kv)
        editor.setProjectOrder(listOf("b", "a", "c"))
        assertEquals(listOf("b", "a", "c", "d"), layout(kv).projectOrder(listOf("a", "b", "c", "d")))
        editor.setProjectOrder(listOf("c", "b", "a"))
        assertEquals(listOf("c", "b", "a"), layout(kv).projectOrder(listOf("a", "b", "c")))
        assertEquals(listOf("b", "x"), layout(kv).projectOrder(listOf("b", "x")))

        editor.pinProject("a", true)
        editor.pinProject("b", true)
        editor.pinProject("a", false)
        assertEquals(listOf("b"), layout(kv).pinnedProjects(listOf("a", "b")))
    }

    @Test
    fun pinnedChatsKeepSavedOrderAndAppendNewPinsByPosition() {
        val kv = offlineKv()
        val chats = listOf(
            Card(id = "first", pinned = true, position = 3, last_activity_at = "2026-01-03T00:00:00Z"),
            Card(id = "second", pinned = true, position = 1, last_activity_at = "2026-01-02T00:00:00Z"),
            Card(id = "third", pinned = true, position = 2, last_activity_at = "2026-01-01T00:00:00Z"),
            Card(id = "loose", pinned = false),
        )
        val editor = NavigationEditor(kv)
        assertEquals(listOf("first", "second", "third"), layout(kv).pinnedChats(chats).map { it.id })
        editor.initializePinnedChatOrder(chats)
        editor.setPinnedChatOrder(listOf("second", "first", "third"))
        assertEquals(listOf("second", "first", "third"), layout(kv).pinnedChats(chats).map { it.id })
        val newPin = chats + Card(id = "fourth", pinned = true, position = 0)
        assertEquals(listOf("second", "first", "third", "fourth"), layout(kv).pinnedChats(newPin).map { it.id })
        editor.initializePinnedChatOrder(chats)
        assertEquals(listOf("second", "first", "third"), layout(kv).pinnedChats(chats).map { it.id }, "initializes only once")
    }

    @Test
    fun flagsHaveTheirLegacyDefaults() {
        val kv = offlineKv()
        val editor = NavigationEditor(kv)
        assertFalse(layout(kv).projectExpanded("p"))
        assertFalse(layout(kv).chatSectionCollapsed("p"))
        assertFalse(layout(kv).chatsShowAll("p"))
        assertTrue(layout(kv).laneDescending("b", "todo"))
        editor.setProjectExpanded("p", true)
        editor.setChatSectionCollapsed("p", true)
        editor.setChatsShowAll("p", true)
        editor.setLaneDescending("b", "todo", false)
        assertTrue(layout(kv).projectExpanded("p"))
        assertTrue(layout(kv).chatSectionCollapsed("p"))
        assertTrue(layout(kv).chatsShowAll("p"))
        assertFalse(layout(kv).laneDescending("b", "todo"))
    }

    @Test
    fun editsSurviveARestartAndNeedAnAccount() {
        val kv = offlineKv()
        NavigationEditor(kv).setLaneDescending("b", "l", false)
        val restored = offlineKv()
        assertEquals(1, restored.status.value.pending)
        assertFalse(NavigationLayout(restored.values.value).laneDescending("b", "l"))
        val anonymous = offlineKv(account = "")
        assertFailsWith<CoreException> { NavigationEditor(anonymous).setLaneDescending("b", "l", false) }
    }

    @Test
    fun orderDiffsMoveOnlyItemsOutsideTheLongestStableRun() {
        assertEquals(emptyList(), NavigationEditor.order(listOf("a", "b", "c"), listOf("a", "b", "c"), "p", "").map { it.key })
        val moved = NavigationEditor.order(listOf("a", "b", "c", "d"), listOf("b", "c", "a", "d"), "p", "")
        assertEquals(listOf("p.a.position"), moved.map { it.key })
        assertEquals("p.c.position", moved.single().move!!.after)
        assertEquals("p.d.position", moved.single().move!!.before)
        val appended = NavigationEditor.order(listOf("a"), listOf("a", "new"), "p", "folder")
        assertEquals(KvMove(parent = "folder", after = "p.a.position", before = ""), appended.single().move)
        assertEquals(listOf(1, 2, 4), NavigationEditor.longestIncreasing(listOf(4, 0, 2, -1, 3)))
    }

    @Test
    fun placeholderRanksSortBetweenTheirNeighbours() {
        for ((left, right) in listOf("" to "", "a" to "b", "a" to "a1", "0000000000010" to "0000000000011", "zz" to "")) {
            val rank = SharedKv.between(left, right)
            assertTrue(rank > left, "$rank > $left")
            if (right.isNotEmpty()) assertTrue(rank < right, "$rank < $right")
        }
    }

    @Test
    fun coveringClocksRejectLaggingReplicas() {
        fun entry(vararg clocks: Map<String, Long>) = KVEntry(key = "k", versions = clocks.map { PeerVersion(clock = it) })
        val seen = entry(mapOf("a" to 2L, "b" to 1L))
        assertTrue(SharedKv.covers(entry(mapOf("a" to 2L, "b" to 1L)), seen))
        assertTrue(SharedKv.covers(entry(mapOf("a" to 3L, "b" to 1L)), seen))
        assertFalse(SharedKv.covers(entry(mapOf("a" to 1L, "b" to 5L)), seen))
        assertTrue(SharedKv.covers(entry(mapOf("a" to 1L), mapOf("a" to 2L, "b" to 1L)), seen), "a sibling may cover")
        assertFalse(SharedKv.covers(null, seen))
        assertTrue(SharedKv.covers(null, entry()))
    }

    @Test
    fun positionsRoundTrip() {
        val encoded = position("folder", "abc")
        assertEquals(KvPosition("folder", "abc"), SharedKv.decodePosition(encoded))
        assertEquals(null, SharedKv.decodePosition("\"text\"".encodeUtf8()))
        assertEquals(null, SharedKv.decodePosition(ByteString.EMPTY))
    }
}

package com.dbpprt.dieter.core.navigation

import com.dbpprt.dieter.api.v1.Card
import com.dbpprt.dieter.api.v1.KVEntry
import com.dbpprt.dieter.api.v1.PeerVersion
import com.dbpprt.dieter.core.runtime.CoreException
import com.dbpprt.dieter.core.runtime.SilentLogger
import com.dbpprt.dieter.core.storage.CoreStorage
import com.dbpprt.dieter.core.testing.offlineSessions
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import kotlin.time.Clock
import okio.ByteString
import okio.ByteString.Companion.encodeUtf8
import okio.Path.Companion.toPath
import okio.fakefilesystem.FakeFileSystem

class NavigationTest {
    private val fileSystem = FakeFileSystem()

    /** A namespace bound to an account but never connected: edits stay pending and project locally. */
    private fun offlineKv(account: String = "acct"): SharedKv {
        val storage = CoreStorage(fileSystem, "/state".toPath())
        storage.write("kv-active-navigation.pb", KvActive.ADAPTER.encode(KvActive(account = account)))
        return SharedKv("navigation", offlineSessions(), Clock.System, SilentLogger).also { it.bind(storage) }
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
    fun flagsHaveTheirDefaults() {
        val kv = offlineKv()
        val editor = NavigationEditor(kv)
        assertFalse("p" in layout(kv).expandedProjects())
        assertFalse(layout(kv).chatSectionCollapsed("p"))
        assertFalse(layout(kv).chatsShowAll("p"))
        assertTrue(layout(kv).laneDescending("b", "todo"))
        editor.setProjectExpanded("p", true)
        editor.setChatSectionCollapsed("p", true)
        editor.setChatsShowAll("p", true)
        editor.setLaneDescending("b", "todo", false)
        assertTrue("p" in layout(kv).expandedProjects())
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

    /** Ported from the Mac's `sidebarProjectPreferencesReorderAndReconcileAvailableProjects`. */
    @Test
    fun projectsMoveBeforeATargetOrToTheEnd() {
        val kv = offlineKv()
        val editor = NavigationEditor(kv)
        val available = listOf("p_one", "p_two", "p_three")
        editor.setProjectOrder(listOf("p_two", "p_missing", "p_one"))
        assertEquals(listOf("p_two", "p_one", "p_three"), layout(kv).projectOrder(available))
        editor.moveProjectBefore("p_three", "p_two", available)
        assertEquals(listOf("p_three", "p_two", "p_one"), layout(kv).projectOrder(available))
        editor.moveProjectBefore("p_three", null, available)
        assertEquals(listOf("p_two", "p_one", "p_three"), layout(kv).projectOrder(available))
        assertEquals(listOf("p_one", "p_four"), layout(kv).projectOrder(listOf("p_one", "p_four")))
        assertTrue("p_missing" in layout(kv).savedProjectOrder(), "a project whose machine is offline keeps its place")
        val pending = kv.status.value.pending
        editor.moveProjectBefore("p_one", "p_one", available)
        editor.moveProjectBefore("p_one", "gone", available)
        editor.moveProjectBefore("p_one", "p_three", available)
        assertEquals(pending, kv.status.value.pending, "a move onto itself, onto an unknown target, or to where it is records nothing")
    }

    @Test
    fun projectsMoveWithinTheirFolderOrAmongUnfiledProjects() {
        val kv = offlineKv()
        val editor = NavigationEditor(kv)
        val available = listOf("p1", "p2", "p3", "u1", "u2")
        val folder = editor.createFolder(FolderScope.PROJECTS, "Work")
        for (id in listOf("p1", "p2", "p3")) editor.moveToFolder(FolderScope.PROJECTS, id, folder)
        editor.moveProjectBefore("p3", "p1", available)
        assertEquals(listOf("p3", "p1", "p2"), layout(kv).folders(FolderScope.PROJECTS).single().itemIds)
        editor.moveProjectBefore("p3", null, available)
        assertEquals(listOf("p1", "p2", "p3"), layout(kv).folders(FolderScope.PROJECTS).single().itemIds, "the end of its folder")
        editor.moveProjectBefore("u2", "u1", available)
        assertEquals(listOf("u2", "u1"), layout(kv).sidebarProjects(available).unfiled)
        val pending = kv.status.value.pending
        editor.moveProjectBefore("u1", "p1", available)
        editor.moveProjectBefore("p1", "u1", available)
        assertEquals(pending, kv.status.value.pending, "a target in another group changes nothing")
        editor.moveProjectBefore("u1", "p1", available, ungrouped = true)
        assertEquals(listOf("u1", "p1", "p2", "p3", "u2"), layout(kv).projectOrder(available), "lists without folders move in the shared order")
        assertEquals(listOf("p1", "p2", "p3"), layout(kv).folders(FolderScope.PROJECTS).single().itemIds)
    }

    /** Ported from the Mac's `sidebarProjectPreferencesRetainOrderAndExpandedState`. */
    @Test
    fun theSidebarShowsAvailableProjectsInTheirGroups() {
        val kv = offlineKv()
        val editor = NavigationEditor(kv)
        val available = listOf("p_one", "p_two", "p_three")
        editor.moveProjectBefore("p_three", "p_one", available)
        editor.setProjectExpanded("p_two", true)
        editor.pinProject("p_two", true)
        editor.pinProject("offline", true)
        val folder = editor.createFolder(FolderScope.PROJECTS, "Clients")
        editor.moveToFolder(FolderScope.PROJECTS, "offline", folder)
        editor.moveToFolder(FolderScope.PROJECTS, "p_one", folder)
        val sidebar = layout(kv).sidebarProjects(available)
        assertEquals(listOf("p_three", "p_one", "p_two"), sidebar.order)
        assertEquals(listOf(NavigationFolder(folder, "Clients", listOf("p_one"))), sidebar.folders, "members whose machine is offline are left out")
        assertEquals(listOf("p_three", "p_two"), sidebar.unfiled)
        assertEquals(listOf("p_two"), sidebar.pinned)
        assertEquals(listOf("p_two"), sidebar.expanded)
        assertEquals(listOf("p_two", "offline"), layout(kv).savedPinnedProjects())
    }

    @Test
    fun pinningAPinnedProjectKeepsItsPlace() {
        val kv = offlineKv()
        val editor = NavigationEditor(kv)
        editor.pinProject("a", true)
        editor.pinProject("b", true)
        val pending = kv.status.value.pending
        editor.pinProject("a", true)
        editor.pinProject("c", false)
        editor.pinProject(" ", true)
        assertEquals(pending, kv.status.value.pending)
        assertEquals(listOf("a", "b"), layout(kv).pinnedProjects(listOf("a", "b", "c")))
    }

    /** Ported from the Mac's `pinnedChatsKeepSavedLocationsAndAppendNewPinsDeterministically` and `pinnedChatPreferencesMatchAndroidDropTargetMovement`. */
    @Test
    fun pinnedChatsMoveOntoTheirTarget() {
        val kv = offlineKv()
        val editor = NavigationEditor(kv)
        val first = Card(id = "c_first", pinned = true, position = 30, last_activity_at = "2026-01-03T00:00:00Z")
        val second = Card(id = "c_second", pinned = true, position = 10, last_activity_at = "2026-01-02T00:00:00Z")
        val third = Card(id = "c_third", pinned = true, position = 20, last_activity_at = "2026-01-01T00:00:00Z")
        val chats = listOf(first, second, third)
        editor.initializePinnedChatOrder(chats)
        fun shown() = layout(kv).pinnedChats(chats).map { it.id }
        editor.movePinnedChat(first.id, second.id, shown())
        assertEquals(listOf("c_second", "c_first", "c_third"), shown())
        editor.movePinnedChat(third.id, second.id, shown())
        assertEquals(listOf("c_third", "c_second", "c_first"), shown())

        val saved = NavigationLayout(mapOf("pinned-order.c_first.position" to position("", "a"), "pinned-order.c_second.position" to position("", "b")))
        val newPin = Card(id = "c_new", pinned = true, position = 20)
        assertEquals(listOf("c_first", "c_second", "c_new"), saved.pinnedChats(listOf(newPin, first, second)).map { it.id })
        assertEquals(listOf("c_first", "c_second", "c_new"), saved.pinnedChats(listOf(second, first, newPin)).map { it.id }, "activity never reshuffles")
    }

    /** Ported from the Mac's `navigationFoldersRepairDuplicateMembershipWhenLoading`. */
    @Test
    fun replacingFoldersKeepsAnItemInItsFirstFolder() {
        val kv = offlineKv()
        NavigationEditor(kv).setFolders(
            FolderScope.CHATS,
            listOf(NavigationFolder("first", "First", listOf("shared", "one")), NavigationFolder("second", "Second", listOf("shared", "two"))),
        )
        val folders = layout(kv).folders(FolderScope.CHATS)
        assertEquals(listOf("shared", "one"), folders[0].itemIds)
        assertEquals(listOf("two"), folders[1].itemIds)
    }

    /** Ported from the Mac's `navigationFoldersCreateMoveRenameCollapseDeleteAndEncode`. */
    @Test
    fun foldersRejectOversizedRenamesAndUnfileItems() {
        val kv = offlineKv()
        val editor = NavigationEditor(kv)
        val work = editor.createFolder(FolderScope.CHATS, "Work")
        assertFailsWith<CoreException> { editor.renameFolder(FolderScope.CHATS, work, "界".repeat(86)) }
        editor.moveToFolder(FolderScope.CHATS, "c1", work)
        editor.moveToFolder(FolderScope.CHATS, "c1", null)
        assertEquals(emptyList(), layout(kv).folders(FolderScope.CHATS).single().itemIds)
        assertEquals(listOf("c1", "c2"), layout(kv).unfiled(FolderScope.CHATS, listOf("c1", "c2")))
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

package com.getdieter.mobile.store

import com.getdieter.api.v1.Folder
import com.getdieter.client.v1.*
import com.getdieter.mobile.navigation.*
import kotlin.test.*
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.*

@OptIn(ExperimentalCoroutinesApi::class)
class FoldersModelTest {
    private fun TestScope.store(core: FakeMobileCore) =
        MobileStore(core, StandardTestDispatcher(testScheduler))

    private fun folders(core: FakeMobileCore) = core.sentOf { it.folders }

    private val list = MobileRoute.Tool(ToolPage.FOLDERS)

    @Test
    fun folderRoutesObserveTheListTheFolderAndItsDirectory() = runTest {
        val core = FakeMobileCore()
        val store = store(core)
        try {
            runCurrent()
            // Nothing is observed until a folder route is visible.
            assertFalse(core.observing(Slice.SLICE_FOLDERS, MobileStore.FOLDERS_SCOPE))
            store.openMore(list)
            runCurrent()
            assertTrue(core.observing(Slice.SLICE_FOLDERS, MobileStore.FOLDERS_SCOPE))
            assertTrue(core.observing(Slice.SLICE_FOLDER_SYNC_SETTINGS, MobileStore.FOLDERS_SCOPE))
            core.publish(
                Slice.SLICE_FOLDERS,
                MobileStore.FOLDERS_SCOPE,
                Update(
                    folders = FoldersSlice(folders = listOf(FolderRow(id = "f1", name = "Inbox")))
                ),
            )
            runCurrent()
            assertEquals("Inbox", store.folders.list.value.folders.single().name)

            store.showFrom(list, MobileRoute.Folder("f1"))
            runCurrent()
            assertTrue(core.observing(Slice.SLICE_FOLDER, "f1"))
            // Its surface opens at the root, so the root needs no browse.
            assertTrue(folders(core).none { it.browse != null })
            core.publish(
                Slice.SLICE_FOLDER,
                "f1",
                Update(folder = FolderSlice(id = "f1", found = true, name = "Inbox")),
            )
            runCurrent()
            assertEquals("Inbox", store.folders.folder.value.name)

            store.push(MobileRoute.FolderFiles("f1", "Scans"))
            runCurrent()
            store.push(MobileRoute.FolderPage("f1", FolderSection.TRASH))
            runCurrent()
            store.pop()
            store.pop()
            runCurrent()
            assertEquals(
                listOf(FolderPath("f1", "Scans"), FolderPath("f1", "")),
                folders(core).mapNotNull { it.browse },
            )
            assertTrue(folders(core).filter { it.browse != null }.all { it.scope == "f1" })

            // Another tab ends every folder observation.
            store.selectTab(MobileTab.INBOX)
            runCurrent()
            assertFalse(core.observing(Slice.SLICE_FOLDER, "f1"))
            assertFalse(core.observing(Slice.SLICE_FOLDERS, MobileStore.FOLDERS_SCOPE))
        } finally {
            store.close()
        }
    }

    @Test
    fun commandsAreScopedToTheirFolderAndFoldTheirReply() = runTest {
        val core = FakeMobileCore { command ->
            when {
                command.folders?.set_device_settings != null ->
                    Result(
                        folder_sync_settings =
                            FolderSyncSettingsSlice(
                                settings = command.folders!!.set_device_settings,
                                next_sync = "In about 15 min",
                            )
                    )
                command.folders?.list_trash != null ->
                    Result(
                        folder =
                            FolderSlice(
                                id = "f1",
                                found = true,
                                trash = FolderTrashState(daemon_id = "d1"),
                            )
                    )
                else -> Result(done = Done())
            }
        }
        val store = store(core)
        try {
            store.openMore(list)
            store.showFrom(list, MobileRoute.Folder("f1"))
            runCurrent()
            store.folders.syncNow("f1")
            store.folders.download("f1", "a.txt")
            store.folders.resolveDeletions("f1", apply = false)
            store.folders.resolveConflict("f1", "a (conflict).txt", keepCopy = true)
            store.folders.loadTrash("f1")
            store.folders.setDeviceSettings(
                FolderDeviceSettings(enabled = true, interval_minutes = 15)
            )
            runCurrent()
            val sent = folders(core)
            assertEquals("f1", sent.mapNotNull { it.sync_now }.single().folder_id)
            assertEquals(FolderPath("f1", "a.txt"), sent.mapNotNull { it.download }.single())
            assertFalse(sent.mapNotNull { it.resolve_deletions }.single().apply)
            assertTrue(sent.mapNotNull { it.resolve_conflict }.single().keep_copy)
            assertEquals("f1", sent.single { it.list_trash != null }.scope)
            assertEquals("f1", sent.single { it.download != null }.scope)
            assertEquals("d1", store.folders.folder.value.trash?.daemon_id)
            assertEquals("In about 15 min", store.folders.settings.value.next_sync)
            assertEquals(15, store.folders.settings.value.settings?.interval_minutes)
        } finally {
            store.close()
        }
    }

    @Test
    fun addingAFolderCreatesItBindsTheMachineAndKeepsItHere() = runTest {
        val core = FakeMobileCore { command ->
            if (command.folders?.create != null)
                Result(synced_folder = Folder(id = "f_new", name = command.folders!!.create!!.name))
            else Result(done = Done())
        }
        val store = store(core)
        try {
            store.present(MobileRoute.AddFolder())
            runCurrent()
            var added = ""
            store.folders.add(
                AddFolderPlan(
                    name = " Inbox ",
                    daemonId = "d_studio",
                    path = "/Users/me/Dieter/Inbox",
                    location = "content://tree/inbox",
                    locationLabel = "Documents/Inbox",
                    direction = FolderDirection.FOLDER_DIRECTION_UPLOAD_ONLY,
                    removeAfterUpload = true,
                )
            ) {
                added = it
            }
            runCurrent()
            val sent = folders(core)
            assertEquals("Inbox", sent[0].create?.name)
            assertEquals("d_studio", sent[0].create?.daemon_id)
            val attach = assertNotNull(sent[1].attach_daemon)
            assertEquals("f_new", attach.folder_id)
            assertEquals("/Users/me/Dieter/Inbox", attach.path)
            val device = assertNotNull(sent[2].attach_device)
            assertEquals("f_new", device.folder_id)
            assertEquals("content://tree/inbox", device.location)
            assertEquals(FolderDirection.FOLDER_DIRECTION_UPLOAD_ONLY, device.direction)
            assertTrue(device.remove_after_upload)
            assertEquals("f_new", added)

            // Joining skips the create and, without a machine, the attach.
            store.folders.add(AddFolderPlan(join = "f_old", onDevice = true)) {}
            runCurrent()
            val joined = folders(core).drop(3)
            assertEquals(1, joined.size)
            assertEquals("f_old", joined.single().attach_device?.folder_id)
        } finally {
            store.close()
        }
    }

    @Test
    fun aFolderShareOpensThePickerAndSavesTheFilesUnread() = runTest {
        val core = FakeMobileCore { command ->
            if (command.folders?.save_files != null)
                Result(
                    folder_saved =
                        FolderSaveResult(
                            paths = listOf("scan.pdf"),
                            message = "Saved 1 file to Inbox.",
                        )
                )
            else Result(done = Done())
        }
        val store = store(core)
        try {
            core.publish(
                Slice.SLICE_WORKSPACE,
                update = Update(workspace = WorkspaceSlice(loaded = true)),
            )
            runCurrent()
            store.sharing.receive(
                SharedItems(
                    "",
                    emptyList(),
                    ShareDestination.FOLDER,
                    files = listOf(SharedFile("content://media/1", "scan.pdf")),
                )
            )
            runCurrent()
            assertEquals(MobileRoute.SaveToFolder, store.routes.value.modal)
            // The picker lists folders, so the list is observed.
            assertTrue(core.observing(Slice.SLICE_FOLDERS, MobileStore.FOLDERS_SCOPE))
            store.sharing.saveInto("f1")
            runCurrent()
            val save = assertNotNull(folders(core).single().save_files)
            assertEquals("f1", save.folder_id)
            assertEquals(listOf(FolderSaveSource("content://media/1", "scan.pdf")), save.sources)
            assertNull(store.routes.value.modal)
            assertNull(store.sharing.target.value)
            assertEquals("Saved 1 file to Inbox.", store.folders.saved.value)
        } finally {
            store.close()
        }
    }
}

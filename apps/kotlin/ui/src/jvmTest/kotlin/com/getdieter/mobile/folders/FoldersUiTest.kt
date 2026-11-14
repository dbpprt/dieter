@file:OptIn(androidx.compose.ui.test.ExperimentalTestApi::class)

package com.getdieter.mobile.folders

import androidx.compose.ui.graphics.toAwtImage
import androidx.compose.ui.test.*
import com.getdieter.client.v1.*
import com.getdieter.mobile.app.MobileApp
import com.getdieter.mobile.desktop.DesktopFixture
import com.getdieter.mobile.navigation.*
import com.getdieter.mobile.platform.JvmFolderSurfaces
import com.getdieter.mobile.store.*
import java.io.File
import javax.imageio.ImageIO
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import kotlinx.coroutines.Dispatchers

/**
 * The folder screens of the touch shell, rendered offscreen at a phone's size against a fake core:
 * More › Folders, a folder's files and deletion guard, Settings › Folder sync, the add-folder flow
 * and "Save to folder…". Each step leaves a screenshot under build/desktop-screenshots.
 */
class FoldersUiTest {
    private val list =
        FoldersSlice(
            folders =
                listOf(
                    FolderRow(
                        id = "f_inbox",
                        name = "Inbox",
                        status = "Up to date · 3m ago",
                        tone = Tone.TONE_SUCCESS,
                        on_device = true,
                        direction = "Upload only",
                        members = "Studio · 1 phone",
                        accepts_files = true,
                    ),
                    FolderRow(
                        id = "f_reports",
                        name = "Reports",
                        status = "Syncing · 5 files left",
                        tone = Tone.TONE_ACTIVE,
                        on_device = true,
                        direction = "Download only",
                        syncing = true,
                    ),
                    FolderRow(
                        id = "f_archive",
                        name = "Archive",
                        status = "On Studio, box · not on this device",
                        members = "Studio, box",
                    ),
                ),
            daemons =
                listOf(
                    FolderDaemonOption("d_studio", "Studio", true, "Studio"),
                    FolderDaemonOption("d_box", "box", false, "box"),
                ),
            device_capable = true,
        )

    private val settings =
        FolderSyncSettingsSlice(
            settings =
                FolderDeviceSettings(
                    enabled = true,
                    background = FolderBackgroundSync.FOLDER_BACKGROUND_SYNC_INTERVAL,
                    interval_minutes = 60,
                    sync_when_opened = true,
                    upload_right_away = true,
                    live_sync = true,
                    network = FolderNetworkPolicy.FOLDER_NETWORK_POLICY_UNMETERED,
                    large_file_bytes = 25L shl 20,
                    respect_data_saver = true,
                    never_roaming = true,
                    pause_in_power_saver = true,
                    pause_below_percent = 20,
                    auto_download_bytes = 25L shl 20,
                    storage_limit_bytes = 2L shl 30,
                    keep_free_bytes = 1L shl 30,
                    notify_conflicts = true,
                    notify_attention = true,
                ),
            interval_options =
                listOf(15 to "Every 15 min", 60 to "Every hour", 1440 to "Every 24 hours").map {
                    FolderIntervalOption(
                        FolderBackgroundSync.FOLDER_BACKGROUND_SYNC_INTERVAL,
                        it.first,
                        it.second,
                        it.first == 60,
                    )
                } +
                    FolderIntervalOption(
                        FolderBackgroundSync.FOLDER_BACKGROUND_SYNC_MANUAL,
                        0,
                        "Manual only",
                        false,
                    ),
            battery_options = listOf(FolderSizeOption(20, "Pause below 20%", true)),
            auto_download_options = listOf(FolderSizeOption(25L shl 20, "Files up to 25 MB", true)),
            storage_options = listOf(FolderSizeOption(2L shl 30, "2 GB", true)),
            keep_free_options =
                listOf(FolderSizeOption(1L shl 30, "Keep at least 1 GB free", true)),
            large_file_options = listOf(FolderSizeOption(25L shl 20, "25 MB", true)),
            roaming_available = true,
            data_saver_label = "Respect Data Saver",
            power_saver_label = "Pause in Battery Saver",
            last_sync = "3m ago",
            next_sync = "In about 45 min",
            used_label = "1.2 GB of 2 GB",
            folders_on_device = 2,
            device_capable = true,
        )

    private fun inbox(
        welcomeDownloaded: Boolean = false,
        deletions: FolderDeletionsRow? = null,
    ) =
        FolderSlice(
            id = "f_inbox",
            found = true,
            name = "Inbox",
            status = "Up to date · 3m ago",
            tone = Tone.TONE_SUCCESS,
            trash_label = "30 days",
            delete_guard_label = "More than 100 files or 30%",
            members =
                listOf(
                    FolderMemberRow(
                        member_id = "d_studio",
                        name = "Studio",
                        daemon = true,
                        mode_label = "Two-way",
                        status = "Up to date",
                        tone = Tone.TONE_SUCCESS,
                        last_sync = "1m ago",
                        online = true,
                    ),
                    FolderMemberRow(
                        member_id = "p_pixel",
                        name = "Pixel 9",
                        this_device = true,
                        mode_label = "Upload only",
                        status = "Up to date · 3m ago",
                        tone = Tone.TONE_SUCCESS,
                        home = "Studio",
                        online = true,
                    ),
                ),
            device =
                FolderDeviceState(
                    attached = true,
                    settings =
                        FolderLocalSettings(
                            folder_id = "f_inbox",
                            direction = FolderDirection.FOLDER_DIRECTION_UPLOAD_ONLY,
                            location = "private:f_inbox",
                            location_label = "Private to Dieter",
                        ),
                    direction = FolderDirection.FOLDER_DIRECTION_UPLOAD_ONLY,
                    direction_label = "Upload only",
                    location_label = "Private to Dieter",
                    home_label = "Auto (Studio)",
                    home_options =
                        listOf(
                            FolderDaemonOption("", "Auto", true, "Auto (Studio)", true),
                            FolderDaemonOption("d_studio", "Studio", true, "Studio"),
                        ),
                    can_attach = true,
                    usage_label = "2 files · 1 KB on this device of 2 KB",
                ),
            breadcrumbs = listOf(FolderCrumb("", "Inbox")),
            files =
                listOf(
                    FolderFileRow(path = "Scans", name = "Scans", directory = true),
                    FolderFileRow(
                        path = "welcome.txt",
                        name = "welcome.txt",
                        size = 1024,
                        size_label = "1 KB",
                        downloaded = welcomeDownloaded,
                        badge = if (welcomeDownloaded) "" else "Not downloaded",
                    ),
                ),
            pending_deletions = deletions,
        )

    private fun ComposeUiTest.shot(name: String) {
        val directory = System.getProperty("dieter.screenshots") ?: return
        waitForIdle()
        // A sheet is a second root; the window's own is the first.
        val image = onAllNodes(isRoot()).onFirst().captureToImage().toAwtImage()
        File(directory, "folders").mkdirs()
        ImageIO.write(image, "png", File(File(directory, "folders"), "$name.png"))
    }

    private fun DesktopComposeUiTest.launch(): Pair<MobileStore, FakeMobileCore> {
        val core = FakeMobileCore { command ->
            when {
                command.folders?.set_device_settings != null ->
                    Result(
                        folder_sync_settings =
                            settings.copy(settings = command.folders!!.set_device_settings)
                    )
                command.folders?.create != null ->
                    Result(
                        synced_folder =
                            com.getdieter.api.v1.Folder(
                                id = "f_new",
                                name = command.folders!!.create!!.name,
                            )
                    )
                command.admin?.directories != null ->
                    Result(
                        directory_listing =
                            com.getdieter.api.v1.DirectoryListing(
                                path = "/Users/me",
                                name = "me",
                                entries =
                                    listOf(
                                        com.getdieter.api.v1.DirectoryEntry(
                                            name = "Dieter",
                                            path = "/Users/me/Dieter",
                                        )
                                    ),
                            )
                    )
                else -> Result(done = Done())
            }
        }
        val store = MobileStore(core, Dispatchers.Unconfined)
        store.layout.setInterfaceMode(InterfaceMode.TOUCH)
        store.theme.setAppearance("light")
        DesktopFixture.publish(core)
        setContent { MobileApp(store) }
        waitForIdle()
        return store to core
    }

    private fun FakeMobileCore.publishFolders() {
        publish(Slice.SLICE_FOLDERS, MobileStore.FOLDERS_SCOPE, Update(folders = list))
        publish(
            Slice.SLICE_FOLDER_SYNC_SETTINGS,
            MobileStore.FOLDERS_SCOPE,
            Update(folder_sync_settings = settings),
        )
    }

    private fun folders(core: FakeMobileCore) = core.sentOf { it.folders }

    @Test
    fun moreOpensFoldersAFolderItsFilesAndItsDeletionGuard() =
        runDesktopComposeUiTest(width = 412, height = 900) {
            val (store, core) = launch()
            try {
                // More's sheet has a Folders tile.
                onNodeWithTag("nav-more").performClick()
                waitForIdle()
                onNodeWithTag("more-folders").performClick()
                waitForIdle()
                assertEquals(MobileRoute.Tool(ToolPage.FOLDERS), store.routes.value.top)
                core.publishFolders()
                waitForIdle()
                onNodeWithTag("folder-row-f_inbox").assertIsDisplayed()
                onNodeWithTag("folder-row-f_inbox").assertTextContains("Inbox")
                onNodeWithTag("folders-next-sync").assertIsDisplayed()
                shot("01-folders")

                onNodeWithTag("folder-row-f_inbox").performClick()
                waitForIdle()
                assertEquals(MobileRoute.Folder("f_inbox"), store.routes.value.top)
                assertTrue(core.observing(Slice.SLICE_FOLDER, "f_inbox"))
                core.publish(Slice.SLICE_FOLDER, "f_inbox", Update(folder = inbox()))
                waitForIdle()
                onNodeWithTag("folder-status").assertTextEquals("Up to date · 3m ago")
                onNodeWithTag("folder-file-welcome.txt").assertIsDisplayed()
                onNodeWithTag("folder-file-cloud-welcome.txt", useUnmergedTree = true)
                    .assertExists()
                shot("02-folder")

                // A file that is not here downloads on tap, then offers open and share.
                onNodeWithTag("folder-file-welcome.txt").performClick()
                waitForIdle()
                assertEquals(
                    FolderPath("f_inbox", "welcome.txt"),
                    folders(core).mapNotNull { it.download }.single(),
                )
                core.publish(
                    Slice.SLICE_FOLDER,
                    "f_inbox",
                    Update(folder = inbox(welcomeDownloaded = true)),
                )
                waitForIdle()
                onNodeWithTag("folder-file-share").assertIsDisplayed()
                shot("03-file-actions")
                onNodeWithTag("folder-file-open").performClick()
                waitForIdle()

                // A directory opens below the folder.
                onNodeWithTag("folder-file-Scans").performClick()
                waitForIdle()
                assertEquals(MobileRoute.FolderFiles("f_inbox", "Scans"), store.routes.value.top)
                assertEquals(
                    FolderPath("f_inbox", "Scans"),
                    folders(core).mapNotNull { it.browse }.last(),
                )
                store.pop()
                waitForIdle()

                // The deletion guard holds a batch: Restore undoes it.
                core.publish(
                    Slice.SLICE_FOLDER,
                    "f_inbox",
                    Update(
                        folder =
                            inbox(
                                deletions =
                                    FolderDeletionsRow(
                                        count = 412,
                                        sample = listOf("a.txt", "b.txt"),
                                        source = "local",
                                        title = "Confirm deletion of 412 files",
                                        detail = "These files are missing on this device.",
                                    )
                            )
                    ),
                )
                waitForIdle()
                onNodeWithText("Confirm deletion of 412 files").assertIsDisplayed()
                shot("04-deletion-guard")
                onNodeWithTag("folder-deletions-restore").performClick()
                waitForIdle()
                assertEquals(
                    false,
                    folders(core).mapNotNull { it.resolve_deletions }.single().apply,
                )
            } finally {
                store.close()
            }
        }

    @Test
    fun settingsFolderSyncChangesTheDeviceDefaults() =
        runDesktopComposeUiTest(width = 412, height = 900) {
            val (store, core) = launch()
            try {
                store.openMore(MobileRoute.Tool(ToolPage.SETTINGS))
                waitForIdle()
                onNodeWithTag("settings").performScrollToNode(hasTestTag("settings-folder-sync"))
                onNodeWithTag("settings-folder-sync").performClick()
                waitForIdle()
                assertEquals(MobileRoute.FolderSync, store.routes.value.top)
                core.publishFolders()
                waitForIdle()
                onNodeWithTag("folder-sync-enabled").assertIsOn()
                shot("05-folder-sync")
                // Any network.
                onNodeWithTag("folder-sync-network-1").performClick()
                waitForIdle()
                assertEquals(
                    FolderNetworkPolicy.FOLDER_NETWORK_POLICY_ANY,
                    folders(core).mapNotNull { it.set_device_settings }.last().network,
                )
                // Every 15 minutes.
                onNodeWithTag("folder-sync-interval-15").performClick()
                waitForIdle()
                assertEquals(
                    15,
                    folders(core).mapNotNull { it.set_device_settings }.last().interval_minutes,
                )
                onNodeWithTag("folder-sync-settings")
                    .performScrollToNode(hasTestTag("folder-sync-charging"))
                onNodeWithTag("folder-sync-charging").performClick()
                waitForIdle()
                assertTrue(
                    folders(core).mapNotNull { it.set_device_settings }.last().only_while_charging
                )
                onNodeWithTag("folder-sync-settings")
                    .performScrollToNode(hasTestTag("folder-sync-status-last-sync"))
                onNodeWithTag("folder-sync-status-last-sync").assertIsDisplayed()
                shot("06-folder-sync-status")
            } finally {
                store.close()
            }
        }

    @Test
    fun theAddFolderFlowCreatesBindsAndKeepsTheFolderHere() =
        runDesktopComposeUiTest(width = 412, height = 900) {
            val (store, core) = launch()
            JvmFolderSurfaces.locationPicker = { picked ->
                picked("content://tree/primary%3ADocuments%2FInbox", "Documents/Inbox")
            }
            try {
                store.openMore(MobileRoute.Tool(ToolPage.FOLDERS))
                waitForIdle()
                core.publishFolders()
                waitForIdle()
                onNodeWithTag("folders-list").performScrollToNode(hasTestTag("folders-add-row"))
                onNodeWithTag("folders-add-row").performClick()
                waitForIdle()
                assertEquals(MobileRoute.AddFolder(), store.routes.value.modal)
                onNodeWithTag("add-folder-name").performTextInput("Inbox 2")
                shot("07-add-start")
                onNodeWithTag("chrome-add-folder-next").performClick()
                waitForIdle()
                // The machine: Studio is preselected; browse picks a directory.
                onNodeWithTag("folder-daemon-browse").performClick()
                waitForIdle()
                onNodeWithTag("directory-entry-Dieter").assertIsDisplayed()
                onNodeWithTag("sheet-pick-directory").performClick()
                waitForIdle()
                onNodeWithTag("folder-daemon-path").assertTextContains("/Users/me")
                shot("08-add-machine")
                onNodeWithTag("chrome-add-folder-next").performClick()
                waitForIdle()
                onNodeWithTag("add-folder-location-shared").performClick()
                waitForIdle()
                onNodeWithText("Documents/Inbox").assertIsDisplayed()
                onNodeWithTag("chrome-add-folder-next").performClick()
                waitForIdle()
                onNodeWithTag("add-folder-direction-2").performClick()
                waitForIdle()
                onNodeWithTag("add-folder-remove-after-upload").performClick()
                onNodeWithTag("chrome-add-folder-next").performClick()
                waitForIdle()
                shot("09-add-review")
                onNodeWithTag("chrome-add-folder-next").performClick()
                waitForIdle()
                val sent = folders(core)
                assertEquals("Inbox 2", sent.mapNotNull { it.create }.single().name)
                assertEquals("/Users/me", sent.mapNotNull { it.attach_daemon }.single().path)
                val device = sent.mapNotNull { it.attach_device }.single()
                assertEquals("content://tree/primary%3ADocuments%2FInbox", device.location)
                assertEquals(FolderDirection.FOLDER_DIRECTION_UPLOAD_ONLY, device.direction)
                assertTrue(device.remove_after_upload)
                assertEquals(null, store.routes.value.modal)
                assertEquals(MobileRoute.Folder("f_new"), store.routes.value.top)
            } finally {
                JvmFolderSurfaces.locationPicker = null
                store.close()
            }
        }

    @Test
    fun saveToFolderOffersFoldersThatTakeFiles() =
        runDesktopComposeUiTest(width = 412, height = 900) {
            val (store, core) = launch()
            try {
                store.sharing.receive(
                    SharedItems(
                        "",
                        emptyList(),
                        ShareDestination.FOLDER,
                        files = listOf(SharedFile("content://media/7", "receipt.pdf")),
                    )
                )
                waitForIdle()
                assertEquals(MobileRoute.SaveToFolder, store.routes.value.modal)
                core.publishFolders()
                waitForIdle()
                onNodeWithTag("share-folder-f_inbox").assertIsDisplayed()
                // Download only and not-on-device folders take no files.
                onAllNodesWithTag("share-folder-f_reports").assertCountEquals(0)
                onAllNodesWithTag("share-folder-f_archive").assertCountEquals(0)
                shot("10-save-to-folder")
                onNodeWithTag("share-folder-f_inbox").performClick()
                waitForIdle()
                val save = folders(core).mapNotNull { it.save_files }.single()
                assertEquals("f_inbox", save.folder_id)
                assertEquals("receipt.pdf", save.sources.single().name)
                assertEquals(null, store.routes.value.modal)
            } finally {
                store.close()
            }
        }
}

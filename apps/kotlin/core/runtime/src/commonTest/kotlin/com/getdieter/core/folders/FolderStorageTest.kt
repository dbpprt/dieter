package com.getdieter.core.folders

import com.getdieter.api.v1.FolderEntry
import com.getdieter.api.v1.FolderEntryKind
import com.getdieter.core.storage.CoreStorage
import com.getdieter.core.v1.FolderDirection
import com.getdieter.core.v1.FolderLocalSettings
import com.getdieter.core.v1.FolderNetworkPolicy
import com.getdieter.core.v1.LocalFolderEntry
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNull
import kotlin.test.assertTrue
import okio.Path.Companion.toPath
import okio.fakefilesystem.FakeFileSystem

/** The sharded index and the settings record on disk. */
class FolderStorageTest {
    private val disk = FakeFileSystem()
    private val storage = CoreStorage(disk, "/state".toPath())

    private fun file(path: String, size: Long = 1) =
        LocalFolderEntry(
            entry =
                FolderEntry(
                    path = path,
                    kind = FolderEntryKind.FOLDER_ENTRY_KIND_FILE,
                    size = size,
                    sha256 = "a".repeat(64),
                    version = Versions.bump(emptyList(), Versions.actorOf("p")),
                ),
            synced = true,
        )

    @Test
    fun oneChangedEntryRewritesOneShard() {
        val index = FolderIndex(storage)
        repeat(2000) { index.put(file("dir/file-$it.txt")) }
        assertTrue(index.flush() > 200)
        assertEquals(0, index.flush())
        index.put(file("dir/file-42.txt", size = 99))
        assertEquals(1, index.flush())
        index.remove("dir/file-7.txt")
        assertEquals(1, index.flush())
        val reloaded = FolderIndex(storage)
        assertEquals(1999, reloaded.size)
        assertEquals(99, reloaded["dir/file-42.txt"]!!.entry!!.size)
        assertNull(reloaded["dir/file-7.txt"])
    }

    @Test
    fun theIndexIsBounded() {
        val index = FolderIndex(storage, limit = 3)
        repeat(3) { index.put(file("f$it")) }
        // Replacing an entry is fine; a new path is not.
        index.put(file("f1", size = 5))
        assertFailsWith<FolderIndexFullException> { index.put(file("f3")) }
    }

    @Test
    fun settingsRoundTripAndStartFromTheDefaults() {
        val store = FolderSettingsStore(storage)
        assertEquals(FolderSettings.DEFAULTS, store.device())
        assertTrue(store.load().folders.isEmpty())
        store.setDevice(
            FolderSettings.DEFAULTS.copy(interval_minutes = 5, auto_download_bytes = -1)
        )
        store.putFolder(
            FolderLocalSettings(
                folder_id = "inbox",
                direction = FolderDirection.FOLDER_DIRECTION_UPLOAD_ONLY,
                remove_after_upload = true,
                location = "content://tree/inbox",
                network = FolderNetworkPolicy.FOLDER_NETWORK_POLICY_ANY,
            )
        )
        val reloaded = FolderSettingsStore(storage)
        // Intervals stay within what platforms schedule.
        assertEquals(15, reloaded.device().interval_minutes)
        assertEquals(-1, reloaded.device().auto_download_bytes)
        assertEquals("content://tree/inbox", reloaded.folder("inbox")!!.location)
        assertEquals(
            FolderNetworkPolicy.FOLDER_NETWORK_POLICY_ANY,
            FolderSettings.network(reloaded.device(), reloaded.folder("inbox")),
        )
        reloaded.removeFolder("inbox")
        assertNull(FolderSettingsStore(storage).folder("inbox"))
    }

    @Test
    fun theClientContractsSettingsShareTheRecordsWireFormat() {
        val core = FolderSettings.DEFAULTS.copy(storage_limit_bytes = 7, pause_below_percent = 30)
        val client = com.getdieter.client.v1.FolderDeviceSettings.ADAPTER.decode(core.encode())
        assertEquals(7, client.storage_limit_bytes)
        assertEquals(30, client.pause_below_percent)
        assertEquals(
            core,
            com.getdieter.core.v1.FolderDeviceSettings.ADAPTER.decode(client.encode()),
        )
        val local =
            FolderLocalSettings(
                folder_id = "f",
                home_daemon_id = "d",
                auto_download_override = true,
                auto_download_bytes = 3,
            )
        assertEquals(
            local,
            FolderLocalSettings.ADAPTER.decode(
                com.getdieter.client.v1.FolderLocalSettings.ADAPTER.decode(local.encode()).encode()
            ),
        )
    }
}

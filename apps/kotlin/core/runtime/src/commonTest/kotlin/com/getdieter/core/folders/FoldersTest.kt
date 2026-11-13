package com.getdieter.core.folders

import com.getdieter.api.v1.FolderIndexPage
import com.getdieter.api.v1.FolderMember
import com.getdieter.api.v1.GetFolderIndexRequest
import com.getdieter.api.v1.RegisterFolderClientRequest
import com.getdieter.core.runtime.SilentLogger
import com.getdieter.core.storage.CoreStorage
import com.getdieter.core.testing.FakeDeviceConditions
import com.getdieter.core.testing.FakeFolderDaemon
import com.getdieter.core.testing.FakeFolderFileSystem
import com.getdieter.core.testing.FakeFolderScheduler
import com.getdieter.core.v1.FolderDirection
import com.squareup.wire.GrpcException
import com.squareup.wire.GrpcStatus
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlin.time.Clock
import kotlin.time.Duration.Companion.minutes
import kotlin.time.Duration.Companion.seconds
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import okio.Path.Companion.toPath
import okio.fakefilesystem.FakeFileSystem

/** The device-level manager: settings, scheduling, policy, failover and this device's commands. */
class FoldersTest {
    private val files = FakeFolderFileSystem()
    private val conditions = FakeDeviceConditions()
    private val scheduler = FakeFolderScheduler()
    private val home = FakeFolderDaemon("d_home", "Studio")
    private var homes = listOf("d_home")
    private var remotes: Map<String, FolderRemote> = mapOf("d_home" to home)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    /** What other apps shared, by source. */
    private val shared = HashMap<String, ByteArray>()
    private val sources = FolderSources { source ->
        val bytes = shared[source] ?: error("That file is gone.")
        var offset = 0
        object : FolderSource {
            override fun read(buffer: ByteArray): Int {
                if (offset >= bytes.size) return -1
                val count = minOf(buffer.size, bytes.size - offset)
                bytes.copyInto(buffer, 0, offset, offset + count)
                offset += count
                return count
            }

            override fun close() = Unit
        }
    }
    private val folders =
        Folders(
            FolderPlatform(files, conditions, scheduler, "android", sources),
            object : FolderHost {
                override fun me() = FolderMe("p_phone", "Pixel 9")

                override fun definitions() =
                    mapOf(
                        "f1" to
                            FolderDefinition(
                                "f1",
                                "Inbox",
                                FolderRules.parse(FolderRules.DEFAULT_RULES),
                            )
                    )

                override fun homes(folderId: String, preferred: String) =
                    if (preferred.isNotEmpty()) homes.filter { it == preferred } else homes

                override fun remote(machineId: String) = remotes.getValue(machineId)
            },
            scope,
            Clock.System,
            SilentLogger,
        )

    init {
        folders.bind(CoreStorage(FakeFileSystem(), "/state".toPath()))
    }

    private suspend fun attach(
        direction: FolderDirection = FolderDirection.FOLDER_DIRECTION_TWO_WAY
    ) {
        folders.attach("f1", "Inbox", "", "", direction, false, "")
        // Attaching starts a sync; let it finish so tests start from a settled folder.
        settle()
    }

    private suspend fun settle() =
        withContext(Dispatchers.Default) {
            withTimeout(10.seconds) {
                while (folders.view("f1")?.syncing == true) delay(10)
                delay(50)
                while (folders.view("f1")?.syncing == true) delay(10)
            }
        }

    private suspend fun window(trigger: FolderTrigger = FolderTrigger.BACKGROUND) =
        folders.window(Clock.System.now() + 5.minutes, "f1", trigger)

    @Test
    fun attachingKeepsTheFolderAndSchedulesTheWindow() = runTest {
        home.put("hello.txt", "hi".encodeToByteArray())
        attach()
        val settings = assertNotNull(folders.folder("f1"))
        assertEquals("private/f1", settings.location)
        assertEquals(60.minutes, scheduler.scheduled!!.interval)
        assertTrue(scheduler.scheduled!!.unmeteredOnly)
        window()
        assertContentEquals("hi".encodeToByteArray(), files.read("private/f1", "hello.txt"))
        val view = assertNotNull(folders.view("f1"))
        assertEquals(1, view.files)
        assertTrue(view.state.last_sync_millis > 0)
        scope.cancel()
    }

    @Test
    fun thePolicySkipsWithAReasonAndSyncNowStillRespectsTheNetwork() = runTest {
        attach()
        home.put("a.txt", "a".encodeToByteArray())
        conditions.conditions = FolderConditions(network = FolderNetwork.METERED)
        window()
        assertEquals("Waiting for Wi-Fi", folders.view("f1")!!.reason)
        assertNull(files.read("private/f1", "a.txt"))
        window(FolderTrigger.MANUAL)
        assertEquals("Waiting for Wi-Fi", folders.view("f1")!!.reason)
        conditions.conditions = FolderConditions()
        window()
        assertEquals("", folders.view("f1")!!.reason)
        assertTrue(files.exists("private/f1", "a.txt"))
        scope.cancel()
    }

    @Test
    fun anUnreachableHomeFailsOverToTheNextDaemon() = runTest {
        val dead =
            object : FolderRemote by home {
                override val daemonId = "d_dead"

                override suspend fun register(request: RegisterFolderClientRequest): FolderMember =
                    throw GrpcException(GrpcStatus.UNAVAILABLE, "unreachable")

                override suspend fun index(request: GetFolderIndexRequest): FolderIndexPage =
                    throw GrpcException(GrpcStatus.UNAVAILABLE, "unreachable")
            }
        remotes = mapOf("d_dead" to dead, "d_home" to home)
        homes = listOf("d_dead", "d_home")
        home.put("a.txt", "a".encodeToByteArray())
        attach()
        window()
        assertTrue(files.exists("private/f1", "a.txt"))
        assertEquals("d_home", folders.view("f1")!!.state.home_daemon_id)
        scope.cancel()
    }

    @Test
    fun aTapDownloadsAFileAboveTheLimitAndEvictionFreesIt() = runTest {
        folders.setDeviceSettings(FolderSettings.DEFAULTS.copy(auto_download_bytes = 0))
        home.put("movie.mp4", ByteArray(64) { it.toByte() })
        attach()
        window()
        assertFalse(files.exists("private/f1", "movie.mp4"))
        folders.download("f1", "movie.mp4")
        settle()
        window(FolderTrigger.MANUAL)
        assertTrue(files.exists("private/f1", "movie.mp4"))
        assertEquals(1, folders.evict("f1", "movie.mp4"))
        assertFalse(files.exists("private/f1", "movie.mp4"))
        // Freed, never deleted.
        window()
        assertTrue(home.live().containsKey("movie.mp4"))
        assertEquals(0, folders.view("f1")!!.localBytes)
        scope.cancel()
    }

    @Test
    fun restoringHeldLocalDeletionsDownloadsTheFilesAgain() = runTest {
        repeat(12) { home.put("f$it.txt", "$it".encodeToByteArray()) }
        attach()
        window()
        repeat(12) { files.remove("private/f1", "f$it.txt") }
        window()
        assertEquals("Confirm deletion of 12 files", folders.view("f1")!!.state.attention)
        folders.resolveDeletions("f1", apply = false)
        settle()
        window(FolderTrigger.MANUAL)
        assertEquals(12, files.files("private/f1").keys.count { it.endsWith(".txt") })
        assertEquals(12, home.live().size)
        assertEquals("", folders.view("f1")!!.state.attention)
        scope.cancel()
    }

    @Test
    fun savedFilesKeepTheirNameOrAFreeVariantAndReachTheDaemon() = runTest {
        attach(FolderDirection.FOLDER_DIRECTION_UPLOAD_ONLY)
        files.write("private/f1", "scan.pdf", "old".encodeToByteArray())
        shared["content://a"] = "first".encodeToByteArray()
        shared["content://b"] = "second".encodeToByteArray()
        shared["content://c"] = ByteArray(0)
        val outcome =
            folders.save(
                "f1",
                "",
                listOf(
                    FolderSaveRequest("content://a", "Scan.PDF"),
                    FolderSaveRequest("content://b", "notes/../.dieter-transfer-x:y.txt"),
                    FolderSaveRequest("content://gone", "lost.txt"),
                    FolderSaveRequest("content://c", ""),
                ),
            )
        // A name differing only by case is taken; path parts, protected prefixes and characters
        // FAT cannot store are dropped; an unreadable file is reported and the others saved.
        assertEquals(listOf("Scan (2).PDF", "xy.txt", "Shared file"), outcome.paths)
        assertTrue(outcome.problem.startsWith("lost.txt could not be saved"))
        assertContentEquals("old".encodeToByteArray(), files.read("private/f1", "scan.pdf"))
        assertContentEquals("first".encodeToByteArray(), files.read("private/f1", "Scan (2).PDF"))
        assertEquals(0, files.read("private/f1", "Shared file")!!.size)
        assertTrue(files.files("private/f1").keys.none { it.contains(".dieter-transfer-") })
        settle()
        window(FolderTrigger.MANUAL)
        assertContentEquals("second".encodeToByteArray(), home.content("xy.txt"))
        scope.cancel()
    }

    @Test
    fun savingIntoADirectoryCreatesIt() = runTest {
        attach()
        shared["content://a"] = "a".encodeToByteArray()
        val outcome =
            folders.save("f1", "Scans/2026", listOf(FolderSaveRequest("content://a", "a.txt")))
        assertEquals(listOf("Scans/2026/a.txt"), outcome.paths)
        assertEquals("", outcome.problem)
        assertTrue(files.exists("private/f1", "Scans/2026/a.txt"))
        scope.cancel()
    }

    @Test
    fun theDefaultLocationMovesAFolderToPrivateStorage() = runTest {
        folders.attach(
            "f1",
            "Inbox",
            "content://tree/inbox",
            "Documents/Inbox",
            FolderDirection.FOLDER_DIRECTION_TWO_WAY,
            false,
            "",
        )
        settle()
        assertEquals("content://tree/inbox", folders.folder("f1")!!.location)
        folders.setFolderSettings(
            folders.folder("f1")!!.copy(location = Folders.DEFAULT_LOCATION),
            "Inbox",
        )
        settle()
        assertEquals("private/f1", folders.folder("f1")!!.location)
        assertEquals("Private to Dieter", folders.folder("f1")!!.location_label)
        scope.cancel()
    }

    @Test
    fun cellularDataCountsPerMonth() = runTest {
        attach()
        assertEquals(0, folders.cellularBytes())
        conditions.conditions = FolderConditions(network = FolderNetwork.METERED)
        folders.setDeviceSettings(
            FolderSettings.DEFAULTS.copy(
                network = com.getdieter.core.v1.FolderNetworkPolicy.FOLDER_NETWORK_POLICY_ANY
            )
        )
        home.put("a.txt", ByteArray(300) { 1 })
        window()
        assertTrue(files.exists("private/f1", "a.txt"))
        assertEquals(300, folders.cellularBytes())
        scope.cancel()
    }

    @Test
    fun removingTheFolderForgetsItAndCanDeleteTheCopy() = runTest {
        home.put("a.txt", "a".encodeToByteArray())
        attach()
        window()
        folders.remove("f1", deleteLocalCopy = true)
        assertNull(folders.folder("f1"))
        assertNull(scheduler.scheduled)
        assertFalse(files.exists("private/f1", "a.txt"))
        assertTrue(home.live().containsKey("a.txt"))
        assertFalse(home.registered.containsKey("p_phone"))
        scope.cancel()
    }
}

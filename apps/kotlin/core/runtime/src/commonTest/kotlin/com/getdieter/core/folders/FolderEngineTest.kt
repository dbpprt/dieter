package com.getdieter.core.folders

import com.getdieter.api.v1.FolderDeleteGuard
import com.getdieter.api.v1.FolderEntryKind
import com.getdieter.core.runtime.SilentLogger
import com.getdieter.core.storage.CoreStorage
import com.getdieter.core.testing.FakeFolderDaemon
import com.getdieter.core.testing.FakeFolderFileSystem
import com.getdieter.core.testing.ManualClock
import com.getdieter.core.v1.FolderDirection
import com.getdieter.core.v1.FolderLocalSettings
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlin.time.Duration.Companion.minutes
import kotlin.time.Duration.Companion.seconds
import kotlinx.coroutines.test.runTest
import okio.Path.Companion.toPath
import okio.fakefilesystem.FakeFileSystem

/** The phone engine against a fake file system and a fake home daemon. */
class FolderEngineTest {
    private val clock = ManualClock()
    private val disk = FakeFileSystem()
    private val files = FakeFolderFileSystem()
    private val daemon = FakeFolderDaemon()
    private val me = FolderMe("p_phone", "Pixel 9")
    private val location = "private/f1"
    private var storage = CoreStorage(disk, "/state".toPath())
    private var settings =
        FolderLocalSettings(
            folder_id = "f1",
            direction = FolderDirection.FOLDER_DIRECTION_TWO_WAY,
            location = location,
        )
    private var device = FolderSettings.DEFAULTS.copy(auto_download_bytes = -1)
    private var definition =
        FolderDefinition("f1", "Inbox", FolderRules.parse(FolderRules.DEFAULT_RULES))

    private fun engine() =
        FolderEngine("f1", storage.scope("f1"), files, clock, SilentLogger).also {
            files.prepare(FolderRoot("f1", location))
        }

    private suspend fun FolderEngine.sync(
        decision: FolderRunDecision = FolderRunDecision.RunAll,
        budget: kotlin.time.Duration = 10.minutes,
    ): FolderRunResult =
        run(definition, FolderRunPlan(device, settings, decision, clock.now() + budget), daemon, me)

    private fun bytes(size: Int, seed: Int = 1) =
        ByteArray(size) { ((it * 31 + seed) % 251).toByte() }

    @Test
    fun downloadsTheDaemonsFilesAndUploadsLocalOnes() = runTest {
        daemon.mkdir("docs")
        daemon.put("docs/a.txt", "alpha".encodeToByteArray())
        files.write(location, "notes.md", "from the phone".encodeToByteArray())
        val engine = engine()
        val result = engine.sync()
        assertTrue(result.complete, result.toString())
        assertContentEquals("alpha".encodeToByteArray(), files.read(location, "docs/a.txt"))
        assertContentEquals("from the phone".encodeToByteArray(), daemon.content("notes.md"))
        val uploaded = assertNotNull(daemon.entries["notes.md"])
        assertEquals(listOf(me.actor), uploaded.version.map { it.actor })
        assertEquals("p_phone", uploaded.author_id)
        assertTrue(engine.index["notes.md"]!!.synced)
        assertTrue(engine.index["docs/a.txt"]!!.synced)
        assertTrue(daemon.registered.containsKey("p_phone"))
        // Nothing changed: the next run moves nothing.
        daemon.calls.clear()
        assertTrue(engine.sync().complete)
        assertEquals(listOf("index"), daemon.calls)
    }

    @Test
    fun aTouchOnlyChangeKeepsTheVersion() = runTest {
        files.write(location, "a.txt", "same".encodeToByteArray())
        val engine = engine()
        engine.sync()
        val before = daemon.entries.getValue("a.txt")
        files.write(location, "a.txt", "same".encodeToByteArray())
        engine.sync()
        assertEquals(before, daemon.entries.getValue("a.txt"))
        assertTrue(engine.index["a.txt"]!!.synced)
    }

    @Test
    fun anExpiredBudgetResumesFromTheJournal() = runTest {
        val content = bytes(3 * FolderBounds.CHUNK_SIZE + 17)
        daemon.put("video.mp4", content)
        // Every chunk takes a second of the window.
        daemon.beforeCall = { if (it.startsWith("read:")) clock.current += 1.seconds }
        val engine = engine()
        val first = engine.sync(budget = 1500.milliseconds())
        assertFalse(first.complete)
        assertNull(files.read(location, "video.mp4"))
        val journaled = engine.transfers.single()
        assertTrue(journaled.offset > 0, journaled.toString())
        daemon.calls.clear()
        val second = engine.sync()
        assertTrue(second.complete, second.toString())
        assertContentEquals(content, files.read(location, "video.mp4"))
        // It resumed: the first chunk was not read again.
        val reads = daemon.calls.filter { it.startsWith("read:") }
        assertFalse("read:0" in reads, reads.toString())
        assertTrue(engine.transfers.isEmpty())
    }

    @Test
    fun anInterruptedUploadResumesItsSession() = runTest {
        val content = bytes(3 * FolderBounds.CHUNK_SIZE)
        files.write(location, "big.bin", content)
        daemon.beforeCall = { if (it.startsWith("write:")) clock.current += 1.seconds }
        val engine = engine()
        assertFalse(engine.sync(budget = 1500.milliseconds()).complete)
        assertNull(daemon.content("big.bin"))
        daemon.calls.clear()
        assertTrue(engine.sync().complete)
        assertContentEquals(content, daemon.content("big.bin"))
        assertEquals(1, daemon.calls.count { it == "get" })
        assertFalse("write:0" in daemon.calls)
    }

    @Test
    fun aLosingLocalEditBecomesAConflictCopy() = runTest {
        daemon.put("report.txt", "v1".encodeToByteArray())
        val engine = engine()
        engine.sync()
        // The phone edits offline; the daemon gets a later edit meanwhile.
        files.write(location, "report.txt", "phone".encodeToByteArray(), modifiedNanos = 1)
        daemon.put("report.txt", "studio".encodeToByteArray())
        val result = engine.sync()
        assertTrue(result.complete, result.toString())
        assertContentEquals("studio".encodeToByteArray(), files.read(location, "report.txt"))
        val copy = daemon.live().keys.single { it.startsWith("report (conflict, Pixel 9, ") }
        assertTrue(copy.endsWith(").txt"))
        assertContentEquals("phone".encodeToByteArray(), daemon.content(copy))
        assertContentEquals("phone".encodeToByteArray(), files.read(location, copy))
    }

    @Test
    fun aWinningLocalEditKeepsTheRemoteVersionAsAConflictCopy() = runTest {
        daemon.put("plan.txt", "v1".encodeToByteArray())
        val engine = engine()
        engine.sync()
        daemon.put("plan.txt", "studio".encodeToByteArray())
        // The phone's edit is later, so it wins.
        files.write(
            location,
            "plan.txt",
            "phone".encodeToByteArray(),
            modifiedNanos = Long.MAX_VALUE / 2,
        )
        val result = engine.sync()
        assertTrue(result.complete, result.toString())
        assertContentEquals("phone".encodeToByteArray(), daemon.content("plan.txt"))
        assertContentEquals("phone".encodeToByteArray(), files.read(location, "plan.txt"))
        val copy = daemon.live().keys.single { it.startsWith("plan (conflict, Studio, ") }
        assertContentEquals("studio".encodeToByteArray(), daemon.content(copy))
        assertContentEquals("studio".encodeToByteArray(), files.read(location, copy))
        // The phone's version dominates the daemon's previous one.
        val versions = daemon.entries.getValue("plan.txt").version.map { it.actor }.toSet()
        assertEquals(setOf(me.actor, daemon.actor), versions)
    }

    @Test
    fun deletionsTravelAsTombstonesBothWays() = runTest {
        daemon.put("old.txt", "x".encodeToByteArray())
        daemon.put("keep.txt", "y".encodeToByteArray())
        files.write(location, "mine.txt", "z".encodeToByteArray())
        val engine = engine()
        engine.sync()
        daemon.delete("old.txt")
        files.remove(location, "mine.txt")
        assertTrue(engine.sync().complete)
        assertFalse(files.exists(location, "old.txt"))
        assertEquals(
            FolderEntryKind.FOLDER_ENTRY_KIND_DELETED,
            daemon.entries.getValue("mine.txt").kind,
        )
        assertEquals(
            FolderEntryKind.FOLDER_ENTRY_KIND_DELETED,
            engine.index["old.txt"]!!.entry!!.kind,
        )
        assertTrue(files.exists(location, "keep.txt"))
    }

    @Test
    fun filesAboveTheAutoDownloadLimitAreListedAndNeverDeleted() = runTest {
        device = device.copy(auto_download_bytes = 4)
        daemon.put("small.txt", "tiny".encodeToByteArray())
        daemon.put("large.bin", bytes(100))
        val engine = engine()
        assertTrue(engine.sync().complete)
        assertTrue(files.exists(location, "small.txt"))
        assertFalse(files.exists(location, "large.bin"))
        assertTrue(engine.index["large.bin"]!!.absent_by_policy)
        // Scans keep seeing it absent; it is never sent as a deletion.
        engine.sync()
        engine.sync()
        assertEquals(
            FolderEntryKind.FOLDER_ENTRY_KIND_FILE,
            daemon.entries.getValue("large.bin").kind,
        )
        assertTrue(daemon.calls.none { it == "apply" })
    }

    @Test
    fun uploadOnlyWithRemoveAfterUploadEvictsCommittedFiles() = runTest {
        settings =
            settings.copy(
                direction = FolderDirection.FOLDER_DIRECTION_UPLOAD_ONLY,
                remove_after_upload = true,
            )
        files.write(location, "scan.pdf", "pdf".encodeToByteArray())
        val engine = engine()
        assertTrue(engine.sync().complete)
        assertContentEquals("pdf".encodeToByteArray(), daemon.content("scan.pdf"))
        assertFalse(files.exists(location, "scan.pdf"))
        assertTrue(engine.index["scan.pdf"]!!.evicted)
        // The eviction is not a deletion.
        engine.sync()
        assertEquals(
            FolderEntryKind.FOLDER_ENTRY_KIND_FILE,
            daemon.entries.getValue("scan.pdf").kind,
        )
    }

    @Test
    fun aMassLocalDeletionTripsTheGuardUntilApplied() = runTest {
        repeat(20) { files.write(location, "f$it.txt", "$it".encodeToByteArray()) }
        val engine = engine()
        engine.sync()
        repeat(15) { files.remove(location, "f$it.txt") }
        val held = engine.sync()
        assertFalse(held.complete)
        assertEquals("Confirm deletion of 15 files", held.attention)
        assertEquals(20, daemon.live().size)
        assertEquals(15, engine.state.held_deletions!!.entries.size)
        // Applying records them on the next run.
        engine.edit {
            state = state.copy(deletions_confirmed = true, held_deletions = null, attention = "")
            saveState()
        }
        assertTrue(engine.sync().complete)
        assertEquals(5, daemon.live().size)
    }

    @Test
    fun aMassRemoteDeletionIsHeldBeforeItTouchesTheFiles() = runTest {
        definition = definition.copy(guard = FolderDeleteGuard.FOLDER_DELETE_GUARD_STRICT)
        repeat(12) { daemon.put("f$it.txt", "$it".encodeToByteArray()) }
        val engine = engine()
        engine.sync()
        repeat(12) { daemon.delete("f$it.txt") }
        val held = engine.sync()
        assertEquals("Confirm deletion of 12 files", held.attention)
        assertEquals(12, files.files(location).keys.count { it.endsWith(".txt") })
        // A held folder stays paused.
        assertEquals("Confirm deletion of 12 files", engine.sync().attention)
    }

    @Test
    fun aMissingLocationPausesInsteadOfDeleting() = runTest {
        daemon.put("a.txt", "a".encodeToByteArray())
        val engine = engine()
        engine.sync()
        files.available[location] = false
        val result = engine.sync()
        assertEquals(FolderRun.LOCATION_UNAVAILABLE, result.attention)
        assertEquals(FolderEntryKind.FOLDER_ENTRY_KIND_FILE, daemon.entries.getValue("a.txt").kind)
        files.available[location] = true
        files.replaceRoot(location)
        assertEquals(FolderRun.LOCATION_UNAVAILABLE, engine.sync().attention)
        assertTrue(daemon.calls.none { it == "apply" })
    }

    @Test
    fun receiveOnlyNeverUploadsAndKeepsLocalChanges() = runTest {
        settings = settings.copy(direction = FolderDirection.FOLDER_DIRECTION_DOWNLOAD_ONLY)
        daemon.put("report.txt", "v1".encodeToByteArray())
        files.write(location, "local.txt", "mine".encodeToByteArray())
        val engine = engine()
        assertTrue(engine.sync().complete)
        assertNull(daemon.entries["local.txt"])
        assertTrue(engine.index["local.txt"]!!.local_change)
        files.write(location, "report.txt", "edited here".encodeToByteArray())
        engine.sync()
        assertContentEquals("v1".encodeToByteArray(), daemon.content("report.txt"))
        // A remote change keeps the local edit as a conflict copy.
        daemon.put("report.txt", "v2".encodeToByteArray())
        engine.sync()
        assertContentEquals("v2".encodeToByteArray(), files.read(location, "report.txt"))
        val copy = files.files(location).keys.single { it.startsWith("report (conflict, Pixel 9") }
        assertContentEquals("edited here".encodeToByteArray(), files.read(location, copy))
        assertTrue(daemon.calls.none { it == "begin" || it == "apply" })
    }

    @Test
    fun sendOnlyNeverAppliesRemoteChanges() = runTest {
        settings = settings.copy(direction = FolderDirection.FOLDER_DIRECTION_UPLOAD_ONLY)
        daemon.put("theirs.txt", "remote".encodeToByteArray())
        files.write(location, "mine.txt", "local".encodeToByteArray())
        val engine = engine()
        engine.sync()
        assertFalse(files.exists(location, "theirs.txt"))
        assertContentEquals("local".encodeToByteArray(), daemon.content("mine.txt"))
        assertEquals(listOf("theirs.txt"), engine.state.out_of_sync)
    }

    @Test
    fun smallOnlyLeavesLargeFilesForLater() = runTest {
        daemon.put("small.txt", "s".encodeToByteArray())
        daemon.put("large.bin", bytes(5000))
        val engine = engine()
        val result =
            engine.sync(FolderRunDecision.SmallOnly(100, "Files over 100 B wait for Wi-Fi"))
        assertFalse(result.complete)
        assertEquals("Files over 100 B wait for Wi-Fi", result.reason)
        assertTrue(files.exists(location, "small.txt"))
        assertFalse(files.exists(location, "large.bin"))
        assertTrue(engine.sync().complete)
        assertTrue(files.exists(location, "large.bin"))
    }

    @Test
    fun theIndexSurvivesARestart() = runTest {
        daemon.put("a.txt", "a".encodeToByteArray())
        files.write(location, "b.txt", "b".encodeToByteArray())
        engine().sync()
        val restarted = engine()
        assertEquals(
            setOf("a.txt", "b.txt"),
            restarted.index.entries().map { it.entry!!.path }.toSet(),
        )
        assertEquals(daemon.indexId, restarted.state.index_id)
        daemon.calls.clear()
        assertTrue(restarted.sync().complete)
        assertEquals(listOf("index"), daemon.calls)
    }

    @Test
    fun excludedAndProtectedPathsNeverSync() = runTest {
        files.write(location, ".DS_Store", "x".encodeToByteArray())
        files.write(location, "a/.dieter-transfer-1", "x".encodeToByteArray())
        files.write(location, "notes.swp", "x".encodeToByteArray())
        files.write(location, "keep.txt", "x".encodeToByteArray())
        engine().sync()
        assertEquals(setOf("a", "keep.txt"), daemon.live().keys)
    }

    private fun Int.milliseconds() = kotlin.time.Duration.parse("${this}ms")
}

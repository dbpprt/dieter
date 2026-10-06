package com.dbpprt.dieter.core.sync

import com.dbpprt.dieter.api.v1.ChangesCursor
import com.dbpprt.dieter.api.v1.ChangesFrame
import com.dbpprt.dieter.core.runtime.SilentLogger
import com.dbpprt.dieter.core.storage.CoreStorage
import com.dbpprt.dieter.core.store.WorkspaceStore
import com.dbpprt.dieter.core.sync.TestRecords.board
import com.dbpprt.dieter.core.sync.TestRecords.checkout
import com.dbpprt.dieter.core.sync.TestRecords.field
import com.dbpprt.dieter.core.sync.TestRecords.item
import com.dbpprt.dieter.core.sync.TestRecords.project
import com.dbpprt.dieter.core.testing.ManualClock
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlinx.coroutines.test.runTest
import okio.Path.Companion.toPath
import okio.fakefilesystem.FakeFileSystem

class AccountSyncTest {
    private val fileSystem = FakeFileSystem()
    private val storage = CoreStorage(fileSystem, "/state".toPath())
    private val clock = ManualClock()
    private val records =
        project("p", "Atlas") +
            checkout("co", "p", "studio") +
            board("b", "p") +
            item("c", "p", "co", owner = "studio", boardId = "b")

    private fun frame(sequence: Long, vararg extra: com.dbpprt.dieter.api.v1.PeerRecord) =
        ChangesFrame(
            daemon_id = "studio",
            account = "account",
            cursor =
                ChangesCursor(
                    records_epoch = "e",
                    records_sequence = sequence,
                    local_epoch = "l",
                    local_sequence = 1,
                ),
            reset_records = sequence == 1L,
            reset_local = sequence == 1L,
            caught_up = true,
            records = if (sequence == 1L) records else extra.toList(),
        )

    @Test
    fun caughtUpPublishesActiveWorkBeforeTheStreamCanReportLive() = runTest {
        val store = WorkspaceStore()
        val sync = AccountSync(store, backgroundScope, clock, SilentLogger)
        sync.bind(storage)
        sync.apply("studio", frame(1))
        assertTrue(store.state.value.loaded)
        sync.apply("studio", frame(2, field("item", "c", "summary", """{"runtime":"running"}""")))
        // No dispatcher yield: a Smart window inspects this immediately after Live.
        assertEquals("running", store.state.value.card("c")?.runtime)
        sync.apply(
            "studio",
            frame(3, field("item", "c", "summary", """{"runtime":"idle","responseSeq":9}""")),
        )
        assertEquals(9L, store.state.value.card("c")?.response_seq)
    }

    @Test
    fun anEmptyCompleteViewIsLoadedWithoutAContentChange() = runTest {
        val store = WorkspaceStore()
        val sync = AccountSync(store, backgroundScope, clock, SilentLogger)
        sync.apply(
            "empty",
            ChangesFrame(reset_records = true, reset_local = true, caught_up = true),
        )
        assertTrue(store.state.value.loaded)
        assertTrue(sync.loaded.value)
    }

    @Test
    fun framesFromAnyMachineCoalesceIntoOneViewInTheStore() = runTest {
        val store = WorkspaceStore()
        val sync = AccountSync(store, backgroundScope, clock, SilentLogger)
        sync.bind(storage)
        assertFalse(sync.loaded.value)
        sync.apply("studio", frame(1))
        sync.apply(
            "studio",
            frame(
                2,
                field("item", "c", "title", "\"Renamed\"")
                    .copy(revision = "r2", value_revision = "r2"),
            ),
        )
        testScheduler.runCurrent()
        assertTrue(store.state.value.loaded)
        assertEquals("Renamed", store.state.value.card("c")?.title)
        assertEquals(clock.current, sync.updatedAt.value["studio"])
        assertEquals(listOf("studio"), sync.observers("item/c.title"))
    }

    @Test
    fun everyMachinesViewSurvivesARestartAndResumesFromItsCursor() = runTest {
        val first = AccountSync(WorkspaceStore(), backgroundScope, clock, SilentLogger)
        first.bind(storage)
        first.apply("studio", frame(1))
        first.flush()

        val store = WorkspaceStore()
        val restored = AccountSync(store, backgroundScope, clock, SilentLogger)
        restored.bind(storage)
        assertEquals(
            "Atlas",
            store.state.value.project("p")?.name,
            "the cached view renders before any network access",
        )
        assertEquals(1L, restored.cursor("studio")?.records_sequence)
        assertEquals(clock.current, restored.updatedAt.value["studio"])
        assertTrue(restored.loaded.value)
    }

    @Test
    fun machinesThatLeaveTheAccountTakeTheirViewAndCacheWithThem() = runTest {
        val store = WorkspaceStore()
        val sync = AccountSync(store, backgroundScope, clock, SilentLogger)
        sync.bind(storage)
        sync.apply("studio", frame(1))
        sync.apply(
            "laptop",
            ChangesFrame(
                daemon_id = "laptop",
                cursor = ChangesCursor(records_epoch = "e2", records_sequence = 1),
                reset_records = true,
                reset_local = true,
                caught_up = true,
                records = project("q", "Beacon"),
            ),
        )
        sync.flush()
        sync.publish()
        assertEquals(listOf("Atlas", "Beacon"), store.state.value.projects.map { it.name })

        sync.retain(setOf("studio"))
        sync.publish()
        assertEquals(listOf("Atlas"), store.state.value.projects.map { it.name })
        assertTrue(storage.names().none { it.contains("laptop") })
    }

    @Test
    fun aCleanSyncReplaysEveryStreamWhileTheViewStays() = runTest {
        val store = WorkspaceStore()
        val sync = AccountSync(store, backgroundScope, clock, SilentLogger)
        sync.bind(storage)
        sync.apply("studio", frame(1))
        sync.apply(
            "studio",
            frame(
                2,
                field("item", "c", "title", "\"Renamed\"")
                    .copy(revision = "r2", value_revision = "r2"),
            ),
        )
        sync.rewind()
        assertNull(sync.cursor("studio"), "the stream replays from the beginning")
        sync.flush()
        assertNull(
            AccountSync(WorkspaceStore(), backgroundScope, clock, SilentLogger)
                .also { it.bind(storage) }
                .cursor("studio"),
            "a restart still replays",
        )

        // A frame the old stream had in flight is not part of the replay.
        sync.apply(
            "studio",
            frame(
                3,
                field("item", "c", "title", "\"Stale\"")
                    .copy(revision = "r3", value_revision = "r3"),
            ),
        )
        assertNull(sync.cursor("studio"))
        val replay =
            frame(1)
                .copy(
                    caught_up = false,
                    cursor =
                        ChangesCursor(
                            records_epoch = "e2",
                            records_sequence = 1,
                            local_epoch = "l2",
                            local_sequence = 1,
                        ),
                )
        sync.apply("studio", replay)
        sync.publish()
        assertEquals(
            "Renamed",
            store.state.value.card("c")?.title,
            "the view stays until the replay caught up",
        )
        sync.apply(
            "studio",
            ChangesFrame(
                daemon_id = "studio",
                account = "account",
                cursor =
                    ChangesCursor(
                        records_epoch = "e2",
                        records_sequence = 2,
                        local_epoch = "l2",
                        local_sequence = 1,
                    ),
                caught_up = true,
            ),
        )
        sync.publish()
        assertEquals("c", store.state.value.card("c")?.title, "then the replayed view replaces it")
        assertEquals("e2", sync.cursor("studio")?.records_epoch)
    }
}

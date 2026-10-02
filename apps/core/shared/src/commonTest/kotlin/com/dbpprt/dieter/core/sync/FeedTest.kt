package com.dbpprt.dieter.core.sync

import com.dbpprt.dieter.api.v1.GlobalSnapshot
import com.dbpprt.dieter.api.v1.SyncFrame
import com.dbpprt.dieter.core.runtime.SilentLogger
import com.dbpprt.dieter.core.storage.CoreStorage
import com.dbpprt.dieter.core.store.WorkspaceStore
import com.dbpprt.dieter.core.testing.ManualClock
import com.dbpprt.dieter.core.testing.offlineSessions
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.time.Instant
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import okio.Path.Companion.toPath
import okio.fakefilesystem.FakeFileSystem

class FeedTest {
    private val storage = CoreStorage(FakeFileSystem(), "/state".toPath())
    private val clock = ManualClock()
    private val applied = Instant.parse("2026-09-30T10:00:00Z")

    private fun feed() = Feed("d1", offlineSessions(), storage, WorkspaceStore(clock), CoroutineScope(Dispatchers.Unconfined), FeedConfig(), clock, SilentLogger)

    @Test
    fun theLastUpdateTimeSurvivesARestartWithItsProjection() {
        storage.write("feed-${CoreStorage.safeName("d1")}.applied", applied.toEpochMilliseconds().toString().encodeToByteArray())
        // Without the projection it describes, the time is not trusted.
        assertNull(feed().status.value.lastAppliedAt)

        storage.write("feed-${CoreStorage.safeName("d1")}.pb", SyncFrame.ADAPTER.encode(SyncFrame(snapshot = GlobalSnapshot())))
        assertEquals(applied, feed().status.value.lastAppliedAt)

        storage.write("feed-${CoreStorage.safeName("d1")}.applied", "not a time".encodeToByteArray())
        assertNull(feed().status.value.lastAppliedAt)
    }
}

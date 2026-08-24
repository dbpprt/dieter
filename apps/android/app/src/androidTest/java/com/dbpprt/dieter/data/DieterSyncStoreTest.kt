package com.dbpprt.dieter.data

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.dbpprt.dieter.v1.GlobalSnapshot
import com.dbpprt.dieter.v1.SyncCursor
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.util.UUID

@RunWith(AndroidJUnit4::class)
class DieterSyncStoreTest {
    @Test
    fun cleanSyncClearsEveryProjectionAndPreservesOutbox() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val root = File(context.cacheDir, "sync-store-test-${UUID.randomUUID()}")
        try {
            val store = DieterSyncStore(context, root)
            val firstScope = "https://one.example:443#daemon-one"
            val secondScope = "https://two.example:443#daemon-two"
            val snapshot = GlobalSnapshot.newBuilder().build()
            val cursor = SyncCursor.newBuilder().setEpoch("epoch-one").setSequence(42).build()
            val entry = AndroidOutboxEntry(
                commandId = "command-one",
                clientId = store.clientId,
                endpointId = firstScope,
                kind = OutboxKind.SEND_MESSAGE,
                request = byteArrayOf(1, 2, 3),
                optimisticId = "message-one",
            )
            store.saveProjection(firstScope, snapshot, cursor)
            store.saveProjection(secondScope, snapshot, cursor)
            store.saveOutbox(listOf(entry))

            store.clearProjections()

            assertNull(store.loadSnapshot(firstScope))
            assertNull(store.loadCursor(firstScope))
            assertNull(store.loadSnapshot(secondScope))
            assertNull(store.loadCursor(secondScope))
            val restoredOutbox = store.loadOutbox()
            assertEquals(1, restoredOutbox.size)
            assertEquals(entry.commandId, restoredOutbox.single().commandId)
            assertArrayEquals(entry.request, restoredOutbox.single().request)
        } finally {
            root.deleteRecursively()
        }
    }
}

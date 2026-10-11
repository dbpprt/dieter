package com.dbpprt.dieter.core.connection

import com.dbpprt.dieter.client.v1.MachineEntry
import com.dbpprt.dieter.client.v1.MachineOutbox
import com.dbpprt.dieter.core.runtime.FailureKind
import com.dbpprt.dieter.core.runtime.Failures
import com.dbpprt.dieter.core.session.MachineSessions
import com.squareup.wire.GrpcException
import com.squareup.wire.GrpcStatus
import kotlin.test.*

class StorageWarningsTest {
    @Test
    fun storageRetriesStayVisibleWithoutBecomingFailedCommands() {
        val machine =
            MachineEntry(id = "studio", name = "Studio", detail = "no space left on device")
        val outbox =
            MachineOutbox(
                daemon_id = "studio",
                phase = MachineOutbox.Phase.PHASE_WAITING_FOR_STORAGE,
                title = "Low disk space on Studio",
                detail =
                    "1 message queued. Free disk space on Studio; retries automatically every minute.",
            )
        val warnings = StorageWarnings.of(listOf(machine), listOf(outbox))
        assertEquals(listOf(StorageWarning("studio", outbox.title, outbox.detail)), warnings)
        assertEquals(
            1,
            StorageWarnings.of(listOf(machine), emptyList()).size,
            "a failed read needs no queued send to show a warning",
        )
        assertTrue(
            StorageWarnings.of(listOf(machine.copy(detail = "Online")), emptyList()).isEmpty(),
            "recovery clears the warning",
        )
        assertTrue(
            StorageWarnings.of(
                    emptyList(),
                    listOf(outbox.copy(phase = MachineOutbox.Phase.PHASE_RETRYING)),
                )
                .isEmpty()
        )
    }

    @Test
    fun sqliteAndFilesystemCapacityFailuresReceiveTheSameSlowRetry() {
        for (message in
            listOf(
                "database or disk is full (13)",
                "no space left on device",
                "disk quota exceeded",
            )) {
            assertEquals(
                FailureKind.OUT_OF_STORAGE,
                Failures.kind(GrpcException(GrpcStatus.RESOURCE_EXHAUSTED, message)),
            )
            assertFalse(
                MachineSessions.isTransportFailure(
                    GrpcException(GrpcStatus.RESOURCE_EXHAUSTED, message)
                ),
                "a failed write must not close concurrent read streams",
            )
        }
        assertEquals(
            FailureKind.TRANSIENT,
            Failures.kind(GrpcException(GrpcStatus.RESOURCE_EXHAUSTED, "too many streams")),
        )
    }
}

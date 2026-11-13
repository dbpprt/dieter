package com.getdieter.core.folders

import com.getdieter.api.v1.Folder
import com.getdieter.api.v1.FolderHead
import com.getdieter.api.v1.FolderMode
import com.getdieter.api.v1.FolderState
import com.getdieter.api.v1.KVEntry
import com.getdieter.core.v1.FolderDirection
import com.getdieter.core.v1.FolderLocalSettings
import com.getdieter.core.v1.FolderSyncState
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.time.Instant
import okio.ByteString.Companion.encodeUtf8

/** Daemon members from `folder-member` records and the status lines every client shows. */
class FolderPresentationTest {
    private val now = Instant.parse("2026-11-13T14:00:00Z")

    private fun kv(key: String, json: String) =
        KVEntry(namespace = FolderMembers.NAMESPACE, key = key, value_json = json.encodeUtf8())

    private val studio =
        kv(
            "f1.d_studio",
            """{"folderId":"f1","daemonId":"d_studio","name":"Studio","mode":"two-way","paused":false,
               "state":"idle","sequence":42,"indexId":"i1","lastSyncAt":"2026-11-13T13:57:00Z",
               "needFiles":0,"needBytes":0,"conflicts":0,
               "clients":[{"deviceId":"p_pixel","name":"Pixel 9","mode":"send-only",
                           "lastSeenAt":"2026-11-13T13:00:00Z","acknowledged":40}]}""",
        )
    private val box =
        kv(
            "f1.d_box",
            """{"folderId":"f1","daemonId":"d_box","name":"box","mode":"receive-only","paused":true,"state":4}""",
        )

    @Test
    fun membersParseFromTheirRecords() {
        val members =
            FolderMembers.of(mapOf("a" to studio, "b" to box, "c" to kv("f2.d_x", "{}")), "f1")
        assertEquals(listOf("box", "Studio"), members.map { it.name })
        val first = members.single { it.daemonId == "d_studio" }
        assertEquals(FolderMode.FOLDER_MODE_TWO_WAY, first.mode)
        assertEquals(FolderState.FOLDER_STATE_IDLE, first.state)
        assertEquals(Instant.parse("2026-11-13T13:57:00Z"), first.lastSyncAt)
        assertEquals(FolderMode.FOLDER_MODE_SEND_ONLY, first.clients.single().mode)
        val second = members.single { it.daemonId == "d_box" }
        assertEquals(FolderMode.FOLDER_MODE_RECEIVE_ONLY, second.mode)
        assertEquals(FolderState.FOLDER_STATE_PAUSED, second.state)
        assertEquals(true, second.paused)
    }

    @Test
    fun statusLinesReadTheSameEverywhere() {
        val members =
            FolderMembers.of(mapOf("a" to studio), "f1").map { FolderDaemonState(it, null) }
        val folder = Folder(id = "f1", name = "Inbox")
        assertEquals(
            FolderStatusLine("Up to date · 3m ago · not on this device", FolderTone.NEUTRAL),
            FolderPresentation.folder(folder, null, members, now),
        )
        val syncing = members.map {
            it.copy(
                head =
                    FolderHead(
                        folder_id = "f1",
                        state = FolderState.FOLDER_STATE_SYNCING,
                        need_files = 3,
                    )
            )
        }
        assertEquals(
            "Syncing on Studio",
            FolderPresentation.folder(folder, null, syncing, now).text,
        )
        assertEquals("Syncing · 3 files", FolderPresentation.daemon(syncing.single(), now).text)
        val attention = members.map {
            it.copy(
                head =
                    FolderHead(
                        folder_id = "f1",
                        state = FolderState.FOLDER_STATE_ATTENTION,
                        state_detail = "Confirm deletion of 412 files",
                    )
            )
        }
        assertEquals(
            FolderStatusLine("Studio: Confirm deletion of 412 files", FolderTone.DANGER),
            FolderPresentation.folder(folder, null, attention, now),
        )
        assertEquals(
            "No machine keeps it yet",
            FolderPresentation.folder(folder, null, emptyList(), now).text,
        )
        assertEquals(
            "Archived",
            FolderPresentation.folder(folder.copy(archived = true), null, members, now).text,
        )
        assertEquals("Studio · 2 phones", FolderPresentation.members(members, 2))
    }

    @Test
    fun thisDevicesLineSaysWhyItWaits() {
        fun view(
            reason: String = "",
            attention: String = "",
            uploads: Int = 0,
            last: Long = 0,
            direction: FolderDirection = FolderDirection.FOLDER_DIRECTION_TWO_WAY,
            conflicts: List<String> = emptyList(),
        ) =
            FolderLocalView(
                folderId = "f1",
                settings = FolderLocalSettings(folder_id = "f1", direction = direction),
                state = FolderSyncState(attention = attention, last_sync_millis = last),
                syncing = false,
                reason = reason,
                pendingUploads = uploads,
                pendingUploadBytes = 0,
                pendingDownloads = 0,
                pendingDownloadBytes = 0,
                files = 0,
                bytes = 0,
                localBytes = 0,
                conflicts = conflicts,
                localChanges = emptyList(),
                error = "",
            )
        assertEquals(
            "Waiting for Wi-Fi",
            FolderPresentation.device(view(reason = "Waiting for Wi-Fi"), now).text,
        )
        assertEquals(
            FolderStatusLine("Folder location unavailable", FolderTone.DANGER),
            FolderPresentation.device(
                view(attention = "Folder location unavailable", reason = "x"),
                now,
            ),
        )
        assertEquals(
            "Paused",
            FolderPresentation.device(
                    view(direction = FolderDirection.FOLDER_DIRECTION_PAUSED),
                    now,
                )
                .text,
        )
        assertEquals(
            "2 conflicts",
            FolderPresentation.device(view(conflicts = listOf("a", "b")), now).text,
        )
        assertEquals("↑ 3 files waiting", FolderPresentation.device(view(uploads = 3), now).text)
        assertEquals(
            "Up to date · 1h ago",
            FolderPresentation.device(view(last = now.toEpochMilliseconds() - 3_600_000), now).text,
        )
        assertEquals("Not synced yet", FolderPresentation.device(view(), now).text)
        assertEquals(
            "↑ 1 file (2 MB) · ↓ 4 files",
            FolderPresentation.pending(1, 2 * FolderSettings.MB, 4, 0),
        )
    }
}

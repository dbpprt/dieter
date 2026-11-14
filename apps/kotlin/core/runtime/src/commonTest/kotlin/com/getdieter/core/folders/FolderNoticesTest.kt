package com.getdieter.core.folders

import com.getdieter.core.v1.FolderLocalSettings
import com.getdieter.core.v1.FolderSyncState
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/** Folder notifications: what is posted and removed after a window, per the device settings. */
class FolderNoticesTest {
    private val names = mapOf("f1" to "Specs", "f2" to "Inbox")

    private fun view(
        id: String = "f1",
        conflicts: List<String> = emptyList(),
        attention: String = "",
        reason: String = "",
        uploads: Int = 0,
        downloads: Int = 0,
        lastSync: Long = 0,
    ) =
        FolderLocalView(
            folderId = id,
            settings = FolderLocalSettings(folder_id = id),
            state =
                FolderSyncState(folder_id = id, attention = attention, last_sync_millis = lastSync),
            syncing = false,
            reason = reason,
            pendingUploads = uploads,
            pendingUploadBytes = 0,
            pendingDownloads = downloads,
            pendingDownloadBytes = 0,
            files = 0,
            bytes = 0,
            localBytes = 0,
            conflicts = conflicts,
            localChanges = emptyList(),
            error = "",
        )

    private val conflictsKey = FolderNotices.key("f1", FolderNoticeKind.CONFLICTS)
    private val attentionKey = FolderNotices.key("f1", FolderNoticeKind.ATTENTION)
    private val finishedKey = FolderNotices.key("f1", FolderNoticeKind.FINISHED)

    @Test
    fun newConflictsAndAttentionPostOnceAndClearWhenResolved() {
        val copy = "a (conflict, Pixel 9, 2026-11-13 14.12).txt"
        val first =
            FolderNotices.diff(
                listOf(view()),
                listOf(view(conflicts = listOf(copy), attention = "Confirm deletion of 412 files")),
                names,
                FolderSettings.DEFAULTS,
            )
        assertEquals(
            listOf(
                FolderNotice(
                    conflictsKey,
                    "f1",
                    FolderNoticeKind.CONFLICTS,
                    "Specs",
                    "1 conflict. Choose which version to keep.",
                ),
                FolderNotice(
                    attentionKey,
                    "f1",
                    FolderNoticeKind.ATTENTION,
                    "Specs",
                    "Confirm deletion of 412 files",
                ),
            ),
            first.post,
        )
        // The same state again posts nothing new.
        val same =
            listOf(view(conflicts = listOf(copy), attention = "Confirm deletion of 412 files"))
        assertTrue(FolderNotices.diff(same, same, names, FolderSettings.DEFAULTS).post.isEmpty())
        // Resolved: both go.
        val resolved = FolderNotices.diff(same, listOf(view()), names, FolderSettings.DEFAULTS)
        assertTrue(resolved.post.isEmpty())
        assertTrue(resolved.cancel.containsAll(listOf(conflictsKey, attentionKey)))
    }

    @Test
    fun aReachedStorageLimitNeedsAttentionButWaitingForWiFiDoesNot() {
        val limit =
            FolderNotices.diff(
                listOf(view()),
                listOf(view(reason = FolderSyncPolicy.STORAGE_FULL)),
                names,
                FolderSettings.DEFAULTS,
            )
        assertEquals("Storage limit reached", limit.post.single().text)
        val wifi =
            FolderNotices.diff(
                listOf(view()),
                listOf(view(reason = "Waiting for Wi-Fi")),
                names,
                FolderSettings.DEFAULTS,
            )
        assertTrue(wifi.post.isEmpty())
    }

    @Test
    fun syncFinishedOnlyWhenTurnedOnAndFilesMoved() {
        val before = listOf(view(uploads = 2, downloads = 1, lastSync = 10))
        val after = listOf(view(lastSync = 20))
        assertTrue(
            FolderNotices.diff(before, after, names, FolderSettings.DEFAULTS).post.none {
                it.kind == FolderNoticeKind.FINISHED
            }
        )
        val on = FolderSettings.DEFAULTS.copy(notify_finished = true)
        assertEquals(
            "Up to date · 3 files synced",
            FolderNotices.diff(before, after, names, on).post.single().text,
        )
        // Nothing moved: no notification.
        assertTrue(FolderNotices.diff(listOf(view(lastSync = 10)), after, names, on).post.isEmpty())
    }

    @Test
    fun settingsTurnedOffAndRemovedFoldersClearTheirNotifications() {
        val off = FolderSettings.DEFAULTS.copy(notify_conflicts = false, notify_attention = false)
        val changes =
            FolderNotices.diff(
                listOf(view(), view("f2")),
                listOf(view(conflicts = listOf("x (conflict, a, b).txt"), attention = "Paused")),
                names,
                off,
            )
        assertTrue(changes.post.isEmpty())
        assertTrue(changes.cancel.containsAll(listOf(conflictsKey, attentionKey, finishedKey)))
        assertTrue(
            changes.cancel.containsAll(FolderNoticeKind.entries.map { FolderNotices.key("f2", it) })
        )
    }
}

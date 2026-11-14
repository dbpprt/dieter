package com.getdieter.core.folders

import com.getdieter.core.v1.FolderDeviceSettings

/** What a folder notification is about; each folder has at most one of each. */
enum class FolderNoticeKind {
    CONFLICTS,
    /** A held deletion, a lost location, a reached limit. */
    ATTENTION,
    FINISHED,
}

/** A notification folder sync posts on this device; [key] is its platform tag. */
data class FolderNotice(
    val key: String,
    val folderId: String,
    val kind: FolderNoticeKind,
    val title: String,
    val text: String,
)

/** Notifications to post, and the tags of those to remove. */
data class FolderNoticeChanges(val post: List<FolderNotice>, val cancel: List<String>)

/**
 * The notifications of Settings › Folder sync (conflicts, needs attention, sync finished), decided
 * once for every phone from this device's folders before and after a sync window.
 */
object FolderNotices {
    fun key(folderId: String, kind: FolderNoticeKind) = "folder-$folderId-${kind.name.lowercase()}"

    /** Reasons that wait for the person rather than for the network or the battery. */
    private val ATTENTION_REASONS = setOf(FolderSyncPolicy.STORAGE_FULL)

    /** What needs the person in [view], or empty. */
    fun attention(view: FolderLocalView): String =
        view.state.attention.ifEmpty { view.reason.takeIf { it in ATTENTION_REASONS }.orEmpty() }

    /**
     * Compares [before] and [after] (this device's folders around a window) with the device
     * [settings]: new conflict copies, a new attention and a sync that moved files and finished
     * post a notification, by folder name from [names]; resolved ones and those the settings turn
     * off are removed. A folder no longer on this device removes all of its notifications.
     */
    fun diff(
        before: List<FolderLocalView>,
        after: List<FolderLocalView>,
        names: Map<String, String>,
        settings: FolderDeviceSettings,
    ): FolderNoticeChanges {
        val post = ArrayList<FolderNotice>()
        val cancel = ArrayList<String>()
        val previous = before.associateBy { it.folderId }
        val current = after.mapTo(HashSet()) { it.folderId }
        for (gone in previous.keys - current) FolderNoticeKind.entries.forEach {
            cancel += key(gone, it)
        }
        for (view in after) {
            val id = view.folderId
            val old = previous[id]
            val title = names[id]?.ifBlank { null } ?: "Synced folder"
            fun notice(kind: FolderNoticeKind, text: String) =
                FolderNotice(key(id, kind), id, kind, title, text)

            val conflicts = view.conflicts
            when {
                !settings.notify_conflicts || conflicts.isEmpty() ->
                    cancel += key(id, FolderNoticeKind.CONFLICTS)
                (conflicts - old?.conflicts.orEmpty().toSet()).isNotEmpty() ->
                    post +=
                        notice(
                            FolderNoticeKind.CONFLICTS,
                            "${FolderPresentation.conflicts(conflicts.size)}. " +
                                "Choose which version to keep.",
                        )
            }

            val attention = attention(view)
            when {
                !settings.notify_attention || attention.isEmpty() ->
                    cancel += key(id, FolderNoticeKind.ATTENTION)
                old == null || attention != attention(old) ->
                    post += notice(FolderNoticeKind.ATTENTION, attention)
            }

            val moved = old?.let { it.pendingUploads + it.pendingDownloads } ?: 0
            val finished =
                old != null &&
                    moved > 0 &&
                    view.pendingUploads + view.pendingDownloads == 0 &&
                    view.state.last_sync_millis > old.state.last_sync_millis
            when {
                !settings.notify_finished -> cancel += key(id, FolderNoticeKind.FINISHED)
                finished ->
                    post +=
                        notice(
                            FolderNoticeKind.FINISHED,
                            "Up to date · ${FolderPresentation.files(moved.toLong())} synced",
                        )
            }
        }
        return FolderNoticeChanges(post, cancel)
    }
}

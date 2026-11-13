package com.getdieter.core.folders

import com.getdieter.api.v1.FolderDeleteGuard
import com.getdieter.api.v1.FolderEntry
import com.getdieter.api.v1.FolderEntryKind

/** The deletion guard and the order of work (`internal/folders/guard.go`). */
object FolderGuard {
    /**
     * Whether deleting [deletions] of [total] entries in one batch needs a person's confirmation.
     * Default: more than 100 files or more than 30% of the folder, with at least 10. Strict: more
     * than 10 or more than 10%, with at least 3.
     */
    fun trips(policy: FolderDeleteGuard, deletions: Int, total: Int): Boolean {
        var floor = 10
        var files = 100
        var percent = 30
        when (policy) {
            FolderDeleteGuard.FOLDER_DELETE_GUARD_OFF -> return false
            FolderDeleteGuard.FOLDER_DELETE_GUARD_STRICT -> {
                floor = 3
                files = 10
                percent = 10
            }
            else -> Unit
        }
        if (deletions < floor) return false
        return deletions > files || deletions.toLong() * 100 > percent.toLong() * total
    }

    /** The policy a shared `deleteGuard` value names; unknown values guard by default. */
    fun policy(value: String): FolderDeleteGuard =
        when (value) {
            "strict" -> FolderDeleteGuard.FOLDER_DELETE_GUARD_STRICT
            "off" -> FolderDeleteGuard.FOLDER_DELETE_GUARD_OFF
            else -> FolderDeleteGuard.FOLDER_DELETE_GUARD_DEFAULT
        }

    private fun rank(entry: FolderEntry): Int =
        when (entry.kind) {
            FolderEntryKind.FOLDER_ENTRY_KIND_DIRECTORY -> 0
            FolderEntryKind.FOLDER_ENTRY_KIND_DELETED -> 1
            else -> 2
        }

    /**
     * The order a member works in: directories to create (shallow first), then deletions (deep
     * first), then files by ascending size; paths break ties.
     */
    val ORDER: Comparator<FolderEntry> = Comparator { a, b ->
        val ranked = rank(a).compareTo(rank(b))
        if (ranked != 0) return@Comparator ranked
        val kind =
            when (a.kind) {
                FolderEntryKind.FOLDER_ENTRY_KIND_DIRECTORY ->
                    FolderNames.depth(a.path).compareTo(FolderNames.depth(b.path))
                FolderEntryKind.FOLDER_ENTRY_KIND_DELETED ->
                    FolderNames.depth(b.path).compareTo(FolderNames.depth(a.path))
                else -> a.size.compareTo(b.size)
            }
        if (kind != 0) kind else FolderNames.compareUtf8(a.path, b.path)
    }

    /** [entries] in [ORDER]. */
    fun ordered(entries: List<FolderEntry>): List<FolderEntry> = entries.sortedWith(ORDER)
}

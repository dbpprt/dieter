package com.getdieter.core.folders

import com.getdieter.api.v1.Folder
import com.getdieter.api.v1.FolderDeleteGuard
import com.getdieter.api.v1.FolderHead
import com.getdieter.api.v1.FolderState
import com.getdieter.core.presentation.Ages
import com.getdieter.core.v1.FolderDirection
import kotlin.time.Instant

/** How a status line reads. */
enum class FolderTone {
    NEUTRAL,
    ACTIVE,
    SUCCESS,
    WARNING,
    DANGER,
}

data class FolderStatusLine(val text: String, val tone: FolderTone)

/** A daemon member with its live head, when its machine streams one. */
data class FolderDaemonState(val record: FolderMemberRecord, val head: FolderHead?) {
    val state: FolderState
        get() = head?.state?.takeIf { it != FolderState.FOLDER_STATE_UNSPECIFIED } ?: record.state

    val detail: String
        get() =
            head?.state_detail?.takeIf { head.state != FolderState.FOLDER_STATE_UNSPECIFIED }
                ?: record.stateDetail

    val needFiles: Long
        get() = head?.need_files ?: record.needFiles

    val conflicts: Int
        get() = head?.conflicts ?: record.conflicts

    val lastSyncAt: Instant?
        get() =
            head?.last_sync_at?.let { com.getdieter.core.runtime.Timestamps.parse(it) }
                ?: record.lastSyncAt
}

/** The English the folder views show, decided once for every client. */
object FolderPresentation {
    fun files(count: Long): String = if (count == 1L) "1 file" else "$count files"

    fun conflicts(count: Int): String = if (count == 1) "1 conflict" else "$count conflicts"

    fun trashLabel(days: Int): String =
        when {
            days <= 0 -> "Off"
            days == 1 -> "1 day"
            else -> "$days days"
        }

    fun guardLabel(guard: FolderDeleteGuard): String =
        when (guard) {
            FolderDeleteGuard.FOLDER_DELETE_GUARD_STRICT -> "Strict: more than 10 files or 10%"
            FolderDeleteGuard.FOLDER_DELETE_GUARD_OFF -> "Off"
            else -> "More than 100 files or 30%"
        }

    /** "↑ 3 files (2 MB) · ↓ 1 file (12 MB)"; empty with nothing pending. */
    fun pending(uploads: Int, uploadBytes: Long, downloads: Int, downloadBytes: Long): String =
        listOfNotNull(
                if (uploads > 0)
                    "↑ ${files(uploads.toLong())}" +
                        if (uploadBytes > 0) " (${FolderSettings.size(uploadBytes)})" else ""
                else null,
                if (downloads > 0)
                    "↓ ${files(downloads.toLong())}" +
                        if (downloadBytes > 0) " (${FolderSettings.size(downloadBytes)})" else ""
                else null,
            )
            .joinToString(" · ")

    /** "3m ago", "Never". */
    fun lastSync(at: Instant?, now: Instant): String = at?.let { Ages.ago(it, now) } ?: "Never"

    /** A daemon member's status line. */
    fun daemon(member: FolderDaemonState, now: Instant): FolderStatusLine {
        if (member.record.paused) return FolderStatusLine("Paused", FolderTone.NEUTRAL)
        return when (member.state) {
            FolderState.FOLDER_STATE_ATTENTION ->
                FolderStatusLine(member.detail.ifEmpty { "Needs attention" }, FolderTone.DANGER)
            FolderState.FOLDER_STATE_ERROR ->
                FolderStatusLine(
                    member.detail.ifEmpty { "Retrying after errors" },
                    FolderTone.WARNING,
                )
            FolderState.FOLDER_STATE_PAUSED -> FolderStatusLine("Paused", FolderTone.NEUTRAL)
            FolderState.FOLDER_STATE_SCANNING -> FolderStatusLine("Scanning", FolderTone.ACTIVE)
            FolderState.FOLDER_STATE_SYNCING ->
                FolderStatusLine(
                    if (member.needFiles > 0) "Syncing · ${files(member.needFiles)}" else "Syncing",
                    FolderTone.ACTIVE,
                )
            else ->
                if (member.conflicts > 0)
                    FolderStatusLine(conflicts(member.conflicts), FolderTone.WARNING)
                else
                    member.lastSyncAt?.let {
                        FolderStatusLine("Up to date · ${Ages.ago(it, now)}", FolderTone.SUCCESS)
                    } ?: FolderStatusLine("Up to date", FolderTone.SUCCESS)
        }
    }

    /** This device's status line for a folder kept here. */
    fun device(view: FolderLocalView, now: Instant): FolderStatusLine {
        val pending = view.pendingUploads + view.pendingDownloads
        return when {
            view.syncing ->
                FolderStatusLine(
                    if (pending > 0) "Syncing · ${files(pending.toLong())} left" else "Syncing",
                    FolderTone.ACTIVE,
                )
            view.state.attention.isNotEmpty() ->
                FolderStatusLine(view.state.attention, FolderTone.DANGER)
            view.settings.direction == FolderDirection.FOLDER_DIRECTION_PAUSED ->
                FolderStatusLine("Paused", FolderTone.NEUTRAL)
            view.reason.isNotEmpty() -> FolderStatusLine(view.reason, FolderTone.WARNING)
            view.error.isNotEmpty() ->
                FolderStatusLine("Will retry · ${view.error}", FolderTone.WARNING)
            view.conflicts.isNotEmpty() ->
                FolderStatusLine(conflicts(view.conflicts.size), FolderTone.WARNING)
            pending > 0 ->
                FolderStatusLine(
                    pending(view.pendingUploads, 0, view.pendingDownloads, 0) + " waiting",
                    FolderTone.NEUTRAL,
                )
            view.state.last_sync_millis > 0 ->
                FolderStatusLine(
                    "Up to date · " +
                        Ages.ago(Instant.fromEpochMilliseconds(view.state.last_sync_millis), now),
                    FolderTone.SUCCESS,
                )
            else -> FolderStatusLine("Not synced yet", FolderTone.NEUTRAL)
        }
    }

    /** A folder's status line in the list: this device's when kept here, else its daemons'. */
    fun folder(
        folder: Folder,
        local: FolderLocalView?,
        daemons: List<FolderDaemonState>,
        now: Instant,
    ): FolderStatusLine {
        if (folder.archived) return FolderStatusLine("Archived", FolderTone.NEUTRAL)
        if (local != null) return device(local, now)
        if (daemons.isEmpty())
            return FolderStatusLine("No machine keeps it yet", FolderTone.WARNING)
        daemons
            .firstOrNull { it.state == FolderState.FOLDER_STATE_ATTENTION }
            ?.let {
                return FolderStatusLine(
                    "${it.record.name}: ${it.detail.ifEmpty { "needs attention" }}",
                    FolderTone.DANGER,
                )
            }
        daemons
            .firstOrNull { it.state == FolderState.FOLDER_STATE_SYNCING }
            ?.let {
                return FolderStatusLine("Syncing on ${it.record.name}", FolderTone.ACTIVE)
            }
        val conflicts = daemons.maxOf { it.conflicts }
        if (conflicts > 0) return FolderStatusLine(conflicts(conflicts), FolderTone.WARNING)
        if (daemons.all { it.record.paused || it.state == FolderState.FOLDER_STATE_PAUSED })
            return FolderStatusLine("Paused", FolderTone.NEUTRAL)
        val synced = daemons.mapNotNull { it.lastSyncAt }.maxOrNull()
        val names = daemons.joinToString(", ") { it.record.name }
        return FolderStatusLine(
            if (synced != null) "Up to date · ${Ages.ago(synced, now)} · not on this device"
            else "On $names · not on this device",
            FolderTone.NEUTRAL,
        )
    }

    /** "Mac mini, box · 2 phones". */
    fun members(daemons: List<FolderDaemonState>, phones: Int): String {
        val names = daemons.joinToString(", ") { it.record.name }
        val devices =
            when (phones) {
                0 -> ""
                1 -> "1 phone"
                else -> "$phones phones"
            }
        return listOf(names, devices).filter { it.isNotEmpty() }.joinToString(" · ")
    }
}

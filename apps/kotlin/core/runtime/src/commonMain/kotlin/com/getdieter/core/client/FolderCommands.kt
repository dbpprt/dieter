package com.getdieter.core.client

import com.getdieter.api.v1.AttachFolderRequest
import com.getdieter.api.v1.CreateFolderRequest
import com.getdieter.api.v1.Folder
import com.getdieter.api.v1.FolderEntryKind
import com.getdieter.api.v1.FolderRef
import com.getdieter.api.v1.FolderTrashItem
import com.getdieter.api.v1.ListFolderTrashRequest
import com.getdieter.api.v1.PurgeFolderTrashRequest
import com.getdieter.api.v1.ResolveFolderDeletionsRequest
import com.getdieter.api.v1.RestoreFolderTrashRequest
import com.getdieter.api.v1.UpdateFolderMemberRequest
import com.getdieter.api.v1.UpdateFolderRequest
import com.getdieter.client.v1.Done
import com.getdieter.client.v1.FolderBackgroundSync as ClientBackgroundSync
import com.getdieter.client.v1.FolderConflictRow
import com.getdieter.client.v1.FolderCrumb
import com.getdieter.client.v1.FolderDaemonOption
import com.getdieter.client.v1.FolderDeletionsRow
import com.getdieter.client.v1.FolderDeviceSettings as ClientDeviceSettings
import com.getdieter.client.v1.FolderDeviceState
import com.getdieter.client.v1.FolderDirection as ClientDirection
import com.getdieter.client.v1.FolderFileRow
import com.getdieter.client.v1.FolderIntervalOption
import com.getdieter.client.v1.FolderLocalSettings as ClientLocalSettings
import com.getdieter.client.v1.FolderMemberRow
import com.getdieter.client.v1.FolderProblemRow
import com.getdieter.client.v1.FolderRow
import com.getdieter.client.v1.FolderSaveResult
import com.getdieter.client.v1.FolderSizeOption
import com.getdieter.client.v1.FolderSlice
import com.getdieter.client.v1.FolderSyncSettingsSlice
import com.getdieter.client.v1.FolderTrashRow
import com.getdieter.client.v1.FolderTrashState
import com.getdieter.client.v1.FoldersCommand
import com.getdieter.client.v1.FoldersSlice
import com.getdieter.client.v1.Result
import com.getdieter.client.v1.Tone
import com.getdieter.core.CoreRuntime
import com.getdieter.core.connection.ConnectionPhase
import com.getdieter.core.folders.FolderDaemonState
import com.getdieter.core.folders.FolderIndex
import com.getdieter.core.folders.FolderLocalView
import com.getdieter.core.folders.FolderMembers
import com.getdieter.core.folders.FolderNames
import com.getdieter.core.folders.FolderPresentation
import com.getdieter.core.folders.FolderReconcile
import com.getdieter.core.folders.FolderRunDecision
import com.getdieter.core.folders.FolderSaveRequest
import com.getdieter.core.folders.FolderSettings
import com.getdieter.core.folders.FolderSyncPolicy
import com.getdieter.core.folders.FolderTone
import com.getdieter.core.folders.FolderTrigger
import com.getdieter.core.presentation.Ages
import com.getdieter.core.runtime.Timestamps
import com.getdieter.core.sync.AccountSnapshot
import com.getdieter.core.v1.FolderBackgroundSync
import com.getdieter.core.v1.FolderDeviceSettings
import com.getdieter.core.v1.FolderLocalSettings
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.minutes
import kotlin.time.Instant
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.conflate
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.transform
import kotlinx.coroutines.launch

// Synced folders (SLICE_FOLDERS, SLICE_FOLDER, SLICE_FOLDER_SYNC_SETTINGS) and FoldersCommand.

/** One folder's view state: the shown directory and the daemon trash page it read. */
internal class FolderSurface(val folderId: String) {
    val directory = MutableStateFlow("")
    val trash = MutableStateFlow<FolderTrashState?>(null)
    val actionError = MutableStateFlow("")
}

private fun FolderTone.client(): Tone =
    when (this) {
        FolderTone.NEUTRAL -> Tone.TONE_NEUTRAL
        FolderTone.ACTIVE -> Tone.TONE_ACTIVE
        FolderTone.SUCCESS -> Tone.TONE_SUCCESS
        FolderTone.WARNING -> Tone.TONE_WARNING
        FolderTone.DANGER -> Tone.TONE_DANGER
    }

/** The client contract's settings share the record's wire format, so they convert byte for byte. */
internal fun FolderDeviceSettings.client(): ClientDeviceSettings =
    ClientDeviceSettings.ADAPTER.decode(encode())

internal fun ClientDeviceSettings.core(): FolderDeviceSettings =
    FolderDeviceSettings.ADAPTER.decode(encode())

internal fun FolderLocalSettings.client(): ClientLocalSettings =
    ClientLocalSettings.ADAPTER.decode(encode())

internal fun ClientLocalSettings.core(): FolderLocalSettings =
    FolderLocalSettings.ADAPTER.decode(encode())

private fun CoreRuntime.daemonStates(
    snapshot: AccountSnapshot,
    folderId: String,
): List<FolderDaemonState> =
    FolderMembers.of(snapshot.kv[FolderMembers.NAMESPACE].orEmpty(), folderId).map { record ->
        val machine = snapshot.directory.machine(record.daemonId)
        FolderDaemonState(record, snapshot.folderHeads[machine]?.get(folderId))
    }

private fun CoreRuntime.machineOnline(snapshot: AccountSnapshot, daemonId: String): Boolean {
    val machine = snapshot.directory.machine(daemonId)
    return connection.machines.value.online.any { it.id == machine }
}

private fun CoreRuntime.daemonOptions(): List<FolderDaemonOption> {
    val directory = connection.machines.value
    val online = directory.online.mapTo(HashSet()) { it.id }
    return directory.all
        .filter { it.compatible }
        .sortedWith(compareBy({ it.name.lowercase() }, { it.id }))
        .map {
            FolderDaemonOption(
                daemon_id = it.id,
                name = it.name.ifBlank { it.id },
                online = it.id in online,
                label = it.name.ifBlank { it.id },
            )
        }
}

private fun platformName(runtime: CoreRuntime): String =
    runtime.folders.platform?.platform ?: runtime.platform.deviceKeys.platform

/** The folder list now. */
internal suspend fun CoreRuntime.foldersSlice(): FoldersSlice {
    val snapshot = accountSync.snapshot.value
    val now = platform.clock.now()
    val locals = folders.views().associateBy { it.folderId }
    val device = folders.device()
    val rows =
        snapshot.folders.values
            .filter { !it.archived }
            .sortedWith(compareBy({ it.name.lowercase() }, { it.id }))
            .map { folder ->
                val daemons = daemonStates(snapshot, folder.id)
                val local = locals[folder.id]
                val status = FolderPresentation.folder(folder, local, daemons, now)
                val phones =
                    daemons
                        .flatMap { it.record.clients }
                        .map { it.deviceId }
                        .toMutableSet()
                        .also { set ->
                            if (local != null)
                                trust.view.value.deviceId.takeIf { it.isNotEmpty() }?.let(set::add)
                        }
                FolderRow(
                    id = folder.id,
                    name = folder.name,
                    status = status.text,
                    tone = status.tone.client(),
                    on_device = local != null,
                    direction =
                        local
                            ?.let { FolderSettings.directionLabel(it.settings.direction) }
                            .orEmpty(),
                    members = FolderPresentation.members(daemons, phones.size),
                    project_name =
                        workspace.state.value.projects
                            .firstOrNull { it.id == folder.project_id }
                            ?.name
                            .orEmpty(),
                    attention =
                        status.tone == FolderTone.DANGER ||
                            (local?.conflicts?.isNotEmpty()
                                ?: (daemons.maxOfOrNull { it.conflicts } ?: 0 > 0)),
                    syncing = local?.syncing == true,
                    conflicts =
                        local?.conflicts?.size ?: (daemons.maxOfOrNull { it.conflicts } ?: 0),
                    last_sync_millis = local?.state?.last_sync_millis ?: 0,
                    accepts_files =
                        local != null &&
                            local.settings.direction !=
                                com.getdieter.core.v1.FolderDirection
                                    .FOLDER_DIRECTION_DOWNLOAD_ONLY,
                )
            }
    val phase = connection.state.value.phase
    return FoldersSlice(
        folders = rows,
        daemons = daemonOptions(),
        notice =
            if (folders.capable && locals.isNotEmpty() && !device.enabled)
                "Folder sync is off on this device."
            else "",
        loading =
            rows.isEmpty() &&
                !accountSync.loaded.value &&
                phase in
                    setOf(
                        ConnectionPhase.CONNECTING,
                        ConnectionPhase.RECONNECTING,
                        ConnectionPhase.CONNECTED,
                    ),
        empty_title = if (rows.isEmpty()) "No folders yet" else "",
        empty_detail =
            if (rows.isEmpty())
                "Create a folder to keep files the same on your machines and phones."
            else "",
        device_capable = folders.capable,
    )
}

private fun FolderTrashItem.row(now: Instant): FolderTrashRow {
    val deleted = Timestamps.parse(deleted_at)
    val verb =
        when (reason) {
            "replaced" -> "Replaced"
            "adopted" -> "Set aside"
            else -> "Deleted"
        }
    return FolderTrashRow(
        id = id,
        path = path,
        name = FolderNames.name(path),
        size_label = FolderSettings.size(size),
        deleted_millis = deleted?.toEpochMilliseconds() ?: 0,
        detail =
            listOfNotNull(
                    "$verb by ${deleted_by.ifEmpty { "a member" }}",
                    deleted?.let { Ages.ago(it, now) },
                )
                .joinToString(" · "),
    )
}

/** One folder now, as [surface] shows it. */
internal suspend fun CoreRuntime.folderSlice(surface: FolderSurface): FolderSlice {
    val snapshot = accountSync.snapshot.value
    val now = platform.clock.now()
    val folder: Folder =
        snapshot.folders[surface.folderId]
            ?: return FolderSlice(
                id = surface.folderId,
                found = false,
                action_error = surface.actionError.value,
            )
    val local = folders.view(folder.id)
    val daemons = daemonStates(snapshot, folder.id)
    val status = FolderPresentation.folder(folder, local, daemons, now)
    val me = trust.view.value.deviceId
    val homeId = local?.state?.home_daemon_id.orEmpty()
    val members = ArrayList<FolderMemberRow>()
    for (daemon in daemons) {
        val line = FolderPresentation.daemon(daemon, now)
        val machine = snapshot.directory.machine(daemon.record.daemonId)
        members +=
            FolderMemberRow(
                member_id = daemon.record.daemonId,
                name = daemon.record.name,
                daemon = true,
                mode = daemon.record.mode,
                mode_label = FolderSettings.modeLabel(daemon.record.mode),
                paused = daemon.record.paused,
                state = daemon.state,
                status = line.text,
                tone = line.tone.client(),
                last_sync_millis = daemon.lastSyncAt?.toEpochMilliseconds() ?: 0,
                last_sync = FolderPresentation.lastSync(daemon.lastSyncAt, now),
                online = machineOnline(snapshot, daemon.record.daemonId),
                home_of_this_device =
                    homeId.isNotEmpty() && (homeId == machine || homeId == daemon.record.daemonId),
            )
    }
    if (local != null) {
        val line = FolderPresentation.device(local, now)
        val last =
            local.state.last_sync_millis.takeIf { it > 0 }?.let(Instant::fromEpochMilliseconds)
        members +=
            FolderMemberRow(
                member_id = me,
                name = platform.deviceKeys.deviceName.ifBlank { "This device" },
                this_device = true,
                mode = FolderSettings.mode(local.settings.direction),
                mode_label = FolderSettings.directionLabel(local.settings.direction),
                paused =
                    local.settings.direction ==
                        com.getdieter.core.v1.FolderDirection.FOLDER_DIRECTION_PAUSED,
                status = line.text,
                tone = line.tone.client(),
                last_sync_millis = local.state.last_sync_millis,
                last_sync = FolderPresentation.lastSync(last, now),
                online = true,
                home =
                    daemons
                        .firstOrNull { snapshot.directory.machine(it.record.daemonId) == homeId }
                        ?.record
                        ?.name
                        .orEmpty(),
            )
    }
    val phones =
        LinkedHashMap<String, Pair<com.getdieter.core.folders.FolderClientRecord, String>>()
    for (daemon in daemons) for (client in daemon.record.clients) {
        if (client.deviceId == me && local != null) continue
        val known = phones[client.deviceId]
        if (
            known == null ||
                (client.lastSeenAt ?: Instant.DISTANT_PAST) >
                    (known.first.lastSeenAt ?: Instant.DISTANT_PAST)
        )
            phones[client.deviceId] = client to daemon.record.name
    }
    for ((client, home) in phones.values.sortedBy { it.first.name.lowercase() }) {
        members +=
            FolderMemberRow(
                member_id = client.deviceId,
                name = client.name,
                mode = client.mode,
                mode_label = FolderSettings.modeLabel(client.mode),
                status =
                    client.lastSeenAt?.let { "Last seen ${Ages.ago(it, now)}" } ?: "Not seen yet",
                last_sync_millis = client.lastSeenAt?.toEpochMilliseconds() ?: 0,
                last_sync = FolderPresentation.lastSync(client.lastSeenAt, now),
                home = home,
            )
    }
    val directory = surface.directory.value
    val listing = if (local != null) folders.listing(folder.id, directory) else emptyList()
    val downloading = if (local != null) folders.downloading(folder.id) else emptySet()
    val receiveOnly =
        local?.settings?.direction ==
            com.getdieter.core.v1.FolderDirection.FOLDER_DIRECTION_DOWNLOAD_ONLY
    val files =
        listing
            .sortedWith(
                compareBy<com.getdieter.core.v1.LocalFolderEntry>(
                        { it.entry!!.kind != FolderEntryKind.FOLDER_ENTRY_KIND_DIRECTORY },
                        { FolderNames.name(it.entry!!.path).lowercase() },
                    )
                    .thenBy { it.entry!!.path }
            )
            .map { item ->
                val entry = item.entry!!
                val isDirectory = entry.kind == FolderEntryKind.FOLDER_ENTRY_KIND_DIRECTORY
                val present = isDirectory || FolderIndex.present(item)
                val conflict = FolderReconcile.conflictOriginal(entry.path) != null
                FolderFileRow(
                    path = entry.path,
                    name = FolderNames.name(entry.path),
                    directory = isDirectory,
                    size = entry.size,
                    size_label = if (isDirectory) "" else FolderSettings.size(entry.size),
                    modified_millis = entry.modified_nanos / 1_000_000,
                    downloaded = present,
                    badge =
                        when {
                            !present && entry.path in downloading -> "Waiting to download"
                            !present -> "Not downloaded"
                            item.local_change -> "Local change"
                            !item.synced && !receiveOnly && entry.version.isNotEmpty() ->
                                "Waiting to upload"
                            conflict -> "Conflict copy"
                            else -> ""
                        },
                    conflict = conflict,
                    disk_path = if (isDirectory) "" else FolderIndex.diskPath(item),
                )
            }
    val crumbs = buildList {
        add(FolderCrumb("", folder.name))
        if (directory.isNotEmpty())
            for (path in FolderNames.ancestors(directory) + directory) add(
                FolderCrumb(path, FolderNames.name(path))
            )
    }
    val held = local?.state?.held_deletions
    val homeOptions =
        listOf(
            FolderDaemonOption(
                daemon_id = "",
                name = "Auto",
                online = true,
                label =
                    "Auto" +
                        (daemons
                            .firstOrNull {
                                snapshot.directory.machine(it.record.daemonId) == homeId
                            }
                            ?.let {
                                " (${it.record.name})"
                            } ?: ""),
                selected = local?.settings?.home_daemon_id.isNullOrEmpty(),
            )
        ) +
            daemons.map {
                FolderDaemonOption(
                    daemon_id = it.record.daemonId,
                    name = it.record.name,
                    online = machineOnline(snapshot, it.record.daemonId),
                    label = it.record.name,
                    selected = local?.settings?.home_daemon_id == it.record.daemonId,
                )
            }
    val memberDaemons = daemons.mapTo(HashSet()) { snapshot.directory.machine(it.record.daemonId) }
    return FolderSlice(
        id = folder.id,
        found = true,
        name = folder.name,
        status = status.text,
        tone = status.tone.client(),
        rules = folder.rules,
        trash_days = folder.trash_days,
        trash_label = FolderPresentation.trashLabel(folder.trash_days),
        delete_guard = folder.delete_guard,
        delete_guard_label = FolderPresentation.guardLabel(folder.delete_guard),
        project_id = folder.project_id,
        project_name =
            workspace.state.value.projects
                .firstOrNull { it.id == folder.project_id }
                ?.name
                .orEmpty(),
        archived = folder.archived,
        conflict_fields = folder.conflict_fields,
        members = members,
        device = deviceState(local, homeOptions, now),
        directory = directory,
        breadcrumbs = crumbs,
        files = files.take(MAX_FILE_ROWS),
        files_truncated = files.size > MAX_FILE_ROWS,
        conflicts =
            local?.conflicts.orEmpty().map { path ->
                FolderConflictRow(
                    path = path,
                    original = FolderReconcile.conflictOriginal(path).orEmpty(),
                    detail = FolderReconcile.conflictDetail(path),
                    downloaded =
                        listing.firstOrNull { it.entry!!.path == path }?.let(FolderIndex::present)
                            ?: true,
                )
            },
        pending_deletions =
            held?.let {
                FolderDeletionsRow(
                    count = it.total.takeIf { total -> total > 0 } ?: it.entries.size.toLong(),
                    sample = it.entries.take(32).map { entry -> entry.path },
                    source = it.source,
                    title =
                        local.state.attention.ifEmpty {
                            "Confirm deletion of ${it.entries.size} files"
                        },
                    detail =
                        if (it.source == "local") "These files are missing on this device."
                        else "Another device deleted these files.",
                )
            },
        trash = surface.trash.value,
        errors =
            local?.state?.errors.orEmpty().map {
                FolderProblemRow(it.path, it.message, it.at_millis)
            },
        unsyncable =
            local?.state?.unsyncable.orEmpty().map {
                FolderProblemRow(it.path, it.message, it.at_millis)
            },
        local_changes = local?.localChanges.orEmpty(),
        out_of_sync = local?.state?.out_of_sync.orEmpty(),
        action_error = surface.actionError.value,
        addable_daemons = daemonOptions().filter { it.daemon_id !in memberDaemons },
    )
}

private fun CoreRuntime.deviceState(
    local: FolderLocalView?,
    homeOptions: List<FolderDaemonOption>,
    now: Instant,
): FolderDeviceState {
    if (local == null) return FolderDeviceState(attached = false, can_attach = folders.capable)
    val line = FolderPresentation.device(local, now)
    val last = local.state.last_sync_millis.takeIf { it > 0 }?.let(Instant::fromEpochMilliseconds)
    val direction =
        ClientDirection.fromValue(local.settings.direction.value)
            ?: ClientDirection.FOLDER_DIRECTION_TWO_WAY
    return FolderDeviceState(
        attached = true,
        settings = local.settings.client(),
        direction = direction,
        direction_label = FolderSettings.directionLabel(local.settings.direction),
        location_label = local.settings.location_label.ifEmpty { local.settings.location },
        home_daemon_id = local.state.home_daemon_id,
        home_label = homeOptions.firstOrNull { it.selected }?.label.orEmpty(),
        home_options = homeOptions,
        status = line.text,
        tone = line.tone.client(),
        reason = local.reason,
        last_sync_millis = local.state.last_sync_millis,
        last_sync = FolderPresentation.lastSync(last, now),
        syncing = local.syncing,
        pending_uploads = local.pendingUploads,
        pending_upload_bytes = local.pendingUploadBytes,
        pending_downloads = local.pendingDownloads,
        pending_download_bytes = local.pendingDownloadBytes,
        pending_label =
            FolderPresentation.pending(
                local.pendingUploads,
                local.pendingUploadBytes,
                local.pendingDownloads,
                local.pendingDownloadBytes,
            ),
        files = local.files,
        bytes = local.bytes,
        local_bytes = local.localBytes,
        usage_label =
            "${FolderPresentation.files(local.files.toLong())} · ${FolderSettings.size(local.localBytes)} on this device of ${FolderSettings.size(local.bytes)}",
        can_attach = true,
    )
}

/** Settings › Folder sync now. */
internal suspend fun CoreRuntime.folderSyncSettingsSlice(): FolderSyncSettingsSlice {
    val settings = folders.settings()
    val device = settings.device ?: FolderSettings.DEFAULTS
    val platformName = platformName(this)
    val ios = platformName == "ios"
    val views = folders.views()
    val now = platform.clock.now()
    val last =
        views
            .maxOfOrNull { it.state.last_sync_millis }
            ?.takeIf { it > 0 }
            ?.let(Instant::fromEpochMilliseconds)
    val attempt =
        views
            .maxOfOrNull { it.state.last_attempt_millis }
            ?.takeIf { it > 0 }
            ?.let(Instant::fromEpochMilliseconds)
    val next = FolderSyncPolicy.nextSync(device, settings.folders, attempt, now)
    val used = views.sumOf { it.localBytes }
    val conditions = folders.platform?.conditions?.current()
    val reason =
        conditions
            ?.let {
                when (
                    val decision =
                        FolderSyncPolicy.decide(
                            device,
                            null,
                            it,
                            FolderTrigger.BACKGROUND,
                            platformName,
                        )
                ) {
                    is FolderRunDecision.Skip -> decision.reason
                    is FolderRunDecision.SmallOnly -> decision.reason
                    FolderRunDecision.RunAll -> ""
                }
            }
            .orEmpty()
    fun sizes(options: List<Long>, selected: Long, label: (Long) -> String) = options.map {
        FolderSizeOption(amount = it, label = label(it), selected = it == selected)
    }
    val intervals =
        FolderSettings.intervalOptions(platformName).map { (minutes, label) ->
            FolderIntervalOption(
                background = ClientBackgroundSync.FOLDER_BACKGROUND_SYNC_INTERVAL,
                minutes = minutes,
                label = label,
                selected =
                    device.background == FolderBackgroundSync.FOLDER_BACKGROUND_SYNC_INTERVAL &&
                        device.interval_minutes == minutes,
            )
        } +
            listOf(
                FolderIntervalOption(
                    background = ClientBackgroundSync.FOLDER_BACKGROUND_SYNC_WHILE_OPEN,
                    label = "Only while Dieter is open",
                    selected =
                        device.background == FolderBackgroundSync.FOLDER_BACKGROUND_SYNC_WHILE_OPEN,
                ),
                FolderIntervalOption(
                    background = ClientBackgroundSync.FOLDER_BACKGROUND_SYNC_MANUAL,
                    label = "Manual only",
                    selected =
                        device.background == FolderBackgroundSync.FOLDER_BACKGROUND_SYNC_MANUAL,
                ),
            )
    val uploads = views.sumOf { it.pendingUploads }
    val uploadBytes = views.sumOf { it.pendingUploadBytes }
    val downloads = views.sumOf { it.pendingDownloads }
    val downloadBytes = views.sumOf { it.pendingDownloadBytes }
    return FolderSyncSettingsSlice(
        settings = device.client(),
        interval_options = intervals,
        large_file_options =
            sizes(FolderSettings.LARGE_FILE_OPTIONS, device.large_file_bytes, FolderSettings::size),
        battery_options =
            sizes(
                FolderSettings.BATTERY_OPTIONS,
                device.pause_below_percent.toLong(),
                FolderSettings::batteryLabel,
            ),
        auto_download_options =
            sizes(
                FolderSettings.AUTO_DOWNLOAD_OPTIONS,
                device.auto_download_bytes,
                FolderSettings::autoDownloadLabel,
            ),
        storage_options =
            sizes(
                FolderSettings.STORAGE_OPTIONS,
                device.storage_limit_bytes,
                FolderSettings::storageLabel,
            ),
        keep_free_options =
            sizes(
                FolderSettings.KEEP_FREE_OPTIONS,
                device.keep_free_bytes,
                FolderSettings::keepFreeLabel,
            ),
        background_caption =
            if (ios)
                "iOS decides the exact time based on battery, network and how often you use Dieter. Background syncs run only while your iPhone is unlocked."
            else "",
        roaming_available = !ios,
        data_saver_label = if (ios) "Respect Low Data Mode" else "Respect Data Saver",
        power_saver_label = if (ios) "Pause in Low Power Mode" else "Pause in Battery Saver",
        last_sync_millis = last?.toEpochMilliseconds() ?: 0,
        last_sync = FolderPresentation.lastSync(last, now),
        next_sync_millis = next?.toEpochMilliseconds() ?: 0,
        next_sync =
            next?.let { at ->
                val minutes = (at - now).inWholeMinutes
                when {
                    minutes < 1 -> "Soon"
                    minutes < 60 -> "In about $minutes min"
                    else -> "In about ${minutes / 60} h"
                }
            } ?: if (settings.folders.isEmpty()) "" else "Not scheduled",
        pending_uploads = uploads,
        pending_upload_bytes = uploadBytes,
        pending_downloads = downloads,
        pending_download_bytes = downloadBytes,
        pending_label = FolderPresentation.pending(uploads, uploadBytes, downloads, downloadBytes),
        used_bytes = used,
        used_label =
            if (device.storage_limit_bytes > 0)
                "${FolderSettings.size(used)} of ${FolderSettings.size(device.storage_limit_bytes)}"
            else FolderSettings.size(used),
        reason = reason,
        folders_on_device = settings.folders.size,
        device_capable = folders.capable,
        cellular_bytes = folders.cellularBytes(),
        cellular_label = "Cellular this month: ${FolderSettings.size(folders.cellularBytes())}",
    )
}

private const val MAX_FILE_ROWS = 500

/** Coalesces bursts (a scan changes thousands of entries) into at most one update per interval. */
private fun <T> Flow<T>.throttled(): Flow<T> =
    conflate().transform {
        emit(it)
        delay(250.milliseconds)
    }

private fun CoreRuntime.minutes(): Flow<Unit> = flow {
    while (true) {
        emit(Unit)
        val now = platform.clock.now().toEpochMilliseconds()
        delay(60_000 - now % 60_000)
    }
}

private fun CoreRuntime.folderInputs(): List<Flow<Any?>> =
    listOf(
        accountSync.snapshot
            .map { Triple(it.folders, it.kv[FolderMembers.NAMESPACE], it.folderHeads) }
            .distinctUntilChanged(),
        folders.revision.throttled(),
        connection.machines,
        connection.state.map { it.phase }.distinctUntilChanged(),
        accountSync.loaded,
        minutes(),
    )

internal fun CoreRuntime.foldersSlices(): Flow<FoldersSlice> =
    combine(folderInputs()) { foldersSlice() }.distinctUntilChanged()

internal fun CoreRuntime.folderSlices(surface: FolderSurface): Flow<FolderSlice> =
    combine(folderInputs() + listOf(surface.directory, surface.trash, surface.actionError)) {
            folderSlice(surface)
        }
        .distinctUntilChanged()

internal fun CoreRuntime.folderSyncSettingsSlices(): Flow<FolderSyncSettingsSlice> =
    combine(folders.revision.throttled(), minutes()) { _, _ -> folderSyncSettingsSlice() }
        .distinctUntilChanged()

private fun direction(value: ClientDirection) =
    com.getdieter.core.v1.FolderDirection.fromValue(value.value)
        ?: com.getdieter.core.v1.FolderDirection.FOLDER_DIRECTION_TWO_WAY

/**
 * A folders command. Shared definitions and daemon members go to a daemon; this device's
 * membership, settings and files stay here. Browse and trash pages need the folder's surface.
 */
internal suspend fun CoreRuntime.executeFolders(
    command: FoldersCommand,
    surfaces: Surfaces<FolderSurface>,
): Result {
    val folderId =
        command.update?.folder_id
            ?: command.archive?.folder_id
            ?: command.attach_device?.folder_id
            ?: command.attach_daemon?.folder_id
            ?: command.update_daemon?.folder_id
            ?: command.detach_daemon?.folder_id
            ?: command.set_direction?.folder_id
            ?: command.sync_now?.folder_id
            ?: command.resolve_deletions?.folder_id
            ?: command.list_trash?.folder_id
            ?: command.restore_trash?.folder_id
            ?: command.purge_trash?.folder_id
            ?: command.download?.folder_id
            ?: command.evict?.folder_id
            ?: command.remove_device?.folder_id
            ?: command.set_folder_settings?.folder_id
            ?: command.rescan_daemon?.folder_id
            ?: command.browse?.folder_id
            ?: command.resolve_conflict?.folder_id
            ?: command.save_files?.folder_id
            ?: ""
    val surface = surfaces[command.scope.ifEmpty { folderId }]
    fun definition(id: String): Folder =
        accountSync.snapshot.value.folders[id] ?: invalid("That folder is not known yet.")
    fun required(id: String) = id.ifBlank { invalid("Choose a folder.") }
    try {
        val result =
            folderCommand(command, surface, ::definition, ::required)
                ?: invalid("Choose what to do with the folder.")
        surface?.actionError?.value = ""
        return result
    } catch (error: Throwable) {
        if (error is kotlin.coroutines.cancellation.CancellationException) throw error
        surface?.actionError?.value = classify(error).message
        throw error
    }
}

private suspend fun CoreRuntime.folderCommand(
    command: FoldersCommand,
    surface: FolderSurface?,
    definition: (String) -> Folder,
    required: (String) -> String,
): Result? {
    val done = Result(done = Done())
    command.create?.let { create ->
        if (create.name.isBlank()) invalid("Name the folder.")
        val folder =
            onFolderDaemon(create.daemon_id.ifEmpty { null }) {
                it.CreateFolder()
                    .execute(
                        CreateFolderRequest(
                            name = create.name.trim(),
                            rules = create.rules,
                            trash_days = create.trash_days,
                            delete_guard = create.delete_guard,
                            project_id = create.project_id,
                            no_default_rules = create.no_default_rules,
                        )
                    )
            }
        return Result(synced_folder = folder)
    }
    command.update?.let { update ->
        required(update.folder_id)
        val folder =
            onFolderDaemon(null) {
                it.UpdateFolder()
                    .execute(
                        UpdateFolderRequest(
                            folder_id = update.folder_id,
                            name = update.name,
                            set_rules = update.set_rules,
                            rules = update.rules,
                            trash_days = update.trash_days,
                            delete_guard = update.delete_guard,
                            project_id = update.project_id,
                        )
                    )
            }
        return Result(synced_folder = folder)
    }
    command.archive?.let {
        val folder =
            onFolderDaemon(null) { api ->
                api.ArchiveFolder().execute(FolderRef(required(it.folder_id)))
            }
        return Result(synced_folder = folder)
    }
    command.attach_device?.let { attach ->
        val folder = definition(required(attach.folder_id))
        folders.attach(
            folder.id,
            folder.name,
            attach.location,
            attach.location_label,
            direction(attach.direction),
            attach.remove_after_upload,
            attach.home_daemon_id,
        )
        return surface?.let { Result(folder = folderSlice(it)) } ?: done
    }
    command.attach_daemon?.let { attach ->
        required(attach.folder_id)
        if (attach.daemon_id.isBlank()) invalid("Choose a machine.")
        if (attach.path.isBlank()) invalid("Choose a directory on that machine.")
        val result =
            onFolderDaemon(attach.daemon_id) {
                it.AttachFolder()
                    .execute(
                        AttachFolderRequest(
                            folder_id = attach.folder_id,
                            path = attach.path,
                            mode = attach.mode,
                            join = attach.join,
                            dry_run = attach.dry_run,
                        )
                    )
            }
        return Result(folder_attach = result)
    }
    command.update_daemon?.let { update ->
        required(update.folder_id)
        if (update.daemon_id.isBlank()) invalid("Choose a machine.")
        val member =
            onFolderDaemon(update.daemon_id) {
                it.UpdateFolderMember()
                    .execute(
                        UpdateFolderMemberRequest(
                            folder_id = update.folder_id,
                            mode = update.mode,
                            paused = update.paused,
                            rescan_seconds = update.rescan_seconds,
                            bandwidth_limit = update.bandwidth_limit,
                            concurrency = update.concurrency,
                            quarantine = update.quarantine,
                            watch = update.watch,
                        )
                    )
            }
        return Result(folder_member = member)
    }
    command.detach_daemon?.let { detach ->
        if (detach.daemon_id.isBlank()) invalid("Choose a machine.")
        onFolderDaemon(detach.daemon_id) {
            it.DetachFolder().execute(FolderRef(required(detach.folder_id)))
        }
        return done
    }
    command.set_direction?.let {
        folders.setDirection(required(it.folder_id), direction(it.direction))
        return done
    }
    command.sync_now?.let {
        val id = it.folder_id.ifEmpty { null }
        scope.launch { folderSyncWindow(MANUAL_WINDOW, id, FolderTrigger.MANUAL) }
        return done
    }
    command.resolve_deletions?.let { resolve ->
        required(resolve.folder_id)
        if (resolve.daemon_id.isEmpty()) folders.resolveDeletions(resolve.folder_id, resolve.apply)
        else
            onFolderDaemon(resolve.daemon_id) {
                it.ResolveFolderDeletions()
                    .execute(ResolveFolderDeletionsRequest(resolve.folder_id, resolve.apply))
            }
        return done
    }
    command.list_trash?.let { query ->
        val target = surface ?: invalid("Open the folder first.")
        val daemon = trashDaemon(required(query.folder_id), query.daemon_id)
        val name = connection.machines.value.machine(daemon)?.name?.ifBlank { null } ?: daemon
        target.trash.value =
            (target.trash.value ?: FolderTrashState()).copy(
                daemon_id = daemon,
                daemon_name = name,
                loading = true,
                error = "",
            )
        try {
            val page =
                onFolderDaemon(daemon) {
                    it.ListFolderTrash()
                        .execute(ListFolderTrashRequest(query.folder_id, query.after, 100))
                }
            val now = platform.clock.now()
            val previous =
                target.trash.value?.rows.orEmpty().takeIf { query.after.isNotEmpty() }.orEmpty()
            target.trash.value =
                FolderTrashState(
                    daemon_id = daemon,
                    daemon_name = name,
                    rows = previous + page.items.map { it.row(now) },
                    next = page.next,
                    total_bytes = page.total_bytes,
                )
        } catch (error: Throwable) {
            target.trash.value =
                target.trash.value?.copy(loading = false, error = classify(error).message)
            throw error
        }
        return Result(folder = folderSlice(target))
    }
    command.restore_trash?.let { items ->
        val daemon = trashDaemon(required(items.folder_id), items.daemon_id)
        if (items.ids.isEmpty()) invalid("Choose what to restore.")
        onFolderDaemon(daemon) { api ->
            for (id in items.ids) api.RestoreFolderTrash()
                .execute(RestoreFolderTrashRequest(items.folder_id, id))
        }
        surface?.let { target ->
            target.trash.value =
                target.trash.value?.let { state ->
                    state.copy(rows = state.rows.filter { it.id !in items.ids })
                }
        }
        return done
    }
    command.purge_trash?.let { items ->
        val daemon = trashDaemon(required(items.folder_id), items.daemon_id)
        onFolderDaemon(daemon) {
            it.PurgeFolderTrash().execute(PurgeFolderTrashRequest(items.folder_id, items.ids))
        }
        surface?.let { target ->
            target.trash.value =
                target.trash.value?.let { state ->
                    if (items.ids.isEmpty())
                        state.copy(rows = emptyList(), next = "", total_bytes = 0)
                    else state.copy(rows = state.rows.filter { it.id !in items.ids })
                }
        }
        return done
    }
    command.download?.let {
        if (it.path.isBlank()) invalid("Choose a file.")
        folders.download(required(it.folder_id), it.path)
        return done
    }
    command.evict?.let {
        folders.evict(required(it.folder_id), it.path)
        return done
    }
    command.free_up_space?.let {
        folders.freeUpSpace()
        return done
    }
    command.remove_device?.let {
        folders.remove(required(it.folder_id), it.delete_local_copy)
        return done
    }
    command.set_device_settings?.let {
        folders.setDeviceSettings(it.core())
        return Result(folder_sync_settings = folderSyncSettingsSlice())
    }
    command.set_folder_settings?.let {
        val folder = definition(required(it.folder_id))
        folders.setFolderSettings(it.core(), folder.name)
        return surface?.let { target -> Result(folder = folderSlice(target)) } ?: done
    }
    command.rescan_daemon?.let { rescan ->
        if (rescan.daemon_id.isBlank()) invalid("Choose a machine.")
        onFolderDaemon(rescan.daemon_id) {
            it.RescanFolder().execute(FolderRef(required(rescan.folder_id)))
        }
        return done
    }
    command.browse?.let { browse ->
        val target = surface ?: invalid("Open the folder first.")
        if (browse.path.isNotEmpty() && !FolderNames.validPath(browse.path))
            invalid("That is not a folder path.")
        target.directory.value = browse.path
        return Result(folder = folderSlice(target))
    }
    command.resolve_conflict?.let {
        if (it.path.isBlank()) invalid("Choose a conflict copy.")
        folders.resolveConflict(required(it.folder_id), it.path, it.keep_copy)
        return done
    }
    command.save_files?.let { save ->
        val folder = definition(required(save.folder_id))
        if (save.sources.isEmpty()) invalid("Choose files to save.")
        val outcome =
            folders.save(
                folder.id,
                save.directory,
                save.sources.map { FolderSaveRequest(it.source, it.name) },
            )
        if (outcome.paths.isEmpty()) invalid(outcome.problem.ifEmpty { "Nothing was saved." })
        return Result(
            folder_saved =
                FolderSaveResult(
                    paths = outcome.paths,
                    message =
                        "Saved ${FolderPresentation.files(outcome.paths.size.toLong())} to ${folder.name}.",
                    problem = outcome.problem,
                )
        )
    }
    return null
}

/** The daemon whose trash a command means: [daemonId], else the folder's first reachable member. */
private fun CoreRuntime.trashDaemon(folderId: String, daemonId: String): String {
    if (daemonId.isNotEmpty()) return daemonId
    return folderHomes(folderId, "").firstOrNull()
        ?: invalid("No machine with this folder is reachable.")
}

private val MANUAL_WINDOW = 10.minutes

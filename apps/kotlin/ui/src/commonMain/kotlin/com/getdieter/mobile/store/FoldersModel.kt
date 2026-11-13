package com.getdieter.mobile.store

import com.getdieter.api.v1.DirectoryListing
import com.getdieter.api.v1.FolderDeleteGuard
import com.getdieter.api.v1.FolderJoin
import com.getdieter.api.v1.FolderMode
import com.getdieter.client.v1.*
import com.getdieter.core.client.ClientSubscription
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch

/**
 * Synced folders as the core presents them: the folder list, the open folder and Settings › Folder
 * sync. The core words, decides and syncs everything; this holder observes the slices while their
 * routes are visible and sends folder commands.
 */
class FoldersModel internal constructor(private val context: StoreContext) {
    val list = MutableStateFlow(FoldersSlice())
    val folder = MutableStateFlow(FolderSlice())
    val settings = MutableStateFlow(FolderSyncSettingsSlice())
    /** The last "Save to folder…" confirmation, e.g. "Saved 2 files to Inbox."; empty for none. */
    val saved = MutableStateFlow("")

    private var listSubscription: ClientSubscription? = null
    private var settingsSubscription: ClientSubscription? = null
    private var folderSubscription: ClientSubscription? = null
    private var shownFolder = ""
    private var shownDirectory: String? = null

    /** The list and the device settings are on screen (a folder route, the add flow, a share). */
    internal fun showList(on: Boolean) {
        if (on == (listSubscription != null)) return
        if (on) {
            listSubscription =
                context.observe(Slice.SLICE_FOLDERS, MobileStore.FOLDERS_SCOPE) {
                    it.folders?.let { value -> list.value = value }
                }
            settingsSubscription =
                context.observe(Slice.SLICE_FOLDER_SYNC_SETTINGS, MobileStore.FOLDERS_SCOPE) {
                    it.folder_sync_settings?.let { value -> settings.value = value }
                }
        } else {
            listSubscription?.close()
            settingsSubscription?.close()
            listSubscription = null
            settingsSubscription = null
        }
    }

    /**
     * [folderId]'s slice is on screen, showing [directory] of its copy (null keeps what it shows);
     * a null [folderId] shows none.
     */
    internal fun show(folderId: String?, directory: String? = null) {
        val id = folderId.orEmpty()
        if (id != shownFolder) {
            folderSubscription?.close()
            folderSubscription = null
            shownFolder = id
            // A folder's surface opens at its root.
            shownDirectory = ""
            folder.value = FolderSlice(id = id)
            if (id.isNotEmpty())
                folderSubscription =
                    context.observe(Slice.SLICE_FOLDER, id) {
                        it.folder?.let { value ->
                            if (value.id == shownFolder) folder.value = value
                        }
                    }
        }
        if (id.isNotEmpty() && directory != null && directory != shownDirectory) {
            shownDirectory = directory
            send(FoldersCommand(browse = FolderPath(id, directory)), quiet = true)
        }
    }

    // Shared definitions --------------------------------------------------------------------

    fun rename(folderId: String, name: String) =
        send(FoldersCommand(update = SyncedFolderUpdate(folder_id = folderId, name = name.trim())))

    /** Replaces the rules: one pattern per line, "-PATTERN" excludes and "+PATTERN" includes. */
    fun setRules(folderId: String, rules: List<String>) =
        send(
            FoldersCommand(
                update = SyncedFolderUpdate(folder_id = folderId, set_rules = true, rules = rules)
            )
        )

    /** [days] of trash; negative turns it off. */
    fun setTrashDays(folderId: String, days: Int) =
        send(FoldersCommand(update = SyncedFolderUpdate(folder_id = folderId, trash_days = days)))

    fun setDeleteGuard(folderId: String, guard: FolderDeleteGuard) =
        send(
            FoldersCommand(update = SyncedFolderUpdate(folder_id = folderId, delete_guard = guard))
        )

    /** Links [projectId] for agents; empty unlinks. */
    fun linkProject(folderId: String, projectId: String) =
        send(
            FoldersCommand(
                update = SyncedFolderUpdate(folder_id = folderId, project_id = projectId)
            )
        )

    fun archive(folderId: String) = send(FoldersCommand(archive = SyncedFolderRef(folderId)))

    // Daemon members ---------------------------------------------------------------------------

    fun attachDaemon(folderId: String, daemonId: String, path: String, mode: FolderMode) =
        send(
            FoldersCommand(
                attach_daemon =
                    FolderAttachDaemon(
                        folder_id = folderId,
                        daemon_id = daemonId,
                        path = path.trim(),
                        mode = mode,
                        join = FolderJoin.FOLDER_JOIN_MERGE,
                    )
            )
        )

    fun setDaemonMode(folderId: String, daemonId: String, mode: FolderMode) =
        send(FoldersCommand(update_daemon = FolderUpdateDaemon(folderId, daemonId, mode = mode)))

    fun pauseDaemon(folderId: String, daemonId: String, paused: Boolean) =
        send(
            FoldersCommand(update_daemon = FolderUpdateDaemon(folderId, daemonId, paused = paused))
        )

    fun rescanDaemon(folderId: String, daemonId: String) =
        send(FoldersCommand(rescan_daemon = FolderDaemonRef(folderId, daemonId)))

    fun detachDaemon(folderId: String, daemonId: String) =
        send(FoldersCommand(detach_daemon = FolderDaemonRef(folderId, daemonId)))

    // This device ------------------------------------------------------------------------------

    /** Syncs [folderId] now; empty syncs every folder on this device. */
    fun syncNow(folderId: String = "") =
        send(FoldersCommand(sync_now = SyncedFolderRef(folderId)), quiet = true)

    fun setDirection(folderId: String, direction: FolderDirection) =
        send(FoldersCommand(set_direction = FolderSetDirection(folderId, direction)))

    /** Replaces this device's overrides of [folderId]; another location attaches it there. */
    fun setFolderSettings(settings: FolderLocalSettings) =
        send(FoldersCommand(set_folder_settings = settings))

    fun remove(folderId: String, deleteLocalCopy: Boolean) =
        send(FoldersCommand(remove_device = FolderRemoveDevice(folderId, deleteLocalCopy)))

    fun download(folderId: String, path: String) =
        send(FoldersCommand(download = FolderPath(folderId, path)), quiet = true)

    /** Frees [path] (the whole folder when empty); it stays listed and downloads on tap. */
    fun evict(folderId: String, path: String) =
        send(FoldersCommand(evict = FolderPath(folderId, path)))

    fun freeUpSpace() = send(FoldersCommand(free_up_space = Step()))

    /** Applies or undoes the deletions the guard holds, here (empty [daemonId]) or on a daemon. */
    fun resolveDeletions(folderId: String, apply: Boolean, daemonId: String = "") =
        send(FoldersCommand(resolve_deletions = FolderResolveDeletions(folderId, daemonId, apply)))

    fun resolveConflict(folderId: String, path: String, keepCopy: Boolean) =
        send(FoldersCommand(resolve_conflict = FolderResolveConflict(folderId, path, keepCopy)))

    fun setDeviceSettings(value: FolderDeviceSettings) {
        settings.value = settings.value.copy(settings = value)
        send(FoldersCommand(set_device_settings = value))
    }

    // Trash ------------------------------------------------------------------------------------

    /** Reads [daemonId]'s trash (the first reachable member when empty), after [after]. */
    fun loadTrash(folderId: String, daemonId: String = "", after: String = "") =
        send(FoldersCommand(list_trash = FolderTrashQuery(folderId, daemonId, after)), quiet = true)

    fun restore(folderId: String, daemonId: String, ids: List<String>) =
        send(FoldersCommand(restore_trash = FolderTrashItems(folderId, daemonId, ids)))

    /** Purges [ids], or the whole trash of [daemonId] when empty. */
    fun purge(folderId: String, daemonId: String, ids: List<String> = emptyList()) =
        send(FoldersCommand(purge_trash = FolderTrashItems(folderId, daemonId, ids)))

    // Adding a folder ------------------------------------------------------------------------

    /** A daemon's directories at [path] (its home when empty), for the add-folder picker. */
    suspend fun directories(daemonId: String, path: String): DirectoryListing =
        context.core
            .dispatch(Command(admin = AdminCommand(directories = AdminDirectories(daemonId, path))))
            .directory_listing ?: DirectoryListing()

    /**
     * Runs the add-folder flow's choices in order: creates the folder (or joins
     * [AddFolderPlan.join]), binds the daemon's directory, and keeps a copy on this device. [done]
     * runs with the folder's ID once every step succeeded; a failure stops there and shows why.
     */
    fun add(plan: AddFolderPlan, done: (String) -> Unit) = context.action {
        var folderId = plan.join
        if (folderId.isEmpty()) {
            val created =
                context.core
                    .dispatch(
                        Command(
                            folders =
                                FoldersCommand(
                                    create =
                                        SyncedFolderCreate(
                                            name = plan.name.trim(),
                                            daemon_id = plan.daemonId,
                                            project_id = plan.projectId,
                                        )
                                )
                        )
                    )
                    .synced_folder
            folderId = checkNotNull(created?.id) { "The folder was not created." }
        }
        if (plan.daemonId.isNotEmpty() && plan.path.isNotBlank())
            context.core.dispatch(
                Command(
                    folders =
                        FoldersCommand(
                            attach_daemon =
                                FolderAttachDaemon(
                                    folder_id = folderId,
                                    daemon_id = plan.daemonId,
                                    path = plan.path.trim(),
                                    mode = FolderMode.FOLDER_MODE_TWO_WAY,
                                    join = plan.daemonJoin,
                                )
                        )
                )
            )
        if (plan.onDevice)
            context.core.dispatch(
                Command(
                    folders =
                        FoldersCommand(
                            scope = folderId,
                            attach_device =
                                FolderAttachDevice(
                                    folder_id = folderId,
                                    location = plan.location,
                                    location_label = plan.locationLabel,
                                    direction = plan.direction,
                                    remove_after_upload = plan.removeAfterUpload,
                                    home_daemon_id = plan.homeDaemonId,
                                ),
                        )
                )
            )
        done(folderId)
    }

    /** Saves [files] another app shared into [folderId]; [done] runs once they are saved. */
    fun save(folderId: String, files: List<FolderSaveSource>, done: () -> Unit) = context.action {
        val result =
            context.core
                .dispatch(
                    Command(
                        folders =
                            FoldersCommand(
                                scope = folderId,
                                save_files = FolderSaveFiles(folder_id = folderId, sources = files),
                            )
                    )
                )
                .folder_saved
        saved.value = result?.message.orEmpty()
        if (!result?.problem.isNullOrEmpty()) context.error.value = result.problem
        done()
    }

    /**
     * Sends [command], scoped to its folder, and folds the slice it returns. A [quiet] failure
     * shows only where the folder's slice says why (its action error).
     */
    private fun send(command: FoldersCommand, quiet: Boolean = false) {
        if (context.closed) return
        context.scope.launch {
            try {
                val scoped = command.copy(scope = command.scope.ifEmpty { folderOf(command) })
                val result = context.serialized { context.core.dispatch(Command(folders = scoped)) }
                result.folder?.let { if (it.id == shownFolder) folder.value = it }
                result.folders?.let { list.value = it }
                result.folder_sync_settings?.let { settings.value = it }
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (failure: Throwable) {
                if (!quiet) context.error.value = failure.message ?: "The folder command failed."
            }
        }
    }

    private fun folderOf(command: FoldersCommand): String =
        command.browse?.folder_id
            ?: command.list_trash?.folder_id
            ?: command.restore_trash?.folder_id
            ?: command.purge_trash?.folder_id
            ?: command.set_folder_settings?.folder_id
            ?: command.attach_device?.folder_id
            ?: command.resolve_conflict?.folder_id
            ?: command.resolve_deletions?.folder_id
            ?: command.download?.folder_id
            ?: command.evict?.folder_id
            ?: ""

    internal fun release() {
        showList(false)
        show(null)
    }
}

/** The add-folder flow's choices. */
data class AddFolderPlan(
    /** An existing folder to join; empty creates one named [name]. */
    val join: String = "",
    val name: String = "",
    val projectId: String = "",
    /** The daemon that keeps the folder and the directory on it; empty skips that step. */
    val daemonId: String = "",
    val path: String = "",
    val daemonJoin: FolderJoin = FolderJoin.FOLDER_JOIN_MERGE,
    /** Keep a copy on this device too. */
    val onDevice: Boolean = true,
    /** Empty uses the platform's own location. */
    val location: String = "",
    val locationLabel: String = "",
    val direction: FolderDirection = FolderDirection.FOLDER_DIRECTION_TWO_WAY,
    val removeAfterUpload: Boolean = false,
    val homeDaemonId: String = "",
)

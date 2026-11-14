package com.getdieter.core.folders

import com.getdieter.api.v1.FolderClientRef
import com.getdieter.api.v1.FolderEntry
import com.getdieter.api.v1.FolderEntryKind
import com.getdieter.core.runtime.CoreException
import com.getdieter.core.runtime.CoreLogger
import com.getdieter.core.runtime.FailureKind
import com.getdieter.core.runtime.Failures
import com.getdieter.core.session.MachineSessions
import com.getdieter.core.storage.CoreStorage
import com.getdieter.core.v1.FolderDeviceSettings
import com.getdieter.core.v1.FolderDirection
import com.getdieter.core.v1.FolderLocalSettings
import com.getdieter.core.v1.FolderSyncSettings
import com.getdieter.core.v1.FolderSyncState
import com.getdieter.core.v1.FolderTransfer
import com.getdieter.core.v1.FolderTransferKind
import com.getdieter.core.v1.LocalFolderEntry
import kotlin.concurrent.Volatile
import kotlin.coroutines.cancellation.CancellationException
import kotlin.time.Clock
import kotlin.time.Duration
import kotlin.time.Duration.Companion.minutes
import kotlin.time.Duration.Companion.seconds
import kotlin.time.Instant
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.IO
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** What the folder engines need from the rest of the core. */
interface FolderHost {
    /** This device once the roster trusts it; null before. */
    fun me(): FolderMe?

    /** The account's folder definitions by ID. */
    fun definitions(): Map<String, FolderDefinition>

    /**
     * The machines to try as [folderId]'s home, in order: only [preferred] when set, else daemon
     * members with a direct route first, then the most recently reachable.
     */
    fun homes(folderId: String, preferred: String): List<String>

    fun remote(machineId: String): FolderRemote
}

/** The outcome of a folder sync window. */
data class FolderWindowResult(
    /** Some folder has work left; the platform was asked for a longer run. */
    val workRemains: Boolean,
    /** Folders that ran. */
    val ran: Int = 0,
)

/** What a view shows of one folder on this device. */
data class FolderLocalView(
    val folderId: String,
    val settings: FolderLocalSettings,
    val state: FolderSyncState,
    val syncing: Boolean,
    /** Why it does not sync now, from the policy or the last run; empty when it may. */
    val reason: String,
    val pendingUploads: Int,
    val pendingUploadBytes: Long,
    val pendingDownloads: Int,
    val pendingDownloadBytes: Long,
    /** Files listed, their bytes, and the bytes held on this device. */
    val files: Int,
    val bytes: Long,
    val localBytes: Long,
    /** Conflict copies, by path. */
    val conflicts: List<String>,
    /** Download only: paths changed here that are not sent. */
    val localChanges: List<String>,
    val error: String,
)

/**
 * Synced folders on this device: the settings, one [FolderEngine] per folder kept here, run windows
 * and the commands that change this device's copies. Engines and their files are confined to
 * [dispatcher]; blocking file system calls run on the I/O dispatcher. Without a [platform] (the
 * Mac, the JVM) this device keeps no folders.
 */
class Folders(
    val platform: FolderPlatform?,
    private val host: FolderHost,
    private val scope: CoroutineScope,
    private val clock: Clock,
    private val logger: CoreLogger,
) {
    val dispatcher = Dispatchers.Default.limitedParallelism(1)

    private class Binding(val storage: CoreStorage) {
        val settings = FolderSettingsStore(storage)
        val engines = HashMap<String, FolderEngine>()
    }

    @Volatile private var binding: Binding? = null
    private val mutableRevision = MutableStateFlow(0L)

    /** Advances whenever settings or a folder's state on this device change. */
    val revision: StateFlow<Long> = mutableRevision.asStateFlow()
    private val running = MutableStateFlow<Set<String>>(emptySet())
    private val reasons = MutableStateFlow<Map<String, String>>(emptyMap())
    private val errors = MutableStateFlow<Map<String, String>>(emptyMap())
    @Volatile private var foreground: Job? = null
    private val watchers = HashMap<String, Job>()

    val capable: Boolean
        get() = platform != null

    /** Binds the account's namespace (null after sign-out); engines of the previous one go. */
    fun bind(storage: CoreStorage?) {
        val previous = binding
        binding = storage?.let { Binding(it.scope(NAMESPACE)) }
        scope.launch(dispatcher) {
            previous?.engines?.values?.forEach { engine ->
                watchers.remove(engine.folderId)?.cancel()
            }
        }
        running.value = emptySet()
        reasons.value = emptyMap()
        errors.value = emptyMap()
        changed()
        if (storage != null) reschedule()
    }

    private fun changed() = mutableRevision.update { it + 1 }

    private fun bound(): Binding =
        binding ?: throw CoreException(FailureKind.TRANSIENT, "Sign in to keep folders here.")

    private fun platformOrFail(): FolderPlatform =
        platform
            ?: throw CoreException(
                FailureKind.PERMANENT,
                "This device keeps no folders; a daemon member keeps them.",
            )

    /** The settings now; defaults before any were saved. */
    fun settings(): FolderSyncSettings =
        binding?.settings?.load() ?: FolderSyncSettings(device = FolderSettings.DEFAULTS)

    fun device(): FolderDeviceSettings = settings().device ?: FolderSettings.DEFAULTS

    fun folder(folderId: String): FolderLocalSettings? = binding?.settings?.folder(folderId)

    private fun engine(binding: Binding, folderId: String): FolderEngine {
        binding.engines[folderId]?.let {
            return it
        }
        val engine =
            FolderEngine(
                folderId,
                binding.storage.scope(folderId),
                platformOrFail().fileSystem,
                clock,
                logger,
            )
        binding.engines[folderId] = engine
        watchers[folderId] = scope.launch(dispatcher) { engine.revision.collect { changed() } }
        return engine
    }

    /** Runs [block] on the engines' dispatcher. */
    suspend fun <T> onFolders(block: suspend Folders.() -> T): T =
        withContext(dispatcher) { block() }

    // --- Windows ------------------------------------------------------------------------------

    /**
     * Syncs [folderId] (every folder on this device when null) until [deadline]: each folder's
     * policy decides, then its engine runs against its home daemon, failing over to the next one.
     * Reschedules the background window and asks the platform for a longer run when work remains.
     */
    suspend fun window(
        deadline: Instant,
        folderId: String? = null,
        trigger: FolderTrigger = FolderTrigger.BACKGROUND,
    ): FolderWindowResult =
        withContext(dispatcher) {
            val platform = platform ?: return@withContext FolderWindowResult(false)
            val binding = binding ?: return@withContext FolderWindowResult(false)
            val settings = binding.settings.load()
            val device = settings.device ?: FolderSettings.DEFAULTS
            val targets = settings.folders.filter { folderId == null || it.folder_id == folderId }
            var remains = false
            var ran = 0
            for (folder in targets) {
                if (clock.now() >= deadline) {
                    remains = true
                    break
                }
                val id = folder.folder_id
                if (id in running.value) continue
                val me = host.me()
                if (me == null) {
                    reason(id, "Waiting for this device to be trusted")
                    continue
                }
                val definition = host.definitions()[id]
                if (definition == null) {
                    reason(id, "Waiting for the folder's details")
                    continue
                }
                if (definition.archived) {
                    reason(id, "Archived")
                    continue
                }
                val conditions = platform.conditions.current()
                val decision =
                    FolderSyncPolicy.decide(device, folder, conditions, trigger, platform.platform)
                if (decision is FolderRunDecision.Skip) {
                    // A later window retries; a longer run now would skip just the same.
                    reason(id, decision.reason)
                    continue
                }
                val homes = host.homes(id, folder.home_daemon_id)
                if (homes.isEmpty()) {
                    reason(id, "No machine with this folder is reachable")
                    continue
                }
                reason(id, "")
                val engine = engine(binding, id)
                val used = usedBytes(binding)
                val plan =
                    FolderRunPlan(
                        device = device,
                        folder = folder,
                        decision = decision,
                        deadline = deadline,
                        usedBytes = { used },
                        metered = conditions.network == FolderNetwork.METERED,
                    )
                running.update { it + id }
                changed()
                try {
                    ran++
                    for ((attempt, home) in homes.withIndex()) {
                        try {
                            val result = engine.run(definition, plan, host.remote(home), me)
                            if (!result.complete) remains = true
                            binding.settings.addCellular(month(), result.meteredBytes)
                            errors.update { it - id }
                            break
                        } catch (cancelled: CancellationException) {
                            throw cancelled
                        } catch (error: Throwable) {
                            val message = Failures.message(error)
                            logger.info(TAG, "sync of $id with $home failed: $message")
                            errors.update { it + (id to message) }
                            remains = true
                            // An unreachable home fails over to the next daemon member.
                            if (
                                !MachineSessions.isTransportFailure(error) ||
                                    attempt == homes.lastIndex
                            )
                                break
                        }
                    }
                } finally {
                    running.update { it - id }
                    changed()
                }
            }
            reschedule()
            if (remains) platform.scheduler.requestLongRun(trigger == FolderTrigger.MANUAL)
            FolderWindowResult(remains, ran)
        }

    /** This month, as the cellular data count names it ("2026-11", UTC). */
    private fun month(): String =
        FolderReconcile.utcStamp(clock.now().toEpochMilliseconds() * 1_000_000).take(7)

    /** Cellular data folder sync used this month. */
    fun cellularBytes(): Long = binding?.settings?.cellular(month()) ?: 0

    private fun reason(folderId: String, text: String) {
        if ((reasons.value[folderId] ?: "") == text) return
        reasons.update { if (text.isEmpty()) it - folderId else it + (folderId to text) }
        changed()
    }

    private suspend fun usedBytes(binding: Binding): Long {
        var total = 0L
        for (folder in binding.settings.load().folders) {
            val engine = engine(binding, folder.folder_id)
            total += engine.index.entries().filter(FolderIndex::present).sumOf { it.entry!!.size }
        }
        return total
    }

    /** Schedules the periodic window for the folders on this device, or cancels it. */
    fun reschedule() {
        val platform = platform ?: return
        val settings = binding?.settings?.load()
        val request = settings?.let {
            FolderSyncPolicy.schedule(it.device ?: FolderSettings.DEFAULTS, it.folders)
        }
        if (request == null) platform.scheduler.cancel() else platform.scheduler.schedule(request)
    }

    /** Starts a window for [folderId] (all when null) in the background. */
    fun syncSoon(folderId: String?, trigger: FolderTrigger, length: Duration = MANUAL_WINDOW): Job =
        scope.launch {
            try {
                window(clock.now() + length, folderId, trigger)
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Throwable) {
                logger.warn(TAG, "folder sync failed", error)
            }
        }

    /**
     * Dieter is in the foreground or not: opening runs one window, and while open a scan runs every
     * 30 s so local changes go up right away.
     */
    fun setForeground(active: Boolean) {
        if (platform == null) return
        if (!active) {
            foreground?.cancel()
            foreground = null
            return
        }
        if (foreground?.isActive == true) return
        if (binding?.settings?.load()?.folders.isNullOrEmpty()) return
        foreground = scope.launch {
            syncSoon(null, FolderTrigger.OPENED).join()
            while (isActive) {
                delay(FOREGROUND_SCAN)
                syncSoon(null, FolderTrigger.LOCAL_CHANGE, FOREGROUND_WINDOW).join()
            }
        }
    }

    /** A home daemon's head moved past what this device applied: keep in sync live. */
    fun headMoved(folderId: String, machineId: String, indexId: String, sequence: Long) {
        if (foreground?.isActive != true) return
        scope.launch(dispatcher) {
            val engine = binding?.engines?.get(folderId) ?: return@launch
            val state = engine.state
            if (state.home_daemon_id != machineId) return@launch
            if (state.index_id == indexId && state.sequence.toULong() >= sequence.toULong())
                return@launch
            syncSoon(folderId, FolderTrigger.LIVE, FOREGROUND_WINDOW)
        }
    }

    // --- This device's membership ---------------------------------------------------------------

    /** Keeps [folderId] on this device at [location] (empty: the platform's own location). */
    suspend fun attach(
        folderId: String,
        name: String,
        location: String,
        locationLabel: String,
        direction: FolderDirection,
        removeAfterUpload: Boolean,
        homeDaemonId: String,
    ): FolderLocalSettings =
        withContext(dispatcher) {
            val platform = platformOrFail()
            val binding = bound()
            val chosen =
                if (location.isBlank()) platform.fileSystem.defaultLocation(folderId, name)
                else FolderLocation(location, locationLabel.ifBlank { location })
            val root = FolderRoot(folderId, chosen.location)
            val identity =
                try {
                    withContext(Dispatchers.IO) { platform.fileSystem.prepare(root) }
                } catch (unavailable: FolderUnavailableException) {
                    throw CoreException(FailureKind.PERMANENT, "That location cannot be used.")
                }
            val settings =
                FolderLocalSettings(
                    folder_id = folderId,
                    direction =
                        direction.takeIf { it != FolderDirection.FOLDER_DIRECTION_UNSPECIFIED }
                            ?: FolderDirection.FOLDER_DIRECTION_TWO_WAY,
                    remove_after_upload = removeAfterUpload,
                    location = chosen.location,
                    location_label = chosen.label,
                    home_daemon_id = homeDaemonId,
                )
            binding.engines.remove(folderId)?.forget() ?: binding.storage.scope(folderId).clear()
            val engine = engine(binding, folderId)
            engine.state = FolderSyncState(folder_id = folderId, root_identity = identity)
            engine.saveState()
            binding.settings.putFolder(settings)
            changed()
            reschedule()
            syncSoon(folderId, FolderTrigger.MANUAL)
            settings
        }

    /** Stops keeping [folderId] here; [deleteLocalCopy] also deletes this device's files. */
    suspend fun remove(folderId: String, deleteLocalCopy: Boolean) =
        withContext(dispatcher) {
            val binding = bound()
            val settings = binding.settings.folder(folderId) ?: return@withContext
            val engine = engine(binding, folderId)
            engine.edit {
                val registered = state.registered_daemon_ids
                if (deleteLocalCopy) {
                    withContext(Dispatchers.IO) {
                        platformOrFail()
                            .fileSystem
                            .deleteAll(FolderRoot(folderId, settings.location))
                    }
                }
                forget()
                val me = host.me()
                if (me != null) {
                    for (daemon in registered) {
                        runCatching {
                            host.remote(daemon).unregister(FolderClientRef(folderId, me.deviceId))
                        }
                    }
                }
            }
            binding.engines.remove(folderId)
            watchers.remove(folderId)?.cancel()
            binding.settings.removeFolder(folderId)
            reasons.update { it - folderId }
            changed()
            reschedule()
        }

    suspend fun setDirection(folderId: String, direction: FolderDirection) =
        withContext(dispatcher) {
            val binding = bound()
            val current = binding.settings.folder(folderId) ?: notOnDevice()
            binding.settings.putFolder(current.copy(direction = direction))
            // The home daemons learn the new mode when this device registers again.
            val engine = engine(binding, folderId)
            engine.local {
                state = state.copy(registered_daemon_ids = emptyList())
                saveState()
            }
            changed()
            reschedule()
            if (direction != FolderDirection.FOLDER_DIRECTION_PAUSED)
                syncSoon(folderId, FolderTrigger.MANUAL)
        }

    /**
     * Replaces [settings]' overrides; another location attaches the folder there afresh, and
     * [DEFAULT_LOCATION] means the platform's own location (private storage on Android).
     */
    suspend fun setFolderSettings(requested: FolderLocalSettings, name: String) {
        val settings =
            if (requested.location != DEFAULT_LOCATION) requested
            else
                platformOrFail().fileSystem.defaultLocation(requested.folder_id, name).let {
                    requested.copy(location = it.location, location_label = it.label)
                }
        val current = withContext(dispatcher) { bound().settings.folder(settings.folder_id) }
        if (
            current == null ||
                settings.location != current.location && settings.location.isNotEmpty()
        ) {
            attach(
                settings.folder_id,
                name,
                settings.location,
                settings.location_label,
                settings.direction,
                settings.remove_after_upload,
                settings.home_daemon_id,
            )
            return
        }
        withContext(dispatcher) {
            val binding = bound()
            binding.settings.putFolder(
                settings.copy(location = current.location, location_label = current.location_label)
            )
            if (settings.direction != current.direction) {
                val engine = engine(binding, settings.folder_id)
                engine.local {
                    state = state.copy(registered_daemon_ids = emptyList())
                    saveState()
                }
            }
            changed()
            reschedule()
        }
    }

    suspend fun setDeviceSettings(settings: FolderDeviceSettings) =
        withContext(dispatcher) {
            bound().settings.setDevice(settings)
            changed()
            reschedule()
        }

    private fun notOnDevice(): Nothing =
        throw CoreException(FailureKind.PERMANENT, "This folder is not on this device.")

    /** Downloads [path], which is listed but not on this device. */
    suspend fun download(folderId: String, path: String) {
        withContext(dispatcher) {
            val binding = bound()
            binding.settings.folder(folderId) ?: notOnDevice()
            val engine = engine(binding, folderId)
            engine.local {
                val local =
                    index[path] ?: throw CoreException(FailureKind.PERMANENT, "That file is gone.")
                val entry = local.entry!!
                if (entry.kind != FolderEntryKind.FOLDER_ENTRY_KIND_FILE)
                    throw CoreException(FailureKind.PERMANENT, "Only files download.")
                if (FolderIndex.present(local)) return@local
                queue(
                    FolderTransfer(
                        kind = FolderTransferKind.FOLDER_TRANSFER_KIND_APPLY,
                        path = path,
                        remote = entry,
                        on_demand = true,
                    )
                )
                saveJournal()
                changed()
            }
        }
        syncSoon(folderId, FolderTrigger.MANUAL)
    }

    /**
     * Frees [path] (every downloaded file a daemon holds when empty); returns the files freed.
     * Never a deletion: they stay listed and download on tap.
     */
    suspend fun evict(folderId: String, path: String): Int =
        withContext(dispatcher) {
            val binding = bound()
            val settings = binding.settings.folder(folderId) ?: notOnDevice()
            val engine = engine(binding, folderId)
            val root = FolderRoot(folderId, settings.location)
            engine.local {
                val targets =
                    if (path.isEmpty())
                        index.entries().filter { FolderIndex.present(it) && it.synced }.toList()
                    else
                        listOfNotNull(index[path]).also { list ->
                            val local =
                                list.firstOrNull()
                                    ?: throw CoreException(
                                        FailureKind.PERMANENT,
                                        "That file is gone.",
                                    )
                            if (!FolderIndex.present(local)) return@local 0
                            if (!local.synced)
                                throw CoreException(
                                    FailureKind.PERMANENT,
                                    "This file is not uploaded yet, so it cannot be freed.",
                                )
                        }
                var freed = 0
                for (local in targets) {
                    val disk = FolderIndex.diskPath(local)
                    val evicted =
                        withContext(Dispatchers.IO) {
                            val now = fs.stat(root, disk)
                            if (
                                now != null &&
                                    now.size == local.observed_size &&
                                    now.modifiedNanos == local.observed_modified_nanos &&
                                    now.token == local.observed_token
                            ) {
                                fs.delete(root, disk, now)
                                true
                            } else false
                        }
                    if (evicted) {
                        index.put(local.copy(evicted = true))
                        freed++
                    }
                }
                index.flush()
                changed()
                freed
            }
        }

    /** Frees every downloaded file a daemon holds, in every folder. */
    suspend fun freeUpSpace(): Int {
        val ids =
            withContext(dispatcher) {
                binding?.settings?.load()?.folders?.map { it.folder_id }.orEmpty()
            }
        return ids.sumOf { evict(it, "") }
    }

    /**
     * Applies or undoes the deletions the guard holds on this device. Applying records them;
     * restoring downloads missing files again, or sends this device's copies of files another
     * device deleted.
     */
    suspend fun resolveDeletions(folderId: String, apply: Boolean) {
        withContext(dispatcher) {
            val binding = bound()
            binding.settings.folder(folderId) ?: notOnDevice()
            val engine = engine(binding, folderId)
            val me = host.me()
            engine.local {
                val held = state.held_deletions ?: return@local
                if (held.source == FolderRun.LOCAL) {
                    if (apply) state = state.copy(deletions_confirmed = true)
                    else
                        for (entry in held.entries) {
                            val local = index[entry.path] ?: continue
                            if (entry.kind != FolderEntryKind.FOLDER_ENTRY_KIND_FILE) continue
                            // Not on disk on purpose until the download is back.
                            index.put(local.copy(evicted = true))
                            queue(
                                FolderTransfer(
                                    kind = FolderTransferKind.FOLDER_TRANSFER_KIND_APPLY,
                                    path = entry.path,
                                    remote = local.entry,
                                    on_demand = true,
                                )
                            )
                        }
                } else {
                    for (tombstone in held.entries) {
                        if (apply) {
                            queue(
                                FolderTransfer(
                                    kind = FolderTransferKind.FOLDER_TRANSFER_KIND_APPLY,
                                    path = tombstone.path,
                                    remote = tombstone,
                                )
                            )
                        } else if (me != null) {
                            // The deletion is undone by a version that dominates it.
                            val local = index[tombstone.path] ?: continue
                            val entry = local.entry!!
                            index.put(
                                local.copy(
                                    entry =
                                        entry.copy(
                                            version =
                                                Versions.bump(
                                                    Versions.merge(
                                                        entry.version,
                                                        tombstone.version,
                                                    ),
                                                    me.actor,
                                                ),
                                            author_id = me.deviceId,
                                            author_name = me.name,
                                        ),
                                    synced = false,
                                )
                            )
                        }
                    }
                }
                state = state.copy(held_deletions = null, attention = "")
                index.flush()
                saveJournal()
                saveState()
            }
        }
        syncSoon(folderId, FolderTrigger.MANUAL)
    }

    /**
     * Keeps one side of a conflict: with [keepCopy] the conflict copy replaces the original,
     * otherwise the conflict copy goes. Both are local changes that sync like any other.
     */
    suspend fun resolveConflict(folderId: String, path: String, keepCopy: Boolean) {
        withContext(dispatcher) {
            val binding = bound()
            val settings = binding.settings.folder(folderId) ?: notOnDevice()
            val original =
                FolderReconcile.conflictOriginal(path)
                    ?: throw CoreException(FailureKind.PERMANENT, "That is not a conflict copy.")
            val me =
                host.me()
                    ?: throw CoreException(FailureKind.TRANSIENT, "This device is not trusted yet.")
            val engine = engine(binding, folderId)
            val root = FolderRoot(folderId, settings.location)
            engine.local {
                val copy =
                    index[path] ?: throw CoreException(FailureKind.PERMANENT, "That file is gone.")
                val tombstone = { local: LocalFolderEntry ->
                    LocalFolderEntry(
                        entry =
                            FolderEntry(
                                path = local.entry!!.path,
                                kind = FolderEntryKind.FOLDER_ENTRY_KIND_DELETED,
                                version = Versions.bump(local.entry!!.version, me.actor),
                                author_id = me.deviceId,
                                author_name = me.name,
                            ),
                        synced = false,
                    )
                }
                if (!keepCopy) {
                    if (FolderIndex.present(copy)) removeObserved(root, copy)
                    index.put(tombstone(copy))
                } else {
                    if (!FolderIndex.present(copy))
                        throw CoreException(
                            FailureKind.PERMANENT,
                            "Download the conflict copy first.",
                        )
                    val target = index[original]
                    if (target != null && FolderIndex.present(target)) removeObserved(root, target)
                    val moved =
                        withContext(Dispatchers.IO) {
                            val now =
                                fs.stat(root, FolderIndex.diskPath(copy))
                                    ?: throw FolderChangedException()
                            fs.move(root, FolderIndex.diskPath(copy), original, now)
                            fs.stat(root, original) ?: throw FolderChangedException()
                        }
                    val entry = copy.entry!!
                    index.put(
                        LocalFolderEntry(
                            entry =
                                entry.copy(
                                    path = original,
                                    version =
                                        Versions.bump(target?.entry?.version.orEmpty(), me.actor),
                                    author_id = me.deviceId,
                                    author_name = me.name,
                                ),
                            observed_size = moved.size,
                            observed_modified_nanos = moved.modifiedNanos,
                            observed_token = moved.token,
                            synced = false,
                        )
                    )
                    index.put(tombstone(copy))
                }
                index.flush()
                changed()
            }
        }
        syncSoon(folderId, FolderTrigger.LOCAL_CHANGE)
    }

    /**
     * Saves files another app shared ([FolderSaveRequest.source] as the platform reads it) into
     * [directory] of [folderId]'s copy on this device ("Save to folder…"). Each keeps its name, or
     * gets a free variant ("Report (2).pdf") when that name or one differing only by case is taken,
     * and is published create-only, so nothing here is ever overwritten. The files are local
     * changes the next scan sends; a sync starts at once. Files that cannot be read are reported in
     * [FolderSaveOutcome.problem]; the others are still saved.
     */
    suspend fun save(
        folderId: String,
        directory: String,
        files: List<FolderSaveRequest>,
    ): FolderSaveOutcome {
        val outcome =
            withContext(dispatcher) {
                val platform = platformOrFail()
                val sources =
                    platform.sources
                        ?: throw CoreException(
                            FailureKind.PERMANENT,
                            "This device cannot save shared files into folders.",
                        )
                val binding = bound()
                val settings = binding.settings.folder(folderId) ?: notOnDevice()
                if (directory.isNotEmpty() && !FolderNames.validPath(directory))
                    throw CoreException(FailureKind.PERMANENT, "That is not a folder path.")
                if (files.isEmpty())
                    throw CoreException(FailureKind.PERMANENT, "Choose files to save.")
                val root = FolderRoot(folderId, settings.location)
                val saved = ArrayList<String>()
                var problem = ""
                for (file in files) {
                    try {
                        saved +=
                            withContext(Dispatchers.IO) {
                                saveOne(platform.fileSystem, sources, root, directory, file)
                            }
                    } catch (cancelled: CancellationException) {
                        throw cancelled
                    } catch (unavailable: FolderUnavailableException) {
                        throw CoreException(
                            FailureKind.PERMANENT,
                            unavailable.message ?: "The folder location is unavailable.",
                        )
                    } catch (error: Throwable) {
                        logger.info(TAG, "saving a shared file into $folderId failed: $error")
                        problem =
                            "${FolderNames.sharedName(file.name)} could not be saved: " +
                                (error.message ?: "it could not be read.")
                    }
                }
                FolderSaveOutcome(saved, problem)
            }
        if (outcome.paths.isNotEmpty()) syncSoon(folderId, FolderTrigger.LOCAL_CHANGE)
        return outcome
    }

    private fun saveOne(
        fs: FolderFileSystem,
        sources: FolderSources,
        root: FolderRoot,
        directory: String,
        file: FolderSaveRequest,
    ): String {
        val wanted = FolderNames.sharedName(file.name)
        if (directory.isNotEmpty()) fs.mkdir(root, directory)
        val taken = fs.list(root, directory).mapTo(HashSet()) { FolderNames.foldKey(it.name) }
        for (attempt in 0 until MAX_NAME_ATTEMPTS) {
            val name = FolderNames.variant(wanted, attempt)
            if (FolderNames.foldKey(name) in taken) continue
            val path = if (directory.isEmpty()) name else "$directory/$name"
            if (fs.stat(root, path) != null) continue
            val stagingName =
                FolderBounds.TEMPORARY_PREFIX +
                    kotlin.random.Random.nextLong().toULong().toString(16).padStart(16, '0')
            val staging = if (directory.isEmpty()) stagingName else "$directory/$stagingName"
            try {
                sources.open(file.source).use { input ->
                    val buffer = ByteArray(FolderBounds.CHUNK_SIZE)
                    var offset = 0L
                    fs.writeStaging(root, staging, 0, ByteArray(0))
                    while (true) {
                        val read = input.read(buffer)
                        if (read < 0) break
                        if (read == 0) continue
                        if (offset + read > FolderBounds.MAX_FILE_SIZE)
                            throw CoreException(FailureKind.PERMANENT, "it is larger than 64 GB.")
                        fs.writeStaging(root, staging, offset, buffer.copyOf(read))
                        offset += read
                    }
                }
                fs.publish(
                    root,
                    staging,
                    path,
                    null,
                    clock.now().toEpochMilliseconds() * 1_000_000,
                    false,
                )
                return path
            } catch (taken: FolderChangedException) {
                // Something appeared at that name meanwhile: try the next one.
                fs.discardStaging(root, staging)
            } catch (error: Throwable) {
                runCatching { fs.discardStaging(root, staging) }
                throw error
            }
        }
        throw CoreException(FailureKind.PERMANENT, "no free name is left for it.")
    }

    private suspend fun FolderEngine.removeObserved(root: FolderRoot, local: LocalFolderEntry) {
        withContext(Dispatchers.IO) {
            val disk = FolderIndex.diskPath(local)
            val now = fs.stat(root, disk) ?: return@withContext
            if (
                now.size != local.observed_size ||
                    now.modifiedNanos != local.observed_modified_nanos ||
                    now.token != local.observed_token
            )
                throw FolderChangedException("${local.entry!!.path} changed on this device.")
            fs.delete(root, disk, now)
        }
    }

    // --- Views ----------------------------------------------------------------------------------

    /** What views show of [folderId] on this device; null when it is not kept here. */
    suspend fun view(folderId: String): FolderLocalView? =
        withContext(dispatcher) {
            val binding = binding ?: return@withContext null
            val settings = binding.settings.folder(folderId) ?: return@withContext null
            if (platform == null) return@withContext null
            val engine = engine(binding, folderId)
            var files = 0
            var bytes = 0L
            var local = 0L
            var uploads = 0
            var uploadBytes = 0L
            val conflicts = ArrayList<String>()
            val changes = ArrayList<String>()
            val mode = FolderSettings.mode(settings.direction)
            for (item in engine.index.entries()) {
                val entry = item.entry!!
                if (entry.kind != FolderEntryKind.FOLDER_ENTRY_KIND_FILE) {
                    if (
                        item.local_change &&
                            entry.kind == FolderEntryKind.FOLDER_ENTRY_KIND_DIRECTORY
                    )
                        changes += entry.path
                    if (
                        !item.synced &&
                            entry.version.isNotEmpty() &&
                            mode != com.getdieter.api.v1.FolderMode.FOLDER_MODE_RECEIVE_ONLY
                    )
                        uploads++
                    continue
                }
                files++
                bytes += entry.size
                if (FolderIndex.present(item)) local += entry.size
                if (
                    !item.synced &&
                        entry.version.isNotEmpty() &&
                        mode != com.getdieter.api.v1.FolderMode.FOLDER_MODE_RECEIVE_ONLY
                ) {
                    uploads++
                    uploadBytes += entry.size
                }
                if (item.local_change) changes += entry.path
                if (FolderReconcile.conflictOriginal(entry.path) != null) conflicts += entry.path
            }
            val downloads =
                engine.journal.filter {
                    it.kind != FolderTransferKind.FOLDER_TRANSFER_KIND_UPLOAD &&
                        it.remote?.kind == FolderEntryKind.FOLDER_ENTRY_KIND_FILE
                }
            FolderLocalView(
                folderId = folderId,
                settings = settings,
                state = engine.state,
                syncing = folderId in running.value,
                reason = reasons.value[folderId] ?: engine.state.reason,
                pendingUploads = uploads,
                pendingUploadBytes = uploadBytes,
                pendingDownloads = downloads.size,
                pendingDownloadBytes = downloads.sumOf { (it.remote?.size ?: 0) - it.offset },
                files = files,
                bytes = bytes,
                localBytes = local,
                conflicts = conflicts.sorted(),
                localChanges = changes.sorted(),
                error = errors.value[folderId].orEmpty(),
            )
        }

    /** Every folder kept on this device. */
    suspend fun views(): List<FolderLocalView> =
        settings().folders.mapNotNull { view(it.folder_id) }

    /** The entries directly inside [directory] of [folderId]'s copy, deletions left out. */
    suspend fun listing(folderId: String, directory: String): List<LocalFolderEntry> =
        withContext(dispatcher) {
            val binding = binding ?: return@withContext emptyList()
            binding.settings.folder(folderId) ?: return@withContext emptyList()
            if (platform == null) return@withContext emptyList()
            engine(binding, folderId)
                .index
                .entries()
                .filter {
                    val entry = it.entry!!
                    entry.kind != FolderEntryKind.FOLDER_ENTRY_KIND_DELETED &&
                        FolderNames.parent(entry.path) == directory
                }
                .toList()
        }

    /** Paths of planned downloads of [folderId]. */
    suspend fun downloading(folderId: String): Set<String> =
        withContext(dispatcher) {
            binding
                ?.engines
                ?.get(folderId)
                ?.journal
                ?.filter {
                    it.kind == FolderTransferKind.FOLDER_TRANSFER_KIND_APPLY
                }
                ?.mapTo(HashSet()) { it.path }
                .orEmpty()
        }

    companion object {
        private const val TAG = "Folders"
        const val NAMESPACE = "folders"
        /**
         * A location that names the platform's own one, e.g. to move a folder to private storage.
         */
        const val DEFAULT_LOCATION = "default"
        val MANUAL_WINDOW = 10.minutes
        val FOREGROUND_WINDOW = 2.minutes
        val FOREGROUND_SCAN = 30.seconds
        private const val MAX_NAME_ATTEMPTS = 100
    }
}

/** One file to save into a folder: [source] as the platform reads it, and the [name] it wants. */
data class FolderSaveRequest(val source: String, val name: String)

/** The paths saved files got, and why some could not be saved (empty when all were). */
data class FolderSaveOutcome(val paths: List<String>, val problem: String)

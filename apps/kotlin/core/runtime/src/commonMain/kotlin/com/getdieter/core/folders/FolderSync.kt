package com.getdieter.core.folders

import com.getdieter.api.v1.FolderDeleteGuard
import com.getdieter.api.v1.FolderEntry
import com.getdieter.api.v1.FolderEntryKind
import com.getdieter.api.v1.FolderMode
import com.getdieter.api.v1.GetFolderIndexRequest
import com.getdieter.api.v1.RegisterFolderClientRequest
import com.getdieter.core.runtime.CoreLogger
import com.getdieter.core.storage.CoreStorage
import com.getdieter.core.v1.FolderDeviceSettings
import com.getdieter.core.v1.FolderLocalSettings
import com.getdieter.core.v1.FolderProblemRecord
import com.getdieter.core.v1.FolderSyncState
import com.getdieter.core.v1.FolderTransfer
import com.getdieter.core.v1.FolderTransferJournal
import com.getdieter.core.v1.FolderTransferKind
import com.getdieter.core.v1.HeldFolderDeletions
import com.getdieter.core.v1.LocalFolderEntry
import kotlin.time.Clock
import kotlin.time.Instant
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.IO
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

/** This device as a client member: its roster device ID, its actor and the name it shows. */
data class FolderMe(val deviceId: String, val name: String) {
    val actor: String = Versions.actorOf(deviceId)
}

/** A folder's shared definition as the engine uses it. */
data class FolderDefinition(
    val id: String,
    val name: String,
    val rules: List<FolderRule>,
    val guard: FolderDeleteGuard = FolderDeleteGuard.FOLDER_DELETE_GUARD_DEFAULT,
    val archived: Boolean = false,
)

/** What one run may do and until when. */
data class FolderRunPlan(
    val device: FolderDeviceSettings,
    val folder: FolderLocalSettings,
    /** [FolderRunDecision.RunAll] or [FolderRunDecision.SmallOnly]. */
    val decision: FolderRunDecision,
    val deadline: Instant,
    /** Bytes this device's folders hold now, for the storage limit. */
    val usedBytes: () -> Long = { 0 },
    /** The run uses a metered network; its bytes count toward the month's cellular data. */
    val metered: Boolean = false,
)

data class FolderRunResult(
    /** Nothing is left for a later run. */
    val complete: Boolean,
    val uploaded: Int = 0,
    val downloaded: Int = 0,
    val deleted: Int = 0,
    val conflicts: Int = 0,
    /** Why it stopped short, e.g. "Waiting for Wi-Fi"; empty when it did not. */
    val reason: String = "",
    /** What waits for the person; empty when nothing does. */
    val attention: String = "",
    val meteredBytes: Long = 0,
)

/**
 * One synced folder on this device (§3.14): its sharded index, the transfer journal and the
 * checkpoint with its home daemon, all in [storage]. [run] scans the local copy, exchanges the
 * index, reconciles with the shared rules and transfers in order, persisting after every durable
 * step so a run that stops at its deadline resumes where it stopped. Runs and commands of one
 * folder are serialized by [mutex].
 */
class FolderEngine(
    val folderId: String,
    private val storage: CoreStorage,
    internal val fs: FolderFileSystem,
    internal val clock: Clock,
    internal val logger: CoreLogger,
) {
    val index = FolderIndex(storage)
    internal val mutex = Mutex()

    var state: FolderSyncState = load()
        internal set

    internal val journal: MutableList<FolderTransfer> =
        storage
            .read(JOURNAL)
            ?.let { runCatching { FolderTransferJournal.ADAPTER.decode(it) }.getOrNull() }
            ?.transfers
            ?.toMutableList() ?: mutableListOf()

    private val mutableRevision = MutableStateFlow(0L)

    /** Advances after every change a view may show. */
    val revision: StateFlow<Long> = mutableRevision.asStateFlow()

    private fun load(): FolderSyncState =
        storage.read(STATE)?.let { runCatching { FolderSyncState.ADAPTER.decode(it) }.getOrNull() }
            ?: FolderSyncState(folder_id = folderId)

    internal fun saveState() {
        storage.write(STATE, FolderSyncState.ADAPTER.encode(state))
        changed()
    }

    internal fun saveJournal() {
        storage.write(JOURNAL, FolderTransferJournal.ADAPTER.encode(FolderTransferJournal(journal)))
    }

    internal fun changed() = mutableRevision.update { it + 1 }

    /** The planned and started transfers, for the status. */
    val transfers: List<FolderTransfer>
        get() = journal.toList()

    /** Runs one sync of this folder with [remote] as its home daemon. */
    suspend fun run(
        definition: FolderDefinition,
        plan: FolderRunPlan,
        remote: FolderRemote,
        me: FolderMe,
    ): FolderRunResult = mutex.withLock { FolderRun(this, definition, plan, remote, me).execute() }

    /** Runs [block] with this folder's state once no run holds it. */
    suspend fun <T> edit(block: suspend FolderEngine.() -> T): T = mutex.withLock { block() }

    /**
     * Runs [block] with this folder's state without waiting for a run: both are confined to the
     * engines' dispatcher, and every file operation checks the state it expects, so a command never
     * waits behind a long transfer.
     */
    internal suspend fun <T> local(block: suspend FolderEngine.() -> T): T = block()

    /** Forgets everything this device kept for the folder; its files stay. */
    fun forget() {
        index.clear()
        journal.clear()
        storage.clear()
        state = FolderSyncState(folder_id = folderId)
        changed()
    }

    /** Queues [transfer], replacing the planned one for the same path. */
    internal fun queue(transfer: FolderTransfer) {
        val key = transferKey(transfer)
        journal.removeAll { transferKey(it) == key }
        journal += transfer
    }

    internal fun transferKey(transfer: FolderTransfer): String =
        when (transfer.kind) {
            FolderTransferKind.FOLDER_TRANSFER_KIND_CONFLICT_COPY ->
                "copy:" + transfer.conflict_copy
            FolderTransferKind.FOLDER_TRANSFER_KIND_UPLOAD -> "up:" + transfer.path
            else -> "apply:" + transfer.path
        }

    internal companion object {
        const val STATE = "state.pb"
        const val JOURNAL = "journal.pb"
    }
}

/** One run of a [FolderEngine]. */
internal class FolderRun(
    val engine: FolderEngine,
    val definition: FolderDefinition,
    val plan: FolderRunPlan,
    val remote: FolderRemote,
    val me: FolderMe,
) {
    val folderId = engine.folderId
    val fs = engine.fs
    val root = FolderRoot(folderId, plan.folder.location)
    val mode = FolderSettings.mode(plan.folder.direction)
    val decision = plan.decision
    val removeAfterUpload =
        mode == FolderMode.FOLDER_MODE_SEND_ONLY && plan.folder.remove_after_upload
    private val autoDownload = FolderSettings.autoDownloadBytes(plan.device, plan.folder)

    var workRemains = false
    var needIndex = false
    var stopped = false
    var reason = ""
    var uploaded = 0
    var downloaded = 0
    var deleted = 0
    var conflicts = 0
    private var meteredBytes = 0L
    private val outOfSync = LinkedHashSet<String>()
    private var errors = 0

    fun expired(): Boolean = engine.clock.now() >= plan.deadline

    suspend fun <T> io(block: () -> T): T = withContext(Dispatchers.IO) { block() }

    fun put(entry: LocalFolderEntry) {
        engine.index.put(entry)
        engine.changed()
    }

    /** Records [op]'s progress durably; returns it. */
    fun journal(op: FolderTransfer): FolderTransfer {
        val key = engine.transferKey(op)
        val at = engine.journal.indexOfFirst { engine.transferKey(it) == key }
        if (at >= 0) engine.journal[at] = op else engine.journal += op
        engine.saveJournal()
        engine.index.flush()
        return op
    }

    /** A finished transfer leaves the journal, after the index recorded its result. */
    fun drop(op: FolderTransfer) {
        engine.index.flush()
        val key = engine.transferKey(op)
        engine.journal.removeAll { engine.transferKey(it) == key }
        engine.saveJournal()
        engine.changed()
    }

    fun problem(path: String, message: String) {
        errors++
        val record = FolderProblemRecord(path, message, engine.clock.now().toEpochMilliseconds())
        engine.state =
            engine.state.copy(
                errors = (listOf(record) + engine.state.errors).take(FolderBounds.MAX_PROBLEMS)
            )
    }

    fun attention(message: String) {
        stopped = true
        engine.state = engine.state.copy(attention = message)
        engine.saveState()
    }

    fun metered(bytes: Long) {
        if (plan.metered) meteredBytes += bytes
    }

    suspend fun fitsStorage(size: Long, onDemand: Boolean): Boolean {
        val free = io { fs.freeBytes(root) }
        return FolderSyncPolicy.fitsStorage(plan.device, plan.usedBytes(), free, size, onDemand)
    }

    fun sameObserved(info: FolderFileInfo, local: LocalFolderEntry): Boolean =
        info.kind == FolderFileKind.FILE &&
            info.size == local.observed_size &&
            info.modifiedNanos == local.observed_modified_nanos &&
            info.token == local.observed_token

    /** The SHA-256 of the file at [path] as [info] describes it; null when it changed meanwhile. */
    suspend fun hash(path: String, info: FolderFileInfo): String? {
        val hash = Sha256()
        var offset = 0L
        val chunk = FolderBounds.CHUNK_SIZE.toLong()
        while (offset < info.size) {
            if (expired()) return null
            val bytes = io { fs.read(root, path, offset, minOf(chunk, info.size - offset).toInt()) }
            if (bytes.isEmpty()) return null
            hash.update(bytes)
            offset += bytes.size
        }
        val after = io { fs.stat(root, path) } ?: return null
        if (
            after.size != info.size ||
                after.modifiedNanos != info.modifiedNanos ||
                after.token != info.token
        )
            return null
        return hash.hex()
    }

    suspend fun execute(): FolderRunResult {
        var state = engine.state
        val identity = io { fs.rootIdentity(root) }
        if (
            identity == null || state.root_identity.isNotEmpty() && identity != state.root_identity
        ) {
            attention(LOCATION_UNAVAILABLE)
            return result(complete = false)
        }
        if (state.root_identity.isEmpty()) state = state.copy(root_identity = identity)
        if (state.held_deletions != null) {
            // A held deletion waits for the person.
            engine.state = state
            engine.saveState()
            stopped = true
            return result(complete = false)
        }
        // Anything else that waited (a lost location, a full index) is checked again.
        state = state.copy(attention = "")
        if (state.home_daemon_id != remote.daemonId)
            state = state.copy(home_daemon_id = remote.daemonId, index_id = "", sequence = 0)
        engine.state = state.copy(last_attempt_millis = engine.clock.now().toEpochMilliseconds())
        if (remote.daemonId !in engine.state.registered_daemon_ids) {
            remote.register(
                RegisterFolderClientRequest(
                    folder_id = folderId,
                    device_id = me.deviceId,
                    name = me.name,
                    mode = mode,
                )
            )
            engine.state =
                engine.state.copy(
                    registered_daemon_ids = engine.state.registered_daemon_ids + remote.daemonId
                )
        }
        engine.saveState()
        val scanned = scan()
        if (!stopped) {
            var rounds = 0
            while (!stopped && !expired()) {
                if (!exchange()) break
                needIndex = false
                val before = uploaded + downloaded + deleted + conflicts
                if (!transfer()) break
                // Another round after a stale version, or for work this one created (conflict
                // copies to send).
                val progressed = uploaded + downloaded + deleted + conflicts != before
                if (++rounds >= MAX_ROUNDS) break
                if (!needIndex && !(progressed && plan().isNotEmpty())) break
            }
            if (needIndex) workRemains = true
        }
        if (expired()) workRemains = true
        if (!scanned) workRemains = true
        return finish()
    }

    private fun finish(): FolderRunResult {
        val pending =
            engine.journal.isNotEmpty() ||
                mode != FolderMode.FOLDER_MODE_RECEIVE_ONLY &&
                    engine.index.entries().any { !it.synced && it.entry!!.version.isNotEmpty() }
        val remains = workRemains || pending
        val now = engine.clock.now().toEpochMilliseconds()
        engine.index.flush()
        engine.state =
            engine.state.copy(
                last_sync_millis =
                    if (!remains && !stopped && errors == 0) now else engine.state.last_sync_millis,
                out_of_sync = outOfSync.toList().take(FolderBounds.MAX_PROBLEMS),
                reason = reason,
                work_remains = remains,
            )
        engine.saveState()
        return result(!remains && !stopped)
    }

    private fun result(complete: Boolean) =
        FolderRunResult(
            complete = complete,
            uploaded = uploaded,
            downloaded = downloaded,
            deleted = deleted,
            conflicts = conflicts,
            reason = reason,
            attention = engine.state.attention,
            meteredBytes = meteredBytes,
        )

    // --- Scan ---------------------------------------------------------------------------------

    /**
     * Walks the local copy: a changed file is hashed, and only new content bumps this device's
     * counter. Files missing after a complete walk become deletions, unless they were never
     * downloaded or were evicted, and the deletion guard holds a mass deletion. Returns whether the
     * walk completed.
     */
    private suspend fun scan(): Boolean {
        val seen = HashSet<String>()
        val unsyncable = ArrayList<FolderProblemRecord>()
        val now = engine.clock.now().toEpochMilliseconds()
        val directories = ArrayDeque<String>()
        directories.addLast("")
        var complete = true
        walk@ while (directories.isNotEmpty()) {
            if (expired()) {
                complete = false
                break
            }
            val directory = directories.removeLast()
            val children = io { fs.list(root, directory) }
            for (child in children) {
                if (FolderNames.protected(child.name)) continue
                val disk = if (directory.isEmpty()) child.name else "$directory/${child.name}"
                val path = FolderNames.normalize(disk)
                if (!FolderRules.included(path, definition.rules)) continue
                val invalid = FolderNames.pathProblem(path)
                if (invalid != null) {
                    unsyncable += FolderProblemRecord(path, "Can't sync here: $invalid", now)
                    continue
                }
                try {
                    when (child.kind) {
                        FolderFileKind.SYMLINK -> {
                            unsyncable += FolderProblemRecord(path, "Symlinks are not synced", now)
                            continue
                        }
                        FolderFileKind.OTHER -> {
                            unsyncable += FolderProblemRecord(path, "Not a file or folder", now)
                            continue
                        }
                        FolderFileKind.DIRECTORY -> {
                            seen += path
                            scanDirectory(path, disk)
                            directories.addLast(disk)
                        }
                        FolderFileKind.FILE -> {
                            seen += path
                            if (!scanFile(path, disk, child)) complete = false
                        }
                    }
                } catch (full: FolderIndexFullException) {
                    attention(TOO_MANY_FILES)
                    complete = false
                    break@walk
                }
                if (expired()) {
                    complete = false
                    break@walk
                }
            }
        }
        engine.state = engine.state.copy(unsyncable = unsyncable.take(FolderBounds.MAX_PROBLEMS))
        if (complete) detectDeletions(seen)
        engine.index.flush()
        engine.saveState()
        return complete
    }

    private fun diskName(path: String, disk: String) = if (disk == path) "" else disk

    private suspend fun scanFile(path: String, disk: String, info: FolderFileInfo): Boolean {
        val existing = engine.index[path]
        val entry = existing?.entry
        if (existing != null && FolderIndex.present(existing) && sameObserved(info, existing))
            return true
        val sha = hash(disk, info) ?: return false
        val observed = { local: LocalFolderEntry ->
            local.copy(
                observed_size = info.size,
                observed_modified_nanos = info.modifiedNanos,
                observed_token = info.token,
                disk_path = diskName(path, disk),
            )
        }
        val sameFile =
            entry != null &&
                entry.kind == FolderEntryKind.FOLDER_ENTRY_KIND_FILE &&
                entry.sha256 == sha &&
                entry.size == info.size
        if (sameFile) {
            // Touched, or a file that was not here came back unchanged: no new version.
            put(
                observed(existing)
                    .copy(absent_by_policy = false, evicted = false, local_change = false)
            )
            return true
        }
        if (mode == FolderMode.FOLDER_MODE_RECEIVE_ONLY) {
            // Not sent: shown as a local change; a remote change keeps it as a conflict copy.
            put(
                observed(
                    existing?.copy(local_change = true, absent_by_policy = false, evicted = false)
                        ?: LocalFolderEntry(
                            entry =
                                FolderEntry(
                                    path = path,
                                    kind = FolderEntryKind.FOLDER_ENTRY_KIND_FILE,
                                    size = info.size,
                                    modified_nanos = info.modifiedNanos,
                                    sha256 = sha,
                                    author_id = me.deviceId,
                                    author_name = me.name,
                                ),
                            synced = true,
                            local_change = true,
                        )
                )
            )
            return true
        }
        val version = Versions.bump(entry?.version.orEmpty(), me.actor)
        put(
            observed(
                LocalFolderEntry(
                    entry =
                        FolderEntry(
                            path = path,
                            kind = FolderEntryKind.FOLDER_ENTRY_KIND_FILE,
                            size = info.size,
                            modified_nanos = info.modifiedNanos,
                            executable =
                                entry
                                    ?.takeIf { it.kind == FolderEntryKind.FOLDER_ENTRY_KIND_FILE }
                                    ?.executable ?: false,
                            sha256 = sha,
                            version = version,
                            author_id = me.deviceId,
                            author_name = me.name,
                        ),
                    synced = false,
                )
            )
        )
        return true
    }

    private fun scanDirectory(path: String, disk: String) {
        val existing = engine.index[path]
        if (existing?.entry?.kind == FolderEntryKind.FOLDER_ENTRY_KIND_DIRECTORY) return
        if (mode == FolderMode.FOLDER_MODE_RECEIVE_ONLY) {
            put(
                existing?.copy(local_change = true)
                    ?: LocalFolderEntry(
                        entry =
                            FolderEntry(
                                path = path,
                                kind = FolderEntryKind.FOLDER_ENTRY_KIND_DIRECTORY,
                            ),
                        synced = true,
                        local_change = true,
                        disk_path = diskName(path, disk),
                    )
            )
            return
        }
        put(
            LocalFolderEntry(
                entry =
                    FolderEntry(
                        path = path,
                        kind = FolderEntryKind.FOLDER_ENTRY_KIND_DIRECTORY,
                        version = Versions.bump(existing?.entry?.version.orEmpty(), me.actor),
                        author_id = me.deviceId,
                        author_name = me.name,
                    ),
                synced = false,
                disk_path = diskName(path, disk),
            )
        )
    }

    private fun detectDeletions(seen: Set<String>) {
        val missing =
            engine.index
                .entries()
                .filter { local ->
                    val entry = local.entry!!
                    entry.path !in seen &&
                        entry.kind != FolderEntryKind.FOLDER_ENTRY_KIND_DELETED &&
                        // Never downloaded or evicted: absent on purpose, never a deletion.
                        (entry.kind != FolderEntryKind.FOLDER_ENTRY_KIND_FILE ||
                            FolderIndex.present(local)) &&
                        FolderRules.included(entry.path, definition.rules)
                }
                .toList()
        if (missing.isEmpty()) {
            if (engine.state.held_deletions?.source == LOCAL)
                engine.state = engine.state.copy(held_deletions = null)
            return
        }
        val files = missing.count { it.entry!!.kind == FolderEntryKind.FOLDER_ENTRY_KIND_FILE }
        val total = engine.index.entries().count(FolderIndex::present)
        if (
            !engine.state.deletions_confirmed && FolderGuard.trips(definition.guard, files, total)
        ) {
            engine.state =
                engine.state.copy(
                    held_deletions =
                        HeldFolderDeletions(LOCAL, missing.map { it.entry!! }, files.toLong())
                )
            attention(confirmDeletion(files))
            return
        }
        for (local in missing) {
            val entry = local.entry!!
            when {
                entry.version.isEmpty() -> engine.index.remove(entry.path)
                mode == FolderMode.FOLDER_MODE_RECEIVE_ONLY ->
                    // Not sent; it downloads again on tap or with the next remote change.
                    put(local.copy(evicted = true, local_change = true))
                else ->
                    put(
                        LocalFolderEntry(
                            entry =
                                FolderEntry(
                                    path = entry.path,
                                    kind = FolderEntryKind.FOLDER_ENTRY_KIND_DELETED,
                                    version = Versions.bump(entry.version, me.actor),
                                    author_id = me.deviceId,
                                    author_name = me.name,
                                ),
                            synced = false,
                        )
                    )
            }
        }
        engine.state =
            engine.state.copy(
                deletions_confirmed = false,
                held_deletions = engine.state.held_deletions?.takeIf { it.source != LOCAL },
            )
    }

    // --- Index exchange -------------------------------------------------------------------------

    /**
     * Pages through the home daemon's index from the checkpoint and reconciles every entry. The
     * checkpoint advances only after the page's results and planned transfers are durable. False
     * when the run stopped (deadline or a held deletion).
     */
    private suspend fun exchange(): Boolean {
        while (true) {
            if (expired()) {
                workRemains = true
                return false
            }
            val state = engine.state
            val page =
                remote.index(
                    GetFolderIndexRequest(
                        folder_id = folderId,
                        index_id = state.index_id,
                        after_sequence = state.sequence,
                        page_size = FolderBounds.INDEX_PAGE,
                        member_id = me.deviceId,
                        acknowledged_sequence = state.sequence,
                    )
                )
            val decisions = ArrayList<Pair<FolderEntry, FolderDecision>>()
            for (entry in page.entries) {
                val problem = FolderNames.entryProblem(entry)
                if (problem != null) {
                    problem(entry.path, "Ignored an invalid entry: $problem")
                    continue
                }
                if (!FolderRules.included(entry.path, definition.rules)) continue
                decisions +=
                    entry to FolderReconcile.decide(engine.index[entry.path]?.entry, entry, mode)
            }
            val deletions = decisions.filter { (entry, decision) ->
                decision.action == FolderAction.APPLY &&
                    decision.result?.kind == FolderEntryKind.FOLDER_ENTRY_KIND_DELETED &&
                    engine.index[entry.path]?.let(FolderIndex::present) == true
            }
            val held =
                deletions.isNotEmpty() &&
                    FolderGuard.trips(
                        definition.guard,
                        deletions.size,
                        engine.index.entries().count(FolderIndex::present),
                    )
            val holding = if (held) deletions.mapTo(HashSet()) { it.first.path } else emptySet()
            for ((entry, decision) in decisions) {
                if (entry.path in holding) continue
                record(entry, decision)
            }
            if (held) {
                val previous = engine.state.held_deletions?.takeIf { it.source == REMOTE }
                val entries =
                    previous?.entries.orEmpty() + deletions.mapNotNull { it.second.result }
                engine.state =
                    engine.state.copy(
                        held_deletions = HeldFolderDeletions(REMOTE, entries, entries.size.toLong())
                    )
            }
            engine.index.flush()
            engine.saveJournal()
            engine.state = engine.state.copy(index_id = page.index_id, sequence = page.sequence)
            engine.saveState()
            if (held) {
                attention(confirmDeletion(engine.state.held_deletions!!.entries.size))
                return false
            }
            if (!page.more) return true
        }
    }

    private fun record(remote: FolderEntry, decision: FolderDecision) {
        val local = engine.index[remote.path]
        when (decision.action) {
            FolderAction.OUT_OF_SYNC -> outOfSync += remote.path
            FolderAction.MERGE -> put(local!!.copy(entry = decision.result, synced = true))
            FolderAction.NONE -> {
                local ?: return
                val entry = local.entry!!
                if (decision.conflict) {
                    // This device's version won. Its own version must dominate the remote one,
                    // and the remote content survives as a conflict copy, before it is sent.
                    put(
                        local.copy(
                            entry =
                                entry.copy(version = Versions.merge(entry.version, remote.version)),
                            synced = false,
                        )
                    )
                    if (
                        remote.kind == FolderEntryKind.FOLDER_ENTRY_KIND_FILE &&
                            entry.kind != FolderEntryKind.FOLDER_ENTRY_KIND_DELETED
                    )
                        engine.queue(
                            FolderTransfer(
                                kind = FolderTransferKind.FOLDER_TRANSFER_KIND_CONFLICT_COPY,
                                path = remote.path,
                                remote = remote,
                                conflict_copy =
                                    FolderReconcile.conflictName(
                                        remote.path,
                                        remote.author_name,
                                        remote.modified_nanos,
                                    ),
                            )
                        )
                    conflicts++
                } else if (
                    !local.synced &&
                        Versions.compare(entry.version, remote.version) == Ordering.EQUAL &&
                        FolderReconcile.sameContent(entry, remote)
                ) {
                    // A commit whose answer was lost.
                    put(local.copy(synced = true))
                }
            }
            FolderAction.APPLY -> {
                val result = decision.result!!
                engine.journal.removeAll {
                    it.kind == FolderTransferKind.FOLDER_TRANSFER_KIND_UPLOAD &&
                        it.path == remote.path
                }
                if (decision.conflict) conflicts++
                val present = local != null && FolderIndex.present(local)
                val directory = local?.entry?.kind == FolderEntryKind.FOLDER_ENTRY_KIND_DIRECTORY
                when {
                    result.kind == FolderEntryKind.FOLDER_ENTRY_KIND_DELETED &&
                        !present &&
                        !directory -> put(LocalFolderEntry(entry = result, synced = true))
                    result.kind == FolderEntryKind.FOLDER_ENTRY_KIND_DIRECTORY &&
                        directory &&
                        decision.conflictCopy.isEmpty() ->
                        put(local.copy(entry = result, synced = true, local_change = false))
                    result.kind == FolderEntryKind.FOLDER_ENTRY_KIND_FILE &&
                        present &&
                        !local.local_change &&
                        decision.conflictCopy.isEmpty() &&
                        local.entry!!.sha256 == result.sha256 &&
                        local.entry!!.size == result.size ->
                        put(local.copy(entry = result, synced = true))
                    result.kind == FolderEntryKind.FOLDER_ENTRY_KIND_FILE &&
                        !present &&
                        !directory &&
                        (local?.evicted == true ||
                            !FolderSettings.downloadsAutomatically(autoDownload, result.size)) ->
                        // Listed, not downloaded: it downloads on tap.
                        put(
                            LocalFolderEntry(
                                entry = result,
                                synced = true,
                                evicted = local?.evicted == true,
                                absent_by_policy = local?.evicted != true,
                            )
                        )
                    else ->
                        engine.queue(
                            FolderTransfer(
                                kind = FolderTransferKind.FOLDER_TRANSFER_KIND_APPLY,
                                path = remote.path,
                                remote = result,
                                conflict_copy = decision.conflictCopy,
                            )
                        )
                }
            }
        }
    }

    companion object {
        const val LOCATION_UNAVAILABLE = "Folder location unavailable"
        const val TOO_MANY_FILES = "Too many files for this phone"
        const val LOCAL = "local"
        const val REMOTE = "remote"
        const val MAX_ROUNDS = 4

        fun confirmDeletion(count: Int) =
            "Confirm deletion of $count ${if (count == 1) "file" else "files"}"
    }
}

package com.getdieter.core.folders

import com.getdieter.api.v1.ApplyFolderEntryRequest
import com.getdieter.api.v1.BeginFileUploadRequest
import com.getdieter.api.v1.FileChunk
import com.getdieter.api.v1.FileUpload
import com.getdieter.api.v1.FileUploadRequest
import com.getdieter.api.v1.FolderClientRef
import com.getdieter.api.v1.FolderEntry
import com.getdieter.api.v1.FolderEntryKind
import com.getdieter.api.v1.FolderIndexPage
import com.getdieter.api.v1.FolderMember
import com.getdieter.api.v1.FolderMode
import com.getdieter.api.v1.GetFolderIndexRequest
import com.getdieter.api.v1.ReadFileChunkRequest
import com.getdieter.api.v1.RegisterFolderClientRequest
import com.getdieter.api.v1.TransferPath
import com.getdieter.api.v1.WriteFileChunkRequest
import com.getdieter.core.api.DaemonApi
import com.getdieter.core.v1.FolderTransfer
import com.getdieter.core.v1.FolderTransferKind
import com.getdieter.core.v1.LocalFolderEntry
import com.squareup.wire.GrpcException
import com.squareup.wire.GrpcStatus
import okio.Buffer
import okio.ByteString.Companion.encodeUtf8
import okio.ByteString.Companion.toByteString
import okio.HashingSink
import okio.blackholeSink

/**
 * The home daemon's side of the folder protocol, as a client member uses it (FolderService and the
 * FileService transfer calls whose TransferPath names the folder).
 */
interface FolderRemote {
    val daemonId: String

    suspend fun register(request: RegisterFolderClientRequest): FolderMember

    suspend fun index(request: GetFolderIndexRequest): FolderIndexPage

    suspend fun readChunk(request: ReadFileChunkRequest): FileChunk

    suspend fun beginUpload(request: BeginFileUploadRequest): FileUpload

    suspend fun writeChunk(request: WriteFileChunkRequest): FileUpload

    suspend fun getUpload(id: String): FileUpload

    suspend fun commitUpload(id: String): FileUpload

    suspend fun abortUpload(id: String): FileUpload

    suspend fun apply(request: ApplyFolderEntryRequest): FolderEntry

    suspend fun unregister(request: FolderClientRef)
}

/** [FolderRemote] over a daemon's API; [call] runs one RPC over the machine's data plane. */
class DaemonFolderRemote(
    override val daemonId: String,
    private val call: suspend (suspend (DaemonApi) -> Any) -> Any,
) : FolderRemote {
    @Suppress("UNCHECKED_CAST")
    private suspend fun <T> rpc(block: suspend (DaemonApi) -> T): T = call { block(it) as Any } as T

    override suspend fun register(request: RegisterFolderClientRequest) = rpc {
        it.RegisterFolderClient().execute(request)
    }

    override suspend fun index(request: GetFolderIndexRequest) = rpc {
        it.GetFolderIndex().execute(request)
    }

    override suspend fun readChunk(request: ReadFileChunkRequest) = rpc {
        it.ReadFileChunk().execute(request)
    }

    override suspend fun beginUpload(request: BeginFileUploadRequest) = rpc {
        it.BeginFileUpload().execute(request)
    }

    override suspend fun writeChunk(request: WriteFileChunkRequest) = rpc {
        it.WriteFileChunk().execute(request)
    }

    override suspend fun getUpload(id: String) = rpc {
        it.GetFileUpload().execute(FileUploadRequest(id))
    }

    override suspend fun commitUpload(id: String) = rpc {
        it.CommitFileUpload().execute(FileUploadRequest(id))
    }

    override suspend fun abortUpload(id: String) = rpc {
        it.AbortFileUpload().execute(FileUploadRequest(id))
    }

    override suspend fun apply(request: ApplyFolderEntryRequest) = rpc {
        it.ApplyFolderEntry().execute(request)
    }

    override suspend fun unregister(request: FolderClientRef) {
        rpc { it.UnregisterFolderClient().execute(request) }
    }
}

/** The gRPC status of a daemon's answer, or null for anything else. */
internal fun grpcStatus(error: Throwable): GrpcStatus? = (error as? GrpcException)?.grpcStatus

internal fun sha256Hex(bytes: ByteArray): String = bytes.toByteString().sha256().hex()

/** An incremental SHA-256. */
internal class Sha256 {
    private val sink = HashingSink.sha256(blackholeSink())
    private val buffer = Buffer()

    fun update(bytes: ByteArray) {
        if (bytes.isEmpty()) return
        buffer.write(bytes)
        sink.write(buffer, bytes.size.toLong())
    }

    fun hex(): String = sink.hash.hex()
}

// Transfers of one run, in the order of §3.6: conflict copies the local version needs first, then
// directories, deletions and files by ascending size. Every durable step is journaled, so a run
// that stops at its deadline resumes where it stopped.

/** One unit of work in a run's plan. */
internal class FolderWork(
    val sortKey: FolderEntry,
    val op: FolderTransfer?,
    val local: LocalFolderEntry?,
)

internal fun FolderRun.plan(): List<FolderWork> {
    val ops = engine.journal.toList()
    val copies =
        ops.filter { it.kind == FolderTransferKind.FOLDER_TRANSFER_KIND_CONFLICT_COPY }
            .sortedBy { it.remote?.size ?: 0 }
            .map { FolderWork(it.remote!!, it, null) }
    val applies = ops.filter { it.kind == FolderTransferKind.FOLDER_TRANSFER_KIND_APPLY }
    val applying = applies.mapTo(HashSet()) { it.path }
    val locals =
        if (mode == FolderMode.FOLDER_MODE_RECEIVE_ONLY) emptyList()
        else
            engine.index
                .entries()
                .filter {
                    !it.synced && it.entry!!.path !in applying && it.entry!!.version.isNotEmpty()
                }
                .map { FolderWork(it.entry!!, null, it) }
                .toList()
    val rest =
        (applies.map { FolderWork(it.remote!!, it, null) } + locals).sortedWith { a, b ->
            FolderGuard.ORDER.compare(a.sortKey, b.sortKey)
        }
    return copies + rest
}

/** Runs [plan]; false when the run stopped at its deadline or must pause. */
internal suspend fun FolderRun.transfer(): Boolean {
    for (work in plan()) {
        if (expired()) {
            workRemains = true
            return false
        }
        if (stopped) return false
        val entry = work.sortKey
        val small = decision as? FolderRunDecision.SmallOnly
        val onDemand = work.op?.on_demand == true
        if (
            small != null &&
                !onDemand &&
                entry.kind == FolderEntryKind.FOLDER_ENTRY_KIND_FILE &&
                entry.size > small.maxBytes
        ) {
            workRemains = true
            reason = small.reason
            continue
        }
        try {
            when {
                work.op?.kind == FolderTransferKind.FOLDER_TRANSFER_KIND_CONFLICT_COPY ->
                    copyConflict(work.op)
                work.op != null -> applyRemote(work.op)
                work.local != null -> sendLocal(work.local)
            }
        } catch (changed: FolderChangedException) {
            // Edited while syncing: the next scan sees the change and reconciles again.
            workRemains = true
        } catch (error: Throwable) {
            when (grpcStatus(error)) {
                GrpcStatus.ABORTED -> needIndex = true
                GrpcStatus.FAILED_PRECONDITION -> {
                    reason = error.message?.takeIf { it.isNotBlank() } ?: "The home machine paused"
                    workRemains = true
                    return false
                }
                GrpcStatus.RESOURCE_EXHAUSTED -> {
                    problem(entry.path, error.message ?: "A limit was reached")
                    workRemains = true
                }
                null ->
                    if (error is FolderUnavailableException) {
                        attention(FolderRun.LOCATION_UNAVAILABLE)
                        return false
                    } else throw error
                else -> throw error
            }
        }
    }
    return true
}

private suspend fun FolderRun.applyRemote(op: FolderTransfer) {
    val remote = op.remote!!
    val current = engine.index[op.path]
    val decision = FolderReconcile.decide(current?.entry, remote, mode)
    // A listed file this device does not hold yet: fetch it at the version it has.
    val fetch =
        current != null &&
            current.entry!!.kind == FolderEntryKind.FOLDER_ENTRY_KIND_FILE &&
            remote.kind == FolderEntryKind.FOLDER_ENTRY_KIND_FILE &&
            !FolderIndex.present(current) &&
            Versions.compare(current.entry!!.version, remote.version) == Ordering.EQUAL
    if (decision.action != FolderAction.APPLY && !fetch) {
        if (decision.action == FolderAction.MERGE && current != null)
            put(current.copy(entry = decision.result, synced = true))
        drop(op)
        return
    }
    val result = if (fetch) current.entry!! else decision.result!!
    var copy = decision.conflictCopy.ifEmpty { op.conflict_copy }
    if (copy.isEmpty() && current != null && current.local_change && onDisk(current))
        copy = FolderReconcile.conflictName(op.path, me.name, current.observed_modified_nanos)
    when (result.kind) {
        FolderEntryKind.FOLDER_ENTRY_KIND_FILE -> download(op, current, result, copy)
        FolderEntryKind.FOLDER_ENTRY_KIND_DIRECTORY -> {
            if (current != null && FolderIndex.present(current) && !moveAside(current, copy)) return
            io { fs.mkdir(root, current?.let(FolderIndex::diskPath) ?: op.path) }
            put(
                LocalFolderEntry(
                    entry = result,
                    synced = true,
                    disk_path = current?.disk_path.orEmpty(),
                )
            )
            drop(op)
        }
        else -> deleteLocal(op, current, result)
    }
}

private fun onDisk(local: LocalFolderEntry): Boolean =
    FolderIndex.present(local) || local.entry?.kind == FolderEntryKind.FOLDER_ENTRY_KIND_DIRECTORY

/** The staging file of [path]'s content [sha256], beside the destination. */
internal fun stagingName(path: String, sha256: String): String {
    val parent = FolderNames.parent(path)
    val name =
        FolderBounds.TEMPORARY_PREFIX + "$path\u0000$sha256".encodeUtf8().sha256().hex().take(16)
    return if (parent.isEmpty()) name else "$parent/$name"
}

private suspend fun FolderRun.download(
    start: FolderTransfer,
    current: LocalFolderEntry?,
    result: FolderEntry,
    copy: String,
) {
    var op = start
    if (!fitsStorage(result.size, op.on_demand)) {
        reason = FolderSyncPolicy.STORAGE_FULL
        workRemains = true
        return
    }
    val replacesLocal = current != null && FolderIndex.present(current)
    if (replacesLocal && copy.isNotEmpty()) {
        if (!moveAside(current, copy)) return
    }
    val target = current?.let(FolderIndex::diskPath) ?: result.path
    val staging = op.staging.ifEmpty { stagingName(target, result.sha256) }
    if (op.staging != staging) op = journal(op.copy(staging = staging, offset = 0))
    val chunk = FolderBounds.CHUNK_SIZE.toLong()
    var offset = io { fs.stagingSize(root, staging) }
    offset = if (offset < 0 || offset > result.size) 0 else offset - offset % chunk
    val hash = Sha256()
    var read = 0L
    while (read < offset) {
        val bytes = io { fs.read(root, staging, read, minOf(chunk, offset - read).toInt()) }
        if (bytes.isEmpty()) {
            offset = read
            break
        }
        hash.update(bytes)
        read += bytes.size
    }
    if (result.size == 0L) io { fs.writeStaging(root, staging, 0, ByteArray(0)) }
    while (offset < result.size) {
        if (expired()) {
            journal(op.copy(offset = offset))
            workRemains = true
            return
        }
        val length = minOf(chunk, result.size - offset).toInt()
        val answer =
            remote.readChunk(
                ReadFileChunkRequest(
                    target = TransferPath(folder_id = folderId, path = result.path),
                    revision = result.sha256,
                    offset = offset,
                    length = length,
                )
            )
        val bytes = answer.data_.toByteArray()
        if (bytes.size != length || sha256Hex(bytes) != answer.sha256)
            throw IllegalStateException("A chunk of ${result.path} arrived damaged.")
        io { fs.writeStaging(root, staging, offset, bytes) }
        hash.update(bytes)
        offset += length
        metered(length.toLong())
        op = journal(op.copy(offset = offset))
    }
    if (hash.hex() != result.sha256) {
        io { fs.discardStaging(root, staging) }
        journal(op.copy(offset = 0, staging = "", attempts = op.attempts + 1))
        problem(result.path, "The download did not match its checksum; it will be retried.")
        workRemains = true
        return
    }
    val now = io { fs.stat(root, target) }
    val moved = engine.index[result.path]?.let { !FolderIndex.present(it) } ?: true
    val expected =
        if (moved || current == null) {
            // Nothing may be there unless the scan has seen it.
            if (now != null) throw FolderChangedException()
            null
        } else {
            if (now == null || !sameObserved(now, current)) throw FolderChangedException()
            now
        }
    val published = io {
        fs.publish(root, staging, target, expected, result.modified_nanos, result.executable)
    }
    put(
        LocalFolderEntry(
            entry = result,
            observed_size = published.size,
            observed_modified_nanos = published.modifiedNanos,
            observed_token = published.token,
            synced = true,
            disk_path = if (target == result.path) "" else target,
        )
    )
    drop(op)
    downloaded++
}

/**
 * Moves [current]'s content to [to] before the remote version replaces it, as a new local file;
 * false when the file changed since the scan observed it.
 */
private suspend fun FolderRun.moveAside(current: LocalFolderEntry, to: String): Boolean {
    if (to.isEmpty()) return true
    val disk = FolderIndex.diskPath(current)
    val now = io { fs.stat(root, disk) } ?: return true
    if (!sameObserved(now, current)) throw FolderChangedException()
    var destination = to
    var attempt = 2
    while (engine.index[destination] != null || io { fs.stat(root, destination) } != null) {
        val dot = destination.lastIndexOf('.').takeIf { it > destination.lastIndexOf('/') }
        destination =
            if (dot == null) "$to $attempt"
            else
                to.substring(0, to.lastIndexOf('.')) +
                    " $attempt" +
                    to.substring(to.lastIndexOf('.'))
        if (++attempt > 20) throw FolderChangedException("No free name for a conflict copy.")
    }
    io { fs.move(root, disk, destination, now) }
    val moved = io { fs.stat(root, destination) } ?: throw FolderChangedException()
    val receiveOnly = mode == FolderMode.FOLDER_MODE_RECEIVE_ONLY
    val sha =
        if (current.local_change || current.entry!!.sha256.isEmpty())
            hash(destination, moved) ?: throw FolderChangedException()
        else current.entry!!.sha256
    put(
        LocalFolderEntry(
            entry =
                FolderEntry(
                    path = destination,
                    kind = FolderEntryKind.FOLDER_ENTRY_KIND_FILE,
                    size = moved.size,
                    modified_nanos = moved.modifiedNanos,
                    executable = current.entry!!.executable,
                    sha256 = sha,
                    version =
                        if (receiveOnly) emptyList() else Versions.bump(emptyList(), me.actor),
                    author_id = me.deviceId,
                    author_name = me.name,
                ),
            observed_size = moved.size,
            observed_modified_nanos = moved.modifiedNanos,
            observed_token = moved.token,
            synced = receiveOnly,
            local_change = receiveOnly,
        )
    )
    // The content moved away: the original is not on disk, which is never a deletion.
    put(current.copy(evicted = true, local_change = false))
    engine.index.flush()
    conflicts++
    return true
}

private suspend fun FolderRun.deleteLocal(
    op: FolderTransfer,
    current: LocalFolderEntry?,
    result: FolderEntry,
) {
    val tombstone = LocalFolderEntry(entry = result, synced = true)
    when {
        current == null || !onDisk(current) -> put(tombstone)
        current.entry!!.kind == FolderEntryKind.FOLDER_ENTRY_KIND_FILE -> {
            val disk = FolderIndex.diskPath(current)
            val now = io { fs.stat(root, disk) }
            if (now != null) {
                if (!sameObserved(now, current)) throw FolderChangedException()
                io { fs.delete(root, disk, now) }
                deleted++
            }
            put(tombstone)
        }
        else -> {
            val disk = FolderIndex.diskPath(current)
            val removed = io { fs.stat(root, disk) == null || fs.removeDirectory(root, disk) }
            if (removed) put(tombstone)
            else {
                // Something new is inside: the directory stays, and its version wins.
                val merged = Versions.merge(current.entry!!.version, result.version)
                put(
                    current.copy(
                        entry =
                            current.entry!!.copy(
                                version = Versions.bump(merged, me.actor),
                                author_id = me.deviceId,
                                author_name = me.name,
                            ),
                        synced = mode == FolderMode.FOLDER_MODE_RECEIVE_ONLY,
                    )
                )
            }
        }
    }
    drop(op)
}

/** Fetches the content of a remote version that lost to the local one into its conflict copy. */
private suspend fun FolderRun.copyConflict(op: FolderTransfer) {
    val remote = op.remote!!
    val target = op.conflict_copy
    if (engine.index[target] != null || io { fs.stat(root, target) } != null) {
        drop(op)
        return
    }
    if (!fitsStorage(remote.size, false)) {
        reason = FolderSyncPolicy.STORAGE_FULL
        workRemains = true
        return
    }
    val staging = op.staging.ifEmpty { stagingName(target, remote.sha256) }
    var current = if (op.staging != staging) journal(op.copy(staging = staging, offset = 0)) else op
    val chunk = FolderBounds.CHUNK_SIZE.toLong()
    val hash = Sha256()
    var offset = 0L
    io { fs.writeStaging(root, staging, 0, ByteArray(0)) }
    while (offset < remote.size) {
        if (expired()) {
            workRemains = true
            return
        }
        val length = minOf(chunk, remote.size - offset).toInt()
        val answer =
            try {
                this.remote.readChunk(
                    ReadFileChunkRequest(
                        target = TransferPath(folder_id = folderId, path = remote.path),
                        revision = remote.sha256,
                        offset = offset,
                        length = length,
                    )
                )
            } catch (error: Throwable) {
                if (grpcStatus(error) != GrpcStatus.ABORTED) throw error
                // The daemon replaced that version; its trash keeps it.
                io { fs.discardStaging(root, staging) }
                problem(
                    remote.path,
                    "The other version from ${remote.author_name.ifEmpty { "another device" }} " +
                        "was replaced before it could be copied; the machines' trash keeps it.",
                )
                drop(current)
                return
            }
        val bytes = answer.data_.toByteArray()
        if (bytes.size != length || sha256Hex(bytes) != answer.sha256)
            throw IllegalStateException("A chunk of ${remote.path} arrived damaged.")
        io { fs.writeStaging(root, staging, offset, bytes) }
        hash.update(bytes)
        offset += length
        metered(length.toLong())
        current = journal(current.copy(offset = offset))
    }
    if (hash.hex() != remote.sha256) {
        io { fs.discardStaging(root, staging) }
        throw IllegalStateException(
            "The other version of ${remote.path} did not match its checksum."
        )
    }
    val published = io {
        fs.publish(root, staging, target, null, remote.modified_nanos, remote.executable)
    }
    put(
        LocalFolderEntry(
            entry =
                FolderEntry(
                    path = target,
                    kind = FolderEntryKind.FOLDER_ENTRY_KIND_FILE,
                    size = remote.size,
                    modified_nanos = remote.modified_nanos,
                    executable = remote.executable,
                    sha256 = remote.sha256,
                    version = Versions.bump(emptyList(), me.actor),
                    author_id = me.deviceId,
                    author_name = me.name,
                ),
            observed_size = published.size,
            observed_modified_nanos = published.modifiedNanos,
            observed_token = published.token,
            synced = false,
        )
    )
    drop(current)
    downloaded++
}

private suspend fun FolderRun.sendLocal(local: LocalFolderEntry) {
    val entry = local.entry!!
    if (entry.kind == FolderEntryKind.FOLDER_ENTRY_KIND_FILE) {
        upload(local)
        return
    }
    remote.apply(ApplyFolderEntryRequest(folder_id = folderId, entry = entry.copy(sequence = 0)))
    engine.index[entry.path]?.takeIf { it.entry == entry }?.let { put(it.copy(synced = true)) }
    if (entry.kind == FolderEntryKind.FOLDER_ENTRY_KIND_DELETED) deleted++
}

/** A deterministic operation ID per path and version, so a retry never uploads twice. */
internal fun operationId(folderId: String, entry: FolderEntry): String {
    val version = entry.version.joinToString(",") { "${it.actor}:${it.value_.toULong()}" }
    return "folder-" +
        "$folderId\u0000${entry.path}\u0000${entry.sha256}\u0000$version"
            .encodeUtf8()
            .sha256()
            .hex()
}

private suspend fun FolderRun.upload(local: LocalFolderEntry) {
    val entry = local.entry!!
    if (!FolderIndex.present(local)) return
    if (
        engine.journal.any {
            it.kind == FolderTransferKind.FOLDER_TRANSFER_KIND_CONFLICT_COPY &&
                it.remote?.path == entry.path
        }
    ) {
        workRemains = true
        return
    }
    val disk = FolderIndex.diskPath(local)
    val now = io { fs.stat(root, disk) }
    if (now == null || !sameObserved(now, local)) throw FolderChangedException()
    val id = operationId(folderId, entry)
    val existing =
        engine.journal.firstOrNull {
            it.kind == FolderTransferKind.FOLDER_TRANSFER_KIND_UPLOAD && it.path == entry.path
        }
    var op =
        existing?.takeIf { it.operation_id == id }
            ?: FolderTransfer(
                kind = FolderTransferKind.FOLDER_TRANSFER_KIND_UPLOAD,
                path = entry.path,
                operation_id = id,
                sha256 = entry.sha256,
                version = entry.version,
            )
    if (existing != null && existing !== op) {
        if (existing.upload_id.isNotEmpty()) runCatching { remote.abortUpload(existing.upload_id) }
        drop(existing)
    }
    suspend fun begin(operation: String): FileUpload =
        remote.beginUpload(
            BeginFileUploadRequest(
                target = TransferPath(folder_id = folderId, path = entry.path),
                operation_id = operation,
                expected_revision = "",
                size = entry.size,
                sha256 = entry.sha256,
                modified_nanos = entry.modified_nanos,
                mode = if (entry.executable) 0x1ED else 0x1A4,
                folder_entry = entry.copy(sequence = 0),
            )
        )
    var upload =
        if (op.upload_id.isEmpty()) begin(op.operation_id)
        else
            try {
                remote.getUpload(op.upload_id)
            } catch (error: Throwable) {
                if (grpcStatus(error) != GrpcStatus.NOT_FOUND) throw error
                begin(op.operation_id)
            }
    if (upload.state == UPLOAD_ABORTED) {
        val retry = "${op.operation_id}-${op.attempts + 1}"
        op = op.copy(operation_id = retry, attempts = op.attempts + 1)
        upload = begin(retry)
    }
    op = journal(op.copy(upload_id = upload.id, offset = upload.offset))
    try {
        if (upload.state != UPLOAD_COMMITTED) {
            val chunk = FolderBounds.CHUNK_SIZE.toLong()
            var offset = upload.offset
            while (offset < entry.size) {
                if (expired()) {
                    workRemains = true
                    return
                }
                val length = minOf(chunk, entry.size - offset).toInt()
                val bytes = io { fs.read(root, disk, offset, length) }
                if (bytes.size != length) throw FolderChangedException()
                upload =
                    remote.writeChunk(
                        WriteFileChunkRequest(
                            id = upload.id,
                            offset = offset,
                            data_ = bytes.toByteString(),
                            sha256 = sha256Hex(bytes),
                        )
                    )
                offset = maxOf(upload.offset, offset + length)
                metered(length.toLong())
                op = journal(op.copy(offset = offset))
            }
            val after = io { fs.stat(root, disk) }
            if (after == null || !sameObserved(after, local)) {
                runCatching { remote.abortUpload(upload.id) }
                drop(op)
                throw FolderChangedException()
            }
            remote.commitUpload(upload.id)
        }
    } catch (error: Throwable) {
        when (grpcStatus(error)) {
            // The daemon holds a version this one does not dominate: reconcile first.
            GrpcStatus.ABORTED -> drop(op)
            GrpcStatus.NOT_FOUND -> journal(op.copy(upload_id = "", offset = 0))
            else -> Unit
        }
        throw error
    }
    drop(op)
    val committed = engine.index[entry.path]?.takeIf { it.entry == entry } ?: return
    put(committed.copy(synced = true))
    uploaded++
    if (removeAfterUpload) evict(committed.copy(synced = true))
}

/** Frees a synced file's content; it stays listed and downloads on tap. */
internal suspend fun FolderRun.evict(local: LocalFolderEntry) {
    val disk = FolderIndex.diskPath(local)
    val now = io { fs.stat(root, disk) } ?: return
    if (!sameObserved(now, local)) return
    io { fs.delete(root, disk, now) }
    put(local.copy(evicted = true))
}

internal const val UPLOAD_COMMITTED = "committed"
internal const val UPLOAD_ABORTED = "aborted"

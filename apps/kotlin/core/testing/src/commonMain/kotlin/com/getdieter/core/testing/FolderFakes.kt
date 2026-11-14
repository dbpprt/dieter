package com.getdieter.core.testing

import com.getdieter.api.v1.ApplyFolderEntryRequest
import com.getdieter.api.v1.BeginFileUploadRequest
import com.getdieter.api.v1.FileChunk
import com.getdieter.api.v1.FileUpload
import com.getdieter.api.v1.FolderClientRef
import com.getdieter.api.v1.FolderEntry
import com.getdieter.api.v1.FolderEntryKind
import com.getdieter.api.v1.FolderIndexPage
import com.getdieter.api.v1.FolderMember
import com.getdieter.api.v1.GetFolderIndexRequest
import com.getdieter.api.v1.ReadFileChunkRequest
import com.getdieter.api.v1.RegisterFolderClientRequest
import com.getdieter.api.v1.WriteFileChunkRequest
import com.getdieter.core.folders.DeviceConditions
import com.getdieter.core.folders.FolderChangedException
import com.getdieter.core.folders.FolderConditions
import com.getdieter.core.folders.FolderFileInfo
import com.getdieter.core.folders.FolderFileKind
import com.getdieter.core.folders.FolderFileSystem
import com.getdieter.core.folders.FolderLocation
import com.getdieter.core.folders.FolderRemote
import com.getdieter.core.folders.FolderRoot
import com.getdieter.core.folders.FolderScheduleRequest
import com.getdieter.core.folders.FolderScheduler
import com.getdieter.core.folders.FolderUnavailableException
import com.getdieter.core.folders.Ordering
import com.getdieter.core.folders.Versions
import com.squareup.wire.GrpcException
import com.squareup.wire.GrpcStatus
import okio.ByteString.Companion.toByteString

/**
 * An in-memory folder file system with the guards the platform adapters keep: replacements and
 * deletions check the state the core observed. Tests edit it directly to play the person or another
 * app.
 */
class FakeFolderFileSystem(private val free: Long = 1L shl 40) : FolderFileSystem {
    class Node(
        var directory: Boolean,
        var bytes: ByteArray,
        var modifiedNanos: Long,
        var token: Long,
    )

    private val roots = HashMap<String, HashMap<String, Node>>()
    private val identities = HashMap<String, String>()
    private var tokens = 0L
    var clockNanos = 1_700_000_000_000_000_000L

    /** Location → whether it is reachable; false plays an unmounted or revoked location. */
    val available = HashMap<String, Boolean>()

    fun files(location: String): HashMap<String, Node> = roots.getOrPut(location) { HashMap() }

    private fun tree(root: FolderRoot): HashMap<String, Node> {
        if (available[root.location] == false) throw FolderUnavailableException()
        return files(root.location)
    }

    private fun next(): Long = ++tokens

    private fun tick(): Long {
        clockNanos += 1_000_000_000
        return clockNanos
    }

    /** Writes a file as another app would, creating its parents. */
    fun write(location: String, path: String, bytes: ByteArray, modifiedNanos: Long = tick()) {
        val files = files(location)
        parents(files, path)
        files[path] = Node(false, bytes, modifiedNanos, next())
    }

    fun mkdirs(location: String, path: String) {
        val files = files(location)
        parents(files, path)
        files.getOrPut(path) { Node(true, ByteArray(0), tick(), next()) }
    }

    /** Deletes a file or a whole directory as the person would. */
    fun remove(location: String, path: String) {
        val files = files(location)
        files.keys.filter { it == path || it.startsWith("$path/") }.forEach(files::remove)
    }

    fun read(location: String, path: String): ByteArray? =
        files(location)[path]?.takeIf { !it.directory }?.bytes

    fun exists(location: String, path: String): Boolean = files(location).containsKey(path)

    /** Replaces the root with another directory of the same name. */
    fun replaceRoot(location: String) {
        identities[location] = "root-${next()}"
    }

    private fun parents(files: HashMap<String, Node>, path: String) {
        val parts = path.split('/')
        for (index in 1 until parts.size) {
            val parent = parts.subList(0, index).joinToString("/")
            files.getOrPut(parent) { Node(true, ByteArray(0), clockNanos, next()) }
        }
    }

    private fun info(path: String, node: Node) =
        FolderFileInfo(
            name = path.substringAfterLast('/'),
            kind = if (node.directory) FolderFileKind.DIRECTORY else FolderFileKind.FILE,
            size = if (node.directory) 0 else node.bytes.size.toLong(),
            modifiedNanos = node.modifiedNanos,
            token = node.token.toString(),
        )

    private fun matches(node: Node?, path: String, expected: FolderFileInfo?): Boolean =
        if (expected == null) node == null else node != null && info(path, node) == expected

    override fun defaultLocation(folderId: String, name: String) =
        FolderLocation("private/$folderId", "Private to Dieter")

    override fun prepare(root: FolderRoot): String {
        tree(root)
        return identities.getOrPut(root.location) { "root-${next()}" }
    }

    override fun rootIdentity(root: FolderRoot): String? =
        if (available[root.location] == false) null else identities[root.location]

    override fun list(root: FolderRoot, directory: String): List<FolderFileInfo> {
        val prefix = if (directory.isEmpty()) "" else "$directory/"
        return tree(root)
            .filterKeys {
                it.startsWith(prefix) &&
                    it.length > prefix.length &&
                    '/' !in it.substring(prefix.length)
            }
            .map { (path, node) -> info(path, node) }
            .sortedBy { it.name }
    }

    override fun stat(root: FolderRoot, path: String): FolderFileInfo? =
        tree(root)[path]?.let { info(path, it) }

    override fun read(root: FolderRoot, path: String, offset: Long, length: Int): ByteArray {
        val node = tree(root)[path] ?: return ByteArray(0)
        val start = offset.toInt().coerceAtMost(node.bytes.size)
        return node.bytes.copyOfRange(start, minOf(node.bytes.size, start + length))
    }

    override fun stagingSize(root: FolderRoot, staging: String): Long =
        tree(root)[staging]?.bytes?.size?.toLong() ?: -1

    override fun writeStaging(root: FolderRoot, staging: String, offset: Long, bytes: ByteArray) {
        val files = tree(root)
        parents(files, staging)
        val existing = files[staging]?.bytes ?: ByteArray(0)
        val kept = existing.copyOf(offset.toInt().coerceAtMost(existing.size))
        files[staging] = Node(false, kept + bytes, tick(), next())
    }

    override fun publish(
        root: FolderRoot,
        staging: String,
        path: String,
        expected: FolderFileInfo?,
        modifiedNanos: Long,
        executable: Boolean,
    ): FolderFileInfo {
        val files = tree(root)
        if (!matches(files[path], path, expected)) throw FolderChangedException()
        val node = files.remove(staging) ?: throw FolderChangedException("staging is gone")
        parents(files, path)
        files[path] = Node(false, node.bytes, modifiedNanos, next())
        return info(path, files.getValue(path))
    }

    override fun discardStaging(root: FolderRoot, staging: String) {
        tree(root).remove(staging)
    }

    override fun delete(root: FolderRoot, path: String, expected: FolderFileInfo) {
        val files = tree(root)
        if (!matches(files[path], path, expected)) throw FolderChangedException()
        files.remove(path)
    }

    override fun mkdir(root: FolderRoot, path: String) {
        val files = tree(root)
        parents(files, path)
        files.getOrPut(path) { Node(true, ByteArray(0), tick(), next()) }
    }

    override fun removeDirectory(root: FolderRoot, path: String): Boolean {
        val files = tree(root)
        if (files.keys.any { it.startsWith("$path/") }) return false
        files.remove(path)
        return true
    }

    override fun move(root: FolderRoot, from: String, to: String, expected: FolderFileInfo) {
        val files = tree(root)
        if (!matches(files[from], from, expected) || files.containsKey(to))
            throw FolderChangedException()
        parents(files, to)
        files[to] = files.remove(from)!!.also { it.token = next() }
    }

    override fun freeBytes(root: FolderRoot): Long = free

    override fun deleteAll(root: FolderRoot) {
        tree(root).clear()
    }
}

/** Conditions tests set by hand. */
class FakeDeviceConditions(var conditions: FolderConditions = FolderConditions()) :
    DeviceConditions {
    override fun current(): FolderConditions = conditions
}

/** Records what the core asked the platform to schedule. */
class FakeFolderScheduler : FolderScheduler {
    var scheduled: FolderScheduleRequest? = null
    var longRuns = 0
    var cancelled = 0

    override fun schedule(request: FolderScheduleRequest) {
        scheduled = request
    }

    override fun requestLongRun(userInitiated: Boolean) {
        longRuns++
    }

    override fun cancel() {
        scheduled = null
        cancelled++
    }
}

/**
 * A daemon member's side of the folder protocol in memory: an index with sequences, content by
 * SHA-256, idempotent upload sessions and the dominance checks the daemon makes. [beforeCall] runs
 * before every call, e.g. to advance a test clock or fail a call.
 */
class FakeFolderDaemon(override val daemonId: String = "d_home", val name: String = "Studio") :
    FolderRemote {
    private class Upload(
        val id: String,
        val request: BeginFileUploadRequest,
        var data: ByteArray = ByteArray(0),
        var state: String = "uploading",
    )

    var indexId = "index-1"
    private var sequence = 0L
    val entries = LinkedHashMap<String, FolderEntry>()
    private val contents = HashMap<String, ByteArray>()
    private val uploads = LinkedHashMap<String, Upload>()
    val registered = LinkedHashMap<String, RegisterFolderClientRequest>()
    val acknowledged = HashMap<String, Long>()
    val actor: String = Versions.actorOf(daemonId)
    val calls = ArrayList<String>()
    var beforeCall: (String) -> Unit = {}
    var modifiedNanos = 1_800_000_000_000_000_000L

    private fun call(name: String) {
        calls += name
        beforeCall(name)
    }

    private fun aborted(message: String): Nothing = throw GrpcException(GrpcStatus.ABORTED, message)

    private fun record(entry: FolderEntry): FolderEntry {
        val recorded = entry.copy(sequence = ++sequence)
        entries[entry.path] = recorded
        return recorded
    }

    fun content(path: String): ByteArray? =
        entries[path]
            ?.takeIf { it.kind == FolderEntryKind.FOLDER_ENTRY_KIND_FILE }
            ?.let {
                contents[it.sha256]
            }

    /** A change made on the daemon (by an agent, or another member it synced with). */
    fun put(path: String, bytes: ByteArray, author: String = name): FolderEntry {
        val sha = bytes.toByteString().sha256().hex()
        contents[sha] = bytes
        modifiedNanos += 1_000_000_000
        return record(
            FolderEntry(
                path = path,
                kind = FolderEntryKind.FOLDER_ENTRY_KIND_FILE,
                size = bytes.size.toLong(),
                modified_nanos = modifiedNanos,
                sha256 = sha,
                version = Versions.bump(entries[path]?.version.orEmpty(), actor),
                author_id = daemonId,
                author_name = author,
            )
        )
    }

    fun mkdir(path: String): FolderEntry =
        record(
            FolderEntry(
                path = path,
                kind = FolderEntryKind.FOLDER_ENTRY_KIND_DIRECTORY,
                version = Versions.bump(entries[path]?.version.orEmpty(), actor),
                author_id = daemonId,
                author_name = name,
            )
        )

    fun delete(path: String): FolderEntry =
        record(
            FolderEntry(
                path = path,
                kind = FolderEntryKind.FOLDER_ENTRY_KIND_DELETED,
                version = Versions.bump(entries[path]?.version.orEmpty(), actor),
                author_id = daemonId,
                author_name = name,
            )
        )

    /** Live (not deleted) files and directories by path. */
    fun live(): Map<String, FolderEntry> = entries.filterValues {
        it.kind != FolderEntryKind.FOLDER_ENTRY_KIND_DELETED
    }

    override suspend fun register(request: RegisterFolderClientRequest): FolderMember {
        call("register")
        registered[request.device_id] = request
        return FolderMember(folder_id = request.folder_id, member_id = request.device_id)
    }

    override suspend fun unregister(request: FolderClientRef) {
        call("unregister")
        registered.remove(request.device_id)
    }

    override suspend fun index(request: GetFolderIndexRequest): FolderIndexPage {
        call("index")
        acknowledged[request.member_id] = request.acknowledged_sequence
        val reset = request.index_id.isNotEmpty() && request.index_id != indexId
        val after = if (reset || request.index_id != indexId) 0 else request.after_sequence
        val size = request.page_size.takeIf { it in 1..512 } ?: 512
        val newer = entries.values.filter { it.sequence > after }.sortedBy { it.sequence }
        val page = newer.take(size)
        return FolderIndexPage(
            index_id = indexId,
            reset = reset,
            entries = page,
            sequence = page.lastOrNull()?.sequence ?: after,
            head_sequence = sequence,
            more = newer.size > size,
        )
    }

    override suspend fun readChunk(request: ReadFileChunkRequest): FileChunk {
        call("read:${request.offset}")
        val entry = entries[request.target!!.path]
        if (entry == null || entry.sha256 != request.revision) aborted("the file changed")
        val bytes = contents.getValue(entry.sha256)
        val start = request.offset.toInt()
        val chunk = bytes.copyOfRange(start, minOf(bytes.size, start + request.length))
        return FileChunk(chunk.toByteString(), chunk.toByteString().sha256().hex())
    }

    private fun view(upload: Upload) =
        FileUpload(
            id = upload.id,
            offset = upload.data.size.toLong(),
            size = upload.request.size,
            state = upload.state,
        )

    override suspend fun beginUpload(request: BeginFileUploadRequest): FileUpload {
        call("begin")
        val entry =
            request.folder_entry ?: throw GrpcException(GrpcStatus.INVALID_ARGUMENT, "folder_entry")
        val current = entries[entry.path]
        if (current != null && Versions.compare(entry.version, current.version) != Ordering.AFTER)
            aborted("the version does not dominate")
        uploads[request.operation_id]?.let {
            return view(it)
        }
        val upload = Upload("u${uploads.size + 1}", request)
        uploads[request.operation_id] = upload
        return view(upload)
    }

    private fun upload(id: String): Upload =
        uploads.values.firstOrNull { it.id == id }
            ?: throw GrpcException(GrpcStatus.NOT_FOUND, "upload expired")

    override suspend fun writeChunk(request: WriteFileChunkRequest): FileUpload {
        call("write:${request.offset}")
        val upload = upload(request.id)
        val bytes = request.data_.toByteArray()
        check(request.sha256 == bytes.toByteString().sha256().hex()) { "chunk checksum" }
        check(request.offset % (1 shl 20) == 0L) { "chunk alignment" }
        if (request.offset == upload.data.size.toLong()) upload.data += bytes
        return view(upload)
    }

    override suspend fun getUpload(id: String): FileUpload {
        call("get")
        return view(upload(id))
    }

    override suspend fun commitUpload(id: String): FileUpload {
        call("commit")
        val upload = upload(id)
        if (upload.state == "committed") return view(upload)
        val entry = upload.request.folder_entry!!
        val current = entries[entry.path]
        if (current != null && Versions.compare(entry.version, current.version) != Ordering.AFTER)
            aborted("the version does not dominate")
        check(upload.data.size.toLong() == upload.request.size) { "incomplete upload" }
        check(upload.data.toByteString().sha256().hex() == upload.request.sha256) { "checksum" }
        contents[entry.sha256] = upload.data
        record(entry)
        upload.state = "committed"
        return view(upload)
    }

    override suspend fun abortUpload(id: String): FileUpload {
        call("abort")
        val upload = upload(id)
        upload.state = "aborted"
        return view(upload)
    }

    override suspend fun apply(request: ApplyFolderEntryRequest): FolderEntry {
        call("apply")
        val entry = request.entry!!
        val current = entries[entry.path]
        if (current != null && Versions.compare(entry.version, current.version) != Ordering.AFTER)
            aborted("the version does not dominate")
        return record(entry)
    }
}

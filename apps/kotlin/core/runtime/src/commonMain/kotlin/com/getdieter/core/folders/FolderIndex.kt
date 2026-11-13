package com.getdieter.core.folders

import com.getdieter.api.v1.FolderEntryKind
import com.getdieter.core.storage.CoreStorage
import com.getdieter.core.v1.FolderIndexShard
import com.getdieter.core.v1.LocalFolderEntry
import okio.ByteString.Companion.encodeUtf8

/** A folder on this phone already holds [FolderBounds.MAX_PHONE_ENTRIES] entries. */
class FolderIndexFullException : Exception("Too many files for this phone")

/**
 * One folder's index on this device: 256 Wire shards in [storage], chosen by the first byte of the
 * SHA-256 of each path, so a change rewrites a few KiB rather than the whole index. Each shard is
 * written atomically ([CoreStorage.write]); [flush] writes only shards that changed. Bounded to
 * [limit] entries. Not thread-safe: one folder engine owns it.
 */
class FolderIndex(
    private val storage: CoreStorage,
    private val limit: Int = FolderBounds.MAX_PHONE_ENTRIES,
) {
    private val shards = arrayOfNulls<LinkedHashMap<String, LocalFolderEntry>>(SHARDS)
    private val dirty = BooleanArray(SHARDS)
    private var count = -1

    val size: Int
        get() {
            loadAll()
            return count
        }

    operator fun get(path: String): LocalFolderEntry? = shard(shardOf(path))[path]

    /** Adds or replaces [entry]; a new path beyond the bound throws [FolderIndexFullException]. */
    fun put(entry: LocalFolderEntry) {
        val path = checkNotNull(entry.entry).path
        val index = shardOf(path)
        val shard = shard(index)
        if (path !in shard) {
            loadAll()
            if (count >= limit) throw FolderIndexFullException()
            count++
        }
        shard[path] = entry
        dirty[index] = true
    }

    fun remove(path: String) {
        val index = shardOf(path)
        if (shard(index).remove(path) != null) {
            dirty[index] = true
            if (count > 0) count--
        }
    }

    /** Every entry, in no particular order. */
    fun entries(): Sequence<LocalFolderEntry> {
        loadAll()
        return shards.asSequence().flatMap { it!!.values.asSequence() }
    }

    /** Writes every shard that changed since the last flush; returns how many were written. */
    fun flush(): Int {
        var written = 0
        for (index in 0 until SHARDS) {
            if (!dirty[index]) continue
            val entries = shards[index]!!.values.sortedBy { it.entry!!.path }
            val name = shardName(index)
            if (entries.isEmpty()) storage.delete(name)
            else storage.write(name, FolderIndexShard.ADAPTER.encode(FolderIndexShard(entries)))
            dirty[index] = false
            written++
        }
        return written
    }

    /** Drops every entry and shard file. */
    fun clear() {
        for (index in 0 until SHARDS) {
            storage.delete(shardName(index))
            shards[index] = LinkedHashMap()
            dirty[index] = false
        }
        count = 0
    }

    /** Loads every shard: a cold start reads at most 256 small files. */
    fun loadAll() {
        if (count >= 0) return
        var total = 0
        for (index in 0 until SHARDS) total += shard(index).size
        count = total
    }

    private fun shard(index: Int): LinkedHashMap<String, LocalFolderEntry> =
        shards[index]
            ?: LinkedHashMap<String, LocalFolderEntry>().also { map ->
                storage
                    .read(shardName(index))
                    ?.let { runCatching { FolderIndexShard.ADAPTER.decode(it) }.getOrNull() }
                    ?.entries
                    ?.forEach { entry -> entry.entry?.let { map[it.path] = entry } }
                shards[index] = map
            }

    companion object {
        const val SHARDS = 256

        fun shardOf(path: String): Int = path.encodeUtf8().sha256()[0].toInt() and 0xff

        fun shardName(index: Int): String = "index-" + index.toString(16).padStart(2, '0')

        /** The file's content is on this device. */
        fun present(local: LocalFolderEntry): Boolean =
            local.entry?.kind == FolderEntryKind.FOLDER_ENTRY_KIND_FILE &&
                !local.absent_by_policy &&
                !local.evicted

        /** Where the file is on disk: its own name when the platform stores another form. */
        fun diskPath(local: LocalFolderEntry): String =
            local.disk_path.ifEmpty { local.entry!!.path }
    }
}

package com.getdieter.core.mail

import com.getdieter.core.runtime.CoreLogger
import com.getdieter.core.storage.CoreStorage
import com.getdieter.core.v1.MailBodyEntry
import com.getdieter.core.v1.MailBodyIndex
import okio.ByteString.Companion.encodeUtf8

/**
 * Mail bodies kept on this device, so a message read once (or fetched ahead) opens offline. Keyed
 * by machine, message and body digest: a header whose digest changed misses, and its stale body is
 * replaced. Least recently used bodies go first once the cache holds more than [maxBytes]. Each
 * body is a file of its own beside one index. Confined to the core dispatcher.
 */
class MailBodies(
    private val storage: CoreStorage,
    private val logger: CoreLogger,
    private val maxBytes: Long = MAX_BYTES,
) {
    /** Least recently used first. */
    private val entries = ArrayList<MailBodyEntry>()

    /** The bodies read lately, so a slice update never rereads a file. */
    private val recent = LinkedHashMap<String, String>()

    init {
        val index = runCatching {
            storage.read(INDEX)?.let(MailBodyIndex.ADAPTER::decode)
        }
            .onFailure { logger.warn(TAG, "discarding an unreadable mail body index", it) }
            .getOrNull()
        val files = storage.names().toSet()
        index?.entries?.filter { it.name in files }?.let(entries::addAll)
        // Bodies the index lost are of no use.
        val indexed = entries.mapTo(HashSet()) { it.name }
        for (name in files) if (name != INDEX && name !in indexed) storage.delete(name)
    }

    /** Bytes the cached bodies hold. */
    val bytes: Long
        get() = entries.sumOf { it.bytes }

    fun contains(daemonId: String, id: String, digest: String): Boolean = entries.any {
        it.daemon_id == daemonId && it.id == id && it.body_digest == digest
    }

    /** The body of [daemonId]'s message [id] with [digest], marking it recently used. */
    fun get(daemonId: String, id: String, digest: String): String? {
        val index = entries.indexOfFirst {
            it.daemon_id == daemonId && it.id == id && it.body_digest == digest
        }
        if (index < 0) return null
        val entry = entries[index]
        val body =
            recent.remove(entry.name)
                ?: runCatching { storage.read(entry.name)?.decodeToString() }.getOrNull()
                ?: run {
                    entries.removeAt(index)
                    save()
                    return null
                }
        remember(entry.name, body)
        if (index != entries.lastIndex) {
            entries.removeAt(index)
            entries += entry
            save()
        }
        return body
    }

    /** Keeps [body] as [daemonId]'s message [id] with [digest], replacing an older body of it. */
    fun put(daemonId: String, id: String, digest: String, body: String) {
        val bytes = body.encodeToByteArray()
        if (bytes.size > maxBytes) return
        val file = fileName(daemonId, id)
        entries.removeAll { it.name == file }
        try {
            storage.write(file, bytes)
        } catch (error: Throwable) {
            logger.warn(TAG, "could not keep the body of $id", error)
            save()
            return
        }
        entries += MailBodyEntry(daemonId, id, digest, bytes.size.toLong(), file)
        remember(file, body)
        while (bytes() > maxBytes && entries.size > 1) {
            val evicted = entries.removeAt(0)
            recent.remove(evicted.name)
            storage.delete(evicted.name)
        }
        save()
    }

    /** Forgets every body, e.g. when the account is reset. */
    fun clear() {
        entries.clear()
        recent.clear()
        storage.clear()
    }

    private fun bytes(): Long = entries.sumOf { it.bytes }

    private fun remember(file: String, body: String) {
        recent.remove(file)
        recent[file] = body
        while (recent.size > RECENT) recent.remove(recent.keys.first())
    }

    private fun save() {
        runCatching {
            storage.write(INDEX, MailBodyIndex.ADAPTER.encode(MailBodyIndex(entries.toList())))
        }
            .onFailure { logger.warn(TAG, "could not save the mail body index", it) }
    }

    companion object {
        const val MAX_BYTES = 64L * 1024 * 1024
        private const val INDEX = "index.pb"
        private const val RECENT = 8
        private const val TAG = "MailBodies"

        private fun fileName(daemonId: String, id: String): String =
            "${"$daemonId\u0000$id".encodeUtf8().sha256().hex().take(32)}.md"
    }
}

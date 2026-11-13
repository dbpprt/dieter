package com.getdieter.android.folders

import android.content.ContentResolver
import android.content.Context
import android.net.Uri
import android.provider.DocumentsContract
import android.provider.DocumentsContract.Document
import com.getdieter.core.folders.FolderChangedException
import com.getdieter.core.folders.FolderFileInfo
import com.getdieter.core.folders.FolderFileKind
import com.getdieter.core.folders.FolderFileSystem
import com.getdieter.core.folders.FolderLocation
import com.getdieter.core.folders.FolderRoot
import com.getdieter.core.folders.FolderUnavailableException
import com.getdieter.mobile.platform.AndroidFolderLocations
import java.io.FileInputStream
import java.io.FileNotFoundException
import java.io.FileOutputStream
import java.io.IOException
import java.util.concurrent.ConcurrentHashMap

/**
 * A folder in a document tree the person picked (`ACTION_OPEN_DOCUMENT_TREE`, permission persisted
 * with `takePersistableUriPermission`), through `DocumentsContract`: children come from one
 * projection query per directory, and paths resolve to document IDs through a cache that a miss
 * refreshes.
 *
 * SAF has no atomic replace. [publish] therefore writes the content to a `.dieter-transfer-*`
 * document first, checks that the target still has the size and last-modified time the core
 * observed (or is still missing), deletes it and renames the transfer document to its name. In the
 * short window between that delete and the rename the target is missing; a crash there leaves the
 * transfer document (which scans skip) and the next scan sees the target missing. Documents cannot
 * take a modification time or an executable bit, so a published file keeps the provider's.
 *
 * A revoked permission or a vanished tree is [FolderUnavailableException]: the core pauses the
 * folder and never turns that into deletions.
 */
class SafFolderFileSystem(private val context: Context) : FolderFileSystem {
    private val resolver: ContentResolver
        get() = context.contentResolver

    /** Document IDs by tree and path. */
    private val ids = ConcurrentHashMap<String, String>()

    override fun defaultLocation(folderId: String, name: String) =
        FolderLocation(AndroidFolderLocations.privateLocation(folderId), "Private to Dieter")

    private fun tree(root: FolderRoot): Uri = Uri.parse(root.location)

    /** The person still lets Dieter read and write the tree. */
    private fun permitted(tree: Uri): Boolean =
        resolver.persistedUriPermissions.any {
            it.uri == tree && it.isReadPermission && it.isWritePermission
        }

    private inline fun <T> guarded(block: () -> T): T =
        try {
            block()
        } catch (denied: SecurityException) {
            throw FolderUnavailableException("Dieter lost access to the folder. Choose it again.")
        }

    private fun key(tree: Uri, path: String) = "$tree\u0000$path"

    /** The document ID of [path] (the tree's root when empty), or null when it is missing. */
    private fun id(tree: Uri, path: String): String? {
        if (path.isEmpty()) return DocumentsContract.getTreeDocumentId(tree)
        ids[key(tree, path)]?.let { cached ->
            // A cached ID may name a document that was renamed or replaced; confirm its name.
            if (
                query(DocumentsContract.buildDocumentUriUsingTree(tree, cached))?.name ==
                    path.substringAfterLast('/')
            )
                return cached
            ids.remove(key(tree, path))
        }
        val parent = id(tree, path.substringBeforeLast('/', "")) ?: return null
        val found = children(tree, parent).firstOrNull { it.name == path.substringAfterLast('/') }
        return found?.id?.also { ids[key(tree, path)] = it }
    }

    private class Row(
        val id: String,
        val name: String,
        val mime: String,
        val size: Long,
        val modified: Long,
    ) {
        val directory: Boolean
            get() = mime == Document.MIME_TYPE_DIR

        fun info() =
            FolderFileInfo(
                name = name,
                kind = if (directory) FolderFileKind.DIRECTORY else FolderFileKind.FILE,
                size = if (directory) 0 else size,
                modifiedNanos = modified * 1_000_000,
                token = "$id:$modified:$size",
            )
    }

    private val projection =
        arrayOf(
            Document.COLUMN_DOCUMENT_ID,
            Document.COLUMN_DISPLAY_NAME,
            Document.COLUMN_MIME_TYPE,
            Document.COLUMN_SIZE,
            Document.COLUMN_LAST_MODIFIED,
        )

    private fun row(cursor: android.database.Cursor) =
        Row(
            id = cursor.getString(0),
            name = cursor.getString(1).orEmpty(),
            mime = cursor.getString(2).orEmpty(),
            size = if (cursor.isNull(3)) 0 else cursor.getLong(3),
            modified = if (cursor.isNull(4)) 0 else cursor.getLong(4),
        )

    private fun query(document: Uri): Row? =
        try {
            resolver.query(document, projection, null, null, null)?.use {
                if (it.moveToFirst()) row(it) else null
            }
        } catch (missing: FileNotFoundException) {
            null
        } catch (missing: IllegalArgumentException) {
            null
        }

    private fun children(tree: Uri, parent: String): List<Row> =
        resolver
            .query(
                DocumentsContract.buildChildDocumentsUriUsingTree(tree, parent),
                projection,
                null,
                null,
                null,
            )
            ?.use { cursor ->
                buildList {
                    while (cursor.moveToNext()) add(row(cursor))
                }
            } ?: throw IOException("The folder could not be listed.")

    private fun document(tree: Uri, path: String): Uri? =
        id(tree, path)?.let { DocumentsContract.buildDocumentUriUsingTree(tree, it) }

    private fun matches(now: FolderFileInfo?, expected: FolderFileInfo?): Boolean =
        if (expected == null) now == null
        else
            now != null &&
                now.kind == expected.kind &&
                now.size == expected.size &&
                now.modifiedNanos == expected.modifiedNanos &&
                now.token == expected.token

    override fun prepare(root: FolderRoot): String = guarded {
        rootIdentity(root) ?: throw FolderUnavailableException()
    }

    override fun rootIdentity(root: FolderRoot): String? = guarded {
        val tree = tree(root)
        if (!permitted(tree)) return null
        val id =
            runCatching { DocumentsContract.getTreeDocumentId(tree) }.getOrNull() ?: return null
        val row = query(DocumentsContract.buildDocumentUriUsingTree(tree, id)) ?: return null
        if (!row.directory) return null
        "tree:${tree.authority}:$id"
    }

    private fun usable(root: FolderRoot): Uri {
        val tree = tree(root)
        if (!permitted(tree))
            throw FolderUnavailableException("Dieter lost access to the folder. Choose it again.")
        return tree
    }

    override fun list(root: FolderRoot, directory: String): List<FolderFileInfo> = guarded {
        val tree = usable(root)
        val parent =
            id(tree, directory)
                ?: if (directory.isEmpty()) throw FolderUnavailableException()
                else throw IOException("$directory is gone.")
        children(tree, parent).map { row ->
            ids[key(tree, if (directory.isEmpty()) row.name else "$directory/${row.name}")] = row.id
            row.info()
        }
    }

    override fun stat(root: FolderRoot, path: String): FolderFileInfo? = guarded {
        val tree = usable(root)
        val id = id(tree, path) ?: return null
        val row = query(DocumentsContract.buildDocumentUriUsingTree(tree, id)) ?: return null
        row.info()
    }

    override fun read(root: FolderRoot, path: String, offset: Long, length: Int): ByteArray =
        guarded {
            val tree = usable(root)
            val document = document(tree, path) ?: throw FolderChangedException("$path is gone.")
            resolver.openFileDescriptor(document, "r").use { descriptor ->
                FileInputStream(descriptor!!.fileDescriptor).channel.use { channel ->
                    if (offset >= channel.size()) return ByteArray(0)
                    val buffer =
                        java.nio.ByteBuffer.allocate(
                            minOf(length.toLong(), channel.size() - offset).toInt()
                        )
                    var position = offset
                    while (buffer.hasRemaining()) {
                        val read = channel.read(buffer, position)
                        if (read < 0) break
                        position += read
                    }
                    buffer.array().copyOf(buffer.position())
                }
            }
        }

    override fun stagingSize(root: FolderRoot, staging: String): Long = guarded {
        val tree = usable(root)
        val row = document(tree, staging)?.let(::query) ?: return -1
        row.size
    }

    override fun writeStaging(root: FolderRoot, staging: String, offset: Long, bytes: ByteArray) =
        guarded {
            val tree = usable(root)
            val existing = document(tree, staging)
            val document =
                existing
                    ?: run {
                        val parentPath = staging.substringBeforeLast('/', "")
                        mkdir(root, parentPath)
                        val parent =
                            document(tree, parentPath) ?: throw IOException("$parentPath is gone.")
                        DocumentsContract.createDocument(
                            resolver,
                            parent,
                            "application/octet-stream",
                            staging.substringAfterLast('/'),
                        ) ?: throw IOException("The download could not be started here.")
                    }
            resolver.openFileDescriptor(document, "rw").use { descriptor ->
                FileOutputStream(descriptor!!.fileDescriptor).channel.use { channel ->
                    channel.truncate(offset)
                    var position = offset
                    val buffer = java.nio.ByteBuffer.wrap(bytes)
                    while (buffer.hasRemaining()) position += channel.write(buffer, position)
                }
            }
        }

    override fun publish(
        root: FolderRoot,
        staging: String,
        path: String,
        expected: FolderFileInfo?,
        modifiedNanos: Long,
        executable: Boolean,
    ): FolderFileInfo = guarded {
        val tree = usable(root)
        if (staging.substringBeforeLast('/', "") != path.substringBeforeLast('/', ""))
            throw IOException("A download publishes beside its target.")
        val source =
            document(tree, staging)
                ?: throw FolderChangedException("The download's partial file is gone.")
        val name = path.substringAfterLast('/')
        val target = id(tree, path)
        val now =
            target?.let { query(DocumentsContract.buildDocumentUriUsingTree(tree, it)) }?.info()
        if (!matches(now, expected)) throw FolderChangedException()
        if (target != null) {
            // The short non-atomic window: the target is gone until the rename below.
            DocumentsContract.deleteDocument(
                resolver,
                DocumentsContract.buildDocumentUriUsingTree(tree, target),
            )
            ids.remove(key(tree, path))
        }
        val renamed =
            DocumentsContract.renameDocument(resolver, source, name)
                ?: throw IOException("$path could not be written.")
        ids.remove(key(tree, staging))
        val row = query(renamed) ?: throw FolderChangedException()
        if (row.name != name) {
            // Something took the name meanwhile and the provider chose another; undo.
            DocumentsContract.renameDocument(resolver, renamed, staging.substringAfterLast('/'))
            throw FolderChangedException()
        }
        ids[key(tree, path)] = row.id
        row.info()
    }

    override fun discardStaging(root: FolderRoot, staging: String) {
        runCatching {
            guarded {
                val tree = usable(root)
                document(tree, staging)?.let { DocumentsContract.deleteDocument(resolver, it) }
                ids.remove(key(tree, staging))
            }
        }
    }

    override fun delete(root: FolderRoot, path: String, expected: FolderFileInfo) = guarded {
        val tree = usable(root)
        val document = document(tree, path) ?: throw FolderChangedException()
        if (!matches(query(document)?.info(), expected)) throw FolderChangedException()
        if (!DocumentsContract.deleteDocument(resolver, document))
            throw IOException("$path could not be deleted.")
        ids.remove(key(tree, path))
        Unit
    }

    override fun mkdir(root: FolderRoot, path: String) = guarded {
        if (path.isEmpty()) return@guarded
        val tree = usable(root)
        var parent = id(tree, "") ?: throw FolderUnavailableException()
        var walked = ""
        for (part in path.split('/')) {
            walked = if (walked.isEmpty()) part else "$walked/$part"
            val existing = id(tree, walked)
            parent =
                if (existing != null) existing
                else {
                    val created =
                        DocumentsContract.createDocument(
                            resolver,
                            DocumentsContract.buildDocumentUriUsingTree(tree, parent),
                            Document.MIME_TYPE_DIR,
                            part,
                        ) ?: throw IOException("$walked could not be created.")
                    DocumentsContract.getDocumentId(created).also { ids[key(tree, walked)] = it }
                }
        }
    }

    override fun removeDirectory(root: FolderRoot, path: String): Boolean = guarded {
        val tree = usable(root)
        val id = id(tree, path) ?: return@guarded true
        if (children(tree, id).isNotEmpty()) return@guarded false
        DocumentsContract.deleteDocument(
                resolver,
                DocumentsContract.buildDocumentUriUsingTree(tree, id),
            )
            .also { ids.remove(key(tree, path)) }
    }

    override fun move(root: FolderRoot, from: String, to: String, expected: FolderFileInfo) =
        guarded {
            val tree = usable(root)
            val source = document(tree, from) ?: throw FolderChangedException()
            if (!matches(query(source)?.info(), expected)) throw FolderChangedException()
            if (id(tree, to) != null) throw FolderChangedException()
            val fromParent = from.substringBeforeLast('/', "")
            val toParent = to.substringBeforeLast('/', "")
            var moved = source
            if (fromParent != toParent) {
                mkdir(root, toParent)
                moved =
                    DocumentsContract.moveDocument(
                        resolver,
                        source,
                        document(tree, fromParent) ?: throw FolderChangedException(),
                        document(tree, toParent) ?: throw FolderChangedException(),
                    ) ?: throw IOException("$from could not be moved.")
            }
            val name = to.substringAfterLast('/')
            if (query(moved)?.name != name)
                DocumentsContract.renameDocument(resolver, moved, name)
                    ?: throw IOException("$from could not be renamed.")
            ids.remove(key(tree, from))
            Unit
        }

    override fun freeBytes(root: FolderRoot): Long = guarded {
        val tree = tree(root)
        val volume = runCatching {
            DocumentsContract.getTreeDocumentId(tree)
        }
            .getOrNull()
            ?.substringBefore(':')
        val roots = DocumentsContract.buildRootsUri(tree.authority ?: return@guarded fallbackFree())
        resolver
            .query(
                roots,
                arrayOf(
                    DocumentsContract.Root.COLUMN_ROOT_ID,
                    DocumentsContract.Root.COLUMN_AVAILABLE_BYTES,
                ),
                null,
                null,
                null,
            )
            ?.use { cursor ->
                var first = -1L
                while (cursor.moveToNext()) {
                    if (cursor.isNull(1)) continue
                    val available = cursor.getLong(1)
                    if (cursor.getString(0) == volume) return@guarded available
                    if (first < 0) first = available
                }
                first.takeIf { it >= 0 }
            } ?: fallbackFree()
    }

    private fun fallbackFree(): Long = android.os.Environment.getDataDirectory().usableSpace

    override fun deleteAll(root: FolderRoot) {
        // The tree belongs to the person: only Dieter's copy inside it goes, never the folder.
        runCatching {
            guarded {
                val tree = usable(root)
                val id = id(tree, "") ?: return@guarded
                for (child in children(tree, id)) DocumentsContract.deleteDocument(
                    resolver,
                    DocumentsContract.buildDocumentUriUsingTree(tree, child.id),
                )
                ids.keys.removeIf { it.startsWith("$tree\u0000") }
            }
        }
    }
}

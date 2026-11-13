package com.getdieter.mobile.platform

import android.content.Context
import android.net.Uri
import android.provider.DocumentsContract
import java.io.File

/**
 * Where synced folders live on Android, as the core's opaque locations name them: a document tree
 * the person picked (`content://…`, with a persisted permission) or Dieter's private storage
 * (`private:<folder>`, under the app's files directory, shared through its file provider).
 */
object AndroidFolderLocations {
    const val PRIVATE = "private:"

    fun isTree(location: String): Boolean = location.startsWith("content://")

    /** The private location of [folderId]. */
    fun privateLocation(folderId: String): String =
        PRIVATE +
            folderId.filter { it.isLetterOrDigit() || it == '_' || it == '-' }.ifEmpty { "folder" }

    /** The directory of a private [location]; null for a tree. */
    fun privateDirectory(context: Context, location: String): File? =
        if (!location.startsWith(PRIVATE)) null
        else
            File(
                privateRoot(context),
                location.removePrefix(PRIVATE).takeIf { name ->
                    name.isNotEmpty() && name.all { it.isLetterOrDigit() || it == '_' || it == '-' }
                } ?: return null,
            )

    /** Every private folder lives below this directory, which the file provider shares. */
    fun privateRoot(context: Context): File = File(context.filesDir, "folders")

    /** The file provider that shares private folders' files with other apps. */
    fun authority(context: Context): String = "${context.packageName}.folders"

    /**
     * How a picked tree reads: "Documents/Dieter/Inbox" on internal storage, "SD card · Photos"
     * elsewhere, or the provider's name for the folder.
     */
    fun treeLabel(context: Context, tree: Uri): String {
        val id = runCatching { DocumentsContract.getTreeDocumentId(tree) }.getOrNull().orEmpty()
        val volume = id.substringBefore(':', "")
        val path = id.substringAfter(':', "")
        if (tree.authority == "com.android.externalstorage.documents" && volume.isNotEmpty())
            return when {
                volume == "primary" -> path.ifEmpty { "Internal storage" }
                path.isEmpty() -> "Storage $volume"
                else -> "Storage $volume · $path"
            }
        val root = runCatching { DocumentsContract.buildDocumentUriUsingTree(tree, id) }.getOrNull()
        val name = root?.let { uri ->
            runCatching {
                context.contentResolver
                    .query(
                        uri,
                        arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME),
                        null,
                        null,
                        null,
                    )
                    ?.use { if (it.moveToFirst()) it.getString(0) else null }
            }
                .getOrNull()
        }
        return name?.ifBlank { null } ?: "Shared folder"
    }

    /**
     * The document ID of [path] below [tree]'s root (the root for an empty path), found by listing
     * each directory's children; null when something on the way is missing.
     */
    fun documentId(context: Context, tree: Uri, path: String): String? {
        var id = DocumentsContract.getTreeDocumentId(tree)
        if (path.isEmpty()) return id
        for (component in path.split('/')) {
            id = child(context, tree, id, component) ?: return null
        }
        return id
    }

    /** The child of [parent] named [name], or null. */
    fun child(context: Context, tree: Uri, parent: String, name: String): String? =
        context.contentResolver
            .query(
                DocumentsContract.buildChildDocumentsUriUsingTree(tree, parent),
                arrayOf(
                    DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                    DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                ),
                null,
                null,
                null,
            )
            ?.use { cursor ->
                while (cursor.moveToNext()) if (cursor.getString(1) == name)
                    return@use cursor.getString(0)
                null
            }

    /** A content URI another app can read [path] of [location] through; null when it is missing. */
    fun uriFor(context: Context, location: String, path: String): Uri? {
        if (isTree(location)) {
            val tree = Uri.parse(location)
            val id = documentId(context, tree, path) ?: return null
            return DocumentsContract.buildDocumentUriUsingTree(tree, id)
        }
        val directory = privateDirectory(context, location) ?: return null
        val file = File(directory, path)
        if (!file.isFile) return null
        return androidx.core.content.FileProvider.getUriForFile(context, authority(context), file)
    }
}

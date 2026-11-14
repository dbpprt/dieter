package com.getdieter.android.folders

import android.content.Context
import android.net.Uri
import com.getdieter.core.folders.FolderFileInfo
import com.getdieter.core.folders.FolderFileSystem
import com.getdieter.core.folders.FolderRoot
import com.getdieter.core.folders.FolderSource
import com.getdieter.core.folders.FolderSources
import com.getdieter.mobile.platform.AndroidFolderLocations
import java.io.IOException

/**
 * Android's folder file system: a picked document tree goes through SAF, everything else is
 * Dieter's private storage. New folders default to private storage; the person picks a shared
 * folder in the add-folder flow or on the folder's On this device page.
 */
class AndroidFolderFileSystem(context: Context) : FolderFileSystem {
    private val shared = SafFolderFileSystem(context)
    private val private =
        PrivateFolderFileSystem(AndroidFolderLocations.privateRoot(context).apply { mkdirs() })

    private fun of(root: FolderRoot): FolderFileSystem =
        if (AndroidFolderLocations.isTree(root.location)) shared else private

    override fun defaultLocation(folderId: String, name: String) =
        private.defaultLocation(folderId, name)

    override fun prepare(root: FolderRoot) = of(root).prepare(root)

    override fun rootIdentity(root: FolderRoot) = of(root).rootIdentity(root)

    override fun list(root: FolderRoot, directory: String) = of(root).list(root, directory)

    override fun stat(root: FolderRoot, path: String) = of(root).stat(root, path)

    override fun read(root: FolderRoot, path: String, offset: Long, length: Int) =
        of(root).read(root, path, offset, length)

    override fun stagingSize(root: FolderRoot, staging: String) =
        of(root).stagingSize(root, staging)

    override fun writeStaging(root: FolderRoot, staging: String, offset: Long, bytes: ByteArray) =
        of(root).writeStaging(root, staging, offset, bytes)

    override fun publish(
        root: FolderRoot,
        staging: String,
        path: String,
        expected: FolderFileInfo?,
        modifiedNanos: Long,
        executable: Boolean,
    ) = of(root).publish(root, staging, path, expected, modifiedNanos, executable)

    override fun discardStaging(root: FolderRoot, staging: String) =
        of(root).discardStaging(root, staging)

    override fun delete(root: FolderRoot, path: String, expected: FolderFileInfo) =
        of(root).delete(root, path, expected)

    override fun mkdir(root: FolderRoot, path: String) = of(root).mkdir(root, path)

    override fun removeDirectory(root: FolderRoot, path: String) =
        of(root).removeDirectory(root, path)

    override fun move(root: FolderRoot, from: String, to: String, expected: FolderFileInfo) =
        of(root).move(root, from, to, expected)

    override fun freeBytes(root: FolderRoot) = of(root).freeBytes(root)

    override fun deleteAll(root: FolderRoot) = of(root).deleteAll(root)
}

/** Files other apps share ("Save to folder…"), read from their content URIs. */
class AndroidFolderSources(private val context: Context) : FolderSources {
    override fun open(source: String): FolderSource {
        val uri = Uri.parse(source)
        if (uri.scheme != "content") throw IOException("Only files other apps share can be saved.")
        val input =
            context.contentResolver.openInputStream(uri)
                ?: throw IOException("The file could not be opened.")
        return object : FolderSource {
            override fun read(buffer: ByteArray): Int = input.read(buffer)

            override fun close() = input.close()
        }
    }
}

/** Shares files of folders private to Dieter with the apps that open them. */
class FolderFileProvider : androidx.core.content.FileProvider()

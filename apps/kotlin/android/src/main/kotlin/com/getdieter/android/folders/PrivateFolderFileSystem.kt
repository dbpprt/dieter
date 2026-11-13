package com.getdieter.android.folders

import com.getdieter.core.folders.FolderChangedException
import com.getdieter.core.folders.FolderFileInfo
import com.getdieter.core.folders.FolderFileKind
import com.getdieter.core.folders.FolderFileSystem
import com.getdieter.core.folders.FolderLocation
import com.getdieter.core.folders.FolderRoot
import com.getdieter.core.folders.FolderUnavailableException
import com.getdieter.mobile.platform.AndroidFolderLocations
import java.io.File
import java.io.IOException
import java.io.RandomAccessFile
import java.nio.file.AtomicMoveNotSupportedException
import java.nio.file.FileAlreadyExistsException
import java.nio.file.Files
import java.nio.file.LinkOption
import java.nio.file.NoSuchFileException
import java.nio.file.Path
import java.nio.file.StandardCopyOption
import java.nio.file.attribute.BasicFileAttributes
import java.nio.file.attribute.FileTime
import java.util.concurrent.TimeUnit

/**
 * Folders private to Dieter, below [base] (the app's files directory): plain `java.io`/`java.nio`
 * files. Paths never pass through a symlink; publishing is an atomic rename (a hard link when
 * nothing may be there, so a file that appeared meanwhile is never overwritten).
 */
class PrivateFolderFileSystem(private val base: File) : FolderFileSystem {
    override fun defaultLocation(folderId: String, name: String) =
        FolderLocation(AndroidFolderLocations.privateLocation(folderId), "Private to Dieter")

    /** The directory of [root]; unusable locations are unavailable. */
    private fun directory(root: FolderRoot): File {
        val name =
            root.location.removePrefix(AndroidFolderLocations.PRIVATE).takeIf {
                root.location.startsWith(AndroidFolderLocations.PRIVATE) &&
                    it.isNotEmpty() &&
                    it.all { char -> char.isLetterOrDigit() || char == '_' || char == '-' }
            } ?: throw FolderUnavailableException("That is not a private folder location.")
        return File(base, name)
    }

    /** The existing root's directory. */
    private fun existing(root: FolderRoot): File =
        directory(root).takeIf { it.isDirectory && !Files.isSymbolicLink(it.toPath()) }
            ?: throw FolderUnavailableException()

    /** [path] below [root], refusing symlinks on the way and odd components. */
    private fun resolve(root: FolderRoot, path: String): File {
        var file = existing(root)
        if (path.isEmpty()) return file
        val parts = path.split('/')
        for ((index, part) in parts.withIndex()) {
            if (part.isEmpty() || part == "." || part == ".." || '\u0000' in part)
                throw IOException("Invalid path $path")
            file = File(file, part)
            if (index < parts.lastIndex && Files.isSymbolicLink(file.toPath()))
                throw FolderChangedException("$path passes through a symlink.")
        }
        return file
    }

    private fun attributes(path: Path): BasicFileAttributes? =
        try {
            Files.readAttributes(path, BasicFileAttributes::class.java, LinkOption.NOFOLLOW_LINKS)
        } catch (missing: NoSuchFileException) {
            null
        }

    private fun info(file: File): FolderFileInfo? {
        val path = file.toPath()
        val attributes = attributes(path) ?: return null
        val kind =
            when {
                attributes.isSymbolicLink -> FolderFileKind.SYMLINK
                attributes.isDirectory -> FolderFileKind.DIRECTORY
                attributes.isRegularFile -> FolderFileKind.FILE
                else -> FolderFileKind.OTHER
            }
        val modified = attributes.lastModifiedTime().to(TimeUnit.NANOSECONDS)
        val size = if (kind == FolderFileKind.FILE) attributes.size() else 0
        val key = attributes.fileKey()?.toString() ?: file.name
        return FolderFileInfo(
            name = file.name,
            kind = kind,
            size = size,
            modifiedNanos = modified,
            token = "$key:$modified:$size",
            executable = kind == FolderFileKind.FILE && file.canExecute(),
        )
    }

    private fun matches(file: File, expected: FolderFileInfo?): Boolean {
        val now = info(file)
        return if (expected == null) now == null
        else
            now != null &&
                now.kind == expected.kind &&
                now.size == expected.size &&
                now.modifiedNanos == expected.modifiedNanos &&
                now.token == expected.token
    }

    override fun prepare(root: FolderRoot): String {
        val directory = directory(root)
        if (!directory.isDirectory && !directory.mkdirs())
            throw FolderUnavailableException("The folder could not be created.")
        return rootIdentity(root) ?: throw FolderUnavailableException()
    }

    override fun rootIdentity(root: FolderRoot): String? {
        val directory = runCatching { directory(root) }.getOrNull() ?: return null
        val attributes = attributes(directory.toPath()) ?: return null
        if (!attributes.isDirectory) return null
        return "private:" + (attributes.fileKey()?.toString() ?: directory.absolutePath)
    }

    override fun list(root: FolderRoot, directory: String): List<FolderFileInfo> {
        val folder = resolve(root, directory)
        val children = folder.listFiles() ?: throw IOException("$directory cannot be listed.")
        return children.mapNotNull(::info)
    }

    override fun stat(root: FolderRoot, path: String): FolderFileInfo? = info(resolve(root, path))

    override fun read(root: FolderRoot, path: String, offset: Long, length: Int): ByteArray {
        RandomAccessFile(resolve(root, path), "r").use { file ->
            if (offset >= file.length()) return ByteArray(0)
            file.seek(offset)
            val buffer = ByteArray(minOf(length.toLong(), file.length() - offset).toInt())
            file.readFully(buffer)
            return buffer
        }
    }

    override fun stagingSize(root: FolderRoot, staging: String): Long {
        val file = resolve(root, staging)
        return if (file.isFile) file.length() else -1
    }

    override fun writeStaging(root: FolderRoot, staging: String, offset: Long, bytes: ByteArray) {
        val file = resolve(root, staging)
        file.parentFile?.mkdirs()
        RandomAccessFile(file, "rw").use {
            it.setLength(offset)
            it.seek(offset)
            it.write(bytes)
        }
    }

    override fun publish(
        root: FolderRoot,
        staging: String,
        path: String,
        expected: FolderFileInfo?,
        modifiedNanos: Long,
        executable: Boolean,
    ): FolderFileInfo {
        val source = resolve(root, staging)
        val target = resolve(root, path)
        if (!source.isFile) throw FolderChangedException("The download's partial file is gone.")
        if (!matches(target, expected)) throw FolderChangedException()
        Files.setLastModifiedTime(
            source.toPath(),
            FileTime.from(modifiedNanos, TimeUnit.NANOSECONDS),
        )
        source.setExecutable(executable, false)
        target.parentFile?.mkdirs()
        if (expected == null) {
            // Create-only: a hard link fails when anything appeared at the target meanwhile.
            try {
                Files.createLink(target.toPath(), source.toPath())
                Files.delete(source.toPath())
            } catch (exists: FileAlreadyExistsException) {
                throw FolderChangedException()
            } catch (unsupported: UnsupportedOperationException) {
                if (target.exists()) throw FolderChangedException()
                move(source, target)
            } catch (unsupported: IOException) {
                if (target.exists()) throw FolderChangedException()
                move(source, target)
            }
        } else move(source, target)
        return info(target) ?: throw FolderChangedException()
    }

    private fun move(source: File, target: File) {
        try {
            Files.move(
                source.toPath(),
                target.toPath(),
                StandardCopyOption.ATOMIC_MOVE,
                StandardCopyOption.REPLACE_EXISTING,
            )
        } catch (unsupported: AtomicMoveNotSupportedException) {
            Files.move(source.toPath(), target.toPath(), StandardCopyOption.REPLACE_EXISTING)
        }
    }

    override fun discardStaging(root: FolderRoot, staging: String) {
        runCatching { resolve(root, staging) }.getOrNull()?.takeIf { it.isFile }?.delete()
    }

    override fun delete(root: FolderRoot, path: String, expected: FolderFileInfo) {
        val file = resolve(root, path)
        if (!matches(file, expected)) throw FolderChangedException()
        if (!file.delete() && file.exists()) throw IOException("$path could not be deleted.")
    }

    override fun mkdir(root: FolderRoot, path: String) {
        val directory = resolve(root, path)
        if (Files.isSymbolicLink(directory.toPath()))
            throw FolderChangedException("$path is a symlink.")
        if (!directory.isDirectory && !directory.mkdirs() && !directory.isDirectory)
            throw IOException("$path could not be created.")
    }

    override fun removeDirectory(root: FolderRoot, path: String): Boolean {
        val directory = resolve(root, path)
        if (!directory.isDirectory) return true
        if (!directory.list().isNullOrEmpty()) return false
        return directory.delete()
    }

    override fun move(root: FolderRoot, from: String, to: String, expected: FolderFileInfo) {
        val source = resolve(root, from)
        val target = resolve(root, to)
        if (!matches(source, expected)) throw FolderChangedException()
        if (target.exists()) throw FolderChangedException()
        target.parentFile?.mkdirs()
        try {
            Files.move(source.toPath(), target.toPath(), StandardCopyOption.ATOMIC_MOVE)
        } catch (unsupported: AtomicMoveNotSupportedException) {
            Files.move(source.toPath(), target.toPath())
        }
    }

    override fun freeBytes(root: FolderRoot): Long =
        (runCatching { directory(root) }.getOrNull()?.takeIf { it.exists() } ?: base).usableSpace

    override fun deleteAll(root: FolderRoot) {
        runCatching { directory(root) }.getOrNull()?.let(::deleteTree)
    }

    /** Deletes [file] and what is below it; a symlink goes itself, never what it points to. */
    private fun deleteTree(file: File) {
        if (!Files.isSymbolicLink(file.toPath()) && file.isDirectory)
            file.listFiles()?.forEach(::deleteTree)
        file.delete()
    }
}

package com.dbpprt.dieter.core.storage

import okio.ByteString.Companion.encodeUtf8
import okio.FileSystem
import okio.Path
import okio.use

/**
 * The core's private on-device state. The app supplies the directory
 * (Application Support on Apple, noBackupFilesDir on Android). Every write is
 * fsynced to a temporary file, then atomically renamed over the target, so a
 * crash leaves either the old or the new file.
 */
class CoreStorage(private val fileSystem: FileSystem, val directory: Path) {
    init {
        fileSystem.createDirectories(directory)
    }

    /** A child namespace, e.g. one per gateway account. */
    fun scope(name: String): CoreStorage = CoreStorage(fileSystem, directory / safeName(name))

    fun read(name: String): ByteArray? {
        val path = directory / name
        return if (fileSystem.exists(path)) fileSystem.read(path) { readByteArray() } else null
    }

    fun write(name: String, bytes: ByteArray) {
        val target = directory / name
        val temporary = directory / ".$name.tmp"
        fileSystem.openReadWrite(temporary, mustCreate = false, mustExist = false).use { handle ->
            handle.resize(0)
            handle.write(0, bytes, 0, bytes.size)
            handle.flush()
        }
        fileSystem.atomicMove(temporary, target)
    }

    fun delete(name: String) {
        fileSystem.delete(directory / name, mustExist = false)
    }

    fun names(): List<String> =
        fileSystem.listOrNull(directory).orEmpty().map { it.name }.filterNot { it.startsWith(".") }

    /** Removes this namespace and everything in it. */
    fun clear() {
        fileSystem.deleteRecursively(directory, mustExist = false)
        fileSystem.createDirectories(directory)
    }

    companion object {
        /** A filesystem-safe, collision-resistant name for arbitrary keys such as gateway origins. */
        fun safeName(key: String): String {
            val readable = key.replace(Regex("[^A-Za-z0-9._-]"), "_").take(48)
            val digest = key.encodeUtf8().sha256().hex().take(12)
            return "$readable-$digest"
        }
    }
}

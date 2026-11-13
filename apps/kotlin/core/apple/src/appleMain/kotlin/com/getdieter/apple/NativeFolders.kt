package com.getdieter.apple

import com.getdieter.core.folders.DeviceConditions
import com.getdieter.core.folders.FolderChangedException
import com.getdieter.core.folders.FolderConditions
import com.getdieter.core.folders.FolderFileInfo
import com.getdieter.core.folders.FolderFileKind
import com.getdieter.core.folders.FolderFileSystem
import com.getdieter.core.folders.FolderLocation
import com.getdieter.core.folders.FolderNetwork
import com.getdieter.core.folders.FolderPlatform
import com.getdieter.core.folders.FolderRoot
import com.getdieter.core.folders.FolderScheduleRequest
import com.getdieter.core.folders.FolderScheduler
import com.getdieter.core.folders.FolderSource
import com.getdieter.core.folders.FolderSources
import com.getdieter.core.folders.FolderUnavailableException
import kotlinx.cinterop.addressOf
import kotlinx.cinterop.convert
import kotlinx.cinterop.usePinned
import platform.Foundation.NSData
import platform.Foundation.NSFileHandle
import platform.Foundation.NSURL
import platform.Foundation.fileHandleForReadingFromURL
import platform.posix.memcpy

// Synced folders on iOS: the platform side the core drives. Swift implements these protocols
// (the Documents container under NSFileCoordinator, NWPath and UIDevice, BGTaskScheduler); every
// rule stays in the core. Swift cannot throw into Kotlin, so calls report outcomes as status codes.

/**
 * One directory child or stat result. [kind]: 0 file, 1 directory, 2 symlink, 3 anything else.
 * [token] changes whenever the item is replaced or rewritten (its file resource identifier with the
 * content modification date).
 */
class NativeFolderFileInfo(
    val name: String,
    val kind: Int,
    val size: Long,
    val modifiedNanos: Long,
    val token: String,
    val executable: Boolean,
)

/** Where a new folder lives: "Documents/Inbox", shown as "On My iPhone › Dieter › Inbox". */
class NativeFolderLocation(val location: String, val label: String)

/**
 * A call's outcome: [status] 0 succeeded, 1 the item was not in the expected state (nothing was
 * changed), 2 the folder location is unavailable, 3 another failure described by [message]. [info]
 * is the published file's state after a publish.
 */
class NativeFolderOutcome(val status: Int, val message: String?, val info: NativeFolderFileInfo?)

/**
 * A folder's files. Locations come from [defaultLocation]; paths are relative to the location,
 * '/'-separated; an empty path is the location itself. Never follow or create symlinks. Each
 * replacement or deletion first checks that the item still matches `expected` (size, modification
 * time and token) and changes nothing otherwise (status 1).
 */
interface NativeFolderFileSystem {
    fun defaultLocation(folderId: String, name: String): NativeFolderLocation

    /** Creates the location when missing; its identity, or nil when it is unusable. */
    fun prepare(location: String): String?

    /** The location's identity (its volume and file identifier), or nil when unavailable. */
    fun rootIdentity(location: String): String?

    /** The children of [directory]; nil when the location is unavailable. */
    fun list(location: String, directory: String): List<NativeFolderFileInfo>?

    /** Nil when nothing is at [path]. */
    fun stat(location: String, path: String): NativeFolderFileInfo?

    /** Up to [length] bytes from [offset]; empty at the end, nil when unreadable. */
    fun read(location: String, path: String, offset: Long, length: Int): NSData?

    /** The staging file's size; -1 when it is missing. */
    fun stagingSize(location: String, staging: String): Long

    /** Writes [data] at [offset] of the staging file, truncating anything after [offset] first. */
    fun writeStaging(
        location: String,
        staging: String,
        offset: Long,
        data: NSData,
    ): NativeFolderOutcome

    /**
     * Replaces [path] with the staging file (`replaceItemAt` under a coordinated write) when [path]
     * still matches [expected], or does not exist when [expected] is nil; sets the modification
     * time and the executable bit, and returns the published state in [NativeFolderOutcome.info].
     */
    fun publish(
        location: String,
        staging: String,
        path: String,
        expected: NativeFolderFileInfo?,
        modifiedNanos: Long,
        executable: Boolean,
    ): NativeFolderOutcome

    fun discardStaging(location: String, staging: String)

    fun delete(location: String, path: String, expected: NativeFolderFileInfo): NativeFolderOutcome

    fun mkdir(location: String, path: String): NativeFolderOutcome

    /** Status 0 removed, 1 not empty, 2 unavailable, 3 failed. */
    fun removeDirectory(location: String, path: String): NativeFolderOutcome

    /** Renames [from] (matching [expected]) to [to], which must not exist; status 1 otherwise. */
    fun move(
        location: String,
        from: String,
        to: String,
        expected: NativeFolderFileInfo,
    ): NativeFolderOutcome

    fun freeBytes(location: String): Long

    fun deleteAll(location: String): NativeFolderOutcome
}

/**
 * The device's state: [network] 0 none, 1 unmetered, 2 metered (cellular, `NWPath.isExpensive`);
 * [constrained] is Low Data Mode; [batteryPercent] is -1 when unknown.
 */
class NativeFolderConditions(
    val network: Int,
    val constrained: Boolean,
    val charging: Boolean,
    val batteryPercent: Int,
    val lowPowerMode: Boolean,
)

interface NativeDeviceConditions {
    fun current(): NativeFolderConditions
}

/**
 * BGTaskScheduler: [schedule] submits the refresh task with the interval as its earliest begin date
 * (and a processing task when work remains); [requestLongRun] queues the processing task (or a
 * continued processing task after Sync now); [cancel] cancels both. Each task calls
 * `DieterShared.folderSyncWindow`.
 */
interface NativeFolderScheduler {
    fun schedule(
        intervalSeconds: Long,
        unmeteredOnly: Boolean,
        requiresCharging: Boolean,
    )

    fun requestLongRun(userInitiated: Boolean)

    fun cancel()
}

/** What an iOS host supplies for synced folders. */
class NativeFolders(
    val fileSystem: NativeFolderFileSystem,
    val conditions: NativeDeviceConditions,
    val scheduler: NativeFolderScheduler,
)

internal fun NativeFolders.platform(): FolderPlatform =
    FolderPlatform(
        fileSystem = NativeFolderFileSystemAdapter(fileSystem),
        conditions =
            DeviceConditions {
                val native = conditions.current()
                FolderConditions(
                    network =
                        when (native.network) {
                            0 -> FolderNetwork.NONE
                            2 -> FolderNetwork.METERED
                            else -> FolderNetwork.UNMETERED
                        },
                    constrained = native.constrained,
                    charging = native.charging,
                    batteryPercent = native.batteryPercent,
                    powerSaver = native.lowPowerMode,
                )
            },
        scheduler =
            object : FolderScheduler {
                override fun schedule(request: FolderScheduleRequest) =
                    scheduler.schedule(
                        request.interval.inWholeSeconds,
                        request.unmeteredOnly,
                        request.requiresCharging,
                    )

                override fun requestLongRun(userInitiated: Boolean) =
                    scheduler.requestLongRun(userInitiated)

                override fun cancel() = scheduler.cancel()
            },
        platform = "ios",
        sources = FileUrlSources,
    )

/**
 * "Save to folder…": what the share extension staged, as file URLs (or absolute paths) the app can
 * read. Each file is streamed in chunks, so its size never passes through memory at once.
 */
private object FileUrlSources : FolderSources {
    override fun open(source: String): FolderSource {
        val url =
            when {
                source.startsWith("file:") -> NSURL.URLWithString(source)
                source.startsWith("/") -> NSURL.fileURLWithPath(source)
                else -> null
            } ?: throw IllegalArgumentException("it is not a file on this device.")
        val handle =
            NSFileHandle.fileHandleForReadingFromURL(url, null)
                ?: throw IllegalStateException("it could not be read.")
        return object : FolderSource {
            override fun read(buffer: ByteArray): Int {
                if (buffer.isEmpty()) return 0
                val data =
                    handle.readDataUpToLength(buffer.size.convert(), null)
                        ?: throw IllegalStateException("it could not be read.")
                val count = data.length.toInt()
                if (count == 0) return -1
                buffer.usePinned { memcpy(it.addressOf(0), data.bytes, data.length) }
                return count
            }

            override fun close() {
                handle.closeAndReturnError(null)
            }
        }
    }
}

private class NativeFolderFileSystemAdapter(private val native: NativeFolderFileSystem) :
    FolderFileSystem {
    private fun NativeFolderFileInfo.core() =
        FolderFileInfo(
            name = name,
            kind =
                when (kind) {
                    0 -> FolderFileKind.FILE
                    1 -> FolderFileKind.DIRECTORY
                    2 -> FolderFileKind.SYMLINK
                    else -> FolderFileKind.OTHER
                },
            size = size,
            modifiedNanos = modifiedNanos,
            token = token,
            executable = executable,
        )

    private fun FolderFileInfo.native() =
        NativeFolderFileInfo(
            name = name,
            kind =
                when (kind) {
                    FolderFileKind.FILE -> 0
                    FolderFileKind.DIRECTORY -> 1
                    FolderFileKind.SYMLINK -> 2
                    FolderFileKind.OTHER -> 3
                },
            size = size,
            modifiedNanos = modifiedNanos,
            token = token,
            executable = executable,
        )

    private fun NativeFolderOutcome.check(): NativeFolderOutcome =
        when (status) {
            0 -> this
            1 -> throw FolderChangedException(message ?: "The file changed on this device.")
            2 -> throw FolderUnavailableException(message ?: "The folder location is unavailable.")
            else -> throw IllegalStateException(message ?: "The file operation failed.")
        }

    override fun defaultLocation(folderId: String, name: String): FolderLocation =
        native.defaultLocation(folderId, name).let { FolderLocation(it.location, it.label) }

    override fun prepare(root: FolderRoot): String =
        native.prepare(root.location) ?: throw FolderUnavailableException()

    override fun rootIdentity(root: FolderRoot): String? = native.rootIdentity(root.location)

    override fun list(root: FolderRoot, directory: String): List<FolderFileInfo> =
        native.list(root.location, directory)?.map { it.core() }
            ?: throw FolderUnavailableException()

    override fun stat(root: FolderRoot, path: String): FolderFileInfo? =
        native.stat(root.location, path)?.core()

    override fun read(root: FolderRoot, path: String, offset: Long, length: Int): ByteArray =
        native.read(root.location, path, offset, length)?.toByteArray()
            ?: throw FolderChangedException("The file could not be read.")

    override fun stagingSize(root: FolderRoot, staging: String): Long =
        native.stagingSize(root.location, staging)

    override fun writeStaging(root: FolderRoot, staging: String, offset: Long, bytes: ByteArray) {
        native.writeStaging(root.location, staging, offset, bytes.toNSData()).check()
    }

    override fun publish(
        root: FolderRoot,
        staging: String,
        path: String,
        expected: FolderFileInfo?,
        modifiedNanos: Long,
        executable: Boolean,
    ): FolderFileInfo =
        native
            .publish(root.location, staging, path, expected?.native(), modifiedNanos, executable)
            .check()
            .info
            ?.core() ?: throw IllegalStateException("The published file has no state.")

    override fun discardStaging(root: FolderRoot, staging: String) =
        native.discardStaging(root.location, staging)

    override fun delete(root: FolderRoot, path: String, expected: FolderFileInfo) {
        native.delete(root.location, path, expected.native()).check()
    }

    override fun mkdir(root: FolderRoot, path: String) {
        native.mkdir(root.location, path).check()
    }

    override fun removeDirectory(root: FolderRoot, path: String): Boolean {
        val outcome = native.removeDirectory(root.location, path)
        if (outcome.status == 1) return false
        outcome.check()
        return true
    }

    override fun move(root: FolderRoot, from: String, to: String, expected: FolderFileInfo) {
        native.move(root.location, from, to, expected.native()).check()
    }

    override fun freeBytes(root: FolderRoot): Long = native.freeBytes(root.location)

    override fun deleteAll(root: FolderRoot) {
        native.deleteAll(root.location).check()
    }
}

package com.getdieter.core.folders

import kotlin.time.Duration

/**
 * What a phone supplies so the core can keep synced folders on it. Every rule stays in the core;
 * these are thin platform adapters (SAF or private storage on Android, the Documents container on
 * iOS). Platforms without a client sync engine (the Mac, the JVM) supply none.
 */
class FolderPlatform(
    val fileSystem: FolderFileSystem,
    val conditions: DeviceConditions,
    val scheduler: FolderScheduler,
    /** "android" or "ios": which settings and wording apply. */
    val platform: String,
    /** Reads files other apps share, for "Save to folder…"; null where sharing is not offered. */
    val sources: FolderSources? = null,
)

/** A file another app shared, read once from its start. */
interface FolderSource : AutoCloseable {
    /** Reads into [buffer]; the count read, or -1 at the end. */
    fun read(buffer: ByteArray): Int
}

/** Opens what another app shared: an Android content URI, an iOS file URL. */
fun interface FolderSources {
    /** Throws when [source] cannot be read. */
    fun open(source: String): FolderSource
}

/**
 * Where one folder lives on this device. [location] is opaque to the core: an Android tree URI, or
 * the platform's own location (from [FolderFileSystem.defaultLocation]).
 */
data class FolderRoot(val folderId: String, val location: String)

/** The location the platform suggests and how the UI names it. */
data class FolderLocation(val location: String, val label: String)

enum class FolderFileKind {
    FILE,
    DIRECTORY,
    /** Symlinks are never followed or created; they are listed as unsyncable. */
    SYMLINK,
    /** Sockets, devices and anything else. */
    OTHER,
}

/** One directory child, or what [FolderFileSystem.stat] found. */
data class FolderFileInfo(
    /** The last path component as the platform stores it (not normalized). */
    val name: String,
    val kind: FolderFileKind,
    val size: Long = 0,
    val modifiedNanos: Long = 0,
    /**
     * Changes whenever the item is replaced or rewritten: an inode with its change time, a document
     * ID with its last-modified time. The core compares it with what it observed before.
     */
    val token: String = "",
    val executable: Boolean = false,
)

/** A write found the destination in another state than expected; nothing was overwritten. */
class FolderChangedException(message: String = "The file changed on this device.") :
    Exception(message)

/** The folder's location is missing, replaced or no longer accessible. */
class FolderUnavailableException(message: String = "The folder location is unavailable.") :
    Exception(message)

/**
 * A folder's files on this device. Paths are relative to the root, '/'-separated, as the platform
 * stores them; an empty path is the root. Calls block and run off the core's dispatcher. Writes
 * never follow symlinks, and every replacement or deletion is guarded by the state the core last
 * observed: when the item changed in between, they throw [FolderChangedException] and change
 * nothing. A missing or revoked root throws [FolderUnavailableException].
 */
interface FolderFileSystem {
    /**
     * The platform's own location for a new folder named [name]: private storage, iOS Documents.
     */
    fun defaultLocation(folderId: String, name: String): FolderLocation

    /**
     * Creates the root when the platform owns the location and returns its identity (device and
     * inode, a tree document ID).
     */
    fun prepare(root: FolderRoot): String

    /** The root's identity, or null when it is missing or not accessible. */
    fun rootIdentity(root: FolderRoot): String?

    /** The children of [directory], without following symlinks. */
    fun list(root: FolderRoot, directory: String): List<FolderFileInfo>

    /** [path]'s state, or null when nothing is there. */
    fun stat(root: FolderRoot, path: String): FolderFileInfo?

    /** Up to [length] bytes of the file at [path] from [offset]; empty at its end. */
    fun read(root: FolderRoot, path: String, offset: Long, length: Int): ByteArray

    /** The size of the staging file [staging] (a `.dieter-transfer-` sibling); -1 when missing. */
    fun stagingSize(root: FolderRoot, staging: String): Long

    /**
     * Writes [bytes] at [offset] of the staging file, creating it at offset 0 and truncating
     * anything after [offset] first, so an interrupted write resumes cleanly.
     */
    fun writeStaging(root: FolderRoot, staging: String, offset: Long, bytes: ByteArray)

    /**
     * Replaces [path] with the staging file atomically, or as close as the platform allows, when
     * [path] is still in the [expected] state (null: nothing may be there), and returns the
     * published file's state. Sets the modification time and the executable bit.
     */
    fun publish(
        root: FolderRoot,
        staging: String,
        path: String,
        expected: FolderFileInfo?,
        modifiedNanos: Long,
        executable: Boolean,
    ): FolderFileInfo

    /** Removes a staging file; nothing when it is gone. */
    fun discardStaging(root: FolderRoot, staging: String)

    /** Deletes the file at [path] when it is still in the [expected] state. */
    fun delete(root: FolderRoot, path: String, expected: FolderFileInfo)

    /** Creates the directory at [path] and missing parents. */
    fun mkdir(root: FolderRoot, path: String)

    /** Removes the directory at [path] when it is empty; false when it is not. */
    fun removeDirectory(root: FolderRoot, path: String): Boolean

    /**
     * Renames [from] (still in the [expected] state) to [to], which must not exist; parents of [to]
     * are created.
     */
    fun move(root: FolderRoot, from: String, to: String, expected: FolderFileInfo)

    /** Bytes free on the location's volume. */
    fun freeBytes(root: FolderRoot): Long

    /** Deletes everything under the root, and the root when the platform owns it. */
    fun deleteAll(root: FolderRoot)
}

enum class FolderNetwork {
    NONE,
    /** Wi-Fi, Ethernet or another network the platform reports as unmetered. */
    UNMETERED,
    /** Cellular or a metered hotspot. */
    METERED,
}

/** What the device is doing now, as far as folder sync cares. */
data class FolderConditions(
    val network: FolderNetwork = FolderNetwork.UNMETERED,
    /** A metered network while roaming (Android only). */
    val roaming: Boolean = false,
    /** iOS Low Data Mode (`NWPath.isConstrained`). */
    val constrained: Boolean = false,
    /** Android Data Saver restricts this app's background data. */
    val dataSaver: Boolean = false,
    val charging: Boolean = true,
    /** 0..100; negative when unknown. */
    val batteryPercent: Int = 100,
    /** Battery Saver or Low Power Mode. */
    val powerSaver: Boolean = false,
)

/** The device's network and power state: ConnectivityManager and BatteryManager, NWPath. */
fun interface DeviceConditions {
    fun current(): FolderConditions
}

/** A periodic background window, as the core asks the platform to schedule it. */
data class FolderScheduleRequest(
    /** Android: the exact period (15 minutes or more); iOS: the earliest begin date. */
    val interval: Duration,
    /** WorkManager `NetworkType.UNMETERED`; otherwise `CONNECTED`. */
    val unmeteredOnly: Boolean,
    /** WorkManager `NetworkType.NOT_ROAMING`. */
    val notRoaming: Boolean,
    val requiresCharging: Boolean,
    val batteryNotLow: Boolean,
    val storageNotLow: Boolean,
)

/**
 * Background hosts: WorkManager and user-initiated jobs on Android, BGTaskScheduler on iOS. Each
 * scheduled run calls `CoreRuntime.folderSyncWindow`.
 */
interface FolderScheduler {
    /** Schedules (or updates) the periodic window. */
    fun schedule(request: FolderScheduleRequest)

    /**
     * Asks for a longer run soon because work remains: a user-initiated data transfer job or a
     * processing task. [userInitiated] is true after the person tapped Sync now.
     */
    fun requestLongRun(userInitiated: Boolean)

    /** Nothing to schedule: no folder is on this device, or background sync is off. */
    fun cancel()
}

package com.getdieter.core.folders

import com.getdieter.api.v1.FolderEntry
import com.getdieter.api.v1.FolderEntryKind
import com.getdieter.core.storage.CoreStorage
import com.getdieter.core.v1.LocalFolderEntry
import java.nio.file.Files
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import kotlin.time.measureTime
import okio.FileSystem
import okio.ForwardingFileSystem
import okio.Path
import okio.Path.Companion.toOkioPath

/**
 * The phone index's storage budget (§4.3): a full folder of 25,000 entries loads cold within a
 * fixed budget, and one changed entry rewrites exactly one shard of a few KiB.
 */
class FolderIndexBudgetTest {
    private class Counting(delegate: FileSystem) : ForwardingFileSystem(delegate) {
        var moves = 0
        val moved = ArrayList<Path>()

        override fun atomicMove(source: Path, target: Path) {
            moves++
            moved += target
            super.atomicMove(source, target)
        }
    }

    private fun entry(index: Int) =
        LocalFolderEntry(
            entry =
                FolderEntry(
                    path =
                        "photos/2026/${index / 100}/IMG_${index.toString().padStart(5, '0')}.jpg",
                    kind = FolderEntryKind.FOLDER_ENTRY_KIND_FILE,
                    size = 2_000_000L + index,
                    modified_nanos = 1_763_000_000_000_000_000 + index,
                    sha256 = index.toString(16).padStart(64, '0'),
                    version = Versions.bump(emptyList(), Versions.actorOf("p_phone")),
                    author_id = "p_phone",
                    author_name = "Pixel 9",
                ),
            observed_size = 2_000_000L + index,
            observed_modified_nanos = 1_763_000_000_000_000_000 + index,
            observed_token = "ino-$index",
            synced = true,
        )

    @Test
    fun aFullFolderLoadsColdAndOneChangeRewritesOneShard() {
        val directory = Files.createTempDirectory("folder-index").toOkioPath()
        try {
            val disk = Counting(FileSystem.SYSTEM)
            val storage = CoreStorage(disk, directory)
            val index = FolderIndex(storage)
            repeat(FolderBounds.MAX_PHONE_ENTRIES) { index.put(entry(it)) }
            assertEquals(FolderIndex.SHARDS, index.flush())

            val cold = measureTime {
                val loaded = FolderIndex(CoreStorage(FileSystem.SYSTEM, directory))
                assertEquals(FolderBounds.MAX_PHONE_ENTRIES, loaded.size)
            }
            assertTrue(cold.inWholeMilliseconds < COLD_LOAD_BUDGET_MS, "cold load took $cold")

            disk.moves = 0
            disk.moved.clear()
            index.put(entry(4242).let { it.copy(entry = it.entry!!.copy(size = 7)) })
            index.flush()
            assertEquals(1, disk.moves, "one changed entry rewrites one shard")
            val shard = FileSystem.SYSTEM.metadata(disk.moved.single()).size!!
            assertTrue(shard < 64 * 1024, "a shard is a few KiB, not the index: $shard bytes")
        } finally {
            FileSystem.SYSTEM.deleteRecursively(directory)
        }
    }

    private companion object {
        /** Generous for loaded CI runners; a phone-class device reads 256 small files. */
        const val COLD_LOAD_BUDGET_MS = 3_000L
    }
}

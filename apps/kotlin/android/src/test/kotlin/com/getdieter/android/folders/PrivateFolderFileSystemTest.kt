package com.getdieter.android.folders

import com.getdieter.core.folders.FolderChangedException
import com.getdieter.core.folders.FolderFileKind
import com.getdieter.core.folders.FolderRoot
import com.getdieter.core.folders.FolderUnavailableException
import java.io.File
import java.nio.file.Files
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** Private storage: guarded writes, atomic publishing, symlinks and a missing root. */
class PrivateFolderFileSystemTest {
    private val base = Files.createTempDirectory("folders").toFile()
    private val files = PrivateFolderFileSystem(base)
    private val root = FolderRoot("f1", files.defaultLocation("f1", "Inbox").location)

    @AfterTest fun cleanUp() = base.deleteRecursively().let {}

    private fun publish(
        path: String,
        text: String,
        expected: com.getdieter.core.folders.FolderFileInfo?,
    ) = files.run {
        val staging = ".dieter-transfer-$path".replace('/', '_')
        writeStaging(root, staging, 0, text.encodeToByteArray())
        publish(root, staging, path, expected, 1_700_000_000_000_000_000, false)
    }

    @Test
    fun theDefaultLocationIsPrivateAndPreparedOnDemand() {
        assertEquals("private:f1", root.location)
        assertNull(files.rootIdentity(root))
        val identity = files.prepare(root)
        assertEquals(identity, files.rootIdentity(root))
        assertTrue(File(base, "f1").isDirectory)
    }

    @Test
    fun publishingCreatesOnlyWhenNothingIsThereAndReplacesOnlyTheObservedFile() {
        files.prepare(root)
        val created = publish("a.txt", "one", null)
        assertEquals(FolderFileKind.FILE, created.kind)
        assertEquals(3, created.size)
        assertEquals(1_700_000_000_000_000_000, created.modifiedNanos)
        // Something is there now: create-only refuses and keeps the download for a retry.
        assertFailsWith<FolderChangedException> { publish("a.txt", "two", null) }
        assertEquals(3, files.stagingSize(root, ".dieter-transfer-a.txt"))
        assertContentEquals("one".encodeToByteArray(), files.read(root, "a.txt", 0, 100))
        val replaced = publish("a.txt", "three", created)
        assertContentEquals("three".encodeToByteArray(), files.read(root, "a.txt", 0, 100))
        // The old observation is stale.
        assertFailsWith<FolderChangedException> { publish("a.txt", "four", created) }
        assertFailsWith<FolderChangedException> { files.delete(root, "a.txt", created) }
        files.delete(root, "a.txt", replaced)
        assertNull(files.stat(root, "a.txt"))
        // Only the refused download's partial file is left, for the core to discard.
        assertEquals(listOf(".dieter-transfer-a.txt"), files.list(root, "").map { it.name })
        files.discardStaging(root, ".dieter-transfer-a.txt")
        assertEquals(emptyList(), files.list(root, "").map { it.name })
    }

    @Test
    fun stagingResumesAndTruncates() {
        files.prepare(root)
        files.writeStaging(root, ".dieter-transfer-x", 0, "hello world".encodeToByteArray())
        files.writeStaging(root, ".dieter-transfer-x", 5, "!".encodeToByteArray())
        assertEquals(6, files.stagingSize(root, ".dieter-transfer-x"))
        assertContentEquals(
            "hello!".encodeToByteArray(),
            files.read(root, ".dieter-transfer-x", 0, 64),
        )
        assertContentEquals("lo".encodeToByteArray(), files.read(root, ".dieter-transfer-x", 3, 2))
        files.discardStaging(root, ".dieter-transfer-x")
        assertEquals(-1, files.stagingSize(root, ".dieter-transfer-x"))
    }

    @Test
    fun directoriesMovesAndSymlinks() {
        files.prepare(root)
        files.mkdir(root, "a/b")
        val file = publish("a/b/c.txt", "c", null)
        assertFalse(files.removeDirectory(root, "a/b"))
        files.move(root, "a/b/c.txt", "d/c.txt", file)
        assertNotNull(files.stat(root, "d/c.txt"))
        assertTrue(files.removeDirectory(root, "a/b"))
        val outside = Files.createTempDirectory("outside").toFile()
        try {
            Files.createSymbolicLink(File(base, "f1/link").toPath(), outside.toPath())
            assertEquals(FolderFileKind.SYMLINK, files.stat(root, "link")!!.kind)
            assertFailsWith<FolderChangedException> { files.mkdir(root, "link/inside") }
            // Deleting the copy never follows the link.
            File(outside, "keep.txt").writeText("keep")
            files.deleteAll(root)
            assertTrue(File(outside, "keep.txt").exists())
            assertFalse(File(base, "f1").exists())
        } finally {
            outside.deleteRecursively()
        }
    }

    @Test
    fun aMissingRootIsUnavailable() {
        assertFailsWith<FolderUnavailableException> { files.list(root, "") }
        assertFailsWith<FolderUnavailableException> {
            files.list(FolderRoot("f2", "private:../escape"), "")
        }
    }
}

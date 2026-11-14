package com.getdieter.core.files

import com.getdieter.client.v1.FilesTarget as ClientFilesTarget
import com.getdieter.core.client.filesSlice
import com.getdieter.core.client.filesTarget
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotEquals
import kotlin.test.assertNull

/**
 * Files can show a synced folder member's directory on a daemon: the target names the folder
 * instead of a project, and every request names exactly one root.
 */
class FolderFilesTargetTest {
    @Test
    fun aFolderTargetBindsTheMembersDirectoryOnItsDaemon() {
        assertEquals(
            FilesTarget("mini", "", folderId = "f1"),
            filesTarget(ClientFilesTarget(daemon_id = "mini", folder_id = "f1")),
        )
        // The folder is the root; a project beside it is not sent.
        assertEquals(
            FilesTarget("mini", "", folderId = "f1"),
            filesTarget(
                ClientFilesTarget(
                    daemon_id = "mini",
                    project_id = "p1",
                    checkout_id = "c1",
                    folder_id = "f1",
                )
            ),
        )
        assertNull(filesTarget(ClientFilesTarget(daemon_id = "mini")), "a root is required")
        assertNull(filesTarget(ClientFilesTarget(folder_id = "f1")), "a daemon is required")
        assertEquals(
            FilesTarget("mini", "p1", "c1"),
            filesTarget(
                ClientFilesTarget(daemon_id = "mini", project_id = "p1", checkout_id = "c1")
            ),
        )
    }

    @Test
    fun requestsNameExactlyOneRoot() {
        val folder = FilesTarget("mini", "", folderId = "f1")
        assertEquals(
            listOf("", "", "", "f1"),
            listOf(
                folder.requestProjectId,
                folder.requestCheckoutId,
                folder.requestCardId,
                folder.folderId,
            ),
        )
        val checkout = FilesTarget("mini", "p1", "c1")
        assertEquals(
            listOf("p1", "c1", "", ""),
            listOf(
                checkout.requestProjectId,
                checkout.requestCheckoutId,
                checkout.requestCardId,
                checkout.folderId,
            ),
        )
        val card = FilesTarget("mini", "p1", "c1", cardId = "k1")
        assertEquals(
            listOf("p1", "", "k1"),
            listOf(card.requestProjectId, card.requestCheckoutId, card.requestCardId),
        )
    }

    @Test
    fun theSliceReportsTheFolderTargetAndItsBuffersStayApart() {
        val folder = FilesTarget("mini", "", folderId = "f1")
        assertEquals(
            ClientFilesTarget(daemon_id = "mini", folder_id = "f1"),
            filesSlice(FilesView(target = folder), documentUnchanged = false).target,
        )
        assertNotEquals(
            FilesTarget("mini", "f1").documentKey("notes.md"),
            folder.documentKey("notes.md"),
        )
    }
}

package com.getdieter.core.workspace

import com.getdieter.api.v1.ChangeComment
import com.getdieter.api.v1.ChangedFile
import com.getdieter.api.v1.Changeset
import com.getdieter.api.v1.ChangesetActivity
import com.getdieter.core.runtime.Failures
import com.squareup.wire.GrpcException
import com.squareup.wire.GrpcStatus
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class ConversationChangesRulesTest {
    private val changes =
        Changeset(
            revision = "tree",
            index_fingerprint = "index",
            branch = "main",
            dirty = true,
            files =
                listOf(
                    ChangedFile(path = "README.md", staged = true, revision = "r-readme"),
                    ChangedFile(path = "src/a.kt", unstaged = true, revision = "r-a"),
                    ChangedFile(
                        path = "src/b.kt",
                        staged = true,
                        unstaged = true,
                        revision = "r-b",
                    ),
                    ChangedFile(path = "srcset.txt", unstaged = true, revision = "r-srcset"),
                ),
        )

    @Test
    fun fileScopedOperationsPinExactlyTheFilesTheyActOn() {
        assertEquals(
            mapOf("src/a.kt" to "r-a", "src/b.kt" to "r-b", "srcset.txt" to "r-srcset"),
            ProjectChangesRules.expectedFiles(changes, GitOperationKinds.STAGE),
        )
        // A folder narrows to the files under it, not to siblings sharing its prefix.
        assertEquals(
            mapOf("src/a.kt" to "r-a", "src/b.kt" to "r-b"),
            ProjectChangesRules.expectedFiles(changes, GitOperationKinds.STAGE, "src/"),
        )
        assertEquals(
            mapOf("README.md" to "r-readme", "src/b.kt" to "r-b"),
            ProjectChangesRules.expectedFiles(changes, GitOperationKinds.UNSTAGE),
        )
        assertEquals(
            mapOf("README.md" to "r-readme"),
            ProjectChangesRules.expectedFiles(
                changes,
                GitOperationKinds.DISCARD_CHANGES,
                "README.md",
            ),
        )
        assertEquals(emptyMap(), ProjectChangesRules.expectedFiles(changes, GitOperationKinds.PUSH))
        assertEquals("r-b", ProjectChangesRules.revision(changes, "src/b.kt"))
        assertEquals("", ProjectChangesRules.revision(changes, "clean.txt"))
    }

    @Test
    fun anActiveAgentHoldsBackOnlyWhatWouldDestroyItsWork() {
        val idle =
            ProjectChangesView(changes = changes, needsReconciliation = false, hasRemote = true)
        assertTrue(idle.allows(GitOperationKinds.DISCARD_CHANGES))
        assertEquals(emptyMap(), idle.unavailableReasons)
        assertEquals("", idle.activity)

        val working =
            idle.copy(changes = changes.copy(activity = ChangesetActivity(agent_active = true)))
        assertTrue(working.agentActive)
        assertEquals("Agent working · changes update live", working.activity)
        for (kind in
            listOf(
                GitOperationKinds.STAGE,
                GitOperationKinds.UNSTAGE,
                GitOperationKinds.COMMIT,
                GitOperationKinds.VALIDATE,
                GitOperationKinds.PUSH,
            )) assertTrue(working.allows(kind), "$kind stays available while an agent works")
        assertFalse(working.allows(GitOperationKinds.DISCARD_CHANGES))
        assertFalse(working.allows(GitOperationKinds.UPDATE))
        assertEquals(
            setOf(GitOperationKinds.DISCARD_CHANGES, GitOperationKinds.UPDATE),
            working.unavailableReasons.keys,
        )
        assertTrue(
            working.unavailableReasons
                .getValue(GitOperationKinds.DISCARD_CHANGES)
                .startsWith("An agent is working")
        )
    }

    @Test
    fun aSharedCheckoutSaysSoWithItsBranch() {
        assertEquals("", ProjectChangesView(changes = changes).sharedLabel)
        assertEquals(
            "Shared checkout · main",
            ProjectChangesView(changes = changes, shared = true).sharedLabel,
        )
    }

    @Test
    fun commentsFollowTheirFileAndOthersAreOutdated() {
        val current =
            ChangeComment(id = "1", path = "src/a.kt", file_revision = "r-a", body = "now")
        val outdated =
            ChangeComment(id = "2", path = "src/a.kt", file_revision = "r-old", body = "then")
        val elsewhere =
            ChangeComment(id = "3", path = "README.md", file_revision = "r-readme", body = "ok")
        val view =
            WorkspaceReviewView(
                changeset = changes,
                comments = listOf(current, outdated, elsewhere),
                selectedPath = "src/a.kt",
            )
        assertEquals(listOf(current, elsewhere), view.currentComments)
        assertEquals(1, view.outdatedComments)
        assertEquals(0, view.copy(selectedCommit = "abc").outdatedComments)
        assertEquals(
            "Agent working · changes update live",
            view
                .copy(changeset = changes.copy(activity = ChangesetActivity(agent_active = true)))
                .activity,
        )
    }

    @Test
    fun daemonRefusalsReadAsWrittenWithoutTheStatusCode() {
        assertEquals(
            "Workspace is busy: an agent is working in this checkout; wait for it to finish or stop it",
            Failures.message(
                GrpcException(
                    GrpcStatus.FAILED_PRECONDITION,
                    "workspace is busy: an agent is working in this checkout; wait for it to finish or stop it",
                )
            ),
        )
        assertEquals(
            "README.md changed since it was reviewed; review it again",
            Failures.message(
                GrpcException(
                    GrpcStatus.ABORTED,
                    "README.md changed since it was reviewed; review it again",
                )
            ),
        )
        assertEquals(
            "gRPC UNAVAILABLE: down",
            Failures.message(GrpcException(GrpcStatus.UNAVAILABLE, "down")),
        )
    }
}

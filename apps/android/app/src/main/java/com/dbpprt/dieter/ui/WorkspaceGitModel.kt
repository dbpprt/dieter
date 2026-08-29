package com.dbpprt.dieter.ui

import com.dbpprt.dieter.v1.Card
import com.dbpprt.dieter.v1.ChangeComment
import com.dbpprt.dieter.v1.Changeset
import com.dbpprt.dieter.v1.FileDiff
import com.dbpprt.dieter.v1.GitOperation
import com.dbpprt.dieter.v1.GitOperationLogEntry
import com.dbpprt.dieter.v1.SCMCapabilities
import com.dbpprt.dieter.v1.Workspace

/** The per-conversation execution location choices shared with the Mac client. */
enum class ConversationWorkspaceMode(val wire: String, val title: String, val shortTitle: String, val detail: String) {
    WORKTREE(
        "worktree", "Worktree", "Worktree",
        "Create an isolated Git worktree and branch for this conversation.",
    ),
    BRANCH(
        "branch", "Dedicated branch", "Branch",
        "Use a dedicated branch in the registered checkout.",
    ),
    MAIN(
        "main", "Main checkout", "Main",
        "Share the registered checkout. Concurrent work is restricted.",
    );

    companion object {
        fun resolve(value: String?): ConversationWorkspaceMode =
            entries.firstOrNull { it.wire == value?.lowercase() } ?: MAIN
    }
}

/** Durable Git operation kinds accepted by StartGitOperation. */
object GitOperationKinds {
    const val COMMIT = "commit"
    const val UPDATE = "update"
    const val VALIDATE = "validate"
    const val MERGE_LOCAL = "merge_local"
    const val PUSH = "push"
    const val CREATE_PR = "create_pr"
    const val REFRESH_PR = "refresh_pr"
    const val MERGE_PR = "merge_pr"
    const val CONTINUE_CONFLICT = "continue_conflict"
    const val ABORT_CONFLICT = "abort_conflict"
    const val MIGRATE = "migrate"
    const val ADOPT = "adopt"
    const val CLEANUP = "cleanup"
    const val DISCARD = "discard"

    fun title(kind: String): String = when (kind) {
        COMMIT -> "Commit changes"
        UPDATE -> "Update from base"
        VALIDATE -> "Run validation"
        MERGE_LOCAL -> "Merge locally"
        PUSH -> "Push branch"
        CREATE_PR -> "Create pull request"
        REFRESH_PR -> "Refresh pull request"
        MERGE_PR -> "Merge pull request"
        CONTINUE_CONFLICT -> "Continue after resolving"
        ABORT_CONFLICT -> "Abort conflicted operation"
        MIGRATE -> "Migrate to worktree"
        ADOPT -> "Move workspace"
        CLEANUP -> "Clean up workspace"
        DISCARD -> "Discard workspace"
        else -> kind.replace('_', ' ').replaceFirstChar(Char::uppercase)
    }

    fun destructive(kind: String): Boolean = kind == DISCARD || kind == ABORT_CONFLICT
}

object GitOperationStatuses {
    fun terminal(value: String): Boolean = value in setOf("succeeded", "failed", "canceled", "interrupted")
    fun active(value: String): Boolean = value in setOf("queued", "running", "waiting_for_resolution")
}

/**
 * Picks the operation the client must resume: a fresh workspace projection wins,
 * otherwise a still-active locally observed operation keeps its stream alive.
 */
fun gitOperationReconciliationId(
    workspaceOperationId: String,
    observedOperationId: String?,
    observedStatus: String?,
): String? {
    if (workspaceOperationId.isNotEmpty()) return workspaceOperationId
    if (observedOperationId.isNullOrEmpty()) return null
    return observedOperationId.takeIf { GitOperationStatuses.active(observedStatus.orEmpty()) }
}

/** Server-state-derived availability for every Git mutation button. */
data class WorkspaceActionAvailability(
    val agentActive: Boolean,
    val operationActive: Boolean,
    val workspaceState: String,
    val workspaceMode: String,
    val changedFiles: Int,
    val hasCommits: Boolean,
    val hasRemote: Boolean,
    val scmAuthenticated: Boolean,
    val hasPullRequest: Boolean,
    /** Uncommitted working-tree changes, unlike [changedFiles] which also counts committed diffs vs base. */
    val dirty: Boolean = false,
) {
    /**
     * The merge flow opens in more states than the raw merge_local gate: a dirty
     * tree is committed first, and a conflicted workspace shows the blocked
     * explanation instead of hiding the entry point.
     */
    val allowsMergeFlow: Boolean
        get() {
            if (agentActive || operationActive || workspaceMode == "main") return false
            return hasCommits || changedFiles > 0 || workspaceState == "conflicted"
        }

    fun allows(kind: String): Boolean {
        if (agentActive || operationActive) return false
        if (workspaceState == "conflicted") {
            return kind == GitOperationKinds.CONTINUE_CONFLICT || kind == GitOperationKinds.ABORT_CONFLICT
        }
        return when (kind) {
            GitOperationKinds.COMMIT -> dirty || changedFiles > 0
            GitOperationKinds.UPDATE, GitOperationKinds.VALIDATE -> true
            GitOperationKinds.MERGE_LOCAL -> workspaceMode != "main" && hasCommits && changedFiles == 0
            GitOperationKinds.PUSH -> workspaceMode != "main" && hasRemote && hasCommits
            GitOperationKinds.CREATE_PR ->
                workspaceMode != "main" && hasRemote && hasCommits && scmAuthenticated && !hasPullRequest
            GitOperationKinds.REFRESH_PR, GitOperationKinds.MERGE_PR -> hasPullRequest && scmAuthenticated
            GitOperationKinds.CONTINUE_CONFLICT, GitOperationKinds.ABORT_CONFLICT -> false
            GitOperationKinds.MIGRATE -> workspaceMode == "branch" && changedFiles == 0
            GitOperationKinds.ADOPT -> true
            GitOperationKinds.CLEANUP -> changedFiles == 0
            GitOperationKinds.DISCARD -> true
            else -> false
        }
    }
}

/** One rendered row of a unified diff. */
data class UnifiedDiffLine(
    val id: Int,
    val kind: Kind,
    val text: String,
    val oldLine: Int?,
    val newLine: Int?,
) {
    enum class Kind { CONTEXT, ADDITION, DELETION, HEADER, HUNK }
}

object UnifiedDiffParser {
    // Git metadata emitted between a `diff --git` line and its first hunk.
    private val metadataPrefixes = listOf(
        "+++", "---", "index ",
        "new file mode", "deleted file mode", "old mode", "new mode",
        "similarity index", "dissimilarity index",
        "rename from", "rename to", "copy from", "copy to", "Binary files",
    )

    fun parse(patch: String): List<UnifiedDiffLine> {
        val result = ArrayList<UnifiedDiffLine>()
        var oldLine: Int? = null
        var newLine: Int? = null
        patch.split("\n").forEachIndexed { index, raw ->
            val hunk = if (raw.startsWith("@@")) hunkRanges(raw) else null
            when {
                hunk != null -> {
                    oldLine = hunk.first
                    newLine = hunk.second
                    result += UnifiedDiffLine(index, UnifiedDiffLine.Kind.HUNK, raw, null, null)
                }
                raw.startsWith("diff ") -> {
                    // A new file section: whole-commit patches concatenate several.
                    oldLine = null
                    newLine = null
                    result += UnifiedDiffLine(index, UnifiedDiffLine.Kind.HEADER, raw, null, null)
                }
                raw.startsWith("\\ No newline") ->
                    result += UnifiedDiffLine(index, UnifiedDiffLine.Kind.HEADER, raw, null, null)
                oldLine == null && newLine == null && metadataPrefixes.any(raw::startsWith) ->
                    result += UnifiedDiffLine(index, UnifiedDiffLine.Kind.HEADER, raw, null, null)
                raw.startsWith("+") -> {
                    result += UnifiedDiffLine(index, UnifiedDiffLine.Kind.ADDITION, raw, null, newLine)
                    newLine = newLine?.plus(1)
                }
                raw.startsWith("-") -> {
                    result += UnifiedDiffLine(index, UnifiedDiffLine.Kind.DELETION, raw, oldLine, null)
                    oldLine = oldLine?.plus(1)
                }
                else -> {
                    result += UnifiedDiffLine(index, UnifiedDiffLine.Kind.CONTEXT, raw, oldLine, newLine)
                    oldLine = oldLine?.plus(1)
                    newLine = newLine?.plus(1)
                }
            }
        }
        return result
    }

    private fun hunkRanges(value: String): Pair<Int, Int>? {
        val pieces = value.split(" ")
        if (pieces.size < 3) return null
        fun start(piece: String): Int? = piece.drop(1).substringBefore(',').toIntOrNull()
        val old = start(pieces[1]) ?: return null
        val new = start(pieces[2]) ?: return null
        return old to new
    }
}

object WorkspaceChangePresentation {
    fun badge(status: String, conflicted: Boolean = false, untracked: Boolean = false): String {
        if (conflicted) return "!"
        if (untracked) return "U"
        return when (status.trim().lowercase()) {
            "a", "add", "added" -> "A"
            "d", "delete", "deleted" -> "D"
            "r", "rename", "renamed" -> "R"
            "c", "copy", "copied" -> "C"
            "u", "unmerged", "conflicted" -> "!"
            else -> "M"
        }
    }

    fun title(status: String, conflicted: Boolean = false, untracked: Boolean = false): String {
        if (conflicted) return "Conflicted"
        if (untracked) return "Untracked"
        return when (badge(status)) {
            "A" -> "Added"
            "D" -> "Deleted"
            "R" -> "Renamed"
            "C" -> "Copied"
            else -> "Modified"
        }
    }

    fun filename(path: String): String = path.substringAfterLast('/')

    fun directory(path: String): String = path.substringBeforeLast('/', "")
}

/** Card runtimes during which Git mutations are rejected by the daemon. */
fun agentRuntimeActive(runtime: String): Boolean =
    runtime.lowercase() in setOf("starting", "running", "working", "streaming", "waiting", "waiting_for_user", "cancelling")

/** Merges frame logs into the ordered, deduplicated log list. */
fun mergeGitOperationLogs(
    current: List<GitOperationLogEntry>,
    incoming: List<GitOperationLogEntry>,
): List<GitOperationLogEntry> {
    if (incoming.isEmpty()) return current
    val known = current.mapTo(mutableSetOf()) { it.sequence }
    val fresh = incoming.filter { it.sequence !in known }
    if (fresh.isEmpty()) return current
    return (current + fresh).sortedBy { it.sequence }
}

/** Derives Git action availability from the freshest server projections available. */
fun workspaceActionAvailability(card: Card?, review: WorkspaceReviewState): WorkspaceActionAvailability {
    val workspace = review.workspace
    val summary = card?.workspace
    val mode = workspace?.mode?.ifBlank { null }
        ?: summary?.mode?.ifBlank { null }
        ?: card?.workspaceMode?.ifBlank { null }
        ?: "main"
    return WorkspaceActionAvailability(
        agentActive = agentRuntimeActive(card?.runtime.orEmpty()),
        operationActive = review.operationActive,
        workspaceState = workspace?.state ?: summary?.state.orEmpty(),
        workspaceMode = mode,
        changedFiles = review.changeset?.filesCount ?: summary?.changedFiles ?: 0,
        hasCommits = (review.changeset?.commitsCount ?: 0) > 0 || (workspace?.ahead ?: summary?.ahead ?: 0) > 0,
        hasRemote = review.scm?.pushAvailable == true,
        scmAuthenticated = review.scm?.authenticated == true,
        hasPullRequest = (card?.pullRequest?.number ?: 0) > 0,
        dirty = workspace?.dirty == true,
    )
}

/** Server projections and review state for the selected conversation's workspace surface. */
data class WorkspaceReviewState(
    val cardId: String = "",
    val workspace: Workspace? = null,
    val changeset: Changeset? = null,
    val scm: SCMCapabilities? = null,
    val comments: List<ChangeComment> = emptyList(),
    val loading: Boolean = false,
    val error: String? = null,
    val selectedPath: String = "",
    val selectedCommitSha: String = "",
    val diff: FileDiff? = null,
    val diffLines: List<UnifiedDiffLine> = emptyList(),
    val diffLoading: Boolean = false,
    val operation: GitOperation? = null,
    val operationLogs: List<GitOperationLogEntry> = emptyList(),
    /** True after cleanup/discard/adopt succeeded and the workspace no longer exists. */
    val surfaceRemoved: Boolean = false,
    val mergeFlowStep: String? = null,
    val toast: String? = null,
) {
    val operationActive: Boolean get() = operation?.let { GitOperationStatuses.active(it.status) } == true
    val conflicted: Boolean
        get() = workspace?.state == "conflicted" || operation?.status == "waiting_for_resolution"
}

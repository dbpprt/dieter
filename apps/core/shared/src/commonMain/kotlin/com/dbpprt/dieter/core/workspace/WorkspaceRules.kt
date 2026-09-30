package com.dbpprt.dieter.core.workspace

import com.dbpprt.dieter.api.v1.Card
import com.dbpprt.dieter.api.v1.Changeset
import com.dbpprt.dieter.api.v1.GitOperation
import com.dbpprt.dieter.api.v1.GitOperationLogEntry
import com.dbpprt.dieter.api.v1.PullRequestSummary
import com.dbpprt.dieter.api.v1.SCMCapabilities
import com.dbpprt.dieter.api.v1.ValidationCommand
import com.dbpprt.dieter.api.v1.Workspace
import com.dbpprt.dieter.core.board.Runtimes
import com.dbpprt.dieter.core.composition.WorkspaceMode

object GitOperations {
    val ACTIVE = setOf("queued", "running", "waiting_for_resolution")
    val TERMINAL = setOf("succeeded", "failed", "canceled", "interrupted")
    val PROJECT_KINDS = setOf("stage", "unstage", "discard_changes", "commit", "update", "validate", "push")
    val REMOVES_WORKSPACE = setOf("cleanup", "discard", "adopt")

    private val titles = mapOf(
        "stage" to "Stage changes", "unstage" to "Unstage changes", "discard_changes" to "Discard local changes", "commit" to "Commit changes",
        "update" to "Update from base", "validate" to "Run validation", "merge_local" to "Merge locally", "push" to "Push branch",
        "create_pr" to "Create pull request", "refresh_pr" to "Refresh pull request", "merge_pr" to "Merge pull request",
        "continue_conflict" to "Continue after resolving", "abort_conflict" to "Abort conflicted operation", "adopt" to "Move workspace",
        "cleanup" to "Clean up workspace", "discard" to "Discard workspace",
    )

    fun title(kind: String): String = titles[kind] ?: kind.replace('_', ' ').replaceFirstChar { it.uppercase() }

    /** Refreshing a pull request and continuing after a conflict start at once; aborting asks first; the rest collect input. */
    fun start(kind: String): OperationStart = when (kind) {
        "refresh_pr", "continue_conflict" -> OperationStart.IMMEDIATE
        "abort_conflict" -> OperationStart.CONFIRM
        else -> OperationStart.FORM
    }

    /** Operations that throw away work. */
    fun destructive(kind: String): Boolean = kind == "discard" || kind == "abort_conflict"

    /** A running operation can be cancelled; one waiting for conflict resolution is continued or aborted instead. */
    fun cancelable(operation: GitOperation?): Boolean = isActive(operation) && operation?.status != "waiting_for_resolution"

    fun statusLabel(operation: GitOperation): String = operation.status.replace('_', ' ').replaceFirstChar { it.uppercase() }

    /** What an operation form explains before it starts. */
    fun description(kind: String, baseBranch: String): String? = when (kind) {
        "update" -> "Fast-forwards the project directory when it is on $baseBranch; otherwise rebases the checked-out review branch onto the latest $baseBranch."
        "validate" -> "Runs the project's validation commands in order on the Dieter machine."
        "push" -> "Pushes the conversation branch to the configured remote. Nothing is merged."
        "create_pr" -> "The branch is pushed first; an existing open PR is reused."
        "merge_pr" -> "The merge is rejected if the remote branch moved past the reviewed revision."
        "cleanup" -> "Removes the workspace only when its work is clean and safely integrated. Dieter-managed branches are deleted."
        "discard" -> "Removes this workspace and its managed branch, including uncommitted work."
        else -> null
    }

    fun isActive(operation: GitOperation?): Boolean = operation?.status in ACTIVE

    fun isTerminal(operation: GitOperation?): Boolean = operation?.status in TERMINAL

    /** The operation to follow: the workspace's current one, else the observed one while it is still active. */
    fun reconciliationId(workspaceOperationId: String, observed: GitOperation?, cardId: String): String? =
        workspaceOperationId.ifEmpty { null } ?: observed?.takeIf { it.card_id == cardId && it.status in ACTIVE }?.id

    /** Merges streamed logs by sequence (the first copy wins), in order. */
    fun mergeLogs(existing: List<GitOperationLogEntry>, incoming: List<GitOperationLogEntry>): List<GitOperationLogEntry> {
        val known = existing.mapTo(HashSet()) { it.sequence }
        val added = incoming.filter { known.add(it.sequence) }
        if (added.isEmpty()) return existing
        return (existing + added).sortedBy { it.sequence.toULong() }
    }

    /** Keeps the newest 2,000 entries within 8 MiB of text. */
    fun trimLogs(logs: List<GitOperationLogEntry>, maxEntries: Int = 2_000, maxBytes: Int = 8 * 1024 * 1024): List<GitOperationLogEntry> {
        var bytes = 0
        var keep = 0
        for (entry in logs.asReversed()) {
            val size = entry.message.encodeToByteArray().size
            if (keep >= maxEntries || (keep > 0 && bytes + size > maxBytes)) break
            bytes += size
            keep++
        }
        return if (keep == logs.size) logs else logs.takeLast(keep)
    }

    /** The resume cursor: the highest sequence seen in the operation or its logs. */
    fun cursor(current: Long, operation: GitOperation?, logs: List<GitOperationLogEntry>): Long =
        listOfNotNull(current.toULong(), operation?.sequence?.toULong(), logs.maxOfOrNull { it.sequence.toULong() }).max().toLong()
}

enum class OperationStart { IMMEDIATE, CONFIRM, FORM }

/** What an operation form collects before starting [kind]. */
data class GitOperationForm(
    val kind: String,
    val subject: String = "",
    val body: String = "",
    val stageAll: Boolean = true,
    val validate: Boolean = true,
    val draft: Boolean = false,
    /** The pull request merge strategy. */
    val strategy: String = "squash",
) {
    /** A commit needs a message; everything else can start as is. */
    val ready: Boolean get() = kind != "commit" || subject.isNotBlank()

    /** The operation's parameters; a pull request merge is pinned to the reviewed head. */
    fun parameters(expectedHeadSha: String = ""): Map<String, String> = when (kind) {
        "commit" -> mapOf("subject" to subject.trim(), "body" to body.trim(), "stage_all" to stageAll.toString())
        "update" -> mapOf("validate" to validate.toString())
        "create_pr" -> buildMap {
            if (subject.isNotBlank()) put("title", subject.trim())
            if (body.isNotBlank()) put("body", body.trim())
            put("draft", draft.toString())
        }
        "merge_pr" -> buildMap {
            put("strategy", strategy)
            if (expectedHeadSha.isNotBlank()) put("expected_head_sha", expectedHeadSha)
        }
        else -> emptyMap()
    }

    companion object {
        /** A commit starts from the conversation's title. */
        fun initial(kind: String, card: Card?): GitOperationForm = GitOperationForm(kind, subject = if (kind == "commit") card?.title.orEmpty() else "")

        val PULL_REQUEST_STRATEGIES = listOf("squash" to "Squash", "merge" to "Merge commit", "rebase" to "Rebase")
    }
}

/** What the workspace allows right now; the daemon enforces the same rules. */
data class WorkspaceAvailability(
    val agentActive: Boolean,
    val operationActive: Boolean,
    val state: String,
    val mode: WorkspaceMode,
    val changedFiles: Int,
    val hasCommits: Boolean,
    val hasRemote: Boolean,
    val scmAuthenticated: Boolean,
    val hasPullRequest: Boolean,
    val dirty: Boolean,
    val branch: String,
    val base: String,
    val publish: String,
) {
    val conflicted: Boolean get() = state == "conflicted"
    val hasReviewBranch: Boolean get() = branch.isNotEmpty() && base.isNotEmpty() && branch != base

    /** Where a merge's result ends up, per the board's publish mode. */
    val mergeDestination: String
        get() = if (publish == "push_base") "The validated result is pushed to the configured base remote." else "Runs locally on the Dieter machine · nothing is pushed."

    val allowsMergeFlow: Boolean
        get() = !agentActive && !operationActive && mode == WorkspaceMode.WORKTREE && publish != "pull_request" &&
            !(publish == "push_base" && !hasRemote) && (hasCommits || changedFiles > 0 || conflicted)

    fun allows(kind: String): Boolean {
        if (agentActive || operationActive) return false
        if (conflicted) return kind == "continue_conflict" || kind == "abort_conflict"
        val pushable = hasReviewBranch && hasRemote && hasCommits
        return when (kind) {
            "commit" -> dirty || changedFiles > 0
            "update", "validate" -> true
            "merge_local" -> mode == WorkspaceMode.WORKTREE && hasCommits && changedFiles == 0 && publish != "pull_request"
            "push" -> pushable
            "create_pr" -> pushable && scmAuthenticated && !hasPullRequest && publish != "push_base"
            "refresh_pr", "merge_pr" -> hasPullRequest && scmAuthenticated
            "adopt", "discard" -> mode == WorkspaceMode.WORKTREE
            "cleanup" -> mode == WorkspaceMode.WORKTREE && changedFiles == 0
            else -> false
        }
    }

    companion object {
        private val agentRuntimes = setOf("starting", "running", "working", "streaming", "waiting", "waiting_for_user", "cancelling")

        fun of(card: Card, workspace: Workspace?, changeset: Changeset?, scm: SCMCapabilities?, operation: GitOperation?, submitting: Boolean = false): WorkspaceAvailability {
            val summary = card.workspace
            return WorkspaceAvailability(
                agentActive = card.runtime.trim().lowercase() in agentRuntimes,
                operationActive = GitOperations.isActive(operation) || submitting,
                state = workspace?.state?.ifEmpty { null } ?: summary?.state.orEmpty(),
                mode = WorkspaceMode.parse(workspace?.mode?.ifEmpty { null } ?: summary?.mode?.ifEmpty { null } ?: card.workspace_mode.ifEmpty { "project" }),
                changedFiles = changeset?.files?.size ?: summary?.changed_files ?: 0,
                hasCommits = changeset?.commits?.isNotEmpty() == true || (workspace?.ahead ?: summary?.ahead ?: 0) > 0,
                hasRemote = scm?.push_available == true,
                scmAuthenticated = scm?.authenticated == true,
                hasPullRequest = (card.pull_request?.number ?: 0) > 0,
                dirty = workspace?.dirty == true,
                branch = workspace?.branch?.ifEmpty { null } ?: summary?.branch.orEmpty(),
                base = workspace?.base_branch?.ifEmpty { null } ?: summary?.base_branch.orEmpty(),
                publish = workspace?.remote_publish_mode?.ifEmpty { null } ?: card.remote_publish_mode.ifEmpty { "manual" },
            )
        }
    }
}

object PullRequests {
    /** Why merging the pull request is blocked, or null. */
    fun mergeBlockedReason(pr: PullRequestSummary): String? = when {
        !pr.state.equals("open", ignoreCase = true) -> "already ${pr.state.lowercase()}"
        pr.draft -> "draft"
        pr.checks_state.equals("pending", ignoreCase = true) || pr.checks_state.equals("running", ignoreCase = true) -> "waiting on checks"
        pr.checks_state.equals("failure", ignoreCase = true) || pr.checks_state.equals("failed", ignoreCase = true) -> "checks failed"
        !pr.mergeable -> "not mergeable"
        else -> null
    }

    /** "Draft" for an open draft, else the state: "Open", "Merged", "Closed". */
    fun stateLabel(pr: PullRequestSummary): String = if (pr.draft && pr.state == "open") "Draft" else pr.state.replaceFirstChar { it.uppercase() }

    fun canAskAgent(pr: PullRequestSummary): Boolean = pr.state.equals("open", ignoreCase = true) &&
        (pr.checks_state.equals("failure", ignoreCase = true) || pr.checks_state.equals("failed", ignoreCase = true) || pr.review_decision.equals("changes_requested", ignoreCase = true))
}

/** The workspace badge on board cards. */
data class WorkspaceBadge(val title: String, val accessibilityLabel: String, val conflicted: Boolean) {
    companion object {
        fun of(card: Card): WorkspaceBadge? {
            val summary = card.workspace
            val rawMode = summary?.mode?.ifBlank { null } ?: card.workspace_mode
            if (rawMode.isBlank()) return null
            val mode = WorkspaceMode.parse(rawMode.trim())
            val branch = (summary?.branch?.ifBlank { null } ?: card.workspace_branch).trim()
            val conflicted = summary?.state == "conflicted"
            val pr = card.pull_request?.number?.takeIf { it > 0 }
            val changed = summary?.changed_files ?: 0
            val title = when {
                conflicted -> "Conflicts"
                pr != null -> "PR #$pr"
                changed > 0 -> "$changed changed"
                else -> branch.ifEmpty { if (mode == WorkspaceMode.WORKTREE) "Worktree" else "Project" }
            }
            val ahead = summary?.ahead ?: 0
            val behind = summary?.behind ?: 0
            val parts = listOfNotNull(
                if (mode == WorkspaceMode.WORKTREE) "Worktree" else "Project directory",
                branch.ifEmpty { null },
                if (ahead > 0 || behind > 0) "$ahead ahead, $behind behind" else null,
                pr?.let { "PR #$it" },
            )
            return WorkspaceBadge(title, "Workspace: " + parts.joinToString(" · "), conflicted)
        }
    }
}

/** Editable validation command: argv one per line, environment as KEY=VALUE lines. */
data class ValidationCommandDraft(
    val name: String = "",
    val executable: String = "",
    val arguments: String = "",
    val workingDirectory: String = "",
    val environment: String = "",
    val timeoutSeconds: String = "600",
) {
    fun toCommand(): ValidationCommand = ValidationCommand(
        name = name.trim(), executable = executable.trim(),
        arguments = arguments.split('\n').filter { it.isNotEmpty() },
        working_directory = workingDirectory.trim(),
        environment = environment.split('\n').filter { it.isNotBlank() }.associate { it.substringBefore('=') to it.substringAfter('=') },
        timeout_seconds = timeoutSeconds.trim().toIntOrNull() ?: 0,
    )

    companion object {
        fun from(command: ValidationCommand) = ValidationCommandDraft(
            name = command.name, executable = command.executable, arguments = command.arguments.joinToString("\n"),
            workingDirectory = command.working_directory,
            environment = command.environment.entries.sortedBy { it.key }.joinToString("\n") { "${it.key}=${it.value}" },
            timeoutSeconds = command.timeout_seconds.toString(),
        )

        /** The first problem in [drafts], or null. */
        fun problem(drafts: List<ValidationCommandDraft>): String? {
            for (draft in drafts) {
                if (draft.executable.isBlank()) return "Every validation command needs an executable."
                val timeout = draft.timeoutSeconds.trim().toIntOrNull()
                if (timeout == null || timeout !in 0..3600) return "Validation timeout must be a number from 0 to 3600."
                val directory = draft.workingDirectory.trim().replace('\\', '/')
                if (directory.startsWith("/") || directory.split('/').any { it == ".." }) return "Validation working directories must stay inside the workspace."
                if (draft.environment.split('\n').any { line -> line.isNotBlank() && (line.indexOf('=') <= 0 || '\u0000' in line) }) {
                    return "Environment entries must use KEY=VALUE, one per line."
                }
            }
            return null
        }
    }
}

enum class StatusTone { DANGER, SUCCESS, NEUTRAL, WARNING, ACTIVE }

object WorkspaceStatus {
    /** A one-line state for the changes view, most important first. */
    fun line(workspace: Workspace?, changeset: Changeset?): String? = status(workspace, changeset)?.first

    /** The line and how it should read. */
    fun status(workspace: Workspace?, changeset: Changeset?): Pair<String, StatusTone>? = when {
        workspace?.state == "conflicted" -> "Conflicted" to StatusTone.DANGER
        workspace?.state == "cleanup_pending" -> "Merged · cleanup pending" to StatusTone.SUCCESS
        workspace?.state == "provisioning" || workspace?.state == "reserved" -> "Provisioning" to StatusTone.NEUTRAL
        workspace?.state in setOf("orphaned", "recovery_required", "failed") -> "Needs attention · ${workspace?.state}" to StatusTone.WARNING
        changeset?.volatile == true -> "Agent is working — live view" to StatusTone.ACTIVE
        workspace?.dirty == true -> "Uncommitted changes" to StatusTone.WARNING
        else -> null
    }

    /** "3 files · 2 commits · +40 −12". */
    fun summary(changes: Changeset): String =
        "${changes.files.size} file${if (changes.files.size == 1) "" else "s"} · " +
            "${changes.commits.size} commit${if (changes.commits.size == 1) "" else "s"} · +${changes.additions} −${changes.deletions}"

    fun conflict(conflict: com.dbpprt.dieter.api.v1.GitConflict): String = "${conflict.path} · ${conflict.hunk_count} hunk${if (conflict.hunk_count == 1) "" else "s"}"

    /** The workspace can change until the first message is sent. */
    fun settingsEditable(card: Card): Boolean = card.initial_prompt_sent_at.isBlank()

    /** A finished board card moves to Done by default; a chat has no lane. */
    fun movesToDone(card: Card): Boolean = card.scope != "chat"

    /** Asks the agent to address review comments, one line per comment. */
    fun reviewPrompt(comments: List<com.dbpprt.dieter.api.v1.ChangeComment>): String =
        "Please address these review comments:\n" + comments.joinToString("\n") { comment ->
            "- ${comment.path}${if (comment.line > 0) ":${comment.line}" else ""} — ${comment.body.trim()}"
        }

    fun conflictPrompt(conflicts: List<com.dbpprt.dieter.api.v1.GitConflict>): String =
        "Please resolve the merge conflicts in this workspace:\n" + conflicts.joinToString("\n") { "- ${it.path} (${it.hunk_count} ${if (it.hunk_count == 1) "hunk" else "hunks"})" } +
            "\nResolve the conflict markers, run validation, and report back."

    fun agentBusy(card: Card): Boolean = Runtimes.blocksWorkspace(card)
}

/** Where review comments sit in a diff. */
object ReviewComments {
    /** A diff line's anchor: a deletion on the old side, anything else on the new; null for lines without a number. */
    fun anchor(line: DiffLine): Pair<String, Int>? =
        if (line.kind == DiffLineKind.DELETION) line.oldLine?.let { "old" to it } else line.newLine?.let { "new" to it }

    /** The comments on [path], by anchor. */
    fun byLine(comments: List<com.dbpprt.dieter.api.v1.ChangeComment>, path: String?): Map<Pair<String, Int>, List<com.dbpprt.dieter.api.v1.ChangeComment>> =
        comments.filter { it.path == path }.groupBy { it.side to it.line }
}

/** Durable Git operation kinds accepted by StartGitOperation. */
object GitOperationKinds {
    const val STAGE = "stage"
    const val UNSTAGE = "unstage"
    const val DISCARD_CHANGES = "discard_changes"
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
    const val ADOPT = "adopt"
    const val CLEANUP = "cleanup"
    const val DISCARD = "discard"
}

/** How a changed file is shown: its status badge and title, name, and directory. */
object ChangedFiles {
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

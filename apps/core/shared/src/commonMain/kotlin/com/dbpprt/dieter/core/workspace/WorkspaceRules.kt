package com.dbpprt.dieter.core.workspace

import com.dbpprt.dieter.api.v1.Card
import com.dbpprt.dieter.api.v1.ChangeComment
import com.dbpprt.dieter.api.v1.Changeset
import com.dbpprt.dieter.api.v1.GitConflict
import com.dbpprt.dieter.api.v1.GitOperation
import com.dbpprt.dieter.api.v1.GitOperationLogEntry
import com.dbpprt.dieter.api.v1.PullRequestSummary
import com.dbpprt.dieter.api.v1.SCMCapabilities
import com.dbpprt.dieter.api.v1.ValidationCommand
import com.dbpprt.dieter.api.v1.Workspace
import com.dbpprt.dieter.core.board.Cards
import com.dbpprt.dieter.core.composition.WorkspaceMode
import com.dbpprt.dieter.core.presentation.Counts

object GitOperations {
    /** An operation stopped on a conflict: the workspace is conflicted until it is continued or aborted. */
    const val WAITING = "waiting_for_resolution"
    val ACTIVE = setOf("queued", "running", WAITING)
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
    fun cancelable(operation: GitOperation?): Boolean = isActive(operation) && operation?.status != WAITING

    /** The operation strip shows an operation while it is active and after it failed. */
    fun visible(operation: GitOperation?): Boolean = isActive(operation) || failed(operation)

    /** A failed operation opens its output. */
    fun failed(operation: GitOperation?): Boolean = operation?.status == "failed"

    fun statusLabel(operation: GitOperation): String = operation.status.replace('_', ' ').replaceFirstChar { it.uppercase() }

    /** What an operation form explains before it starts. */
    fun description(kind: String, baseBranch: String): String? = when (kind) {
        "commit" -> "Creates a commit from the current working changes."
        "update" -> "Fast-forwards the project directory when it is on $baseBranch; otherwise rebases the checked-out review branch onto the latest $baseBranch."
        "validate" -> "Runs the project's validation commands in order on the Dieter machine."
        "merge_local" -> "Integrates this workspace into $baseBranch locally, in an isolated integration worktree."
        "push" -> "Pushes the conversation branch to the configured remote. Nothing is merged."
        "create_pr" -> "The branch is pushed first; an existing open PR is reused."
        "refresh_pr" -> "Refreshes the state, checks, review decision, and head and base revisions from the provider."
        "merge_pr" -> "The merge is rejected if the remote branch moved past the reviewed revision."
        "continue_conflict" -> "Continue only after every conflict marker has been resolved and the files have been saved."
        "abort_conflict" -> "Aborts the paused rebase or merge and restores the workspace to its previous ready state."
        "adopt" -> "Moves this workspace, its branch, recovery history, and terminal ownership to another unstarted conversation."
        "cleanup" -> "Removes the workspace only when its work is clean and safely integrated. Dieter-managed branches are deleted."
        "discard" -> "Removes this workspace and its managed branch, including uncommitted work."
        else -> null
    }

    /** What a form for [kind] collects, in order. */
    fun fields(kind: String): List<GitFormField> = when (kind) {
        GitOperationKinds.COMMIT -> listOf(GitFormField.SUBJECT, GitFormField.BODY, GitFormField.STAGE_ALL)
        GitOperationKinds.UPDATE -> listOf(GitFormField.FETCH, GitFormField.VALIDATE)
        GitOperationKinds.MERGE_LOCAL -> listOf(GitFormField.STRATEGY, GitFormField.SUBJECT, GitFormField.VALIDATE)
        GitOperationKinds.PUSH -> listOf(GitFormField.FORCE_WITH_LEASE, GitFormField.EXPECTED_REMOTE_SHA)
        GitOperationKinds.CREATE_PR -> listOf(GitFormField.SUBJECT, GitFormField.BODY, GitFormField.PUSH, GitFormField.DRAFT)
        GitOperationKinds.MERGE_PR -> listOf(GitFormField.STRATEGY)
        GitOperationKinds.CONTINUE_CONFLICT -> listOf(GitFormField.VALIDATE)
        GitOperationKinds.ADOPT -> listOf(GitFormField.TARGET_CARD_ID)
        else -> emptyList()
    }

    /** How a form for [kind] words its inputs. */
    fun copy(kind: String): GitFormCopy = GitFormCopy(
        subject = when (kind) {
            GitOperationKinds.CREATE_PR -> "Pull request title"
            GitOperationKinds.MERGE_LOCAL -> "Squash commit subject"
            else -> "Commit subject"
        },
        subjectPlaceholder = when (kind) {
            GitOperationKinds.CREATE_PR -> "Summarize the proposed change"
            GitOperationKinds.MERGE_LOCAL -> "Summarize the integrated work"
            else -> "Summarize the change"
        },
        bodyPlaceholder = if (kind == GitOperationKinds.CREATE_PR) "Explain what changed and how it was verified" else "Optional commit body",
        validate = when (kind) {
            GitOperationKinds.UPDATE -> "Run project validation after rebasing"
            GitOperationKinds.MERGE_LOCAL -> "Validate the isolated integration result"
            GitOperationKinds.CONTINUE_CONFLICT -> "Run validation after continuing"
            else -> "Run validation"
        },
    )

    /** The caution a form for [kind] shows below its inputs, or null. */
    fun notice(kind: String): GitFormNotice? = when (kind) {
        GitOperationKinds.DISCARD -> GitFormNotice(
            "Recovery is created first",
            "Dieter keeps recovery artifacts (branch bundle, patches, untracked archive) on the Dieter machine before removing this workspace. " +
                "Its uncommitted changes and managed branch will no longer remain in active use.",
            StatusTone.DANGER,
        )
        GitOperationKinds.CLEANUP -> GitFormNotice(
            "Clean, integrated work only", "Cleanup stops if the branch still has changes or has not been integrated.", StatusTone.SUCCESS,
        )
        GitOperationKinds.MERGE_PR -> GitFormNotice(
            "Head revision is protected",
            "The provider verifies that the pull request head still matches this workspace before merging.",
            StatusTone.SUCCESS,
        )
        GitOperationKinds.CONTINUE_CONFLICT -> GitFormNotice(
            "Confirm conflicts are resolved",
            "Continue only after every conflict marker has been resolved and the files have been saved.",
            StatusTone.WARNING,
        )
        else -> null
    }

    /** The merge strategies a form for [kind] offers, as (wire value, title); the first is the default. */
    fun strategies(kind: String): List<Pair<String, String>> = when (kind) {
        GitOperationKinds.MERGE_LOCAL -> MergeStrategy.entries.map { it.wire to it.title }
        GitOperationKinds.MERGE_PR -> GitOperationForm.PULL_REQUEST_STRATEGIES
        else -> emptyList()
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

/** An input of a Git operation form. */
enum class GitFormField { SUBJECT, BODY, STAGE_ALL, FETCH, VALIDATE, STRATEGY, DRAFT, PUSH, FORCE_WITH_LEASE, EXPECTED_REMOTE_SHA, TARGET_CARD_ID }

/** An operation form's labels, in sentence case, with placeholders and help. */
data class GitFormCopy(
    val subject: String,
    val subjectPlaceholder: String,
    val body: String = "Description",
    val bodyPlaceholder: String,
    val stageAll: String = "Stage all changes",
    val fetch: String = "Fetch the configured base remote",
    val validate: String,
    val strategy: String = "Merge strategy",
    val draft: String = "Create as draft",
    val push: String = "Push branch before creating",
    val forceWithLease: String = "Force with lease",
    val expectedRemoteSha: String = "Expected remote head",
    val expectedRemoteShaPlaceholder: String = "Commit SHA",
    val expectedRemoteShaHelp: String = "The push is rejected if the remote branch no longer matches this exact revision.",
    val targetCardId: String = "Destination conversation ID",
    val targetCardIdPlaceholder: String = "c_…",
)

/** A caution below an operation form's inputs. */
data class GitFormNotice(val title: String, val detail: String, val tone: StatusTone)

/**
 * What an operation form collects before starting [kind]; [GitOperations.fields]
 * says which inputs a kind shows. [subject] is a commit's subject, a local
 * squash merge's commit subject, or a pull request's title.
 */
data class GitOperationForm(
    val kind: String,
    val subject: String = "",
    val body: String = "",
    val stageAll: Boolean = true,
    val validate: Boolean = true,
    val draft: Boolean = false,
    /** The merge strategy: a local merge's ([MergeStrategy]) or a pull request's ([PULL_REQUEST_STRATEGIES]). */
    val strategy: String = "squash",
    /** Fetch the base remote before updating. */
    val fetch: Boolean = true,
    /** Push the branch before creating a pull request. */
    val push: Boolean = true,
    val forceWithLease: Boolean = false,
    /** The remote head a forced push expects. */
    val expectedRemoteSha: String = "",
    /** The unstarted conversation that adopts the workspace. */
    val targetCardId: String = "",
) {
    /**
     * Whether the form can start: a commit and a pull request need a
     * subject, adopting needs a conversation, and a forced push needs the
     * remote head it expects.
     */
    /** Whether [field] shows: a local merge's subject only for a squash, the expected remote head only for a forced push. */
    fun shows(field: GitFormField): Boolean = when (field) {
        GitFormField.SUBJECT -> kind != GitOperationKinds.MERGE_LOCAL || strategy == "squash"
        GitFormField.EXPECTED_REMOTE_SHA -> forceWithLease
        else -> true
    }

    val ready: Boolean get() = when (kind) {
        GitOperationKinds.COMMIT, GitOperationKinds.CREATE_PR -> subject.isNotBlank()
        GitOperationKinds.ADOPT -> targetCardId.isNotBlank()
        GitOperationKinds.PUSH -> !forceWithLease || expectedRemoteSha.isNotBlank()
        else -> true
    }

    /**
     * The operation's parameters; a pull request merge is pinned to the
     * reviewed head. A conflict's operation ID is the daemon's to fill in.
     */
    fun parameters(expectedHeadSha: String = ""): Map<String, String> = when (kind) {
        GitOperationKinds.COMMIT -> mapOf("subject" to subject.trim(), "body" to body.trim(), "stage_all" to stageAll.toString())
        GitOperationKinds.UPDATE -> mapOf("fetch" to fetch.toString(), "validate" to validate.toString())
        GitOperationKinds.MERGE_LOCAL -> buildMap {
            put("strategy", strategy)
            if (subject.isNotBlank()) put("subject", subject.trim())
            put("validate", validate.toString())
        }
        GitOperationKinds.PUSH -> buildMap {
            put("force_with_lease", forceWithLease.toString())
            if (forceWithLease) put("expected_remote_sha", expectedRemoteSha.trim())
        }
        GitOperationKinds.CREATE_PR -> buildMap {
            if (subject.isNotBlank()) put("title", subject.trim())
            if (body.isNotBlank()) put("body", body.trim())
            put("draft", draft.toString())
            put("push", push.toString())
        }
        GitOperationKinds.MERGE_PR -> buildMap {
            put("strategy", strategy)
            if (expectedHeadSha.isNotBlank()) put("expected_head_sha", expectedHeadSha)
        }
        GitOperationKinds.CONTINUE_CONFLICT -> mapOf("validate" to validate.toString())
        GitOperationKinds.ADOPT -> mapOf("target_card_id" to targetCardId.trim())
        else -> emptyMap()
    }

    companion object {
        /** A form for [kind] filled from [card]: see the other [initial]. */
        fun initial(kind: String, card: Card?): GitOperationForm =
            initial(kind, card?.title.orEmpty(), card?.initial_prompt.orEmpty(), card?.pull_request?.head_sha.orEmpty())

        /**
         * A commit, a local merge, and a pull request start from the
         * conversation's [title]; a commit's and a pull request's body from its
         * [prompt]; a forced push expects the pull request's [headSha].
         */
        fun initial(kind: String, title: String, prompt: String, headSha: String): GitOperationForm = GitOperationForm(
            kind,
            subject = if (kind == GitOperationKinds.COMMIT || kind == GitOperationKinds.CREATE_PR || kind == GitOperationKinds.MERGE_LOCAL) title else "",
            body = if (kind == GitOperationKinds.COMMIT || kind == GitOperationKinds.CREATE_PR) prompt else "",
            strategy = GitOperations.strategies(kind).firstOrNull()?.first ?: "squash",
            expectedRemoteSha = if (kind == GitOperationKinds.PUSH) headSha else "",
        )

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
    /** An operation stopped on a conflict; it is not active, the workspace is conflicted. */
    val waitingForResolution: Boolean = false,
    /** Why the pull request cannot merge ([PullRequests.mergeBlockedReason]), or null. */
    val pullRequestBlocked: String? = null,
) {
    val conflicted: Boolean get() = state == "conflicted" || waitingForResolution
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
            "refresh_pr" -> hasPullRequest && scmAuthenticated
            "merge_pr" -> hasPullRequest && scmAuthenticated && pullRequestBlocked == null
            "adopt", "discard" -> mode == WorkspaceMode.WORKTREE
            "cleanup" -> mode == WorkspaceMode.WORKTREE && changedFiles == 0
            else -> false
        }
    }

    companion object {
        private val agentRuntimes = setOf("starting", "running", "working", "streaming", "waiting", "waiting_for_user", "cancelling")

        /** [submitting]: a start is in flight or the review waits for a refresh after an ambiguous one. */
        fun of(card: Card, workspace: Workspace?, changeset: Changeset?, scm: SCMCapabilities?, operation: GitOperation?, submitting: Boolean = false): WorkspaceAvailability {
            val summary = card.workspace
            val waiting = operation?.status == GitOperations.WAITING
            return WorkspaceAvailability(
                agentActive = card.runtime.trim().lowercase() in agentRuntimes,
                operationActive = (GitOperations.isActive(operation) && !waiting) || submitting,
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
                waitingForResolution = waiting,
                pullRequestBlocked = card.pull_request?.takeIf { it.number > 0 }?.let(PullRequests::mergeBlockedReason),
            )
        }
    }
}

/** One fact about a pull request: its checks or its review. */
data class PullRequestSignal(val id: String, val text: String, val tone: StatusTone)

/** A pull request as the review shows it. */
data class PullRequestView(
    val number: Int,
    val url: String,
    val stateLabel: String,
    val stateTone: StatusTone,
    val signals: List<PullRequestSignal>,
    /** Why merging is blocked ("waiting on checks"), or null. */
    val mergeBlockedReason: String?,
    val canAskAgent: Boolean,
    /** The message that asks the agent to address the review. */
    val askAgentPrompt: String,
    /** RFC 3339. */
    val lastSyncedAt: String,
)

/**
 * Pull request state as the daemon reports it: checks are "passed",
 * "running", or "failed" ("pending", "failure", and "success" are read as
 * the same), states and review decisions are lowercase.
 */
object PullRequests {
    /** "passed", "running", "failed", or "" when unknown. */
    fun checks(pr: PullRequestSummary): String = when (pr.checks_state.lowercase()) {
        "passed", "success" -> "passed"
        "running", "pending" -> "running"
        "failed", "failure" -> "failed"
        else -> ""
    }

    private fun open(pr: PullRequestSummary): Boolean = pr.state.equals("open", ignoreCase = true)

    /** Why merging the pull request is blocked, or null. */
    fun mergeBlockedReason(pr: PullRequestSummary): String? = when {
        !open(pr) -> "already ${pr.state.lowercase()}"
        pr.draft -> "draft"
        checks(pr) == "running" -> "waiting on checks"
        checks(pr) == "failed" -> "checks failed"
        !pr.mergeable -> "not mergeable"
        else -> null
    }

    /** "Merged", "Closed", else "Draft" for a draft and "Open". */
    fun stateLabel(pr: PullRequestSummary): String = when (pr.state.lowercase()) {
        "merged" -> "Merged"
        "closed" -> "Closed"
        else -> if (pr.draft) "Draft" else "Open"
    }

    fun stateTone(pr: PullRequestSummary): StatusTone = when (pr.state.lowercase()) {
        "merged" -> StatusTone.NEUTRAL
        "closed" -> StatusTone.DANGER
        else -> if (pr.draft) StatusTone.NEUTRAL else StatusTone.SUCCESS
    }

    /** "checks passed/running/failed", then "approved", "changes requested", or "review requested". */
    fun signals(pr: PullRequestSummary): List<PullRequestSignal> = buildList {
        when (checks(pr)) {
            "passed" -> add(PullRequestSignal("checks", "checks passed", StatusTone.SUCCESS))
            "running" -> add(PullRequestSignal("checks", "checks running", StatusTone.ACTIVE))
            "failed" -> add(PullRequestSignal("checks", "checks failed", StatusTone.DANGER))
        }
        when (pr.review_decision.lowercase()) {
            "approved" -> add(PullRequestSignal("review", "approved", StatusTone.SUCCESS))
            "changes_requested" -> add(PullRequestSignal("review", "changes requested", StatusTone.WARNING))
            "review_required" -> add(PullRequestSignal("review", "review requested", StatusTone.WARNING))
        }
    }

    /** An open pull request with failing checks or requested changes can go back to the agent. */
    fun canAskAgent(pr: PullRequestSummary): Boolean = open(pr) && (checks(pr) == "failed" || pr.review_decision.equals("changes_requested", ignoreCase = true))

    /** Asks the agent to address what holds the pull request up. */
    fun askAgentPrompt(pr: PullRequestSummary): String {
        val reasons = listOfNotNull(
            "failing checks".takeIf { checks(pr) == "failed" },
            "requested review changes".takeIf { pr.review_decision.equals("changes_requested", ignoreCase = true) },
        )
        val cause = if (reasons.isEmpty()) "the open review feedback" else reasons.joinToString(" and ")
        return "Pull request #${pr.number} needs attention: please address $cause, push the fixes to the pull request branch, and summarize what changed."
    }

    /** [pr] as the review shows it; null without a pull request. */
    fun view(pr: PullRequestSummary?): PullRequestView? {
        if (pr == null || pr.number <= 0) return null
        return PullRequestView(
            number = pr.number, url = pr.url, stateLabel = stateLabel(pr), stateTone = stateTone(pr), signals = signals(pr),
            mergeBlockedReason = mergeBlockedReason(pr), canAskAgent = canAskAgent(pr), askAgentPrompt = askAgentPrompt(pr), lastSyncedAt = pr.last_synced_at,
        )
    }
}

/**
 * The workspace badge on board cards and chat rows ([title]); a
 * conversation's header shows [fullTitle], the conflict or the branch.
 */
data class WorkspaceBadge(val title: String, val accessibilityLabel: String, val conflicted: Boolean, val fullTitle: String = title) {
    companion object {
        /** The badge of [card]'s workspace; null when the card names no workspace mode. */
        fun of(card: Card): WorkspaceBadge? {
            val summary = card.workspace
            val rawMode = summary?.mode?.ifBlank { null } ?: card.workspace_mode
            if (rawMode.isBlank()) return null
            val mode = WorkspaceMode.parse(rawMode.trim())
            val branch = (summary?.branch?.ifBlank { null } ?: card.workspace_branch).trim()
            val conflicted = summary?.state == "conflicted"
            val pr = card.pull_request?.number?.takeIf { it > 0 }
            val changed = summary?.changed_files ?: 0
            val named = branch.ifEmpty { mode.shortTitle }
            val title = when {
                conflicted -> "Conflicts"
                pr != null -> "PR #$pr"
                changed > 0 -> "$changed changed"
                else -> named
            }
            val ahead = summary?.ahead ?: 0
            val behind = summary?.behind ?: 0
            val parts = listOfNotNull(
                mode.title,
                branch.ifEmpty { null },
                if (ahead > 0 || behind > 0) "$ahead ahead, $behind behind" else null,
                pr?.let { "PR #$it" },
            )
            return WorkspaceBadge(title, "Workspace: " + parts.joinToString(" · "), conflicted, fullTitle = if (conflicted) "Conflicts" else named)
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

    /**
     * A workspace's [state] in words: "Ready", "Conflicted", "Provisioning"
     * (also while reserved), "Cleanup pending", …; another state reads as
     * written with its first letter capitalized. "" for none.
     */
    fun stateLabel(state: String): String = when (state) {
        "reserved" -> "Provisioning"
        else -> state.replace('_', ' ').replaceFirstChar { it.uppercaseChar() }
    }

    /** "3 files · 2 commits · +40 −12". */
    fun summary(changes: Changeset): String =
        "${Counts.of(changes.files.size, "file")} · ${Counts.of(changes.commits.size, "commit")} · +${changes.additions} −${changes.deletions}"

    fun conflict(conflict: GitConflict): String = "${conflict.path} · ${Counts.of(conflict.hunk_count, "hunk")}"

    /** The workspace can change until the first message is sent. */
    fun settingsEditable(card: Card): Boolean = card.initial_prompt_sent_at.isBlank()

    /** A finished board card moves to Done by default; an unfiled chat has no lane. */
    fun movesToDone(card: Card): Boolean = !Cards.isChat(card)

    /** Asks the agent to address review comments, one line per comment. */
    fun reviewPrompt(comments: List<ChangeComment>): String =
        "Please address these review comments:\n" + comments.joinToString("\n") { comment ->
            "- ${comment.path}${if (comment.line > 0) ":${comment.line}" else ""} — ${comment.body.trim()}"
        }

    /** Asks the agent to resolve the conflicts, one line per file when they are known. */
    fun conflictPrompt(conflicts: List<GitConflict>): String =
        if (conflicts.isEmpty()) {
            "Please resolve the merge conflicts in this workspace.\nResolve the conflict markers, run validation, and report back."
        } else {
            "Please resolve the merge conflicts in this workspace:\n" + conflicts.joinToString("\n") { "- ${it.path} (${Counts.of(it.hunk_count, "hunk")})" } +
                "\nResolve the conflict markers, run validation, and report back."
        }

    /** "2 files conflict with main", or "This workspace conflicts with main" while the files are unknown. */
    fun conflictTitle(conflictedFiles: Int, base: String): String =
        if (conflictedFiles > 0) "${Counts.of(conflictedFiles, "file")} ${Counts.word(conflictedFiles, "conflicts", "conflict")} with $base" else "This workspace conflicts with $base"
}

/** Where review comments sit in a diff. */
object ReviewComments {
    /** A diff line's anchor: a deletion on the old side, anything else on the new; null for lines without a number. */
    fun anchor(line: DiffLine): Pair<String, Int>? =
        if (line.kind == DiffLineKind.DELETION) line.oldLine?.let { "old" to it } else line.newLine?.let { "new" to it }

    /** The comments on [path], by anchor. */
    fun byLine(comments: List<ChangeComment>, path: String?): Map<Pair<String, Int>, List<ChangeComment>> =
        comments.filter { it.path == path }.groupBy { it.side to it.line }
}

/** Durable Git operation kinds accepted by StartGitOperation. */
object Commits {
    /** A commit's abbreviated hash: the daemon's short form, else the full hash, at most seven characters. */
    fun shortSha(shortSha: String, sha: String): String = shortSha.ifBlank { sha }.take(7)
}

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

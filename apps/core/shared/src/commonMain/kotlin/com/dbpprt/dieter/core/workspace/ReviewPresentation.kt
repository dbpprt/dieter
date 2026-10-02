package com.dbpprt.dieter.core.workspace

import com.dbpprt.dieter.api.v1.Card
import com.dbpprt.dieter.api.v1.Changeset
import com.dbpprt.dieter.api.v1.GitOperation
import com.dbpprt.dieter.api.v1.Workspace
import com.dbpprt.dieter.core.presentation.Counts

/** One line of the merge checklist; [at] (RFC 3339) is when its detail happened, for the platform to word as an age. */
data class MergeReadinessItem(val id: String, val tone: StatusTone, val text: String, val detail: String = "", val at: String = "")

/** A finished validation: "go test passed", "2 validations failed". */
data class ValidationSummary(val text: String, val passed: Boolean, val at: String)

/** A merge strategy as the merge sheet offers it. */
data class MergeStrategyOption(val strategy: String, val title: String, val caption: String)

/**
 * The checklist before merging into the base: conflicts block, a finished
 * validation, a base that moved, and uncommitted changes (committed first)
 * are notes.
 */
data class MergeReadiness(
    val items: List<MergeReadinessItem>,
    val dirty: Boolean,
    /** "Merge 3 files", or "Merge into main" when no file changed. */
    val mergeTitle: String,
    val validation: ValidationSummary?,
    val strategies: List<MergeStrategyOption>,
    /** The last local merge failed; updating from the base may resolve it. */
    val mergeFailed: Boolean,
) {
    val blocked: Boolean get() = items.any { it.tone == StatusTone.DANGER }

    /** Uncommitted changes are committed before the merge. */
    val commitsFirst: Boolean get() = dirty

    companion object {
        /** [base] falls back to "base". */
        fun of(workspace: Workspace?, changeset: Changeset?, operation: GitOperation?, cardId: String?, base: String): MergeReadiness {
            val conflictedFiles = operation?.conflicts?.size ?: 0
            val dirty = workspace?.dirty == true
            val behind = workspace?.behind ?: 0
            val validation = validation(operation, cardId)
            val items = buildList {
                if (workspace?.state == "conflicted" || conflictedFiles > 0) {
                    val count = maxOf(conflictedFiles, 1)
                    add(MergeReadinessItem("conflicts", StatusTone.DANGER, WorkspaceStatus.conflictTitle(count, base), "Merge is blocked until conflicts are resolved."))
                } else {
                    add(MergeReadinessItem("conflicts", StatusTone.SUCCESS, "No conflicts with $base", "checked just now"))
                }
                validation?.let {
                    add(MergeReadinessItem("validation", if (it.passed) StatusTone.SUCCESS else StatusTone.WARNING, "${it.text} on the workspace", at = it.at))
                }
                if (behind > 0) {
                    add(MergeReadinessItem("behind", StatusTone.WARNING, "$base moved · ${Counts.of(behind, "new commit")}", "Update from $base to pick them up before merging."))
                }
                if (dirty) add(MergeReadinessItem("uncommitted", StatusTone.WARNING, "Uncommitted changes will be committed first"))
            }
            val files = changeset?.files?.size ?: 0
            return MergeReadiness(
                items = items,
                dirty = dirty,
                mergeTitle = if (files > 0) "Merge ${Counts.of(files, "file")}" else "Merge into $base",
                validation = validation,
                strategies = strategies(changeset?.commits?.size ?: 0, base),
                mergeFailed = operation != null && operation.kind == GitOperationKinds.MERGE_LOCAL && operation.status == "failed",
            )
        }

        /** The latest finished operation's validation results for [cardId], or null. */
        fun validation(operation: GitOperation?, cardId: String?): ValidationSummary? {
            if (operation == null || operation.card_id != cardId || !GitOperations.isTerminal(operation) || operation.validation_results.isEmpty()) return null
            val results = operation.validation_results
            val passed = results.all { it.exit_code == 0 }
            val name = if (results.size == 1) results.single().name else "${results.size} validations"
            return ValidationSummary("$name ${if (passed) "passed" else "failed"}", passed, operation.finished_at)
        }

        /** What each local merge strategy does with [commits] commits on [base]. */
        fun strategies(commits: Int, base: String): List<MergeStrategyOption> = MergeStrategy.entries.map { strategy ->
            MergeStrategyOption(
                strategy.wire, strategy.title,
                when (strategy) {
                    MergeStrategy.SQUASH -> if (commits > 1) "$commits commits become one on $base." else "The work lands as a single commit on $base."
                    MergeStrategy.MERGE_COMMIT -> "Keeps every commit and adds a merge commit."
                    MergeStrategy.FAST_FORWARD -> "Moves $base forward without a new commit."
                },
            )
        }
    }
}

/**
 * What a conversation's review shows beyond its raw state: the operation
 * strip, the conflict banner and its hand-off prompt, the pull request, and
 * the merge checklist. [card] is the reviewed card, when known.
 */
data class ReviewPresentation(
    val operationVisible: Boolean,
    val operationCancelable: Boolean,
    /** The base branch, "base" when unknown. */
    val base: String,
    val conflictTitle: String,
    val conflictPrompt: String,
    /** A merge moves the card to Done by default. */
    val movesToDone: Boolean,
    val pullRequest: PullRequestView?,
    val mergeReadiness: MergeReadiness,
) {
    companion object {
        fun of(view: WorkspaceReviewView, card: Card?): ReviewPresentation {
            val base = view.workspace?.base_branch?.ifEmpty { null } ?: card?.workspace?.base_branch?.ifEmpty { null } ?: "base"
            val conflicts = view.operation?.conflicts.orEmpty()
            return ReviewPresentation(
                operationVisible = GitOperations.visible(view.operation),
                operationCancelable = GitOperations.cancelable(view.operation),
                base = base,
                conflictTitle = WorkspaceStatus.conflictTitle(conflicts.size, base),
                conflictPrompt = WorkspaceStatus.conflictPrompt(conflicts),
                movesToDone = card != null && WorkspaceStatus.movesToDone(card),
                pullRequest = PullRequests.view(card?.pull_request),
                mergeReadiness = MergeReadiness.of(view.workspace, view.changeset, view.operation, view.cardId, base),
            )
        }
    }
}

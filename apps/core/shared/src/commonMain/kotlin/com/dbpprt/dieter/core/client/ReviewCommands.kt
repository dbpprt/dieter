package com.dbpprt.dieter.core.client

import com.dbpprt.dieter.client.v1.GitOperationForm as ClientGitOperationForm
import com.dbpprt.dieter.client.v1.Outcome
import com.dbpprt.dieter.client.v1.ProjectChangesCommand
import com.dbpprt.dieter.client.v1.ProjectWorkspacesCommand
import com.dbpprt.dieter.client.v1.Result
import com.dbpprt.dieter.client.v1.ReviewCommand
import com.dbpprt.dieter.core.client.rules.WorkspaceExports
import com.dbpprt.dieter.core.workspace.ChangeSection
import com.dbpprt.dieter.core.workspace.MergeStrategy
import com.dbpprt.dieter.core.workspace.ProjectChanges
import com.dbpprt.dieter.core.workspace.ProjectChangesView
import com.dbpprt.dieter.core.workspace.ProjectWorkspaces
import com.dbpprt.dieter.core.workspace.WorkspaceReview

/** A form that cannot start yet is refused, with what it lacks. */
private fun ready(form: ClientGitOperationForm) = WorkspaceExports.core(form).also { core ->
    if (!core.ready) invalid(
        when (form.kind) {
            "adopt" -> "Enter the conversation that takes over the workspace."
            "push" -> "Enter the remote head a forced push expects."
            "create_pr" -> "Enter a pull request title."
            else -> "Enter a commit subject."
        },
    )
}

/** The result is a started operation, a comment, the merge outcome, or the review after [command]. */
internal suspend fun WorkspaceReview.execute(command: ReviewCommand): Result {
    command.start?.let { form -> return start(ready(form))?.let { Result(git_operation = it) } ?: Result(review = reviewSlice(view.value, card())) }
    command.add_comment?.let { add ->
        val line = view.value.diffLines.firstOrNull { it.id == add.row_id } ?: invalid("That line is no longer in the diff.")
        return addComment(line, add.body, add.author)?.let { Result(change_comment = it) } ?: Result(review = reviewSlice(view.value, card()))
    }
    command.merge?.let { merge ->
        val strategy = MergeStrategy.entries.firstOrNull { it.wire == merge.strategy } ?: invalid("Choose a merge strategy.")
        return Result(outcome = Outcome(succeeded = mergeFlow(strategy, merge.subject, merge.body, merge.validate, merge.remove_workspace, merge.move_to_done)))
    }
    command.bind?.let { bind(it.card_id.ifEmpty { null }, it.daemon_id.ifEmpty { null }) }
    command.active?.let { setActive(it.on) }
    command.refresh?.let { refresh() }
    command.select?.let { select(it.path.ifEmpty { null }, it.commit.ifEmpty { null }) }
    command.load_more_diff?.let { loadMoreDiff() }
    command.cancel_operation?.let { cancelOperation() }
    command.clear_toast?.let { clearToast() }
    command.layout?.let { setLayout(it.split) }
    return Result(review = reviewSlice(view.value, card()))
}

internal suspend fun ProjectChanges.execute(command: ProjectChangesCommand): Result {
    command.run?.let { form ->
        ready(form)
        return Result(outcome = Outcome(succeeded = run(form.kind, ProjectChangesView.parameters(form.kind, form.subject, form.body, form.path))))
    }
    command.bind?.let { bind(it.project_id.ifEmpty { null }, it.checkout_id.ifEmpty { null }, it.daemon_id.ifEmpty { null }, it.select_first) }
    command.active?.let { setActive(it.on) }
    command.refresh?.let { refresh() }
    command.select?.let { select(it.path, if (it.staged) ChangeSection.STAGED else ChangeSection.UNSTAGED) }
    command.load_more_diff?.let { loadMoreDiff() }
    command.layout?.let { setLayout(it.split) }
    return Result(project_changes = projectChangesSlice(view.value))
}

internal suspend fun ProjectWorkspaces.execute(command: ProjectWorkspacesCommand): Result {
    command.load?.let { load(it.project_id) }
    command.remove?.let { request ->
        val workspace = view.value.workspaces.firstOrNull { it.card_id == request.card_id } ?: invalid("The workspace is no longer listed.")
        remove(workspace, request.discard)
    }
    return Result(project_workspaces = projectWorkspacesSlice(view.value))
}

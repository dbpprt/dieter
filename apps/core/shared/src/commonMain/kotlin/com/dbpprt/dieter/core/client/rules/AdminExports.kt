package com.dbpprt.dieter.core.client.rules

import com.dbpprt.dieter.api.v1.ValidationCommand
import com.dbpprt.dieter.client.v1.AdminChoice
import com.dbpprt.dieter.client.v1.AdminOptions
import com.dbpprt.dieter.client.v1.ValidationDraft
import com.dbpprt.dieter.core.admin.Administration
import com.dbpprt.dieter.core.workspace.ValidationCommandDraft

/** Project and board settings as their forms offer and check them. */
object AdminExports {
    private val options = AdminOptions(
        workflows = Administration.WORKFLOWS.map {
            AdminChoice(id = it, title = Administration.workflowTitle(it), detail = Administration.workflowDetail(it), lanes = Administration.workflowLanes(it))
        },
        publish_modes = Administration.PUBLISH_MODES.map {
            AdminChoice(id = it, title = Administration.publishModeTitle(it), detail = Administration.publishModeDetail(it))
        },
        archive_policies = Administration.ARCHIVE_POLICIES.map { AdminChoice(id = it, title = Administration.archivePolicyTitle(it)) },
        default_board_name = Administration.DEFAULT_BOARD_NAME,
        default_workflow = Administration.DEFAULT_WORKFLOW,
        default_base_remote = Administration.DEFAULT_BASE_REMOTE,
        default_base_branch = Administration.DEFAULT_BASE_BRANCH,
        default_publish_mode = Administration.DEFAULT_PUBLISH_MODE,
        default_archive_policy = Administration.DEFAULT_ARCHIVE_POLICY,
        new_validation = ValidationCommandDraft().wire(),
    )

    /** The workflows, publish modes, and archive policies, in menu order, with each form's defaults. */
    fun options(): AdminOptions = options

    /** [command] as its form edits it. */
    fun validationDraft(command: ValidationCommand): ValidationDraft = ValidationCommandDraft.from(command).wire()

    /** The command [draft] saves as. */
    fun validationCommand(draft: ValidationDraft): ValidationCommand = draft.model().toCommand()

    /** The first problem in [drafts], e.g. "Every validation command needs an executable."; "" when they can save. */
    fun validationProblem(drafts: List<ValidationDraft>): String = ValidationCommandDraft.problem(drafts.map { it.model() }).orEmpty()

    /** A new project needs a folder, a base branch, and valid validation commands. */
    fun canCreateProject(path: String, baseBranch: String, drafts: List<ValidationDraft>): Boolean =
        Administration.canCreateProject(path, baseBranch, drafts.map { it.model() })

    /** The project settings form saves with a name, a base branch, and valid validation commands. */
    fun canSaveProject(name: String, baseBranch: String, drafts: List<ValidationDraft>): Boolean =
        Administration.canSaveProject(name, baseBranch, drafts.map { it.model() })

    private fun ValidationDraft.model() = ValidationCommandDraft(name, executable, arguments, working_directory, environment, timeout_seconds)

    private fun ValidationCommandDraft.wire() = ValidationDraft(name, executable, arguments, workingDirectory, environment, timeoutSeconds)
}

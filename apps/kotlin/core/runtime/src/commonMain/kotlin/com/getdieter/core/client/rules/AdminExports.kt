package com.getdieter.core.client.rules

import com.getdieter.api.v1.ValidationCommand
import com.getdieter.client.v1.AdminChoice
import com.getdieter.client.v1.AdminOptions
import com.getdieter.client.v1.ValidationDraft
import com.getdieter.core.admin.AdminForms
import com.getdieter.core.admin.PromptTemplates
import com.getdieter.core.workspace.ValidationCommandDraft

/** Project and board settings as their forms offer and check them. */
object AdminExports {
    private val options =
        AdminOptions(
            workflows =
                AdminForms.WORKFLOWS.map {
                    AdminChoice(
                        id = it,
                        title = AdminForms.workflowTitle(it),
                        detail = AdminForms.workflowDetail(it),
                        lanes = AdminForms.workflowLanes(it),
                    )
                },
            publish_modes =
                AdminForms.PUBLISH_MODES.map {
                    AdminChoice(
                        id = it,
                        title = AdminForms.publishModeTitle(it),
                        detail = AdminForms.publishModeDetail(it),
                    )
                },
            archive_policies =
                AdminForms.ARCHIVE_POLICIES.map {
                    AdminChoice(id = it, title = AdminForms.archivePolicyTitle(it))
                },
            default_board_name = AdminForms.DEFAULT_BOARD_NAME,
            default_workflow = AdminForms.DEFAULT_WORKFLOW,
            default_base_remote = AdminForms.DEFAULT_BASE_REMOTE,
            default_base_branch = AdminForms.DEFAULT_BASE_BRANCH,
            default_publish_mode = AdminForms.DEFAULT_PUBLISH_MODE,
            default_archive_policy = AdminForms.DEFAULT_ARCHIVE_POLICY,
            new_validation = ValidationCommandDraft().wire(),
        )

    /**
     * The workflows, publish modes, and archive policies, in menu order, with each form's defaults.
     */
    fun options(): AdminOptions = options

    /** [command] as its form edits it. */
    fun validationDraft(command: ValidationCommand): ValidationDraft =
        ValidationCommandDraft.from(command).wire()

    /** The command [draft] saves as. */
    fun validationCommand(draft: ValidationDraft): ValidationCommand = draft.model().toCommand()

    /**
     * The first problem in [drafts], e.g. "Every validation command needs an executable."; "" when
     * they can save.
     */
    fun validationProblem(drafts: List<ValidationDraft>): String =
        ValidationCommandDraft.problem(drafts.map { it.model() }).orEmpty()

    /**
     * The first problem with a project or board prompt [template], e.g. "template is required" or
     * "template must contain {{project.instructions_block}} exactly once"; "" when the daemon
     * accepts it.
     */
    fun promptTemplateProblem(template: String): String =
        PromptTemplates.validate(template, context = true).orEmpty()

    /** A new project needs a folder, a base branch, and valid validation commands. */
    fun canCreateProject(path: String, baseBranch: String, drafts: List<ValidationDraft>): Boolean =
        AdminForms.canCreateProject(path, baseBranch, drafts.map { it.model() })

    /**
     * The project settings form saves with a name, a base branch, and valid validation commands.
     */
    fun canSaveProject(name: String, baseBranch: String, drafts: List<ValidationDraft>): Boolean =
        AdminForms.canSaveProject(name, baseBranch, drafts.map { it.model() })

    private fun ValidationDraft.model() =
        ValidationCommandDraft(
            name,
            executable,
            arguments,
            working_directory,
            environment,
            timeout_seconds,
        )

    private fun ValidationCommandDraft.wire() =
        ValidationDraft(name, executable, arguments, workingDirectory, environment, timeoutSeconds)
}

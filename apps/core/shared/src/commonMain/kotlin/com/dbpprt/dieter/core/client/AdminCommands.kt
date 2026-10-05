package com.dbpprt.dieter.core.client

import com.dbpprt.dieter.api.v1.Card
import com.dbpprt.dieter.client.v1.AdminCommand
import com.dbpprt.dieter.client.v1.Cards
import com.dbpprt.dieter.client.v1.ConflictRecord
import com.dbpprt.dieter.client.v1.Done
import com.dbpprt.dieter.client.v1.Projects
import com.dbpprt.dieter.client.v1.Result
import com.dbpprt.dieter.core.CoreRuntime
import com.dbpprt.dieter.core.composition.WorkspaceMode
import com.dbpprt.dieter.core.workspace.ProjectWorkspaceSettings
import com.dbpprt.dieter.core.workspace.ValidationCommandDraft
import kotlin.coroutines.cancellation.CancellationException
import kotlinx.coroutines.yield

/**
 * Runs an administration command; done when it has no result. A command that changed the workspace
 * returns only after the workspace slice observers were offered the change, so a client that acts
 * on the result (selects a new board, say) already shows it.
 */
internal suspend fun CoreRuntime.administer(command: AdminCommand): Result {
    val before = workspace.state.value
    val result = runAdministration(command)
    // Slice observers collect on this confined dispatcher, resumed in order: yielding lets them
    // deliver first.
    if (workspace.state.value !== before) yield()
    return result
}

private suspend fun CoreRuntime.runAdministration(command: AdminCommand): Result {
    command.create_project?.let {
        return Result(
            created_project =
                admin.createProject(
                    it.daemon_id,
                    it.path,
                    it.name,
                    it.create,
                    it.board_name.ifEmpty { "Main" },
                    it.workflow.ifEmpty { "review" },
                    it.base_remote,
                    it.base_branch,
                    it.validation,
                )
        )
    }
    command.update_project?.let {
        return Result(
            project =
                admin.updateProject(
                    it.project_id,
                    it.name,
                    it.summary,
                    it.prompt,
                    if (it.set_hostnames) it.hostnames else null,
                )
        )
    }
    command.set_project_archived?.let {
        return Result(project = admin.setProjectArchived(it.project_id, it.archived))
    }
    command.archived_projects?.let {
        return Result(
            projects =
                Projects(
                    if (it.daemon_id.isEmpty()) admin.archivedProjects()
                    else admin.archivedProjects(it.daemon_id)
                )
        )
    }
    command.consolidate?.let {
        return Result(project = admin.consolidate(it.source_id, it.destination_id))
    }
    command.directories?.let {
        return Result(directory_listing = admin.directories(it.daemon_id, it.path))
    }
    command.attach_checkout?.let {
        return Result(
            checkout = admin.attachCheckout(it.daemon_id, it.project_id, it.path, it.name)
        )
    }
    command.detach_checkout?.let {
        admin.detachCheckout(it.project_id, it.checkout_id)
        return Result(done = Done())
    }
    command.create_board?.let {
        return Result(
            board =
                admin.createBoard(
                    it.project_id,
                    it.name,
                    it.workflow.ifEmpty { "review" },
                    it.description,
                    it.done_archive_policy.ifEmpty { "never" },
                    it.base_remote,
                    it.publish_mode.ifEmpty { "manual" },
                )
        )
    }
    command.rename_board?.let {
        return Result(board = admin.renameBoard(it.board_id, it.name))
    }
    command.set_archive_policy?.let {
        return Result(board = admin.setArchivePolicy(it.board_id, it.policy))
    }
    command.set_git_settings?.let {
        return Result(board = admin.setGitSettings(it.board_id, it.base_remote, it.publish_mode))
    }
    command.set_hostnames?.let {
        return Result(board = admin.setHostnames(it.board_id, it.hostnames, it.append))
    }
    command.set_board_retired?.let {
        return Result(board = admin.setBoardRetired(it.board_id, it.retired))
    }
    command.create_label?.let {
        return Result(board = admin.createLabel(it.board_id, it.name, it.color, it.instructions))
    }
    command.update_label?.let {
        return Result(
            board = admin.updateLabel(it.board_id, it.label_id, it.name, it.color, it.instructions)
        )
    }
    command.delete_label?.let {
        return Result(board = admin.deleteLabel(it.board_id, it.label_id))
    }
    command.prompt_settings?.let {
        return Result(prompt_settings = admin.promptSettings(it.daemon_id))
    }
    command.update_prompt_settings?.let {
        return Result(
            prompt_settings =
                admin.updatePromptSettings(it.daemon_id, it.context, it.board_skill, it.chat_skill)
        )
    }
    command.set_project_prompt?.let {
        return Result(project = admin.setProjectPrompt(it.scope_id, it.template))
    }
    command.set_board_prompt?.let {
        return Result(board = admin.setBoardPrompt(it.scope_id, it.template))
    }
    command.preview_prompt?.let {
        return Result(
            prompt_preview =
                admin.previewPrompt(
                    it.project_id,
                    it.board_id,
                    it.card_id,
                    it.label_ids,
                    it.checkout_id.ifEmpty { null },
                )
        )
    }
    command.conflict?.let {
        return Result(
            conflict = ConflictRecord(admin.conflict(it.project_id.ifEmpty { null }, it.key))
        )
    }
    command.resolve_conflict?.let { resolve ->
        val record = resolve.record ?: invalid("The conflict record is required.")
        return Result(
            conflict =
                ConflictRecord(
                    admin.resolve(
                        resolve.project_id.ifEmpty { null },
                        record,
                        resolve.value_json,
                        resolve.deleted,
                    )
                )
        )
    }
    command.workspace_settings?.let { update ->
        val project =
            workspace.state.value.project(update.project_id)
                ?: invalid("The project is no longer available.")
        val validation =
            if (update.set_validation) update.validation.map(ValidationCommandDraft::from) else null
        return Result(
            project =
                ProjectWorkspaceSettings.update(
                        sessions,
                        workspace,
                        choice,
                        project,
                        update.base_remote,
                        update.base_branch,
                        update.checkout_id.ifEmpty { null },
                        validation,
                    )
                    .also(workspace::overlayProject)
        )
    }
    command.conversation_workspace?.let {
        return Result(workspace = admin.conversationWorkspace(it.card_id))
    }
    command.update_conversation_workspace?.let {
        return Result(
            card =
                admin.updateConversationWorkspace(
                    it.card_id,
                    WorkspaceMode.parse(it.mode),
                    it.branch,
                    it.base_branch,
                    it.base_remote,
                    it.publish_mode,
                )
        )
    }
    command.archived_chats?.let {
        return Result(cards = Cards(archivedChats()))
    }
    command.read_file?.let {
        return Result(
            file_document =
                admin.readFile(it.daemon_id, it.project_id, it.checkout_id, it.card_id, it.path)
        )
    }
    invalid("Choose an administration action.")
}

/** Archived chats of every online machine; an unreachable one is skipped. */
internal suspend fun CoreRuntime.archivedChats(): List<Card> =
    connection.machines.value.online
        .filter { it.compatible }
        .flatMap { machine ->
            try {
                admin.archivedChats(machine.id)
            } catch (error: Throwable) {
                if (error is CancellationException) throw error
                emptyList()
            }
        }

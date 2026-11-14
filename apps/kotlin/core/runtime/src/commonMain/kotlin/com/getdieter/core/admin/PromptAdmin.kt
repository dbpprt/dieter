package com.getdieter.core.admin

import com.getdieter.api.v1.Board
import com.getdieter.api.v1.PreviewPromptRequest
import com.getdieter.api.v1.Project
import com.getdieter.api.v1.PromptPreview
import com.getdieter.api.v1.PromptSettings
import com.getdieter.api.v1.SetScopedPromptTemplateRequest
import com.getdieter.api.v1.UpdatePromptSettingsRequest
import com.getdieter.core.runtime.CoreException
import com.getdieter.core.runtime.FailureKind
import com.getdieter.core.store.WorkspaceStore

/**
 * The prompts agents receive: each machine's global templates, project and board overrides, and a
 * rendered preview. Templates are checked as the daemon checks them before any machine is called.
 * Confined to the core dispatcher.
 */
class PromptAdmin
internal constructor(private val calls: AdminCalls, private val store: WorkspaceStore) {
    /**
     * Global prompt settings are local to one machine; the editor always names the machine it
     * edits.
     */
    suspend fun settings(daemonId: String): PromptSettings =
        calls.call(AdminRoute.Target(daemonId)) { it.GetPromptSettings().execute(Unit) }

    suspend fun updateSettings(
        daemonId: String,
        context: String,
        boardSkill: String,
        chatSkill: String,
    ): PromptSettings {
        listOf(
                PromptTemplates.validate(context, context = true),
                PromptTemplates.validate(boardSkill)?.let { "board skill template: $it" },
                PromptTemplates.validate(chatSkill)?.let { "chat skill template: $it" },
            )
            .firstOrNull { it != null }
            ?.let { throw CoreException(FailureKind.PERMANENT, it) }
        return calls.call(AdminRoute.Target(daemonId)) {
            it.UpdatePromptSettings()
                .execute(
                    UpdatePromptSettingsRequest(
                        prompt_template = context,
                        board_skill_template = boardSkill,
                        chat_skill_template = chatSkill,
                    )
                )
        }
    }

    /** Sets or clears ([template] null) a project's prompt override. */
    suspend fun setProjectPrompt(projectId: String, template: String?): Project {
        template
            ?.let { PromptTemplates.validate(it, context = true) }
            ?.let { throw CoreException(FailureKind.PERMANENT, it) }
        return calls
            .call(AdminRoute.ForProject(projectId)) {
                it.SetProjectPromptTemplate()
                    .execute(
                        SetScopedPromptTemplateRequest(
                            scope_id = projectId,
                            inherit = template == null,
                            prompt_template = template.orEmpty(),
                        )
                    )
            }
            .also(store::overlayProject)
    }

    /** Sets or clears ([template] null) a board's prompt override. */
    suspend fun setBoardPrompt(boardId: String, template: String?): Board {
        template
            ?.let { PromptTemplates.validate(it, context = true) }
            ?.let { throw CoreException(FailureKind.PERMANENT, it) }
        return calls
            .call(AdminRoute.ForProject(calls.projectOf(boardId))) {
                it.SetBoardPromptTemplate()
                    .execute(
                        SetScopedPromptTemplateRequest(
                            scope_id = boardId,
                            inherit = template == null,
                            prompt_template = template.orEmpty(),
                        )
                    )
            }
            .also(store::overlayBoard)
    }

    /**
     * Renders the prompt an agent would receive; runs where the checkout lives, since it reads the
     * repository.
     */
    suspend fun preview(
        projectId: String,
        boardId: String = "",
        cardId: String = "",
        labelIds: List<String> = emptyList(),
        checkoutId: String? = null,
    ): PromptPreview {
        val route =
            checkoutId?.let { AdminRoute.Owner(it, projectId) } ?: AdminRoute.ForProject(projectId)
        return calls.call(route) {
            it.PreviewPrompt()
                .execute(
                    PreviewPromptRequest(
                        project_id = projectId,
                        board_id = boardId,
                        card_id = cardId,
                        label_ids = labelIds,
                        scope = if (boardId.isNotEmpty()) "board" else "chat",
                    )
                )
        }
    }
}

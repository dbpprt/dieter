package com.getdieter.core.admin

import com.getdieter.api.v1.ArchiveProjectRequest
import com.getdieter.api.v1.AttachCheckoutRequest
import com.getdieter.api.v1.BoardRef
import com.getdieter.api.v1.Card
import com.getdieter.api.v1.Checkout
import com.getdieter.api.v1.CheckoutRef
import com.getdieter.api.v1.ConsolidateProjectRequest
import com.getdieter.api.v1.CreateProjectRequest
import com.getdieter.api.v1.CreateProjectResponse
import com.getdieter.api.v1.DirectoryListing
import com.getdieter.api.v1.ListDirectoriesRequest
import com.getdieter.api.v1.Project
import com.getdieter.api.v1.ProjectHostnames
import com.getdieter.api.v1.UpdateProjectRequest
import com.getdieter.api.v1.ValidationCommand
import com.getdieter.core.machines.MachineChoice
import com.getdieter.core.runtime.CoreException
import com.getdieter.core.runtime.Deadlines
import com.getdieter.core.runtime.FailureKind
import com.getdieter.core.session.MachineSessions
import com.getdieter.core.store.WorkspaceStore
import com.getdieter.core.workspace.ProjectWorkspaceSettings
import com.getdieter.core.workspace.ValidationCommandDraft

/**
 * The archived projects a machine knows and a board's archived cards, as the Archives view lists
 * them.
 */
data class AdministrationArchives(
    val projects: List<Project> = emptyList(),
    val cards: List<Card> = emptyList(),
)

/**
 * Projects, their checkouts, and the archive: creating, editing, archiving, and consolidating
 * projects, and attaching and detaching checkouts on the machines that hold them. Returned projects
 * and checkouts show at once and yield to the account view once it is at least as new. Confined to
 * the core dispatcher.
 */
class ProjectAdmin
internal constructor(
    private val calls: AdminCalls,
    private val sessions: MachineSessions,
    private val store: WorkspaceStore,
    private val choice: MachineChoice,
) {
    /**
     * Registers an existing repository ("open") or creates one ("create") on [daemonId], with its
     * first board ([AdminForms.DEFAULT_BOARD_NAME] when blank). A [summary] or [prompt] is saved on
     * the new project right after.
     */
    suspend fun create(
        daemonId: String,
        path: String,
        name: String = "",
        create: Boolean = false,
        boardName: String = AdminForms.DEFAULT_BOARD_NAME,
        workflow: String = AdminForms.DEFAULT_WORKFLOW,
        baseRemote: String = AdminForms.DEFAULT_BASE_REMOTE,
        baseBranch: String = AdminForms.DEFAULT_BASE_BRANCH,
        validation: List<ValidationCommand> = emptyList(),
        summary: String = "",
        prompt: String = "",
    ): CreateProjectResponse {
        if (path.isBlank())
            throw CoreException(FailureKind.PERMANENT, "Choose a folder for the project.")
        if (baseBranch.isBlank())
            throw CoreException(FailureKind.PERMANENT, "Enter a workspace base branch.")
        val request =
            CreateProjectRequest(
                mode = if (create) "create" else "open",
                path = path.trim(),
                name = name.trim(),
                board_name = boardName.trim().ifEmpty { AdminForms.DEFAULT_BOARD_NAME },
                workflow = workflow,
                base_remote = baseRemote.trim(),
                base_branch = baseBranch.trim(),
                validation_commands = validation,
            )
        val response =
            calls.idempotent("project", CreateProjectRequest.ADAPTER.encodeByteString(request)) {
                operationId ->
                calls.call(AdminRoute.Target(daemonId), Deadlines.PROVISION) {
                    it.CreateProject().execute(request.copy(operation_id = operationId))
                }
            }
        // Its checkout routes calls for the new project to the machine that created it.
        response.project?.let(store::overlayProject)
        response.board?.let(store::overlayBoard)
        val created = response.project
        if (created == null || (summary.isBlank() && prompt.isBlank())) return response
        return response.copy(project = update(created.id, summary = summary, prompt = prompt))
    }

    suspend fun update(
        projectId: String,
        name: String? = null,
        summary: String? = null,
        prompt: String? = null,
        hostnames: List<String>? = null,
    ): Project {
        val request =
            UpdateProjectRequest(
                project_id = projectId,
                name = name?.trim()?.ifEmpty { null },
                summary = summary,
                prompt = prompt,
                hostnames =
                    hostnames?.let {
                        ProjectHostnames(
                            values =
                                Hostnames.normalize(it).getOrElse { error ->
                                    throw CoreException(
                                        FailureKind.PERMANENT,
                                        error.message.orEmpty(),
                                    )
                                }
                        )
                    },
            )
        return calls
            .call(AdminRoute.ForProject(projectId)) { it.UpdateProject().execute(request) }
            .also(store::overlayProject)
    }

    /**
     * Saves the project settings form: the workspace base remote and branch and, unless
     * [validation] is null, [checkoutId]'s validation commands (written on that checkout's
     * machine), then the name, summary, and instructions. A blank [name] keeps the current one. The
     * project shows each result at once.
     */
    suspend fun save(
        projectId: String,
        name: String,
        summary: String,
        prompt: String,
        baseRemote: String,
        baseBranch: String,
        checkoutId: String?,
        validation: List<ValidationCommandDraft>?,
    ): Project {
        val project =
            store.state.value.project(projectId)
                ?: throw CoreException(FailureKind.PERMANENT, "The project is no longer available.")
        ProjectWorkspaceSettings.update(
                sessions,
                store,
                choice,
                project,
                baseRemote,
                baseBranch,
                checkoutId,
                validation,
            )
            .also(store::overlayProject)
        return update(projectId, name = name, summary = summary, prompt = prompt)
    }

    suspend fun setArchived(projectId: String, archived: Boolean): Project =
        calls
            .call(AdminRoute.ForProject(projectId)) {
                it.ArchiveProject()
                    .execute(ArchiveProjectRequest(project_id = projectId, archived = archived))
            }
            .also(store::overlayProject)

    /** The archived projects [daemonId] knows, any reachable machine's by default. */
    suspend fun archived(daemonId: String? = choice.any()): List<Project> {
        val machine =
            daemonId ?: throw CoreException(FailureKind.TRANSIENT, "No machine is reachable.")
        return calls
            .call(AdminRoute.Target(machine)) { it.ListArchivedProjects().execute(Unit) }
            .projects
    }

    /**
     * The archived projects a machine with [projectId] knows and [boardId]'s archived cards, read
     * together for the Archives view.
     */
    suspend fun archives(projectId: String, boardId: String?): AdministrationArchives {
        val projects = archived(calls.daemonFor(AdminRoute.ForProject(projectId)))
        val cards =
            boardId
                ?.let { board ->
                    calls
                        .call(AdminRoute.ForProject(projectId)) {
                            it.ListArchivedCards().execute(BoardRef(board_id = board))
                        }
                        .cards
                }
                .orEmpty()
        return AdministrationArchives(projects, cards)
    }

    /**
     * Folds [sourceId] into [destinationId]; conversations keep their IDs, checkouts, and machines.
     * The source leaves the workspace at once, and the destination shows its boards, items, and
     * checkouts.
     */
    suspend fun consolidate(sourceId: String, destinationId: String): Project {
        if (sourceId == destinationId)
            return store.directoryProjection.projects[destinationId]
                ?: throw CoreException(FailureKind.PERMANENT, "The project is no longer available.")
        return calls
            .call(AdminRoute.ForProject(destinationId)) {
                it.ConsolidateProject()
                    .execute(
                        ConsolidateProjectRequest(
                            source_project_id = sourceId,
                            destination_project_id = destinationId,
                        )
                    )
            }
            .also { store.overlayConsolidation(sourceId, it) }
    }

    // --- Checkouts ----------------------------------------------------------------

    /** Folders on [daemonId]; an empty [path] lists its default locations. */
    suspend fun directories(daemonId: String, path: String = ""): DirectoryListing =
        calls.call(AdminRoute.Target(daemonId)) {
            it.ListDirectories().execute(ListDirectoriesRequest(path = path))
        }

    /**
     * Attaches a Git working tree on [daemonId] as another checkout of [projectId]; the project
     * shows it at once.
     */
    suspend fun attachCheckout(
        daemonId: String,
        projectId: String,
        path: String,
        name: String = "",
    ): Checkout =
        calls
            .call(AdminRoute.Target(daemonId), Deadlines.PROVISION) {
                it.AttachCheckout()
                    .execute(
                        AttachCheckoutRequest(
                            project_id = projectId,
                            path = path.trim(),
                            name = name.trim(),
                        )
                    )
            }
            .also(store::overlayCheckout)

    /**
     * Detaches a checkout on the machine that holds it; refused while a conversation there is
     * running. The project shows it detached at once.
     */
    suspend fun detachCheckout(projectId: String, checkoutId: String) {
        calls.call(AdminRoute.Owner(checkoutId, projectId)) {
            it.DetachCheckout().execute(CheckoutRef(checkout_id = checkoutId))
        }
        store.directoryProjection.projects[projectId]
            ?.checkouts
            ?.firstOrNull { it.id == checkoutId }
            ?.let { store.overlayCheckout(it.copy(detached = true)) }
    }
}

package com.dbpprt.dieter.core.admin

import com.dbpprt.dieter.api.v1.ArchiveProjectRequest
import com.dbpprt.dieter.api.v1.AttachCheckoutRequest
import com.dbpprt.dieter.api.v1.Board
import com.dbpprt.dieter.api.v1.BoardRef
import com.dbpprt.dieter.api.v1.Card
import com.dbpprt.dieter.api.v1.Checkout
import com.dbpprt.dieter.api.v1.CheckoutRef
import com.dbpprt.dieter.api.v1.ConsolidateProjectRequest
import com.dbpprt.dieter.api.v1.CreateBoardLabelRequest
import com.dbpprt.dieter.api.v1.CreateBoardRequest
import com.dbpprt.dieter.api.v1.CreateProjectRequest
import com.dbpprt.dieter.api.v1.CreateProjectResponse
import com.dbpprt.dieter.api.v1.DeleteBoardLabelRequest
import com.dbpprt.dieter.api.v1.DieterServiceClient
import com.dbpprt.dieter.api.v1.DirectoryListing
import com.dbpprt.dieter.api.v1.ListDirectoriesRequest
import com.dbpprt.dieter.api.v1.PeerRecord
import com.dbpprt.dieter.api.v1.PeerRecordRef
import com.dbpprt.dieter.api.v1.PeerVersion
import com.dbpprt.dieter.api.v1.PreviewPromptRequest
import com.dbpprt.dieter.api.v1.Project
import com.dbpprt.dieter.api.v1.ProjectHostnames
import com.dbpprt.dieter.api.v1.PromptPreview
import com.dbpprt.dieter.api.v1.PromptSettings
import com.dbpprt.dieter.api.v1.PutPeerRecordRequest
import com.dbpprt.dieter.api.v1.RenameBoardRequest
import com.dbpprt.dieter.api.v1.SetBoardArchivePolicyRequest
import com.dbpprt.dieter.api.v1.SetBoardRetiredRequest
import com.dbpprt.dieter.api.v1.SetScopedPromptTemplateRequest
import com.dbpprt.dieter.api.v1.Settings
import com.dbpprt.dieter.api.v1.SettingsOptions
import com.dbpprt.dieter.api.v1.UpdateBoardGitSettingsRequest
import com.dbpprt.dieter.api.v1.UpdateBoardHostnamesRequest
import com.dbpprt.dieter.api.v1.UpdateBoardLabelRequest
import com.dbpprt.dieter.api.v1.UpdateProjectRequest
import com.dbpprt.dieter.api.v1.UpdatePromptSettingsRequest
import com.dbpprt.dieter.api.v1.UpdateSettingsRequest
import com.dbpprt.dieter.api.v1.ValidationCommand
import com.dbpprt.dieter.core.runtime.CoreException
import com.dbpprt.dieter.core.runtime.FailureKind
import com.dbpprt.dieter.core.runtime.withDeadline
import com.dbpprt.dieter.core.session.MachineSessions
import com.dbpprt.dieter.core.store.WorkspaceStore
import kotlin.random.Random
import kotlin.time.Duration
import kotlin.time.Duration.Companion.seconds
import kotlin.uuid.Uuid
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonPrimitive
import okio.ByteString
import okio.ByteString.Companion.encodeUtf8

/** Which machine must receive an administrative call. */
sealed interface AdminRoute {
    /** Any replica of the project: the peer store accepts and replicates the write. */
    data class Replica(val projectId: String) : AdminRoute

    /** The machine holding a checkout's path, validation commands, and leases. */
    data class Owner(val checkoutId: String, val projectId: String) : AdminRoute

    /** A machine the user chose, e.g. to host a new project. */
    data class Target(val daemonId: String) : AdminRoute

    /** The machine the feed is attached to. */
    data object Attached : AdminRoute

    companion object {
        /** Shared records of [projectId] live on its replica; without a project, on the attached machine. */
        fun shared(projectId: String?): AdminRoute = projectId?.takeIf { it.isNotEmpty() }?.let(::Replica) ?: Attached
    }
}

/**
 * Projects, checkouts, boards, labels, prompt settings, and shared-record
 * conflicts. Owner and target machines are reached over scoped connections;
 * the feed never moves. Returned projects and boards show at once and yield
 * to the next machine view that is at least as new. Confined to the core
 * dispatcher.
 */
class Administration(private val sessions: MachineSessions, private val store: WorkspaceStore, private val attached: () -> String?) {
    private val operationIds = HashMap<String, String>()

    private fun daemonFor(route: AdminRoute): String {
        val directory = store.directoryProjection
        return when (route) {
            is AdminRoute.Target -> route.daemonId
            is AdminRoute.Replica -> directory.projectReplicas[route.projectId] ?: attached()
                ?: throw CoreException(FailureKind.TRANSIENT, "No project replica is online.")
            is AdminRoute.Owner -> directory.projects[route.projectId]?.checkouts?.firstOrNull { it.id == route.checkoutId }?.daemon_id?.ifEmpty { null }
                ?: throw CoreException(FailureKind.TRANSIENT, "The checkout’s machine is unavailable")
            AdminRoute.Attached -> attached() ?: throw CoreException(FailureKind.TRANSIENT, "No machine is attached.")
        }
    }

    private suspend fun <T> call(route: AdminRoute, timeout: Duration = DEADLINE, block: suspend (DieterServiceClient) -> T): T =
        withDeadline(timeout) { sessions.call(daemonFor(route), block) }

    /** One operation ID per distinct request, so a retry of the same intent is idempotent and an edit is not. */
    private fun operationId(kind: String, fingerprint: ByteString): String =
        operationIds.getOrPut(kind + ":" + fingerprint.sha256().hex()) { Uuid.random().toString() }

    // --- Projects ---------------------------------------------------------------

    /** Registers an existing repository ("open") or creates one ("create") on [daemonId]. */
    suspend fun createProject(
        daemonId: String,
        path: String,
        name: String = "",
        create: Boolean = false,
        boardName: String = "Main",
        workflow: String = "review",
        baseRemote: String = "origin",
        baseBranch: String = "main",
        validation: List<ValidationCommand> = emptyList(),
    ): CreateProjectResponse {
        if (path.isBlank()) throw CoreException(FailureKind.PERMANENT, "Choose a folder for the project.")
        if (baseBranch.isBlank()) throw CoreException(FailureKind.PERMANENT, "Enter a workspace base branch.")
        val request = CreateProjectRequest(
            mode = if (create) "create" else "open", path = path.trim(), name = name.trim(), board_name = boardName.trim().ifEmpty { "Main" },
            workflow = workflow, base_remote = baseRemote.trim(), base_branch = baseBranch.trim(), validation_commands = validation,
        )
        val stable = request.copy(operation_id = operationId("project", CreateProjectRequest.ADAPTER.encodeByteString(request)))
        val response = call(AdminRoute.Target(daemonId), CREATE_DEADLINE) { it.CreateProject().execute(stable) }
        response.project?.let(store::overlayProject)
        response.board?.let(store::overlayBoard)
        return response
    }

    suspend fun updateProject(projectId: String, name: String? = null, summary: String? = null, prompt: String? = null, hostnames: List<String>? = null): Project {
        val request = UpdateProjectRequest(
            project_id = projectId, name = name?.trim()?.ifEmpty { null }, summary = summary, prompt = prompt,
            hostnames = hostnames?.let { ProjectHostnames(values = Hostnames.normalize(it).getOrElse { error -> throw CoreException(FailureKind.PERMANENT, error.message.orEmpty()) }) },
        )
        return call(AdminRoute.Replica(projectId)) { it.UpdateProject().execute(request) }.also(store::overlayProject)
    }

    suspend fun setProjectArchived(projectId: String, archived: Boolean): Project =
        call(AdminRoute.Replica(projectId)) { it.ArchiveProject().execute(ArchiveProjectRequest(project_id = projectId, archived = archived)) }.also(store::overlayProject)

    suspend fun archivedProjects(daemonId: String? = attached()): List<Project> {
        val machine = daemonId ?: throw CoreException(FailureKind.TRANSIENT, "Connect to a machine first.")
        return call(AdminRoute.Target(machine)) { it.ListArchivedProjects().execute(Unit) }.projects
    }

    /** Folds [sourceId] into [destinationId]; conversations keep their IDs, checkouts, and machines. */
    suspend fun consolidate(sourceId: String, destinationId: String): Project {
        if (sourceId == destinationId) return store.directoryProjection.projects[destinationId] ?: throw CoreException(FailureKind.PERMANENT, "The project is no longer available.")
        return call(AdminRoute.Replica(destinationId)) { it.ConsolidateProject().execute(ConsolidateProjectRequest(source_project_id = sourceId, destination_project_id = destinationId)) }
            .also(store::overlayProject)
    }

    // --- Checkouts ----------------------------------------------------------------

    /** Folders on [daemonId]; an empty [path] lists its default locations. */
    suspend fun directories(daemonId: String, path: String = ""): DirectoryListing =
        call(AdminRoute.Target(daemonId)) { it.ListDirectories().execute(ListDirectoriesRequest(path = path)) }

    /** Attaches a Git working tree on [daemonId] as another checkout of [projectId]. */
    suspend fun attachCheckout(daemonId: String, projectId: String, path: String, name: String = ""): Checkout =
        call(AdminRoute.Target(daemonId), CREATE_DEADLINE) { it.AttachCheckout().execute(AttachCheckoutRequest(project_id = projectId, path = path.trim(), name = name.trim())) }

    /** Detaches a checkout on the machine that holds it; refused while a conversation there is running. */
    suspend fun detachCheckout(projectId: String, checkoutId: String) {
        call(AdminRoute.Owner(checkoutId, projectId)) { it.DetachCheckout().execute(CheckoutRef(checkout_id = checkoutId)) }
    }

    // --- Boards -------------------------------------------------------------------

    suspend fun createBoard(projectId: String, name: String, workflow: String = "review", description: String = "", policy: String = "never", baseRemote: String = "", publishMode: String = "manual"): Board {
        if (name.isBlank()) throw CoreException(FailureKind.PERMANENT, "board name is required")
        val request = CreateBoardRequest(
            project_id = projectId, name = name.trim(), workflow = workflow, description = description.trim(), done_archive_policy = policy,
            base_remote = baseRemote.ifEmpty { store.directoryProjection.projects[projectId]?.base_remote.orEmpty() }, remote_publish_mode = publishMode,
        )
        return call(AdminRoute.Replica(projectId)) { it.CreateBoard().execute(request) }.also(store::overlayBoard)
    }

    private fun projectOf(boardId: String): String = store.findBoard(boardId)?.project_id
        ?: throw CoreException(FailureKind.PERMANENT, "The board is no longer available.")

    suspend fun renameBoard(boardId: String, name: String): Board {
        if (name.isBlank()) throw CoreException(FailureKind.PERMANENT, "board name is required")
        return call(AdminRoute.Replica(projectOf(boardId))) { it.RenameBoard().execute(RenameBoardRequest(board_id = boardId, name = name.trim())) }.also(store::overlayBoard)
    }

    suspend fun setArchivePolicy(boardId: String, policy: String): Board {
        if (policy !in ARCHIVE_POLICIES) throw CoreException(FailureKind.PERMANENT, "Done archive policy must be never, immediately, after_1_day, after_7_days, after_30_days, or after_90_days")
        return call(AdminRoute.Replica(projectOf(boardId))) { it.SetBoardArchivePolicy().execute(SetBoardArchivePolicyRequest(board_id = boardId, done_archive_policy = policy)) }.also(store::overlayBoard)
    }

    suspend fun setGitSettings(boardId: String, baseRemote: String, publishMode: String): Board {
        if (publishMode !in PUBLISH_MODES) throw CoreException(FailureKind.PERMANENT, "remote publish mode must be manual, pull_request, or push_base")
        return call(AdminRoute.Replica(projectOf(boardId))) {
            it.UpdateBoardGitSettings().execute(UpdateBoardGitSettingsRequest(board_id = boardId, base_remote = baseRemote.trim(), remote_publish_mode = publishMode))
        }.also(store::overlayBoard)
    }

    suspend fun setHostnames(boardId: String, hostnames: List<String>, append: Boolean = false): Board {
        val values = Hostnames.normalize(hostnames).getOrElse { throw CoreException(FailureKind.PERMANENT, it.message.orEmpty()) }
        return call(AdminRoute.Replica(projectOf(boardId))) { it.UpdateBoardHostnames().execute(UpdateBoardHostnamesRequest(board_id = boardId, hostnames = values, append = append)) }
            .also(store::overlayBoard)
    }

    /**
     * Retires (deletes) or restores a board against the lifecycle revision the
     * replica reports. Only empty boards can be retired. The operation ID is
     * kept for the whole intent, so a retry never applies twice.
     */
    suspend fun setBoardRetired(boardId: String, retired: Boolean): Board {
        val route = AdminRoute.Replica(projectOf(boardId))
        val daemon = daemonFor(route)
        return withDeadline(DEADLINE) {
            sessions.call(daemon) { client ->
                val current = client.GetBoard().execute(BoardRef(board_id = boardId))
                val intent = "retire:$boardId:$retired".encodeUtf8()
                val request = SetBoardRetiredRequest(board_id = boardId, retired = retired, expected_revision = current.retirement_revision, operation_id = operationId("board", intent))
                client.SetBoardRetired().execute(request)
            }
        }.also {
            operationIds.remove("board:" + "retire:$boardId:$retired".encodeUtf8().sha256().hex())
            store.overlayBoard(it)
        }
    }

    // --- Labels ---------------------------------------------------------------------

    suspend fun createLabel(boardId: String, name: String, color: String = "", instructions: String = ""): Board {
        Labels.validate(name, color)?.let { throw CoreException(FailureKind.PERMANENT, it) }
        return call(AdminRoute.Replica(projectOf(boardId))) {
            it.CreateBoardLabel().execute(CreateBoardLabelRequest(board_id = boardId, name = name.trim(), color = color.trim(), instructions = instructions))
        }.also(store::overlayBoard)
    }

    suspend fun updateLabel(boardId: String, labelId: String, name: String, color: String, instructions: String): Board {
        Labels.validate(name, color)?.let { throw CoreException(FailureKind.PERMANENT, it) }
        return call(AdminRoute.Replica(projectOf(boardId))) {
            it.UpdateBoardLabel().execute(UpdateBoardLabelRequest(board_id = boardId, label_id = labelId, name = name.trim(), color = color.trim(), instructions = instructions))
        }.also(store::overlayBoard)
    }

    /** Removes the label from the board and from every card. */
    suspend fun deleteLabel(boardId: String, labelId: String): Board =
        call(AdminRoute.Replica(projectOf(boardId))) { it.DeleteBoardLabel().execute(DeleteBoardLabelRequest(board_id = boardId, label_id = labelId)) }.also(store::overlayBoard)

    // --- Settings and prompts ---------------------------------------------------------

    /** Global prompt settings are local to one machine; the editor always names the machine it edits. */
    suspend fun promptSettings(daemonId: String): PromptSettings = call(AdminRoute.Target(daemonId)) { it.GetPromptSettings().execute(Unit) }

    suspend fun updatePromptSettings(daemonId: String, context: String, boardSkill: String, chatSkill: String): PromptSettings {
        listOf(
            PromptTemplates.validate(context, context = true),
            PromptTemplates.validate(boardSkill)?.let { "board skill template: $it" },
            PromptTemplates.validate(chatSkill)?.let { "chat skill template: $it" },
        ).firstOrNull { it != null }?.let { throw CoreException(FailureKind.PERMANENT, it) }
        return call(AdminRoute.Target(daemonId)) {
            it.UpdatePromptSettings().execute(UpdatePromptSettingsRequest(prompt_template = context, board_skill_template = boardSkill, chat_skill_template = chatSkill))
        }
    }

    /**
     * Portable settings are read from and written to the same machine,
     * [projectId]'s replica (else the attached machine), so an update never
     * lands on a machine whose settings were not the ones shown.
     */
    suspend fun settings(projectId: String?): Settings = call(AdminRoute.shared(projectId)) { it.GetSettings().execute(Unit) }

    suspend fun updateSettings(projectId: String?, settings: Settings): Settings = call(AdminRoute.shared(projectId)) { it.UpdateSettings().execute(UpdateSettingsRequest(settings = settings)) }

    suspend fun settingsOptions(projectId: String?): SettingsOptions = call(AdminRoute.shared(projectId)) { it.GetSettingsOptions().execute(Unit) }

    /** Sets or clears ([template] null) a project's prompt override. */
    suspend fun setProjectPrompt(projectId: String, template: String?): Project {
        template?.let { PromptTemplates.validate(it, context = true) }?.let { throw CoreException(FailureKind.PERMANENT, it) }
        return call(AdminRoute.Replica(projectId)) {
            it.SetProjectPromptTemplate().execute(SetScopedPromptTemplateRequest(scope_id = projectId, inherit = template == null, prompt_template = template.orEmpty()))
        }.also(store::overlayProject)
    }

    suspend fun setBoardPrompt(boardId: String, template: String?): Board {
        template?.let { PromptTemplates.validate(it, context = true) }?.let { throw CoreException(FailureKind.PERMANENT, it) }
        return call(AdminRoute.Replica(projectOf(boardId))) {
            it.SetBoardPromptTemplate().execute(SetScopedPromptTemplateRequest(scope_id = boardId, inherit = template == null, prompt_template = template.orEmpty()))
        }.also(store::overlayBoard)
    }

    /** Renders the prompt an agent would receive; runs where the checkout lives, since it reads the repository. */
    suspend fun previewPrompt(projectId: String, boardId: String = "", cardId: String = "", labelIds: List<String> = emptyList(), checkoutId: String? = null): PromptPreview {
        val route = checkoutId?.let { AdminRoute.Owner(it, projectId) } ?: AdminRoute.Replica(projectId)
        return call(route) {
            it.PreviewPrompt().execute(PreviewPromptRequest(project_id = projectId, board_id = boardId, card_id = cardId, label_ids = labelIds, scope = if (boardId.isNotEmpty()) "board" else "chat"))
        }
    }

    // --- Shared-record conflicts --------------------------------------------------------

    /** The competing versions behind a conflict key such as `board/b_1.name`, read from [projectId]'s replica. */
    suspend fun conflict(projectId: String?, key: String): PeerRecord? {
        val kind = key.substringBefore('/')
        val id = key.substringAfter('/').substringBefore('.')
        val record = call(AdminRoute.shared(projectId)) { it.GetPeerRecord().execute(PeerRecordRef(kind = kind, id = id)) }
        return record.takeIf { it.versions.size > 1 }
    }

    /** Keeps one version (or the deletion) on the replica that served the record. */
    suspend fun resolve(projectId: String?, record: PeerRecord, valueJson: ByteString?, deleted: Boolean): PeerRecord =
        call(AdminRoute.shared(projectId)) {
            it.PutPeerRecord().execute(
                PutPeerRecordRequest(kind = record.kind, id = record.id, value_json = if (deleted) ByteString.EMPTY else valueJson ?: ByteString.EMPTY, deleted = deleted, expected_revision = record.revision),
            )
        }

    /** Archived cards and projects plus settings, read together for the Archives view. */
    suspend fun archives(projectId: String, boardId: String?): Pair<List<Project>, List<Card>> {
        val projects = archivedProjects(daemonFor(AdminRoute.Replica(projectId)))
        val cards = boardId?.let { board -> call(AdminRoute.Replica(projectId)) { it.ListArchivedCards().execute(BoardRef(board_id = board)) }.cards }.orEmpty()
        return projects to cards
    }

    companion object {
        val DEADLINE = 15.seconds
        val CREATE_DEADLINE = 60.seconds
        val ARCHIVE_POLICIES = listOf("never", "immediately", "after_1_day", "after_7_days", "after_30_days", "after_90_days")
        val PUBLISH_MODES = listOf("manual", "pull_request", "push_base")

        /** "Never", "Immediately", "After 7 days". */
        fun archivePolicyTitle(policy: String): String = policy.replace('_', ' ').replaceFirstChar { it.uppercase() }

        fun publishModeTitle(mode: String): String = when (mode) {
            "manual" -> "Manual"
            "pull_request" -> "Pull request"
            "push_base" -> "Push base"
            else -> mode
        }
        val WORKFLOWS = listOf("review", "direct")
    }
}

data class LabelColor(val name: String, val value: String)

object Labels {
    /** The palette every client offers, by name. */
    val COLORS = listOf(
        LabelColor("Ruby", "#d95c68"),
        LabelColor("Coral", "#df7650"),
        LabelColor("Amber", "#c9952f"),
        LabelColor("Lime", "#7d9e45"),
        LabelColor("Emerald", "#3e9970"),
        LabelColor("Teal", "#379799"),
        LabelColor("Sky", "#478dc5"),
        LabelColor("Indigo", "#626fd0"),
        LabelColor("Violet", "#8a62c3"),
        LabelColor("Rose", "#c65f98"),
    )
    val PALETTE = COLORS.map { it.value }
    const val DEFAULT_COLOR = "#6558df"
    private val hex = Regex("^#[0-9a-fA-F]{6}$")

    fun validate(name: String, color: String): String? = when {
        name.isBlank() -> "label name is required"
        color.isNotBlank() && !hex.matches(color.trim()) -> "label color must be a hex color such as #6558df"
        else -> null
    }

    /** A palette color other than [exclude]. */
    fun randomColor(exclude: String? = null, random: Random = Random): String =
        PALETTE.filterNot { it.equals(exclude, ignoreCase = true) }.random(random)

    /** [color]'s palette entry, else the first. */
    fun named(color: String): LabelColor = COLORS.firstOrNull { it.value.equals(color, ignoreCase = true) } ?: COLORS.first()

    /** The same palette color for [id] on every launch and client. */
    fun stable(id: String): String = PALETTE[id.hashCode().mod(PALETTE.size)]
}

/** How competing versions of a shared record read when the user picks one. */
object ConflictVersions {
    /** A string value as itself, other JSON compactly, a deletion as "Deleted". */
    fun versionText(version: PeerVersion): String {
        if (version.deleted) return "Deleted"
        val raw = version.value_json.utf8()
        val element = runCatching { Json.parseToJsonElement(raw) }.getOrNull() ?: return raw
        return (element as? JsonPrimitive)?.takeIf { it.isString }?.content ?: element.toString()
    }

    fun keepLabel(version: PeerVersion): String = if (version.deleted) "Keep deletion" else "Keep this value"
}

/** Browser hostnames that route captured tasks to a project or board. */
object Hostnames {
    const val MAX = 64

    /** Lowercase `host` or `host:port` values, deduplicated and sorted; rejects URLs, paths, and wildcards. */
    fun normalize(values: List<String>): Result<List<String>> {
        val normalized = mutableSetOf<String>()
        for (raw in values) {
            val value = raw.trim()
            if (value.isEmpty()) continue
            val host: String
            val port: Int?
            when {
                value.startsWith("[") -> {
                    val end = value.indexOf(']')
                    if (end < 0) return invalid(value)
                    host = value.substring(1, end)
                    val rest = value.substring(end + 1)
                    port = if (rest.isEmpty()) null else rest.removePrefix(":").toIntOrNull() ?: return invalid(value)
                    if (':' !in host) return invalid(value)
                }
                value.count { it == ':' } == 1 -> {
                    host = value.substringBefore(':')
                    port = value.substringAfter(':').toIntOrNull() ?: return invalid(value)
                }
                value.count { it == ':' } > 1 -> {
                    host = value
                    port = null
                }
                else -> {
                    host = value
                    port = null
                }
            }
            val name = host.lowercase().trimEnd('.')
            if (name.isEmpty() || name.any { it == '/' || it == '*' || it == '?' || it == '#' || it == '@' || it.isWhitespace() }) return invalid(value)
            if (port != null && port !in 1..65535) return invalid(value)
            normalized += when {
                port == null -> name
                ':' in name -> "[$name]:$port"
                else -> "$name:$port"
            }
        }
        if (normalized.size > MAX) return Result.failure(IllegalArgumentException("at most 64 project hostnames are allowed"))
        return Result.success(normalized.sorted())
    }

    private fun invalid(value: String) = Result.failure<List<String>>(
        IllegalArgumentException("invalid project hostname \"$value\": use host or host:port (1-65535), with IPv6 ports written as [::1]:4018; no URL, path, or wildcard"),
    )
}

/** Client-side checks mirroring the daemon's prompt template validation, for live editor feedback. */
object PromptTemplates {
    const val MAX_BYTES = 32 * 1024
    val VARIABLES = listOf(
        "scope",
        "project.name", "project.id", "project.path", "project.registered_path", "project.summary", "project.instructions", "project.instructions_block",
        "workspace.path", "workspace.mode", "workspace.branch", "workspace.base_branch", "workspace.base_remote", "workspace.base_sha", "workspace.remote_publish_mode",
        "board.name", "board.id", "board.workflow", "board.description", "board.labels", "board.target_lane",
        "card.id", "card.title", "card.lane", "card.labels",
        "labels.instructions", "labels.instructions_block",
    )
    private val placeholder = Regex("\\{\\{\\s*([a-z0-9_.]+)\\s*\\}\\}")

    /** The first problem with [template], or null; context templates must place both instruction blocks once. */
    fun validate(template: String, context: Boolean = false): String? {
        if (template.isBlank()) return "template is required"
        if (template.encodeToByteArray().size > MAX_BYTES) return "template exceeds 32 KiB"
        val names = placeholder.findAll(template).map { it.groupValues[1] }.toList()
        names.firstOrNull { it !in VARIABLES }?.let { return "unknown template variable {{$it}}" }
        val rest = placeholder.replace(template, "")
        if ("{{" in rest || "}}" in rest) return "template contains a malformed variable"
        if (context) {
            for (required in listOf("project.instructions_block", "labels.instructions_block")) {
                if (names.count { it == required } != 1) return "template must contain {{$required}} exactly once"
            }
        }
        return null
    }

    /** Rough token estimate the daemon also reports: a quarter of the UTF-8 bytes. */
    fun estimatedTokens(text: String): Int = (text.encodeToByteArray().size + 3) / 4
}

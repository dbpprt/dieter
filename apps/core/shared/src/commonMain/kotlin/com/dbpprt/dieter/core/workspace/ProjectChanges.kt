package com.dbpprt.dieter.core.workspace

import com.dbpprt.dieter.api.v1.ChangedFile
import com.dbpprt.dieter.api.v1.Changeset
import com.dbpprt.dieter.api.v1.FileDiff
import com.dbpprt.dieter.api.v1.GetChangesetRequest
import com.dbpprt.dieter.api.v1.GetDiffRequest
import com.dbpprt.dieter.api.v1.GitOperation
import com.dbpprt.dieter.api.v1.GitOperationRef
import com.dbpprt.dieter.api.v1.Project
import com.dbpprt.dieter.api.v1.ProjectRef
import com.dbpprt.dieter.api.v1.StartGitOperationRequest
import com.dbpprt.dieter.api.v1.UpdateProjectWorkspaceSettingsRequest
import com.dbpprt.dieter.api.v1.Workspace
import com.dbpprt.dieter.core.runtime.CoreException
import com.dbpprt.dieter.core.runtime.FailureKind
import com.dbpprt.dieter.core.runtime.Failures
import com.dbpprt.dieter.core.runtime.withDeadline
import com.dbpprt.dieter.core.session.MachineSessions
import com.dbpprt.dieter.core.store.WorkspaceStore
import com.squareup.wire.GrpcException
import com.squareup.wire.GrpcStatus
import kotlin.coroutines.cancellation.CancellationException
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.seconds
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

/** Which half of a project change: HEAD to index, or index to working tree. */
enum class ChangeSection(val wire: String) { STAGED("staged"), UNSTAGED("unstaged") }

data class ProjectChangesView(
    val projectId: String? = null,
    val checkoutId: String? = null,
    val daemonId: String? = null,
    val changes: Changeset? = null,
    val selection: Pair<String, ChangeSection>? = null,
    val diff: FileDiff? = null,
    val diffLines: List<DiffLine> = emptyList(),
    val diffLoading: Boolean = false,
    val operation: GitOperation? = null,
    val pendingKind: String? = null,
    val needsReconciliation: Boolean = true,
    val refreshing: Boolean = false,
    val refreshError: String? = null,
    val diffError: String? = null,
    val operationError: String? = null,
    val notice: String? = null,
) {
    val busy: Boolean get() = pendingKind != null || needsReconciliation || GitOperations.isActive(operation) || changes?.current_operation_id?.isNotEmpty() == true
    val mutationsDisabled: Boolean get() = changes == null || busy

    val staged: List<ChangedFile> get() = changes?.files?.filter { it.staged }.orEmpty()
    val unstaged: List<ChangedFile> get() = changes?.files?.filter { it.unstaged }.orEmpty()

    /** "3 local files · main". */
    val summary: String? get() = changes?.let { "${it.files.size} local file${if (it.files.size == 1) "" else "s"} · ${it.branch.ifBlank { "current branch" }}" }

    /** Whether [kind] can run on this checkout now; pushing needs a configured remote. */
    fun allows(kind: String, hasRemote: Boolean): Boolean = !mutationsDisabled && when (kind) {
        GitOperationKinds.UPDATE -> changes?.dirty == false
        GitOperationKinds.VALIDATE -> true
        GitOperationKinds.PUSH -> changes?.branch?.isNotEmpty() == true && hasRemote
        GitOperationKinds.COMMIT -> staged.isNotEmpty()
        GitOperationKinds.STAGE, GitOperationKinds.UNSTAGE, GitOperationKinds.DISCARD_CHANGES -> true
        else -> false
    }

    companion object {
        /** A project commit never validates on its own; an update fetches first. */
        fun parameters(kind: String, subject: String = "", body: String = ""): Map<String, String> = when (kind) {
            GitOperationKinds.COMMIT -> mapOf("subject" to subject.trim(), "body" to body.trim(), "validate" to "false")
            GitOperationKinds.UPDATE -> mapOf("fetch" to "true", "validate" to "false")
            else -> emptyMap()
        }
    }
}

/**
 * Changes in a project checkout (outside any conversation's worktree):
 * stage, unstage, discard, commit, update, validate, and push. Polls every
 * 2 s while visible; success is only reported after an authoritative refresh.
 * Confined to the core dispatcher.
 */
class ProjectChanges(private val sessions: MachineSessions, private val store: WorkspaceStore, private val scope: CoroutineScope) {
    private val mutableView = MutableStateFlow(ProjectChangesView())
    val view: StateFlow<ProjectChangesView> = mutableView.asStateFlow()
    private var binding = 0L
    private var diffRequest = 0L
    private var poller: Job? = null
    private val diffCache = LinkedHashMap<Pair<String, ChangeSection>, FileDiff>()

    fun bind(projectId: String?, checkoutId: String?, daemonId: String?) {
        val current = view.value
        if (projectId == current.projectId && checkoutId == current.checkoutId && daemonId == current.daemonId) return
        binding++
        poller?.cancel()
        diffCache.clear()
        mutableView.value = ProjectChangesView(projectId, checkoutId, daemonId)
    }

    fun setActive(active: Boolean) {
        poller?.cancel()
        if (!active) return
        val bound = binding
        poller = scope.launch {
            while (bound == binding) {
                runCatching { refresh() }.onFailure { if (it is CancellationException) throw it }
                delay(REFRESH)
            }
        }
    }

    private fun target(): Triple<String, String, String> {
        val state = view.value
        return Triple(
            state.projectId ?: throw CoreException(FailureKind.PERMANENT, "Choose a project first."),
            state.checkoutId ?: throw CoreException(FailureKind.PERMANENT, "Choose a checkout first."),
            state.daemonId ?: throw CoreException(FailureKind.TRANSIENT, "The checkout's machine is unavailable."),
        )
    }

    suspend fun refresh() {
        val (projectId, checkoutId, daemonId) = target()
        val bound = binding
        mutableView.update { it.copy(refreshing = true) }
        try {
            val changes = withDeadline(TIMEOUT) { sessions.call(daemonId) { it.GetChangeset().execute(GetChangesetRequest(project_id = projectId, checkout_id = checkoutId)) } }
            if (bound != binding) return
            val previous = view.value.changes
            if (previous?.revision != changes.revision) diffCache.clear()
            mutableView.update { it.copy(changes = changes, refreshing = false, refreshError = null, needsReconciliation = false) }
            val selection = view.value.selection?.takeIf { (path, section) ->
                changes.files.any { it.path == path && (if (section == ChangeSection.STAGED) it.staged else it.unstaged) }
            }
            if (selection == null) {
                mutableView.update { it.copy(selection = null, diff = null, diffLines = emptyList()) }
            } else if (previous?.revision != changes.revision) {
                loadDiff(selection, reload = true)
            }
        } catch (error: Throwable) {
            if (error is CancellationException) throw error
            if (bound == binding) mutableView.update { it.copy(refreshing = false, refreshError = Failures.message(error)) }
        }
    }

    /** Shows one section of a file; the latest selection wins. */
    suspend fun select(path: String, section: ChangeSection) {
        val selection = path to section
        mutableView.update { it.copy(selection = selection, diffError = null) }
        loadDiff(selection, reload = false)
    }

    /** Closes the diff; a response still in flight is dropped. */
    fun deselect() {
        diffRequest++
        mutableView.update { it.copy(selection = null, diff = null, diffLines = emptyList(), diffLoading = false, diffError = null) }
    }

    /** Dismisses shown errors and notices; the next refresh or operation reports afresh. */
    fun dismissMessages() = mutableView.update { it.copy(refreshError = null, operationError = null, diffError = null, notice = null) }

    suspend fun loadMoreDiff() {
        val state = view.value
        val selection = state.selection ?: return
        if (state.diffLoading || state.diff?.truncated != true) return
        loadDiff(selection, reload = false, append = true)
    }

    private suspend fun loadDiff(selection: Pair<String, ChangeSection>, reload: Boolean, append: Boolean = false) {
        val (projectId, checkoutId, daemonId) = target()
        val changes = view.value.changes ?: return
        if (!append && !reload) {
            diffCache[selection]?.takeIf { it.revision == changes.revision }?.let { cached ->
                diffCache.remove(selection)
                diffCache[selection] = cached
                mutableView.update { it.copy(diff = cached, diffLines = UnifiedDiff.parse(cached.patch), diffLoading = false) }
                return
            }
        }
        val bound = binding
        val request = ++diffRequest
        mutableView.update { it.copy(diffLoading = true) }
        try {
            val offset = if (append) view.value.diff?.next_offset ?: 0 else 0
            val page = withDeadline(TIMEOUT) {
                sessions.call(daemonId) {
                    it.GetFileDiff().execute(
                        GetDiffRequest(
                            project_id = projectId, checkout_id = checkoutId, path = selection.first, section = selection.second.wire,
                            expected_revision = changes.revision, offset = offset, limit = WorkspaceReview.DIFF_PAGE,
                        ),
                    )
                }
            }
            if (bound != binding || request != diffRequest || view.value.selection != selection || view.value.changes?.revision != changes.revision) return
            val current = view.value.diff
            val combined = if (append && current != null) page.copy(patch = current.patch + page.patch) else page
            remember(selection, combined)
            mutableView.update { it.copy(diff = combined, diffLines = UnifiedDiff.parse(combined.patch), diffLoading = false) }
        } catch (error: Throwable) {
            if (error is CancellationException) throw error
            if (bound != binding || request != diffRequest) return
            mutableView.update { it.copy(diffLoading = false) }
            if (error is GrpcException && error.grpcStatus == GrpcStatus.ABORTED) refresh() else mutableView.update { it.copy(diffError = Failures.message(error)) }
        }
    }

    private fun remember(key: Pair<String, ChangeSection>, diff: FileDiff) {
        diffCache.remove(key)
        diffCache[key] = diff
        while (diffCache.size > CACHE_ENTRIES || diffCache.values.sumOf { it.patch.length.toLong() } > CACHE_BYTES) {
            diffCache.remove(diffCache.keys.first())
        }
    }

    /**
     * Runs a checkout operation and waits for it; success is reported only
     * after the refresh that shows its result. A commit draft survives failure.
     */
    suspend fun run(kind: String, parameters: Map<String, String> = emptyMap()): Boolean {
        if (kind !in GitOperations.PROJECT_KINDS) throw CoreException(FailureKind.PERMANENT, "Git operation \"$kind\" is not available from project Changes")
        val (projectId, checkoutId, daemonId) = target()
        val state = view.value
        if (state.mutationsDisabled) return false
        val bound = binding
        mutableView.update { it.copy(pendingKind = kind, operationError = null, notice = null) }
        try {
            var operation = withDeadline(TIMEOUT) {
                sessions.call(daemonId) {
                    it.StartGitOperation().execute(StartGitOperationRequest(project_id = projectId, checkout_id = checkoutId, kind = kind, expected_revision = state.changes?.revision.orEmpty(), parameters = parameters))
                }
            }
            mutableView.update { it.copy(operation = operation) }
            val started = kotlin.time.TimeSource.Monotonic.markNow()
            while (bound == binding && operation.status in GitOperations.ACTIVE && started.elapsedNow() < 3600.seconds) {
                delay(OPERATION_POLL)
                operation = withDeadline(TIMEOUT) { sessions.call(daemonId) { it.GetGitOperation().execute(GitOperationRef(operation_id = operation.id)) } }
                mutableView.update { it.copy(operation = operation) }
            }
            if (bound != binding) return false
            mutableView.update { it.copy(needsReconciliation = true) }
            refresh()
            if (operation.status != "succeeded") {
                mutableView.update { it.copy(operationError = operation.error.ifEmpty { "The operation ended with status ${operation.status}." }) }
                return false
            }
            mutableView.update { it.copy(notice = notice(kind)) }
            return true
        } catch (error: Throwable) {
            if (error is CancellationException) throw error
            if (bound == binding) mutableView.update { it.copy(operationError = Failures.message(error), needsReconciliation = true) }
            return false
        } finally {
            if (bound == binding) mutableView.update { it.copy(pendingKind = null) }
        }
    }

    companion object {
        private val REFRESH = 2.seconds
        private val TIMEOUT = 30.seconds
        private val OPERATION_POLL = 250.milliseconds
        private const val CACHE_ENTRIES = 8
        private const val CACHE_BYTES = 8L * 1024 * 1024

        fun notice(kind: String): String = when (kind) {
            "stage" -> "Changes staged"
            "unstage" -> "Changes unstaged"
            "commit" -> "Staged changes committed"
            "discard_changes" -> "Changes discarded · recovery copy saved"
            "update" -> "Branch updated"
            "validate" -> "Validation passed"
            "push" -> "Branch pushed"
            else -> "Operation completed"
        }
    }
}

data class ProjectWorkspacesView(
    val projectId: String? = null,
    val workspaces: List<Workspace> = emptyList(),
    val loading: Boolean = false,
    val error: String? = null,
    /** Card IDs with a cleanup or discard in flight. */
    val pending: Set<String> = emptySet(),
    val errors: Map<String, String> = emptyMap(),
)

/** A project's conversation workspaces across its checkouts, with cleanup and discard. */
class ProjectWorkspaces(private val sessions: MachineSessions, private val store: WorkspaceStore) {
    private val mutableView = MutableStateFlow(ProjectWorkspacesView())
    val view: StateFlow<ProjectWorkspacesView> = mutableView.asStateFlow()

    suspend fun load(projectId: String) {
        val daemon = store.directoryProjection.projectReplicas[projectId] ?: throw CoreException(FailureKind.TRANSIENT, "The project's machine is unavailable.")
        mutableView.update { if (it.projectId == projectId) it.copy(loading = true) else ProjectWorkspacesView(projectId, loading = true) }
        try {
            val workspaces = withDeadline(30.seconds) { sessions.call(daemon) { it.ListProjectWorkspaces().execute(ProjectRef(project_id = projectId)) } }.workspaces
            if (view.value.projectId == projectId) mutableView.update { it.copy(workspaces = workspaces, loading = false, error = null) }
        } catch (error: Throwable) {
            if (error is CancellationException) throw error
            if (view.value.projectId == projectId) mutableView.update { it.copy(loading = false, error = Failures.message(error)) }
        }
    }

    /** Cleans up or discards a worktree workspace on its conversation's machine, waiting for the result. */
    suspend fun remove(workspace: Workspace, discard: Boolean) {
        val cardId = workspace.card_id
        if (cardId in view.value.pending) return
        val card = store.directoryProjection.item(cardId)
        val daemon = card?.owner_daemon_id?.ifEmpty { null } ?: store.directoryProjection.projectReplicas[workspace.project_id]
            ?: throw CoreException(FailureKind.TRANSIENT, "The workspace's machine is unavailable.")
        mutableView.update { it.copy(pending = it.pending + cardId, errors = it.errors - cardId) }
        try {
            var operation = withDeadline(30.seconds) {
                sessions.call(daemon) { it.StartGitOperation().execute(StartGitOperationRequest(card_id = cardId, kind = if (discard) "discard" else "cleanup", expected_revision = workspace.revision)) }
            }
            while (operation.status in GitOperations.ACTIVE) {
                delay(500.milliseconds)
                operation = withDeadline(30.seconds) { sessions.call(daemon) { it.GetGitOperation().execute(GitOperationRef(operation_id = operation.id)) } }
            }
            if (operation.status != "succeeded") mutableView.update { it.copy(errors = it.errors + (cardId to operation.error.ifEmpty { "Workspace operation ${operation.status}." })) }
        } catch (error: Throwable) {
            if (error is CancellationException) throw error
            mutableView.update { it.copy(errors = it.errors + (cardId to Failures.message(error))) }
        } finally {
            mutableView.update { it.copy(pending = it.pending - cardId) }
        }
        view.value.projectId?.let { load(it) }
    }
}

/** Project-wide workspace defaults and a checkout's validation commands. */
object ProjectWorkspaceSettings {
    suspend fun update(
        sessions: MachineSessions,
        store: WorkspaceStore,
        project: Project,
        baseRemote: String,
        baseBranch: String,
        checkoutId: String?,
        validation: List<ValidationCommandDraft>?,
    ): Project {
        if (baseBranch.isBlank()) throw CoreException(FailureKind.PERMANENT, "Enter a workspace base branch.")
        ValidationCommandDraft.problem(validation.orEmpty())?.let { throw CoreException(FailureKind.PERMANENT, it) }
        val checkout = checkoutId?.let { id -> project.checkouts.firstOrNull { it.id == id } }
        val current = checkout?.validation_commands.orEmpty().map(ValidationCommandDraft::from)
        val changed = validation != null && checkout != null && validation != current
        val daemon = if (changed) checkout.daemon_id else store.directoryProjection.projectReplicas[project.id]
            ?: throw CoreException(FailureKind.TRANSIENT, "The project's machine is unavailable.")
        val request = UpdateProjectWorkspaceSettingsRequest(
            project_id = project.id, base_remote = baseRemote.trim(), base_branch = baseBranch.trim(),
            checkout_id = if (changed) checkout.id else "", validation_commands = if (changed) validation.map { it.toCommand() } else emptyList(),
        )
        return withDeadline(30.seconds) { sessions.call(daemon) { it.UpdateProjectWorkspaceSettings().execute(request) } }
    }
}

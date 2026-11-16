package com.getdieter.core.workspace

import com.getdieter.api.v1.ChangedFile
import com.getdieter.api.v1.Changeset
import com.getdieter.api.v1.FileDiff
import com.getdieter.api.v1.GetChangesetRequest
import com.getdieter.api.v1.GetDiffRequest
import com.getdieter.api.v1.GitOperation
import com.getdieter.api.v1.Project
import com.getdieter.api.v1.ProjectRef
import com.getdieter.api.v1.StartGitOperationRequest
import com.getdieter.api.v1.UpdateProjectWorkspaceSettingsRequest
import com.getdieter.api.v1.WatchChangesetRequest
import com.getdieter.api.v1.Workspace
import com.getdieter.core.composition.WorkspaceMode
import com.getdieter.core.machines.MachineChoice
import com.getdieter.core.presentation.ByteSizes
import com.getdieter.core.presentation.Counts
import com.getdieter.core.runtime.Backoff
import com.getdieter.core.runtime.CoreException
import com.getdieter.core.runtime.Deadlines
import com.getdieter.core.runtime.FailureKind
import com.getdieter.core.runtime.Failures
import com.getdieter.core.session.MachineSessions
import com.getdieter.core.store.WorkspaceStore
import kotlin.coroutines.cancellation.CancellationException
import kotlin.time.Duration.Companion.milliseconds
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

/** Which half of a project change: HEAD to index, or index to working tree. */
enum class ChangeSection(val wire: String) {
    STAGED("staged"),
    UNSTAGED("unstaged"),
}

object ProjectChangesRules {
    /** Shown while an agent's turn runs in the checkout: a state, never an error. */
    const val AGENT_ACTIVITY = "Agent working · changes update live"

    /** Checkout operations that would destroy or move an agent's working state. */
    val WAIT_FOR_AGENT = setOf(GitOperationKinds.DISCARD_CHANGES, GitOperationKinds.UPDATE)

    /**
     * Where a selection goes after a refresh: the same half if the file still has it, else the
     * file's other half (staging or unstaging moved it), else nowhere.
     */
    fun follow(
        changes: Changeset,
        path: String,
        section: ChangeSection,
    ): Pair<String, ChangeSection>? {
        val file = changes.files.firstOrNull { it.path == path } ?: return null
        return when {
            if (section == ChangeSection.STAGED) file.staged else file.unstaged -> path to section
            file.staged -> path to ChangeSection.STAGED
            file.unstaged -> path to ChangeSection.UNSTAGED
            else -> null
        }
    }

    /** The change a view opens on: the first unstaged file, else the first staged one. */
    fun first(changes: Changeset): Pair<String, ChangeSection>? =
        changes.files.firstOrNull { it.unstaged }?.let { it.path to ChangeSection.UNSTAGED }
            ?: changes.files.firstOrNull { it.staged }?.let { it.path to ChangeSection.STAGED }

    /** [path]'s revision in [changes]; empty when it has no changes. */
    fun revision(changes: Changeset?, path: String): String =
        changes?.files?.firstOrNull { it.path == path }?.revision.orEmpty()

    /**
     * The files [kind] acts on, with their revisions, as its precondition: unstaged files to stage,
     * staged ones to unstage, any to discard; within [path] (a file or folder) when given. The
     * daemon acts on exactly these and refuses only if one of them changed since.
     */
    fun expectedFiles(changes: Changeset?, kind: String, path: String = ""): Map<String, String> {
        val scope = path.trim().trim('/')
        return changes
            ?.files
            .orEmpty()
            .filter { file ->
                (scope.isEmpty() || file.path == scope || file.path.startsWith("$scope/")) &&
                    when (kind) {
                        GitOperationKinds.STAGE -> file.unstaged
                        GitOperationKinds.UNSTAGE -> file.staged
                        GitOperationKinds.DISCARD_CHANGES -> true
                        else -> false
                    }
            }
            .associate { it.path to it.revision }
    }

    /** Why [kind] cannot run while an agent works, or null. */
    fun agentReason(kind: String): String? =
        when (kind) {
            GitOperationKinds.DISCARD_CHANGES ->
                "An agent is working in this checkout. Wait for it to finish, or stop it, before discarding changes."
            GitOperationKinds.UPDATE ->
                "An agent is working in this checkout. Wait for it to finish, or stop it, before updating the branch."
            else -> null
        }
}

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
    /** The project has a base remote to push to. */
    val hasRemote: Boolean = false,
    /** Diffs are laid out side by side rather than unified. */
    val split: Boolean = false,
    /** [diffLines] laid out for [split]; a new instance whenever the lines or the layout change. */
    val layout: DiffLayout = DiffLayout.EMPTY,
    /** "Shared checkout · main" when shown inside a project-directory conversation. */
    val shared: Boolean = false,
) {
    val busy: Boolean
        get() =
            pendingKind != null ||
                needsReconciliation ||
                GitOperations.isActive(operation) ||
                changes?.current_operation_id?.isNotEmpty() == true

    val mutationsDisabled: Boolean
        get() = changes == null || busy

    /** An agent's turn runs in this checkout. */
    val agentActive: Boolean
        get() = changes?.activity?.agent_active == true

    /** [ProjectChangesRules.AGENT_ACTIVITY] while an agent works, else empty. */
    val activity: String
        get() = if (agentActive) ProjectChangesRules.AGENT_ACTIVITY else ""

    /** "Shared checkout · main" inside a conversation, else empty. */
    val sharedLabel: String
        get() =
            if (!shared) ""
            else "Shared checkout · ${changes?.branch?.ifBlank { null } ?: "current branch"}"

    /** Another page of the diff can load. */
    val diffMore: Boolean
        get() = DiffPages.hasMore(diff)

    /**
     * The diff stops at [DiffPages.LIMIT]; [DiffPages.TOO_LARGE] says so instead of loading more.
     */
    val diffTooLarge: Boolean
        get() = diff?.truncated == true && !diffMore

    /** The checkout operations that can run now, in [GitOperations.PROJECT_KINDS] order. */
    val allowed: List<String>
        get() = GitOperations.PROJECT_KINDS.filter { allows(it) }

    /** Why operations that are not allowed cannot run now, when the reason is worth telling. */
    val unavailableReasons: Map<String, String>
        get() =
            if (!agentActive) emptyMap()
            else
                ProjectChangesRules.WAIT_FOR_AGENT.mapNotNull { kind ->
                        ProjectChangesRules.agentReason(kind)?.let { kind to it }
                    }
                    .toMap()

    /** Whether [kind] can run now, with the project's own remote. */
    fun allows(kind: String): Boolean = allows(kind, hasRemote)

    /** [lines] as the shown diff, laid out for this view. */
    fun withDiffLines(lines: List<DiffLine>): ProjectChangesView =
        copy(diffLines = lines, layout = DiffLayout.of(lines, split))

    val staged: List<ChangedFile>
        get() = changes?.files?.filter { it.staged }.orEmpty()

    val unstaged: List<ChangedFile>
        get() = changes?.files?.filter { it.unstaged }.orEmpty()

    /** "3 local files · main". */
    val summary: String?
        get() = changes?.let {
            "${Counts.of(it.files.size, "local file")} · ${it.branch.ifBlank { "current branch" }}"
        }

    /**
     * Whether [kind] can run on this checkout now; pushing needs a configured remote, and an
     * agent's turn holds back what would destroy or move its working state.
     */
    fun allows(kind: String, hasRemote: Boolean): Boolean =
        !mutationsDisabled &&
            !(agentActive && kind in ProjectChangesRules.WAIT_FOR_AGENT) &&
            when (kind) {
                GitOperationKinds.UPDATE -> changes?.dirty == false
                GitOperationKinds.VALIDATE -> true
                GitOperationKinds.PUSH -> changes?.branch?.isNotEmpty() == true && hasRemote
                GitOperationKinds.COMMIT -> staged.isNotEmpty()
                GitOperationKinds.STAGE,
                GitOperationKinds.UNSTAGE,
                GitOperationKinds.DISCARD_CHANGES -> true
                else -> false
            }

    companion object {
        /**
         * A project commit never validates on its own; an update fetches first; [path] narrows
         * staging, unstaging, and discarding to one file or folder.
         */
        fun parameters(
            kind: String,
            subject: String = "",
            body: String = "",
            path: String = "",
        ): Map<String, String> =
            when (kind) {
                GitOperationKinds.COMMIT ->
                    mapOf("subject" to subject.trim(), "body" to body.trim(), "validate" to "false")
                GitOperationKinds.UPDATE -> mapOf("fetch" to "true", "validate" to "false")
                GitOperationKinds.STAGE,
                GitOperationKinds.UNSTAGE,
                GitOperationKinds.DISCARD_CHANGES ->
                    if (path.isEmpty()) emptyMap() else mapOf("path" to path)
                else -> emptyMap()
            }

        /** A commit needs a subject; the other checkout operations need nothing typed. */
        fun ready(kind: String, subject: String): Boolean =
            kind != GitOperationKinds.COMMIT || subject.isNotBlank()
    }
}

/**
 * Changes in a project checkout: stage, unstage, discard, commit, update, validate, and push. The
 * project's Changes and a project-directory conversation show it. While active it follows the
 * daemon's changeset stream, so edits appear as agents make them; nothing polls. A selected diff
 * reloads only when its own file changes, and reads never fail because something else changed.
 * Success is only reported after an authoritative refresh. Confined to the core dispatcher.
 */
class ProjectChanges(
    private val sessions: MachineSessions,
    private val store: WorkspaceStore,
    private val scope: CoroutineScope,
) {
    private val mutableView = MutableStateFlow(ProjectChangesView())
    val view: StateFlow<ProjectChangesView> = mutableView.asStateFlow()
    private var binding = 0L
    private var diffRequest = 0L
    private var watcher: Job? = null
    private val diffCache = LinkedHashMap<Pair<String, ChangeSection>, FileDiff>()
    private var selectFirst = false
    private var inFlight: Deferred<Unit>? = null
    private var refreshAgain = false

    /**
     * Shows a checkout; with [selectFirst], a refresh that leaves nothing selected opens
     * [ProjectChangesRules.first]. [shared] labels it as a project-directory conversation's.
     */
    fun bind(
        projectId: String?,
        checkoutId: String?,
        daemonId: String?,
        selectFirst: Boolean = false,
        shared: Boolean = false,
    ) {
        this.selectFirst = selectFirst
        val current = view.value
        if (
            projectId == current.projectId &&
                checkoutId == current.checkoutId &&
                daemonId == current.daemonId
        ) {
            if (current.shared != shared) mutableView.update { it.copy(shared = shared) }
            return
        }
        val active = watcher?.isActive == true
        binding++
        watcher?.cancel()
        diffCache.clear()
        mutableView.value =
            ProjectChangesView(
                projectId,
                checkoutId,
                daemonId,
                hasRemote = hasRemote(projectId),
                split = current.split,
                shared = shared,
            )
        if (active) setActive(true)
    }

    /**
     * Lays diffs out side by side ([split]) or unified; the view keeps the choice across checkouts.
     */
    fun setLayout(split: Boolean) = mutableView.update {
        if (it.split == split) it else it.copy(split = split).withDiffLines(it.diffLines)
    }

    private fun hasRemote(projectId: String?): Boolean =
        projectId?.let { store.state.value.project(it) }?.base_remote?.isNotBlank() == true

    /** Stops following; nothing is shown. */
    fun stop() {
        setActive(false)
        bind(null, null, null)
    }

    /** Visible and foregrounded: follow the checkout's changeset stream. */
    fun setActive(active: Boolean) {
        watcher?.cancel()
        watcher = null
        if (!active || view.value.projectId == null) return
        val bound = binding
        watcher = scope.launch { follow(bound) }
    }

    /**
     * Applies every changeset the daemon streams for the bound checkout. A dropped stream resumes
     * with backoff; its first frame is a complete changeset, so nothing is missed.
     */
    private suspend fun follow(bound: Long) {
        var attempt = 0
        while (bound == binding) {
            val (projectId, checkoutId, daemonId) =
                try {
                    target()
                } catch (error: CoreException) {
                    if (bound == binding)
                        mutableView.update { it.copy(refreshError = Failures.message(error)) }
                    return
                }
            try {
                coroutineScope {
                    sessions.call(daemonId) { client ->
                        val call = client.WatchChangeset()
                        val frames =
                            call.executeIn(
                                this,
                                WatchChangesetRequest(
                                    project_id = projectId,
                                    checkout_id = checkoutId,
                                    heartbeat_ms = HEARTBEAT_MS,
                                ),
                            )
                        try {
                            for (frame in frames) {
                                val changes = frame.changeset ?: continue
                                attempt = 0
                                if (bound != binding) break
                                apply(changes, bound)
                            }
                        } finally {
                            call.cancel()
                        }
                    }
                }
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Throwable) {
                if (bound == binding)
                    mutableView.update {
                        it.copy(refreshing = false, refreshError = Failures.message(error))
                    }
                if (!Failures.isRetryableRead(error)) return
            }
            delay(Backoff.STREAM.delay(attempt++))
        }
    }

    private fun target(): Triple<String, String, String> {
        val state = view.value
        return Triple(
            state.projectId
                ?: throw CoreException(FailureKind.PERMANENT, "Choose a project first."),
            state.checkoutId
                ?: throw CoreException(FailureKind.PERMANENT, "Choose a checkout first."),
            state.daemonId
                ?: throw CoreException(
                    FailureKind.TRANSIENT,
                    "The checkout's machine is unavailable.",
                ),
        )
    }

    /**
     * Reads the changeset once. A refresh requested while one runs joins it and triggers one more
     * read, so on return the state is at least as new as the call.
     */
    suspend fun refresh() {
        inFlight
            ?.takeIf { it.isActive }
            ?.let { running ->
                refreshAgain = true
                running.await()
                return
            }
        val bound = binding
        val reading = scope.async {
            do {
                refreshAgain = false
                read(bound)
            } while (refreshAgain && bound == binding)
        }
        inFlight = reading
        reading.await()
    }

    private suspend fun read(bound: Long) {
        val (projectId, checkoutId, daemonId) = target()
        mutableView.update { it.copy(refreshing = true) }
        try {
            val changes =
                sessions.call(daemonId, Deadlines.READ) {
                    it.GetChangeset()
                        .execute(
                            GetChangesetRequest(project_id = projectId, checkout_id = checkoutId)
                        )
                }
            if (bound == binding) apply(changes, bound)
        } catch (error: Throwable) {
            if (error is CancellationException) throw error
            if (bound == binding)
                mutableView.update {
                    it.copy(refreshing = false, refreshError = Failures.message(error))
                }
        }
    }

    /**
     * Shows [changes] and keeps the selection on its file; the selected diff reloads only when that
     * file's revision moved.
     */
    private suspend fun apply(changes: Changeset, bound: Long) {
        val (projectId, _, _) = target()
        val previous = view.value
        mutableView.update {
            it.copy(
                changes = changes,
                refreshing = false,
                refreshError = null,
                needsReconciliation = false,
                hasRemote = hasRemote(projectId),
            )
        }
        val current = previous.selection
        val selection =
            current?.let { (path, section) -> ProjectChangesRules.follow(changes, path, section) }
                ?: if (selectFirst) ProjectChangesRules.first(changes) else null
        when {
            selection == null ->
                mutableView.update {
                    it.copy(selection = null, diff = null).withDiffLines(emptyList())
                }
            selection != current -> {
                mutableView.update {
                    it.copy(selection = selection, diff = null, diffError = null)
                        .withDiffLines(emptyList())
                }
                if (bound == binding) loadDiff(selection, reload = false)
            }
            previous.diff?.file_revision !=
                ProjectChangesRules.revision(changes, selection.first) ->
                if (bound == binding) loadDiff(selection, reload = false)
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
        mutableView.update {
            it.copy(selection = null, diff = null, diffLoading = false, diffError = null)
                .withDiffLines(emptyList())
        }
    }

    /** Dismisses shown errors and notices; the next refresh or operation reports afresh. */
    fun dismissMessages() = mutableView.update {
        it.copy(refreshError = null, operationError = null, diffError = null, notice = null)
    }

    /**
     * Loads the next page while one is left; a diff at [DiffPages.LIMIT] stays as it is
     * ([ProjectChangesView.diffTooLarge]).
     */
    suspend fun loadMoreDiff() {
        val state = view.value
        val selection = state.selection ?: return
        if (state.diffLoading || !state.diffMore) return
        loadDiff(selection, reload = false, append = true)
    }

    private suspend fun loadDiff(
        selection: Pair<String, ChangeSection>,
        reload: Boolean,
        append: Boolean = false,
    ) {
        val (projectId, checkoutId, daemonId) = target()
        val revision = ProjectChangesRules.revision(view.value.changes, selection.first)
        if (!append && !reload) {
            diffCache[selection]
                ?.takeIf { revision.isNotEmpty() && it.file_revision == revision }
                ?.let { cached ->
                    diffCache.remove(selection)
                    diffCache[selection] = cached
                    mutableView.update {
                        it.copy(diff = cached, diffLoading = false, diffError = null)
                            .withDiffLines(UnifiedDiff.parse(cached.patch))
                    }
                    return
                }
        }
        val bound = binding
        val request = ++diffRequest
        mutableView.update { it.copy(diffLoading = true) }
        try {
            val loaded = if (append) view.value.diff else null
            val combined =
                DiffPages.read(
                    sessions,
                    daemonId,
                    GetDiffRequest(
                        project_id = projectId,
                        checkout_id = checkoutId,
                        path = selection.first,
                        section = selection.second.wire,
                    ),
                    loaded,
                )
            val current = view.value
            if (
                bound != binding ||
                    request != diffRequest ||
                    current.selection != selection ||
                    (append && current.diff != loaded)
            )
                return
            remember(selection, combined)
            mutableView.update {
                it.copy(diff = combined, diffLoading = false, diffError = null)
                    .withDiffLines(UnifiedDiff.parse(combined.patch))
            }
        } catch (error: Throwable) {
            if (error is CancellationException) throw error
            if (bound != binding || request != diffRequest) return
            mutableView.update { it.copy(diffLoading = false, diffError = Failures.message(error)) }
        }
    }

    private fun remember(key: Pair<String, ChangeSection>, diff: FileDiff) {
        diffCache.remove(key)
        diffCache[key] = diff
        while (
            diffCache.size > CACHE_ENTRIES ||
                diffCache.values.sumOf { it.patch.length.toLong() } > CACHE_BYTES
        ) {
            diffCache.remove(diffCache.keys.first())
        }
    }

    /**
     * Runs a checkout operation and waits for it; success is reported only after the refresh that
     * shows its result. Stage, unstage and discard act on exactly the files shown, and a commit on
     * the index shown; each fails only if those changed since. A commit draft survives failure.
     */
    suspend fun run(kind: String, parameters: Map<String, String> = emptyMap()): Boolean {
        if (kind !in GitOperations.PROJECT_KINDS)
            throw CoreException(
                FailureKind.PERMANENT,
                "Git operation \"$kind\" is not available from project Changes",
            )
        val (projectId, checkoutId, daemonId) = target()
        val state = view.value
        if (state.mutationsDisabled) return false
        state.unavailableReasons[kind]?.let { reason ->
            mutableView.update { it.copy(operationError = reason) }
            return false
        }
        val expectedFiles =
            ProjectChangesRules.expectedFiles(state.changes, kind, parameters["path"].orEmpty())
        if (kind in FILE_SCOPED && expectedFiles.isEmpty()) {
            mutableView.update {
                it.copy(operationError = "Nothing to ${GitOperations.title(kind).lowercase()}.")
            }
            return false
        }
        val bound = binding
        mutableView.update { it.copy(pendingKind = kind, operationError = null, notice = null) }
        try {
            val started =
                sessions.call(daemonId, Deadlines.READ) {
                    it.StartGitOperation()
                        .execute(
                            StartGitOperationRequest(
                                project_id = projectId,
                                checkout_id = checkoutId,
                                kind = kind,
                                parameters = parameters,
                                expected_files = expectedFiles,
                                expected_index =
                                    if (kind == GitOperationKinds.COMMIT)
                                        state.changes?.index_fingerprint.orEmpty()
                                    else "",
                            )
                        )
                }
            mutableView.update { it.copy(operation = started) }
            val operation =
                sessions.followGitOperation(
                    daemonId,
                    started,
                    OPERATION_POLL,
                    keep = { bound == binding },
                ) { read ->
                    mutableView.update { it.copy(operation = read) }
                }
            if (bound != binding) return false
            mutableView.update { it.copy(needsReconciliation = true) }
            refresh()
            if (operation.status != "succeeded") {
                mutableView.update {
                    it.copy(
                        operationError =
                            operation.error.ifEmpty {
                                "The operation ended with status ${operation.status}."
                            }
                    )
                }
                return false
            }
            mutableView.update { it.copy(notice = notice(kind)) }
            return true
        } catch (error: Throwable) {
            if (error is CancellationException) throw error
            if (bound == binding)
                mutableView.update {
                    it.copy(operationError = Failures.message(error), needsReconciliation = true)
                }
            return false
        } finally {
            if (bound == binding) mutableView.update { it.copy(pendingKind = null) }
        }
    }

    companion object {
        const val HEARTBEAT_MS = 15_000
        private val OPERATION_POLL = 250.milliseconds
        private const val CACHE_ENTRIES = 8
        private const val CACHE_BYTES = 8L * 1024 * 1024
        private val FILE_SCOPED =
            setOf(
                GitOperationKinds.STAGE,
                GitOperationKinds.UNSTAGE,
                GitOperationKinds.DISCARD_CHANGES,
            )

        fun notice(kind: String): String =
            when (kind) {
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

/** One workspace of a project's list, as the list shows it. */
data class ProjectWorkspaceRow(
    val cardId: String,
    /** The conversation's title, else the branch, else the card ID. */
    val title: String,
    /** "feature/x · ready": the branch (else the mode) and the state. */
    val detail: String,
    /** "3 files · +40 −12 · 1.2 MB". */
    val stats: String,
    val path: String,
    val conflicted: Boolean,
    /** A worktree without changed files, while nothing runs on it. */
    val canCleanUp: Boolean,
    /** A worktree, while nothing runs on it. */
    val canDiscard: Boolean,
    val pending: Boolean,
    val error: String?,
)

data class ProjectWorkspacesView(
    val projectId: String? = null,
    val workspaces: List<Workspace> = emptyList(),
    val loading: Boolean = false,
    val error: String? = null,
    /** Card IDs with a cleanup or discard in flight. */
    val pending: Set<String> = emptySet(),
    val errors: Map<String, String> = emptyMap(),
    /** Card ID → the conversation's title when the list loaded. */
    val titles: Map<String, String> = emptyMap(),
) {
    val rows: List<ProjectWorkspaceRow>
        get() = workspaces.map { workspace ->
            val worktree = WorkspaceMode.parse(workspace.mode) == WorkspaceMode.WORKTREE
            val pending = workspace.card_id in pending
            val files = workspace.changed_files
            ProjectWorkspaceRow(
                cardId = workspace.card_id,
                title =
                    titles[workspace.card_id]?.ifBlank { null }
                        ?: workspace.branch.ifBlank { null }
                        ?: workspace.card_id,
                detail =
                    listOf(
                            workspace.branch.ifBlank { WorkspaceMode.parse(workspace.mode).title },
                            workspace.state.replace('_', ' '),
                        )
                        .filter { it.isNotBlank() }
                        .joinToString(" · "),
                stats =
                    "${Counts.of(files, "file")} · +${workspace.additions} −${workspace.deletions} · ${ByteSizes.format(workspace.size_bytes)}",
                path = workspace.path,
                conflicted = workspace.state == "conflicted",
                canCleanUp = worktree && files == 0 && !pending,
                canDiscard = worktree && !pending,
                pending = pending,
                error = errors[workspace.card_id],
            )
        }
}

/**
 * A project's conversation workspaces across its checkouts, with cleanup and discard. Each machine
 * lists its own; they are read from every reachable machine with a checkout of the project and
 * listed together.
 */
class ProjectWorkspaces(
    private val sessions: MachineSessions,
    private val store: WorkspaceStore,
    private val choice: MachineChoice,
) {
    private val mutableView = MutableStateFlow(ProjectWorkspacesView())
    val view: StateFlow<ProjectWorkspacesView> = mutableView.asStateFlow()

    suspend fun load(projectId: String) {
        val directory = store.directoryProjection
        val holders =
            directory.projects[projectId]
                ?.checkouts
                .orEmpty()
                .filterNot { it.detached }
                .mapTo(HashSet()) { directory.machine(it.daemon_id) }
        val machines = choice.reachable().filter { it in holders }
        if (machines.isEmpty())
            throw CoreException(
                FailureKind.TRANSIENT,
                "No machine with a checkout of this project is reachable.",
            )
        mutableView.update {
            if (it.projectId == projectId) it.copy(loading = true)
            else ProjectWorkspacesView(projectId, loading = true)
        }
        val results = coroutineScope {
            machines
                .map { daemon ->
                    async {
                        runCatching {
                            sessions
                                .call(daemon, Deadlines.READ) {
                                    it.ListProjectWorkspaces()
                                        .execute(ProjectRef(project_id = projectId))
                                }
                                .workspaces
                        }
                            .onFailure { if (it is CancellationException) throw it }
                    }
                }
                .awaitAll()
        }
        val workspaces = results.flatMap { it.getOrDefault(emptyList()) }.sortedBy { it.card_id }
        val error = results.firstNotNullOfOrNull { it.exceptionOrNull() }?.let(Failures::message)
        val cards = store.state.value
        val titles =
            workspaces
                .mapNotNull { workspace ->
                    cards
                        .card(workspace.card_id)
                        ?.title
                        ?.ifBlank { null }
                        ?.let { workspace.card_id to it }
                }
                .toMap()
        if (view.value.projectId == projectId)
            mutableView.update {
                it.copy(workspaces = workspaces, loading = false, error = error, titles = titles)
            }
    }

    /**
     * Cleans up or discards a worktree workspace on its conversation's machine, waiting for the
     * result.
     */
    suspend fun remove(workspace: Workspace, discard: Boolean) {
        val cardId = workspace.card_id
        if (cardId in view.value.pending) return
        val card = store.directoryProjection.item(cardId)
        val daemon =
            card?.let(store.directoryProjection::owner)
                ?: throw CoreException(
                    FailureKind.TRANSIENT,
                    "The workspace's machine is unavailable.",
                )
        mutableView.update { it.copy(pending = it.pending + cardId, errors = it.errors - cardId) }
        try {
            val started =
                sessions.call(daemon, Deadlines.READ) {
                    it.StartGitOperation()
                        .execute(
                            StartGitOperationRequest(
                                card_id = cardId,
                                kind = if (discard) "discard" else "cleanup",
                                expected_revision = workspace.revision,
                            )
                        )
                }
            val operation = sessions.followGitOperation(daemon, started, REMOVE_POLL)
            if (operation.status != "succeeded")
                mutableView.update {
                    it.copy(
                        errors =
                            it.errors +
                                (cardId to
                                    operation.error.ifEmpty {
                                        "Workspace operation ${operation.status}."
                                    })
                    )
                }
        } catch (error: Throwable) {
            if (error is CancellationException) throw error
            mutableView.update { it.copy(errors = it.errors + (cardId to Failures.message(error))) }
        } finally {
            mutableView.update { it.copy(pending = it.pending - cardId) }
        }
        view.value.projectId?.let { load(it) }
    }

    /** Account or gateway changed: the listed project belongs to the previous one. */
    fun reset() {
        mutableView.value = ProjectWorkspacesView()
    }

    private companion object {
        val REMOVE_POLL = 500.milliseconds
    }
}

/** Project-wide workspace defaults and a checkout's validation commands. */
object ProjectWorkspaceSettings {
    suspend fun update(
        sessions: MachineSessions,
        store: WorkspaceStore,
        choice: MachineChoice,
        project: Project,
        baseRemote: String,
        baseBranch: String,
        checkoutId: String?,
        validation: List<ValidationCommandDraft>?,
    ): Project {
        if (baseBranch.isBlank())
            throw CoreException(FailureKind.PERMANENT, "Enter a workspace base branch.")
        ValidationCommandDraft.problem(validation.orEmpty())?.let {
            throw CoreException(FailureKind.PERMANENT, it)
        }
        val checkout = checkoutId?.let { id -> project.checkouts.firstOrNull { it.id == id } }
        val current = checkout?.validation_commands.orEmpty().map(ValidationCommandDraft::from)
        val changed = validation != null && checkout != null && validation != current
        val daemon =
            if (changed) store.directoryProjection.machine(checkout.daemon_id)
            else
                choice.project(project.id)
                    ?: throw CoreException(
                        FailureKind.TRANSIENT,
                        "No machine with this project is reachable.",
                    )
        val request =
            UpdateProjectWorkspaceSettingsRequest(
                project_id = project.id,
                base_remote = baseRemote.trim(),
                base_branch = baseBranch.trim(),
                checkout_id = if (changed) checkout.id else "",
                validation_commands =
                    if (changed) validation.map { it.toCommand() } else emptyList(),
            )
        return sessions.call(daemon, Deadlines.READ) {
            it.UpdateProjectWorkspaceSettings().execute(request)
        }
    }
}

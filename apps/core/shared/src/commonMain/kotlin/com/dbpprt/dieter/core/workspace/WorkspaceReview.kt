package com.dbpprt.dieter.core.workspace

import com.dbpprt.dieter.api.v1.AddChangeCommentRequest
import com.dbpprt.dieter.api.v1.Card
import com.dbpprt.dieter.api.v1.ChangeComment
import com.dbpprt.dieter.api.v1.Changeset
import com.dbpprt.dieter.api.v1.ConversationRef
import com.dbpprt.dieter.api.v1.FileDiff
import com.dbpprt.dieter.api.v1.GetChangesetRequest
import com.dbpprt.dieter.api.v1.GetDiffRequest
import com.dbpprt.dieter.api.v1.GitOperation
import com.dbpprt.dieter.api.v1.GitOperationLogEntry
import com.dbpprt.dieter.api.v1.GitOperationRef
import com.dbpprt.dieter.api.v1.ListChangeCommentsRequest
import com.dbpprt.dieter.api.v1.SCMCapabilities
import com.dbpprt.dieter.api.v1.StartGitOperationRequest
import com.dbpprt.dieter.api.v1.UpdateConversationWorkspaceRequest
import com.dbpprt.dieter.api.v1.WatchGitOperationRequest
import com.dbpprt.dieter.api.v1.Workspace
import com.dbpprt.dieter.api.v1.WorkspaceSummary
import com.dbpprt.dieter.core.board.BoardOperations
import com.dbpprt.dieter.core.board.Lanes
import com.dbpprt.dieter.core.composition.WorkspaceMode
import com.dbpprt.dieter.core.runtime.Backoff
import com.dbpprt.dieter.core.runtime.CoreException
import com.dbpprt.dieter.core.runtime.FailureKind
import com.dbpprt.dieter.core.runtime.Failures
import com.dbpprt.dieter.core.runtime.withDeadline
import com.dbpprt.dieter.core.session.MachineSessions
import com.dbpprt.dieter.core.store.WorkspaceStore
import com.squareup.wire.GrpcException
import com.squareup.wire.GrpcStatus
import kotlin.coroutines.cancellation.CancellationException
import kotlin.time.Duration
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.seconds
import kotlin.time.TimeSource
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

enum class MergeStep { COMMIT, MERGE, CLEANUP }

enum class MergeStrategy(val wire: String, val title: String) { SQUASH("squash", "Squash"), MERGE_COMMIT("merge_commit", "Merge commit"), FAST_FORWARD("fast_forward", "Fast-forward") }

data class WorkspaceReviewView(
    val cardId: String? = null,
    val daemonId: String? = null,
    val workspace: Workspace? = null,
    val changeset: Changeset? = null,
    val scm: SCMCapabilities? = null,
    val comments: List<ChangeComment> = emptyList(),
    val loading: Boolean = false,
    val error: String? = null,
    val selectedPath: String? = null,
    val selectedCommit: String? = null,
    val diff: FileDiff? = null,
    val diffLines: List<DiffLine> = emptyList(),
    val diffLoading: Boolean = false,
    val operation: GitOperation? = null,
    val logs: List<GitOperationLogEntry> = emptyList(),
    val submitting: Boolean = false,
    /** After a reconnect or an ambiguous start, mutations wait for an authoritative refresh. */
    val needsReconciliation: Boolean = false,
    /** Cleanup, discard, or adopt succeeded; the workspace no longer exists here. */
    val surfaceRemoved: Boolean = false,
    val mergeStep: MergeStep? = null,
    val toast: String? = null,
) {
    val operationActive: Boolean get() = GitOperations.isActive(operation) || submitting || needsReconciliation
    val conflicted: Boolean get() = workspace?.state == "conflicted" || operation?.status == "waiting_for_resolution"
}

/**
 * The review surface of one conversation's workspace: changes, diffs,
 * comments, Git operations, and the merge flow. Runs on the machine that owns
 * the conversation. Start is never retried automatically: it has no
 * idempotency key, so an ambiguous failure is reconciled by refreshing.
 * Confined to the core dispatcher.
 */
class WorkspaceReview(
    private val sessions: MachineSessions,
    private val store: WorkspaceStore,
    private val board: BoardOperations,
    private val scope: CoroutineScope,
) {
    private val mutableView = MutableStateFlow(WorkspaceReviewView())
    val view: StateFlow<WorkspaceReviewView> = mutableView.asStateFlow()
    private var binding = 0L
    private var diffRequest = 0L
    private var inFlight: Deferred<Unit>? = null
    private var refreshAgain = false
    private var poller: Job? = null
    private var watcher: Job? = null
    private var watchedId: String? = null
    private var cursor = 0L

    fun bind(cardId: String?, daemonId: String?) {
        val current = view.value
        if (cardId == current.cardId && daemonId == current.daemonId) return
        binding++
        poller?.cancel()
        watcher?.cancel()
        watchedId = null
        cursor = 0
        mutableView.value = WorkspaceReviewView(cardId = cardId, daemonId = daemonId, needsReconciliation = cardId != null)
    }

    /** Visible and foregrounded: refresh every 5 s, including while idle. */
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

    private fun owns(bound: Long) = bound == binding

    private fun target(): Pair<String, String> {
        val state = view.value
        val card = state.cardId ?: throw CoreException(FailureKind.PERMANENT, "Open a conversation first.")
        val daemon = state.daemonId ?: throw CoreException(FailureKind.TRANSIENT, "The conversation's machine is unavailable.")
        return card to daemon
    }

    private suspend fun <T> call(daemonId: String, timeout: Duration, block: suspend (com.dbpprt.dieter.api.v1.DieterServiceClient) -> T): T =
        withDeadline(timeout) { sessions.call(daemonId, block) }

    /**
     * Reads the workspace and changeset. A refresh requested while one runs
     * joins it and triggers one more read, so on return the state is at least
     * as new as the call; the merge flow relies on that for fresh revisions.
     */
    suspend fun refresh() {
        inFlight?.takeIf { it.isActive }?.let { running ->
            refreshAgain = true
            running.await()
            return
        }
        val bound = binding
        val reading = scope.async {
            do {
                refreshAgain = false
                read()
            } while (refreshAgain && owns(bound))
        }
        inFlight = reading
        reading.await()
    }

    private suspend fun read() {
        val (cardId, daemonId) = target()
        val bound = binding
        mutableView.update { it.copy(loading = it.workspace == null) }
        try {
            val (workspace, changeset) = coroutineScope {
                val workspace = async { call(daemonId, PROVISION_TIMEOUT) { it.GetWorkspace().execute(ConversationRef(card_id = cardId)) } }
                val changeset = async { call(daemonId, READ_TIMEOUT) { it.GetChangeset().execute(GetChangesetRequest(card_id = cardId)) } }
                workspace.await() to changeset.await()
            }
            if (!owns(bound)) return
            val previous = view.value
            val revisionChanged = previous.changeset?.revision != changeset.revision
            val comments = if (revisionChanged) {
                runCatching { call(daemonId, READ_TIMEOUT) { it.ListChangeComments().execute(ListChangeCommentsRequest(card_id = cardId, revision = changeset.revision)) }.comments }
                    .onFailure { if (it is CancellationException) throw it }.getOrDefault(emptyList())
            } else {
                previous.comments
            }
            val scm = previous.scm ?: runCatching { call(daemonId, READ_TIMEOUT) { it.GetSCMCapabilities().execute(ConversationRef(card_id = cardId)) } }
                .onFailure { if (it is CancellationException) throw it }.getOrNull()
            if (!owns(bound)) return
            mutableView.update {
                it.copy(workspace = workspace, changeset = changeset, comments = comments, scm = scm, loading = false, error = null, needsReconciliation = false, surfaceRemoved = false)
            }
            acceptSummary(workspace)
            resolveSelection(revisionChanged)
            GitOperations.reconciliationId(workspace.current_operation_id, view.value.operation, cardId)?.let { resume(it) }
        } catch (error: Throwable) {
            if (error is CancellationException) throw error
            if (owns(bound)) mutableView.update { it.copy(loading = false, error = Failures.message(error)) }
        }
    }

    /** The board card shows the workspace summary the owner just reported. */
    private fun acceptSummary(workspace: Workspace) {
        val cardId = view.value.cardId ?: return
        val card = store.directoryProjection.item(cardId) ?: return
        val summary = WorkspaceSummary(
            mode = workspace.mode, state = workspace.state, branch = workspace.branch, base_branch = workspace.base_branch,
            head_sha = workspace.head_sha, base_sha = workspace.base_sha, revision = workspace.revision, changed_files = workspace.changed_files,
            additions = workspace.additions, deletions = workspace.deletions, ahead = workspace.ahead, behind = workspace.behind,
            current_operation_id = workspace.current_operation_id,
        )
        if (card.workspace != summary) store.foldCard(card.copy(workspace = summary), view.value.daemonId)
    }

    private suspend fun resolveSelection(revisionChanged: Boolean) {
        val state = view.value
        val files = state.changeset?.files.orEmpty()
        val commits = state.changeset?.commits.orEmpty()
        val commit = state.selectedCommit?.takeIf { sha -> commits.any { it.sha == sha } }
        val path = state.selectedPath?.takeIf { selected -> files.any { it.path == selected } || commit != null }
        val nextPath = path ?: if (commit == null) files.firstOrNull()?.path else null
        if (nextPath == null && commit == null) {
            mutableView.update { it.copy(selectedPath = null, selectedCommit = null, diff = null, diffLines = emptyList()) }
            return
        }
        val moved = nextPath != state.selectedPath || commit != state.selectedCommit
        mutableView.update { it.copy(selectedPath = nextPath, selectedCommit = commit) }
        if (revisionChanged || moved || state.diff == null) loadDiff(append = false, retryStale = false)
    }

    /** Shows [path] (or a whole commit when [commit] is set and [path] is empty). */
    suspend fun select(path: String?, commit: String? = null) {
        mutableView.update { it.copy(selectedPath = path, selectedCommit = commit, diff = null, diffLines = emptyList()) }
        loadDiff(append = false, retryStale = true)
    }

    suspend fun loadMoreDiff() {
        val state = view.value
        if (state.diffLoading || state.diff?.truncated != true) return
        loadDiff(append = true, retryStale = true)
    }

    private suspend fun loadDiff(append: Boolean, retryStale: Boolean) {
        val (cardId, daemonId) = target()
        val state = view.value
        val changeset = state.changeset ?: return
        val path = state.selectedPath.orEmpty()
        val commit = state.selectedCommit.orEmpty()
        val bound = binding
        val request = ++diffRequest
        mutableView.update { it.copy(diffLoading = true) }
        try {
            val diffRequestMessage = GetDiffRequest(
                card_id = cardId, path = path, commit_sha = commit, expected_revision = changeset.revision,
                offset = if (append) state.diff?.next_offset ?: 0 else 0, limit = DIFF_PAGE,
            )
            val page = call(daemonId, READ_TIMEOUT) { client ->
                if (commit.isNotEmpty()) client.GetCommitDiff().execute(diffRequestMessage) else client.GetFileDiff().execute(diffRequestMessage)
            }
            val current = view.value
            if (!owns(bound) || request != diffRequest || current.changeset?.revision != changeset.revision ||
                current.selectedPath.orEmpty() != path || current.selectedCommit.orEmpty() != commit
            ) return
            val combined = if (append && current.diff != null) page.copy(patch = current.diff.patch + page.patch) else page
            mutableView.update { it.copy(diff = combined, diffLines = UnifiedDiff.parse(combined.patch), diffLoading = false) }
        } catch (error: Throwable) {
            if (error is CancellationException) throw error
            if (owns(bound) && request == diffRequest) mutableView.update { it.copy(diffLoading = false) }
            if (error is GrpcException && error.grpcStatus == GrpcStatus.ABORTED) {
                // The workspace changed under the diff; one user-initiated refresh brings the new revision.
                if (retryStale && owns(bound)) {
                    mutableView.update { it.copy(error = "The workspace changed while this diff was open. Refreshing…") }
                    refresh()
                }
                return
            }
            if (owns(bound)) mutableView.update { it.copy(error = Failures.message(error)) }
        }
    }

    /** Comments attach to one line of the current revision; whole-commit diffs take none. */
    suspend fun addComment(line: DiffLine, body: String, author: String): ChangeComment? {
        val (cardId, daemonId) = target()
        val state = view.value
        val path = state.selectedPath.orEmpty()
        val changeset = state.changeset ?: return null
        if (path.isEmpty() || body.isBlank() || state.selectedCommit != null) return null
        val (side, lineNumber) = ReviewComments.anchor(line) ?: return null
        val bound = binding
        val comment = call(daemonId, READ_TIMEOUT) {
            it.AddChangeComment().execute(
                AddChangeCommentRequest(card_id = cardId, path = path, side = side, line = lineNumber, body = body.trim(), author = author, revision = changeset.revision),
            )
        }
        if (owns(bound) && view.value.changeset?.revision == changeset.revision) mutableView.update { it.copy(comments = it.comments + comment) }
        return comment
    }

    fun availability(card: Card): WorkspaceAvailability {
        val state = view.value
        return WorkspaceAvailability.of(card, state.workspace, state.changeset, state.scm, state.operation, state.submitting || state.needsReconciliation)
    }

    /** Starts a Git operation against the current revision. Never retried automatically. */
    suspend fun start(kind: String, parameters: Map<String, String> = emptyMap()): GitOperation? {
        val (cardId, daemonId) = target()
        if (view.value.submitting) return null
        val bound = binding
        mutableView.update { it.copy(submitting = true, error = null) }
        try {
            val operation = call(daemonId, READ_TIMEOUT) {
                it.StartGitOperation().execute(StartGitOperationRequest(card_id = cardId, kind = kind, expected_revision = view.value.changeset?.revision.orEmpty(), parameters = parameters))
            }
            if (!owns(bound)) return operation
            cursor = 0
            mutableView.update { it.copy(operation = operation, logs = emptyList(), needsReconciliation = GitOperations.isTerminal(operation)) }
            observe(operation.id)
            return operation
        } catch (error: Throwable) {
            if (error is CancellationException) throw error
            // The start may have been admitted; the next refresh reconciles through current_operation_id.
            if (owns(bound)) mutableView.update { it.copy(error = Failures.message(error), needsReconciliation = true) }
            return null
        } finally {
            if (owns(bound)) mutableView.update { it.copy(submitting = false) }
        }
    }

    private suspend fun resume(id: String) {
        val (cardId, daemonId) = target()
        val bound = binding
        val observed = if (view.value.operation?.id == id) view.value.operation else runCatching {
            call(daemonId, READ_TIMEOUT) { it.GetGitOperation().execute(GitOperationRef(operation_id = id)) }
        }.onFailure { if (it is CancellationException) throw it }.getOrNull()
        if (!owns(bound) || observed == null || observed.card_id != cardId) return
        if (view.value.operation?.id != id) {
            cursor = 0
            mutableView.update { it.copy(operation = observed, logs = emptyList()) }
        }
        if (GitOperations.isActive(observed)) observe(id) else if (watchedId == id) {
            watcher?.cancel()
            watchedId = null
        }
    }

    private fun observe(id: String) {
        if (watchedId == id && watcher?.isActive == true) return
        watcher?.cancel()
        watchedId = id
        val bound = binding
        val daemonId = view.value.daemonId ?: return
        watcher = scope.launch {
            var attempt = 0
            while (owns(bound) && watchedId == id) {
                try {
                    coroutineScope {
                        sessions.call(daemonId) { client ->
                            val call = client.WatchGitOperation()
                            val frames = call.executeIn(this, WatchGitOperationRequest(operation_id = id, after_sequence = cursor, heartbeat_ms = HEARTBEAT_MS))
                            try {
                                for (frame in frames) {
                                    val operation = frame.operation?.takeIf { it.id == id } ?: continue
                                    attempt = 0
                                    val previous = view.value.operation
                                    cursor = GitOperations.cursor(cursor, operation, frame.logs)
                                    mutableView.update { state ->
                                        state.copy(operation = operation, logs = GitOperations.trimLogs(GitOperations.mergeLogs(state.logs, frame.logs)))
                                    }
                                    if (operation.status == "waiting_for_resolution" && previous?.status != "waiting_for_resolution") launch { refresh() }
                                }
                            } finally {
                                call.cancel()
                            }
                        }
                    }
                    // The stream ends when the operation settles.
                    settle(id)
                    return@launch
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (error: Throwable) {
                    if (error is GrpcException && error.grpcStatus == GrpcStatus.NOT_FOUND) {
                        if (owns(bound)) mutableView.update { it.copy(operation = null) }
                        return@launch
                    }
                    if (!Failures.isRetryableRead(error)) {
                        if (owns(bound)) mutableView.update { it.copy(error = Failures.message(error)) }
                        return@launch
                    }
                    delay(Backoff.STREAM.delay(attempt++))
                }
            }
        }
    }

    private suspend fun settle(id: String) {
        val operation = view.value.operation?.takeIf { it.id == id } ?: return
        if (watchedId == id) watchedId = null
        if (operation.status == "succeeded" && operation.kind in GitOperations.REMOVES_WORKSPACE) {
            mutableView.update {
                it.copy(workspace = null, changeset = null, diff = null, diffLines = emptyList(), comments = emptyList(), selectedPath = null, selectedCommit = null, surfaceRemoved = true)
            }
            return
        }
        if (operation.status == "succeeded") mutableView.update { it.copy(toast = "${GitOperations.title(operation.kind)} succeeded") }
        refresh()
    }

    /** Cancels a running operation; one waiting on a conflict is aborted instead. */
    suspend fun cancelOperation() {
        val (_, daemonId) = target()
        val operation = view.value.operation ?: return
        if (!GitOperations.isActive(operation) || operation.status == "waiting_for_resolution") return
        val bound = binding
        val canceled = call(daemonId, READ_TIMEOUT) { it.CancelGitOperation().execute(GitOperationRef(operation_id = operation.id)) }
        if (owns(bound)) mutableView.update { it.copy(operation = canceled) }
    }

    /** Waits for [id] to settle, surviving dropped streams; true when it succeeded. */
    private suspend fun awaitSuccess(id: String, bound: Long): Boolean {
        val daemonId = view.value.daemonId ?: return false
        val started = TimeSource.Monotonic.markNow()
        while (owns(bound) && started.elapsedNow() < MERGE_DEADLINE) {
            val observed = view.value.operation?.takeIf { it.id == id && it.status !in GitOperations.ACTIVE - "waiting_for_resolution" }
                ?: runCatching { call(daemonId, READ_TIMEOUT) { it.GetGitOperation().execute(GitOperationRef(operation_id = id)) } }
                    .onFailure { if (it is CancellationException) throw it }.getOrNull()
            if (observed != null && (observed.status in GitOperations.TERMINAL || observed.status == "waiting_for_resolution")) return observed.status == "succeeded"
            delay(MERGE_POLL)
        }
        return false
    }

    /**
     * Commits pending changes, merges into the base, optionally removes the
     * workspace, and optionally moves the card to Done. Any failed step stops
     * the flow; nothing after it runs.
     */
    suspend fun mergeFlow(
        strategy: MergeStrategy,
        subject: String,
        body: String = "",
        validate: Boolean = true,
        removeWorkspace: Boolean = true,
        moveToDone: Boolean = true,
    ): Boolean {
        val (cardId, _) = target()
        if (view.value.mergeStep != null || subject.isBlank()) return false
        val bound = binding
        // Cleanup removes the workspace, so name the branches before it runs.
        val summary = store.directoryProjection.item(cardId)?.workspace
        val branch = view.value.workspace?.branch?.ifEmpty { null } ?: summary?.branch?.ifEmpty { null } ?: "workspace"
        val base = view.value.workspace?.base_branch?.ifEmpty { null } ?: summary?.base_branch?.ifEmpty { null } ?: "base"
        try {
            if (view.value.workspace?.dirty == true) {
                mutableView.update { it.copy(mergeStep = MergeStep.COMMIT) }
                val commit = start("commit", mapOf("subject" to subject.trim(), "body" to body, "stage_all" to "true")) ?: return false
                if (!awaitSuccess(commit.id, bound)) return false
                refresh()
            }
            if (!owns(bound)) return false
            mutableView.update { it.copy(mergeStep = MergeStep.MERGE) }
            val merge = start("merge_local", mapOf("strategy" to strategy.wire, "subject" to subject.trim(), "validate" to validate.toString())) ?: return false
            if (!awaitSuccess(merge.id, bound)) return false
            if (removeWorkspace) {
                if (!owns(bound)) return false
                mutableView.update { it.copy(mergeStep = MergeStep.CLEANUP) }
                refresh()
                val cleanup = start("cleanup") ?: return false
                if (!awaitSuccess(cleanup.id, bound)) return false
            }
            var moved = false
            val card = store.directoryProjection.item(cardId)
            if (moveToDone && card != null && card.scope != "chat") {
                val done = Lanes.done(store.directoryProjection.board(card.board_id))
                if (done != null && !card.lane.equals(done.id, ignoreCase = true)) {
                    try {
                        board.move(cardId, done.id)
                        moved = true
                    } catch (error: Throwable) {
                        if (error is CancellationException) throw error
                        if (owns(bound)) mutableView.update { it.copy(error = Failures.message(error)) }
                        return false
                    }
                }
            }
            if (owns(bound)) mutableView.update { it.copy(toast = "Merged $branch into $base" + if (moved) " · card moved to Done" else "") }
            return true
        } finally {
            if (owns(bound)) mutableView.update { it.copy(mergeStep = null) }
        }
    }

    /** Changes the workspace before the first turn; later changes are refused by the daemon. */
    suspend fun updateSettings(mode: WorkspaceMode, branch: String = "", baseBranch: String = "", baseRemote: String = "", publishMode: String = "") {
        val (cardId, daemonId) = target()
        val worktree = mode == WorkspaceMode.WORKTREE
        val card = call(daemonId, READ_TIMEOUT) {
            it.UpdateConversationWorkspace().execute(
                UpdateConversationWorkspaceRequest(
                    card_id = cardId, mode = mode.wire, branch = if (worktree) branch.trim() else "", base_branch = if (worktree) baseBranch.trim() else "",
                    base_remote = baseRemote.trim(), remote_publish_mode = publishMode.trim(),
                ),
            )
        }
        store.foldCard(card, daemonId)
        refresh()
    }

    fun clearToast() = mutableView.update { it.copy(toast = null) }

    /** Dismisses a shown error; the next refresh or operation reports a new one. */
    fun clearError() = mutableView.update { it.copy(error = null) }

    companion object {
        const val DIFF_PAGE = 1 shl 20
        const val HEARTBEAT_MS = 15_000
        private val REFRESH = 5.seconds
        private val READ_TIMEOUT = 30.seconds
        private val PROVISION_TIMEOUT = 60.seconds
        private val MERGE_DEADLINE = 3600.seconds
        private val MERGE_POLL = 400.milliseconds
    }
}

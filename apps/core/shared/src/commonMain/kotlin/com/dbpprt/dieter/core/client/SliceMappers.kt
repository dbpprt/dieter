package com.dbpprt.dieter.core.client

import com.dbpprt.dieter.api.v1.Card
import com.dbpprt.dieter.api.v1.ChangeComment
import com.dbpprt.dieter.api.v1.Harness
import com.dbpprt.dieter.client.v1.AgentControlsState
import com.dbpprt.dieter.client.v1.ConversationSlice
import com.dbpprt.dieter.client.v1.DiffDisplayLine
import com.dbpprt.dieter.client.v1.DiffDisplayRow
import com.dbpprt.dieter.client.v1.DiffFileBoundary
import com.dbpprt.dieter.client.v1.DiffFold
import com.dbpprt.dieter.client.v1.DiffHunk
import com.dbpprt.dieter.client.v1.DiffPair
import com.dbpprt.dieter.client.v1.DiffRow
import com.dbpprt.dieter.client.v1.FileTreeFolder
import com.dbpprt.dieter.client.v1.FileTreeSlice
import com.dbpprt.dieter.client.v1.FilesSlice
import com.dbpprt.dieter.client.v1.FilesTarget as ClientFilesTarget
import com.dbpprt.dieter.client.v1.MachineOperationState
import com.dbpprt.dieter.client.v1.MachineReadings
import com.dbpprt.dieter.client.v1.MergeReadiness as ClientMergeReadiness
import com.dbpprt.dieter.client.v1.MergeStrategyOption
import com.dbpprt.dieter.client.v1.MessageDelivery
import com.dbpprt.dieter.client.v1.OverviewTerminal
import com.dbpprt.dieter.client.v1.ProcessesSlice
import com.dbpprt.dieter.client.v1.ProjectChangeSelect
import com.dbpprt.dieter.client.v1.ProjectChangesSlice
import com.dbpprt.dieter.client.v1.ProjectWorkspaceRow as ClientProjectWorkspaceRow
import com.dbpprt.dieter.client.v1.ProjectWorkspacesSlice
import com.dbpprt.dieter.client.v1.PullRequestSignal
import com.dbpprt.dieter.client.v1.PullRequestView as ClientPullRequestView
import com.dbpprt.dieter.client.v1.QuotasSlice
import com.dbpprt.dieter.client.v1.ReviewSlice
import com.dbpprt.dieter.client.v1.Samples
import com.dbpprt.dieter.client.v1.SchedulesSlice
import com.dbpprt.dieter.client.v1.ScreenPreferences as ClientScreenPreferences
import com.dbpprt.dieter.client.v1.ScreenSlice
import com.dbpprt.dieter.client.v1.TelemetrySlice
import com.dbpprt.dieter.client.v1.TerminalOutput
import com.dbpprt.dieter.client.v1.TerminalOverviewSlice
import com.dbpprt.dieter.client.v1.TerminalTarget
import com.dbpprt.dieter.client.v1.TerminalsSlice
import com.dbpprt.dieter.client.v1.TimelineItem as ClientTimelineItem
import com.dbpprt.dieter.client.v1.TimelineStep as ClientTimelineStep
import com.dbpprt.dieter.client.v1.TimelineStepGroup
import com.dbpprt.dieter.client.v1.TimelineStepKind
import com.dbpprt.dieter.client.v1.ToolCallStatus
import com.dbpprt.dieter.client.v1.TurnFailure as ClientTurnFailure
import com.dbpprt.dieter.client.v1.WorkspaceAvailability as ClientWorkspaceAvailability
import com.dbpprt.dieter.core.admin.MachineOperations
import com.dbpprt.dieter.core.admin.TelemetryView
import com.dbpprt.dieter.core.client.rules.WorkspaceExports
import com.dbpprt.dieter.core.conversation.ConversationView
import com.dbpprt.dieter.core.executions.ProcessesView
import com.dbpprt.dieter.core.files.FileTree
import com.dbpprt.dieter.core.files.FilesTarget
import com.dbpprt.dieter.core.files.FilesView
import com.dbpprt.dieter.core.presentation.ActivitySummary
import com.dbpprt.dieter.core.presentation.ConversationPresentation
import com.dbpprt.dieter.core.presentation.ConversationPresenter
import com.dbpprt.dieter.core.presentation.Delivery
import com.dbpprt.dieter.core.presentation.DeliveryState
import com.dbpprt.dieter.core.presentation.StepGroup
import com.dbpprt.dieter.core.presentation.StepKind
import com.dbpprt.dieter.core.presentation.TimelineItem
import com.dbpprt.dieter.core.presentation.TimelineStep
import com.dbpprt.dieter.core.presentation.ToolStatus
import com.dbpprt.dieter.core.presentation.Tools
import com.dbpprt.dieter.core.quotas.QuotaRows
import com.dbpprt.dieter.core.quotas.QuotasView
import com.dbpprt.dieter.core.schedules.SchedulesPresentation
import com.dbpprt.dieter.core.schedules.SchedulesView
import com.dbpprt.dieter.core.screens.DisplayMatchView
import com.dbpprt.dieter.core.screens.ScreenPhase
import com.dbpprt.dieter.core.screens.ScreenPreferences
import com.dbpprt.dieter.core.screens.ScreenView
import com.dbpprt.dieter.core.terminals.TerminalOverviewView
import com.dbpprt.dieter.core.terminals.TerminalRendererSink
import com.dbpprt.dieter.core.terminals.TerminalReplayCursor
import com.dbpprt.dieter.core.terminals.TerminalScope
import com.dbpprt.dieter.core.terminals.TerminalScopeKind
import com.dbpprt.dieter.core.terminals.TerminalsView
import com.dbpprt.dieter.core.workspace.ChangeSection
import com.dbpprt.dieter.core.workspace.DiffLayout
import com.dbpprt.dieter.core.workspace.DiffLine
import com.dbpprt.dieter.core.workspace.DiffLineKind
import com.dbpprt.dieter.core.workspace.DiffPages
import com.dbpprt.dieter.core.workspace.DiffRow as LaidOutRow
import com.dbpprt.dieter.core.workspace.GitOperationKinds
import com.dbpprt.dieter.core.workspace.MergeReadiness
import com.dbpprt.dieter.core.workspace.ProjectChangesView
import com.dbpprt.dieter.core.workspace.ProjectWorkspacesView
import com.dbpprt.dieter.core.workspace.PullRequestView
import com.dbpprt.dieter.core.workspace.ReviewComments
import com.dbpprt.dieter.core.workspace.ReviewPresentation
import com.dbpprt.dieter.core.workspace.WorkspaceAvailability
import com.dbpprt.dieter.core.workspace.WorkspaceReviewView
import com.dbpprt.dieter.core.workspace.WorkspaceStatus
import okio.Buffer
import okio.ByteString

// Maps the views of view-owned surfaces to their contract slices.

/** Git operations a conversation's review offers, in menu order. */
private val REVIEW_KINDS = listOf(
    GitOperationKinds.COMMIT, GitOperationKinds.UPDATE, GitOperationKinds.VALIDATE, GitOperationKinds.MERGE_LOCAL, GitOperationKinds.PUSH,
    GitOperationKinds.CREATE_PR, GitOperationKinds.REFRESH_PR, GitOperationKinds.MERGE_PR, GitOperationKinds.ADOPT, GitOperationKinds.DISCARD,
    GitOperationKinds.CLEANUP, GitOperationKinds.CONTINUE_CONFLICT, GitOperationKinds.ABORT_CONFLICT,
)

internal fun filesTarget(target: ClientFilesTarget): FilesTarget? =
    if (target.daemon_id.isEmpty() || target.project_id.isEmpty()) null
    else FilesTarget(target.daemon_id, target.project_id, target.checkout_id, target.card_id)

internal fun filesSlice(view: FilesView, documentUnchanged: Boolean) = FilesSlice(
    target = view.target?.let { ClientFilesTarget(it.daemonId, it.projectId, it.checkoutId, it.cardId) },
    directory = view.directory, entries = view.entries, show_hidden = view.showHidden,
    listing_loading = view.listingLoading, listing_error = view.listingError.orEmpty(), selected_path = view.selectedPath,
    document = if (documentUnchanged) null else view.document, document_unchanged = documentUnchanged,
    document_loading = view.documentLoading, document_error = view.documentError.orEmpty(), conflict = view.conflict,
    saving = view.saving, can_go_back = view.canGoBack, can_go_forward = view.canGoForward,
    document_key = view.documentKey, language_name = view.languageName, type_label = view.typeLabel,
)

internal fun fileTreeSlice(view: FileTree.TreeView) = FileTreeSlice(
    folders = view.folders.entries.sortedBy { it.key }.map { (path, entries) -> FileTreeFolder(path, entries) },
    expanded = view.expanded.sorted(), loading = view.loading.sorted(), error = view.error.orEmpty(), show_hidden = view.showHidden,
)

private fun diffRow(line: DiffLine) = DiffRow(
    id = line.id,
    kind = when (line.kind) {
        DiffLineKind.HEADER -> DiffRow.Kind.KIND_HEADER
        DiffLineKind.HUNK -> DiffRow.Kind.KIND_HUNK
        DiffLineKind.CONTEXT -> DiffRow.Kind.KIND_CONTEXT
        DiffLineKind.ADDITION -> DiffRow.Kind.KIND_ADDITION
        DiffLineKind.DELETION -> DiffRow.Kind.KIND_DELETION
    },
    text = line.text, old_line = line.oldLine ?: 0, new_line = line.newLine ?: 0,
)

/** [layout]'s rows; a line takes [comments] by anchor and, when [commentable], new ones. */
private fun displayRows(layout: DiffLayout, comments: Map<Pair<String, Int>, List<ChangeComment>>, commentable: Boolean): List<DiffDisplayRow> {
    fun line(line: DiffLine): DiffDisplayLine {
        val anchor = ReviewComments.anchor(line)
        return DiffDisplayLine(row = diffRow(line), comments = anchor?.let { comments[it] }.orEmpty(), commentable = commentable && anchor != null)
    }
    fun pair(pair: LaidOutRow.Pair) = DiffPair(id = pair.id, before = pair.old?.let(::diffRow), after = pair.new?.let(::diffRow))
    return layout.rows.map { row ->
        when (row) {
            is LaidOutRow.Line -> DiffDisplayRow(line = line(row.line))
            is LaidOutRow.Pair -> DiffDisplayRow(pair = pair(row))
            is LaidOutRow.File -> DiffDisplayRow(file_boundary = DiffFileBoundary(id = row.id, path = row.path))
            is LaidOutRow.Hunk -> DiffDisplayRow(hunk = DiffHunk(id = row.id, text = row.text, skipped_lines = row.skippedLines, additions = row.additions, deletions = row.deletions))
            is LaidOutRow.Fold -> DiffDisplayRow(fold = DiffFold(id = row.id, count = row.count, lines = row.lines.map(::line), pairs = row.pairs.map(::pair)))
        }
    }
}

private fun pullRequestView(pr: PullRequestView) = ClientPullRequestView(
    number = pr.number, url = pr.url, state_label = pr.stateLabel, state_tone = WorkspaceExports.tone(pr.stateTone),
    signals = pr.signals.map { PullRequestSignal(id = it.id, text = it.text, tone = WorkspaceExports.tone(it.tone)) },
    merge_blocked_reason = pr.mergeBlockedReason.orEmpty(), can_ask_agent = pr.canAskAgent, ask_agent_prompt = pr.askAgentPrompt, last_synced_at = pr.lastSyncedAt,
)

private fun mergeReadiness(readiness: MergeReadiness) = ClientMergeReadiness(
    items = readiness.items.map { ClientMergeReadiness.Item(id = it.id, tone = WorkspaceExports.tone(it.tone), text = it.text, detail = it.detail, at = it.at) },
    blocked = readiness.blocked, merge_title = readiness.mergeTitle,
    validation_summary = readiness.validation?.text.orEmpty(), validation_passed = readiness.validation?.passed == true, validation_at = readiness.validation?.at.orEmpty(),
    strategies = readiness.strategies.map { MergeStrategyOption(strategy = it.strategy, title = it.title, caption = it.caption) },
    merge_failed = readiness.mergeFailed,
)

/**
 * [card] is the reviewed card, which availability and the pull request
 * follow; [diffUnchanged] leaves out the display rows the view already has.
 */
internal fun reviewSlice(view: WorkspaceReviewView, card: Card? = null, diffUnchanged: Boolean = false): ReviewSlice {
    val presentation = ReviewPresentation.of(view, card)
    // Comments attach to one line of one file's diff, never to a whole commit.
    val commentable = !view.selectedPath.isNullOrEmpty() && view.selectedCommit == null
    return ReviewSlice(
        card_id = view.cardId.orEmpty(), daemon_id = view.daemonId.orEmpty(), workspace = view.workspace, changeset = view.changeset,
        scm = view.scm, comments = view.comments, loading = view.loading, error = view.error.orEmpty(),
        selected_path = view.selectedPath.orEmpty(), selected_commit = view.selectedCommit.orEmpty(),
        diff = view.diff?.copy(patch = ""), diff_loading = view.diffLoading,
        operation = view.operation, logs = view.logs, submitting = view.submitting, needs_reconciliation = view.needsReconciliation,
        merge_step = view.mergeStep?.name?.lowercase().orEmpty(), toast = view.toast.orEmpty(),
        operation_active = view.operationActive, conflicted = view.conflicted,
        availability = card?.let {
            val availability = WorkspaceAvailability.of(it, view.workspace, view.changeset, view.scm, view.operation, view.submitting || view.needsReconciliation)
            ClientWorkspaceAvailability(
                allowed = REVIEW_KINDS.filter(availability::allows), allows_merge_flow = availability.allowsMergeFlow,
                merge_destination = availability.mergeDestination, has_review_branch = availability.hasReviewBranch,
                mode = availability.mode.wire,
            )
        },
        display_rows = if (diffUnchanged) emptyList() else displayRows(view.layout, ReviewComments.byLine(view.comments, view.selectedPath), commentable),
        diff_max_columns = view.layout.maxColumns, diff_unchanged = diffUnchanged, diff_more = view.diffMore, diff_too_large = view.diffTooLarge,
        diff_note = if (view.diffTooLarge) DiffPages.TOO_LARGE else "", split = view.split,
        operation_visible = presentation.operationVisible, operation_cancelable = presentation.operationCancelable,
        conflict_title = presentation.conflictTitle, conflict_prompt = presentation.conflictPrompt, moves_to_done = presentation.movesToDone,
        pull_request = presentation.pullRequest?.let(::pullRequestView), merge_readiness = mergeReadiness(presentation.mergeReadiness),
        workspace_state = WorkspaceStatus.stateLabel(view.workspace?.state.orEmpty()),
    )
}

/** Whether [next] shows the same display rows as [previous]: the same layout, comments, and file. */
internal fun reviewDiffUnchanged(previous: WorkspaceReviewView?, next: WorkspaceReviewView): Boolean =
    previous != null && previous.layout === next.layout && previous.comments == next.comments && previous.selectedPath == next.selectedPath && previous.selectedCommit == next.selectedCommit

/** [diffUnchanged] leaves out the display rows the view already has. */
internal fun projectChangesSlice(view: ProjectChangesView, diffUnchanged: Boolean = false) = ProjectChangesSlice(
    project_id = view.projectId.orEmpty(), checkout_id = view.checkoutId.orEmpty(), daemon_id = view.daemonId.orEmpty(),
    changes = view.changes, selection = view.selection?.let { (path, section) -> ProjectChangeSelect(path, section == ChangeSection.STAGED) },
    diff = view.diff?.copy(patch = ""), diff_loading = view.diffLoading, operation = view.operation,
    pending_kind = view.pendingKind.orEmpty(), needs_reconciliation = view.needsReconciliation, refreshing = view.refreshing,
    refresh_error = view.refreshError.orEmpty(), diff_error = view.diffError.orEmpty(), operation_error = view.operationError.orEmpty(),
    notice = view.notice.orEmpty(), busy = view.busy, mutations_disabled = view.mutationsDisabled,
    display_rows = if (diffUnchanged) emptyList() else displayRows(view.layout, emptyMap(), commentable = false),
    diff_max_columns = view.layout.maxColumns, diff_unchanged = diffUnchanged, diff_more = view.diffMore, diff_too_large = view.diffTooLarge,
    diff_note = if (view.diffTooLarge) DiffPages.TOO_LARGE else "", split = view.split, allowed = view.allowed,
)

internal fun projectWorkspacesSlice(view: ProjectWorkspacesView) = ProjectWorkspacesSlice(
    error = view.error.orEmpty(), errors = view.errors,
    rows = view.rows.map {
        ClientProjectWorkspaceRow(
            card_id = it.cardId, title = it.title, detail = it.detail, stats = it.stats, path = it.path, conflicted = it.conflicted,
            can_clean_up = it.canCleanUp, can_discard = it.canDiscard, pending = it.pending, error = it.error.orEmpty(),
        )
    },
)

internal fun screenSlice(view: ScreenView, displays: DisplayMatchView, preferences: ScreenPreferences, cursorUnchanged: Boolean) = ScreenSlice(
    phase = view.phase.wire,
    phase_label = view.phase.label,
    problem = view.phase.problem ?: (view.phase as? ScreenPhase.Reconnecting)?.reason.orEmpty(),
    active = view.phase.active, capabilities = view.capabilities, state = view.state,
    control_active = view.controlActive, can_transfer_control = view.canTransferControl, control_transferring = view.controlTransferring,
    control_error = view.controlError.orEmpty(), codec_fallback_reason = view.codecFallbackReason.orEmpty(),
    clipboard_enabled = view.clipboardEnabled, clipboard_error = view.clipboardError.orEmpty(), clipboard_busy = view.clipboardBusy,
    clipboard_operations = view.clipboardOperations,
    cursor_image = if (cursorUnchanged) ByteString.EMPTY else view.cursorImage ?: ByteString.EMPTY, cursor_image_unchanged = cursorUnchanged,
    cursor_x = view.cursorX, cursor_y = view.cursorY, cursor_visible = view.cursorVisible, cursor_width = view.cursorWidth,
    cursor_height = view.cursorHeight, cursor_hotspot_x = view.cursorHotspotX, cursor_hotspot_y = view.cursorHotspotY,
    route_label = view.routeLabel,
    preferences = ClientScreenPreferences(
        codec = preferences.codec, max_fps = preferences.maxFps, quality = preferences.quality, display_id = preferences.displayId.orEmpty(),
        clipboard = preferences.clipboard,
    ),
    display_status = displays.status,
    frame_rates = view.frameRates, control_unavailable_reason = view.controlUnavailableReason,
    clipboard_actions_enabled = view.clipboardActionsEnabled, latency_label = view.latencyLabel,
)

internal fun processesSlice(view: ProcessesView) = ProcessesSlice(
    daemon_id = view.target?.daemonId.orEmpty(), project_id = view.target?.projectId.orEmpty(), card_id = view.target?.cardId.orEmpty(),
    processes = view.processes, selected_id = view.selectedId.orEmpty(), stdout = view.stdout, stderr = view.stderr,
    output_truncated = view.outputTruncated, loading = view.loading, stopping = view.stopping, error = view.error.orEmpty(),
    running = view.running, can_stop = view.canStop,
)

internal fun telemetrySlice(view: TelemetryView) = TelemetrySlice(
    machines = view.machines.mapValues { (_, machine) ->
        MachineReadings(
            information = machine.information, loading = machine.loading, error = machine.error.orEmpty(),
            cpu_history = machine.cpuHistory, gpu_history = machine.gpuHistory.mapValues { Samples(it.value) },
            operations = MachineOperations.availability(machine.information).map { MachineOperationState(it.action, it.available, it.unavailableReason) },
        )
    },
    operation_pending = view.operationPending, operation_result = view.operationResult.orEmpty(),
)

internal fun quotasSlice(view: QuotasView) = QuotasSlice(
    groups = view.groups, loading = view.loading, error = view.error.orEmpty(), mutating = view.mutating.sorted(),
    group_rows = QuotaRows.of(view.groups),
)

/** [harnesses] names each schedule's agent by its owner machine's catalog. */
internal fun schedulesSlice(view: SchedulesView, harnesses: (daemonId: String) -> List<Harness>) = SchedulesSlice(
    project_id = view.projectId.orEmpty(), schedules = view.schedules, total_count = view.totalCount,
    next_page_token = view.nextPageToken, loaded = view.loaded, loading = view.loading, loading_more = view.loadingMore,
    error = view.error.orEmpty(), action_error = view.actionError.orEmpty(), selected_id = view.selectedId.orEmpty(),
    runs = view.runs, runs_next_page_token = view.runsNextPageToken, runs_loading = view.runsLoading,
    runs_loading_more = view.runsLoadingMore, preview = view.preview, preview_error = view.previewError.orEmpty(),
    state = when (view.presentation) {
        SchedulesPresentation.LOADING -> SchedulesSlice.State.STATE_LOADING
        SchedulesPresentation.FAILED -> SchedulesSlice.State.STATE_FAILED
        SchedulesPresentation.EMPTY -> SchedulesSlice.State.STATE_EMPTY
        SchedulesPresentation.LOADED -> SchedulesSlice.State.STATE_LOADED
    },
    subtitle = view.subtitle, rows = view.rows(harnesses), run_rows = view.runRows, preview_loading = view.previewLoading,
)

internal fun terminalScope(target: TerminalTarget): TerminalScope? =
    if (target.daemon_id.isEmpty()) null
    else TerminalScope(
        target.daemon_id,
        when (target.kind) {
            TerminalTarget.Kind.KIND_PROJECT -> TerminalScopeKind.PROJECT
            TerminalTarget.Kind.KIND_CARD -> TerminalScopeKind.CARD
            else -> TerminalScopeKind.MACHINE
        },
        target.project_id, target.checkout_id, target.card_id,
    )

/** [outputs] is the observer's replay position; command results carry no output. */
internal fun terminalsSlice(view: TerminalsView, outputs: TerminalOutputs?) = TerminalsSlice(
    target = view.scope?.let { scope ->
        TerminalTarget(
            daemon_id = scope.daemonId,
            kind = when (scope.kind) {
                TerminalScopeKind.MACHINE -> TerminalTarget.Kind.KIND_MACHINE
                TerminalScopeKind.PROJECT -> TerminalTarget.Kind.KIND_PROJECT
                TerminalScopeKind.CARD -> TerminalTarget.Kind.KIND_CARD
            },
            project_id = scope.projectId, checkout_id = scope.checkoutId, card_id = scope.cardId,
        )
    },
    terminals = view.terminals, selected_id = view.selectedId.orEmpty(), loading = view.loading,
    error = view.error.orEmpty(), stream_connected = view.streamConnected,
    output = outputs?.next(view).orEmpty(),
)

internal fun overviewSlice(view: TerminalOverviewView, terminals: TerminalsSlice) = TerminalOverviewSlice(
    entries = view.entries.map { OverviewTerminal(it.id, it.daemonId, it.machineName, it.terminal) },
    selected_id = view.selectedId.orEmpty(), loading = view.loading, errors = view.errors,
    no_machines = view.noMachines, terminals = terminals,
)

/**
 * One observer's replay position in each retained screen, so it receives
 * every byte once; a new epoch or a trimmed-away position replays what is
 * retained after a reset.
 */
internal class TerminalOutputs {
    private val cursors = HashMap<String, TerminalReplayCursor>()

    fun next(view: TerminalsView): List<TerminalOutput> {
        cursors.keys.retainAll(view.screens.keys)
        return view.screens.mapNotNull { (id, screen) ->
            var reset = false
            val written = Buffer()
            cursors.getOrPut(id, ::TerminalReplayCursor).apply(
                screen,
                object : TerminalRendererSink {
                    override fun reset() {
                        reset = true
                        written.clear()
                    }

                    override fun feed(bytes: ByteArray) {
                        written.write(bytes)
                    }

                    override fun redraw() {}
                },
            )
            if (!reset && written.size == 0L) null else TerminalOutput(id, reset, written.readByteString())
        }
    }
}

/**
 * An open conversation with its presentation: the screen state
 * ([ConversationPresenter.state], with the composer's [agent] pickers) and
 * the transcript's rows.
 */
internal fun conversationSlice(view: ConversationView, presented: ConversationPresentation, agent: AgentControlsState? = null): ConversationSlice = ConversationSlice(
    card_id = view.cardId, daemon_id = view.daemonId.orEmpty(), card = view.card,
    conversation = view.conversation?.copy(messages = emptyList()), messages = view.messages,
    loading = view.loading, syncing = view.syncing, error = view.error.orEmpty(), pending = view.pending,
    has_earlier = view.transcript.history.hasMore, loading_earlier = view.transcript.history.loading,
    browsing_earlier = view.transcript.history.browsingEarlier, retrying = view.retrying,
    refreshed_at_millis = view.refreshedAt?.toEpochMilliseconds() ?: 0,
    // The same failure whose diagnostics the timeline leaves to the banner.
    turn_failure = presented.turnFailure?.let {
        ClientTurnFailure(it.summary, it.log, it.failedMessageId.orEmpty(), it.retryParts.isNotEmpty())
    },
    project = view.presented?.detail?.project, board = view.presented?.detail?.board, page = view.presented?.page,
    earlier_count = view.messages.size - view.presented?.conversation?.messages.orEmpty().size,
    state = ConversationPresenter.state(presented).copy(agent = agent),
    timeline = presented.timeline.items.map { item ->
        timelineItem(item, presented::delivery, presented::unconfirmed)
    },
    unattached_plan_ids = presented.timeline.unattachedPlans.map { it.id },
)

/**
 * A transcript row as the client contract carries it; a user message's
 * [delivery] and whether it is [unconfirmed] come by message ID.
 */
internal fun timelineItem(item: TimelineItem, delivery: (String) -> DeliveryState, unconfirmed: (String) -> Boolean): ClientTimelineItem = when (item) {
    is TimelineItem.Message -> {
        val state = if (item.user) delivery(item.message.id) else null
        ClientTimelineItem(
            id = item.id, message_ids = item.messageIds, user = item.user, groups = item.groups.map(::timelineStepGroup),
            plan_ids = item.plans.map { it.id }, subagent_ids = item.subagents.map { it.id },
            created_at_millis = item.createdAt?.toEpochMilliseconds() ?: 0, copyable = item.copyable,
            delivery = state?.let(::messageDelivery) ?: MessageDelivery.MESSAGE_DELIVERY_UNSPECIFIED,
            unconfirmed = item.user && unconfirmed(item.message.id), delivery_label = state?.let(Delivery::label).orEmpty(),
        )
    }
    is TimelineItem.Activity -> {
        val summary = item.summary.english()
        ClientTimelineItem(
            id = item.id, message_ids = item.messageIds, activity = true, summary = summary,
            groups = listOf(TimelineStepGroup(id = item.steps.firstOrNull()?.id.orEmpty(), activity = true, summary = summary, steps = item.steps.map(::timelineStep))),
            created_at_millis = item.createdAt?.toEpochMilliseconds() ?: 0, copyable = item.copyable,
        )
    }
}

private fun timelineStepGroup(group: StepGroup): TimelineStepGroup = TimelineStepGroup(
    id = group.id, activity = group.activity, summary = if (group.activity) ActivitySummary.of(group.steps).english() else "",
    steps = group.steps.map(::timelineStep),
)

private fun timelineStep(step: TimelineStep): ClientTimelineStep {
    val tool = step.kind == StepKind.TOOL
    val status = if (tool) Tools.status(step.part) else null
    return ClientTimelineStep(
        id = step.id, message_id = step.messageId, kind = timelineStepKind(step.kind), part_index = step.partIndex,
        // Only coalesced prose differs from its part's own text.
        text = if (step.text != step.part.text) step.text else "", routine = step.routine,
        tool_status = if (status != null) toolCallStatus(status) else ToolCallStatus.TOOL_CALL_STATUS_UNSPECIFIED,
        tool_title = if (tool) Tools.displayName(step.part) else "",
        tool_status_label = status?.let(Tools::statusText).orEmpty(), tool_attention = status != null && Tools.needsAttention(status),
    )
}

private fun timelineStepKind(kind: StepKind): TimelineStepKind = when (kind) {
    StepKind.TEXT -> TimelineStepKind.TIMELINE_STEP_KIND_TEXT
    StepKind.REASONING -> TimelineStepKind.TIMELINE_STEP_KIND_REASONING
    StepKind.TOOL -> TimelineStepKind.TIMELINE_STEP_KIND_TOOL
    StepKind.ATTENTION -> TimelineStepKind.TIMELINE_STEP_KIND_ATTENTION
    StepKind.ATTACHMENT -> TimelineStepKind.TIMELINE_STEP_KIND_ATTACHMENT
    StepKind.OTHER -> TimelineStepKind.TIMELINE_STEP_KIND_OTHER
    StepKind.SUBAGENTS -> TimelineStepKind.TIMELINE_STEP_KIND_SUBAGENTS
}

private fun toolCallStatus(status: ToolStatus): ToolCallStatus = when (status) {
    ToolStatus.RUNNING -> ToolCallStatus.TOOL_CALL_STATUS_RUNNING
    ToolStatus.COMPLETED -> ToolCallStatus.TOOL_CALL_STATUS_COMPLETED
    ToolStatus.FAILED -> ToolCallStatus.TOOL_CALL_STATUS_FAILED
    ToolStatus.NEEDS_APPROVAL -> ToolCallStatus.TOOL_CALL_STATUS_NEEDS_APPROVAL
    ToolStatus.DENIED -> ToolCallStatus.TOOL_CALL_STATUS_DENIED
    ToolStatus.OTHER -> ToolCallStatus.TOOL_CALL_STATUS_OTHER
}

private fun messageDelivery(state: DeliveryState): MessageDelivery = when (state) {
    DeliveryState.LOCAL -> MessageDelivery.MESSAGE_DELIVERY_LOCAL
    DeliveryState.ACCEPTED -> MessageDelivery.MESSAGE_DELIVERY_ACCEPTED
    DeliveryState.QUEUED -> MessageDelivery.MESSAGE_DELIVERY_QUEUED
    DeliveryState.SYNCED -> MessageDelivery.MESSAGE_DELIVERY_SYNCED
    DeliveryState.FAILED -> MessageDelivery.MESSAGE_DELIVERY_FAILED
}

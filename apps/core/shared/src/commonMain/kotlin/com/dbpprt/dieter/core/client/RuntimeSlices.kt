package com.dbpprt.dieter.core.client

import com.dbpprt.dieter.client.v1.ActivityRow
import com.dbpprt.dieter.client.v1.ActivitySlice
import com.dbpprt.dieter.client.v1.ActivitySummary
import com.dbpprt.dieter.client.v1.BoardSlice
import com.dbpprt.dieter.client.v1.FailedOperation
import com.dbpprt.dieter.client.v1.FeedStatus
import com.dbpprt.dieter.client.v1.GatewayBuild
import com.dbpprt.dieter.client.v1.GatewayEntry
import com.dbpprt.dieter.client.v1.MachineEntry
import com.dbpprt.dieter.client.v1.MachineMetadata
import com.dbpprt.dieter.client.v1.MachineOutbox
import com.dbpprt.dieter.client.v1.MetadataSlice
import com.dbpprt.dieter.client.v1.NavigationFolder as ClientNavigationFolder
import com.dbpprt.dieter.client.v1.NavigationSlice
import com.dbpprt.dieter.client.v1.OutboxSlice
import com.dbpprt.dieter.client.v1.PendingCardMove
import com.dbpprt.dieter.client.v1.ProjectNavigation
import com.dbpprt.dieter.client.v1.SessionSlice
import com.dbpprt.dieter.client.v1.WorkspaceNotice
import com.dbpprt.dieter.client.v1.WorkspaceSlice
import com.dbpprt.dieter.core.CoreRuntime
import com.dbpprt.dieter.core.activity.ActivityCounts
import com.dbpprt.dieter.core.activity.ActivityItem
import com.dbpprt.dieter.core.activity.ActivitySection
import com.dbpprt.dieter.core.activity.IslandModel
import com.dbpprt.dieter.core.activity.MenuBar
import com.dbpprt.dieter.core.board.CardOperation
import com.dbpprt.dieter.core.board.ProjectOverview
import com.dbpprt.dieter.core.connection.Availability
import com.dbpprt.dieter.core.connection.ConnectionPhase
import com.dbpprt.dieter.core.connection.ConnectionState
import com.dbpprt.dieter.core.connection.MachineDirectory
import com.dbpprt.dieter.core.identity.Accounts
import com.dbpprt.dieter.core.journal.OutboxKind
import com.dbpprt.dieter.core.journal.OutboxState
import com.dbpprt.dieter.core.machines.MachineRow
import com.dbpprt.dieter.core.machines.MachineRows
import com.dbpprt.dieter.core.navigation.FolderScope
import com.dbpprt.dieter.core.navigation.NavigationLayout
import com.dbpprt.dieter.core.outbox.DeliveryPhase
import com.dbpprt.dieter.core.routing.RouteKind
import com.dbpprt.dieter.core.session.MachineRoute
import kotlin.time.Instant
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.transformLatest

// The account-wide slices, derived from the runtime's state.

private data class SessionInputs(
    val connection: ConnectionState,
    val machines: MachineDirectory,
    val accounts: Accounts,
    val routes: Map<String, MachineRoute>,
    val showReasoning: Boolean,
)

internal fun CoreRuntime.sessionSlices(): Flow<SessionSlice> = combine(
    combine(connection.state, connection.machines, accounts.state, sessions.routes, conversations.showReasoning, ::SessionInputs),
    connection.feedStatus, connection.freshness, connection.gatewayInformation,
    workspace.state.map { it.loaded }.distinctUntilChanged(),
) { inputs, feed, freshness, gateway, cached ->
    val (state, machines, accounts, routes, showReasoning) = inputs
    val active = accounts.active
    val rows = machines.all.map { MachineRows.of(it, it.online(machines.evaluatedAt), routes[it.id], state.attachedMachineId) }
    // Without a live gateway connection, cached presence is never shown as online.
    val presented = MachineRows.presented(rows, state.phase, emptySet(), emptyMap())
    val connected = state.phase == ConnectionPhase.CONNECTED
    val feedLive = feed.live && !feed.projectionPending
    val now = platform.clock.now()
    SessionSlice(
        phase = SessionSlice.Phase.valueOf("PHASE_${state.phase.name}"),
        gateway_origin = active.origin,
        gateways = accounts.gateways.map { GatewayEntry(it.origin, it.name, it.origin == active.origin, accounts.desiredConnected[it.origin] ?: true) },
        attached_machine_id = state.attachedMachineId.orEmpty(),
        error = state.error.orEmpty(),
        machines = machines.all.indices.sortedWith(compareBy<Int, MachineRow>(MachineRows.ORDER) { rows[it] }).map { index ->
            val machine = machines.all[index]
            val route = routes[machine.id]
            val attached = machine.id == state.attachedMachineId
            val warnings = freshness[machine.id]?.let { MachineRows.syncWarnings(rows, mapOf(machine.id to it), connected, now) }.orEmpty()
            val status = MachineRows.status(rows[index], attached, state.phase, state.error, warnings, feedLive)
            val shown = presented[index]
            MachineEntry(
                id = machine.id, name = machine.name, online = machine.online(machines.evaluatedAt),
                route = route?.kind?.label.orEmpty(), local = route?.kind == RouteKind.LOCAL,
                platform = machine.remoteDesktop?.platform.orEmpty(), release_version = machine.releaseVersion, compatible = machine.compatible,
                last_seen_at = machine.lastSeenAt, minimum_release_version = machine.minimumReleaseVersion,
                remote_desktop_ready = machine.remoteDesktop?.ready == true, remote_desktop_reason = machine.remoteDesktop?.reason.orEmpty(),
                compatibility = machine.compatibility.name,
                detail = status.detail, show_last_seen = status.showsLastSeen,
                available = shown.hostsProjects, unavailable_message = shown.unavailableMessage.orEmpty(),
                screen_status = shown.screenStatus, can_share_screen = shown.canShareScreen,
            )
        },
        feed = FeedStatus(last_applied_at_millis = feed.lastAppliedAt?.toEpochMilliseconds() ?: 0),
        gateway_build = gateway?.let { GatewayBuild(it.release_version, it.source_revision, it.built_at) },
        notice = Availability.workspaceNotice(state.phase, cached)?.let { WorkspaceNotice(it.title, it.detail, it.working, it.offline) },
        phase_label = Availability.label(state.phase),
        workspace_live = Availability.workspaceLive(state.phase, feed.live, feed.projectionPending),
        show_reasoning = showReasoning,
    )
}

internal fun CoreRuntime.metadataSlices(): Flow<MetadataSlice> = metadata.machines.map { machines ->
    MetadataSlice(
        machines.mapValues { (_, metadata) ->
            MachineMetadata(harnesses = metadata.harnesses, settings_options = metadata.settingsOptions, runtime = metadata.runtime, loaded = metadata.loaded)
        },
    )
}

internal fun CoreRuntime.boardSlices(): Flow<BoardSlice> = combine(board.view, outbox.view) { view, outbox ->
    BoardSlice(
        // A start still in the outbox shows as STARTING until sync reports the turn; this client's own operations win.
        operations = outbox.startingCardIds.associateWith { CardOperation.STARTING.name } + view.operations.mapValues { it.value.name },
        moves = view.moves.keys.sorted().map(::PendingCardMove),
    )
}

internal fun CoreRuntime.navigationSlices(): Flow<NavigationSlice> = combine(
    navigationKv.values, navigationKv.status,
    // The sidebar shows the listed, unarchived projects.
    workspace.state.map { view -> view.projects.filterNot { it.archived }.map { it.id } }.distinctUntilChanged(),
) { values, status, available ->
    val layout = NavigationLayout(values)
    fun folders(scope: FolderScope) = layout.folders(scope).map { ClientNavigationFolder(it.id, it.name, it.itemIds, it.expanded) }
    val sidebar = layout.sidebarProjects(available)
    NavigationSlice(
        projects = ProjectNavigation(
            order = sidebar.order,
            folders = sidebar.folders.map { ClientNavigationFolder(it.id, it.name, it.itemIds, it.expanded) },
            unfiled = sidebar.unfiled, pinned = sidebar.pinned, expanded = sidebar.expanded,
        ),
        project_order = layout.savedProjectOrder(), pinned_projects = layout.savedPinnedProjects(),
        pinned_chat_order = layout.savedPinnedChatOrder(),
        project_folders = folders(FolderScope.PROJECTS), chat_folders = folders(FolderScope.CHATS),
        expanded_projects = layout.expandedProjects(),
        collapsed_chat_sections = layout.collapsedChatSections(),
        chats_show_all = layout.projectsShowingAllChats(),
        pending = status.pending,
        error = (status.deliveryError ?: status.watchError).orEmpty(), caught_up = status.caughtUp,
    )
}

internal fun CoreRuntime.workspaceSlices(): Flow<WorkspaceSlice> = workspace.state.map { view ->
    WorkspaceSlice(
        projects = view.projects, boards = view.boards.values.flatten(), cards = view.allItems,
        pending_card_ids = view.pendingCardIds.sorted(), loaded = view.loaded, project_replicas = view.projectReplicas,
        retired_boards = view.retiredBoards, settings = view.settings,
        board_attention = ProjectOverview.boardAttention(view.cards.values.flatten()),
    )
}

internal fun CoreRuntime.outboxSlices(): Flow<OutboxSlice> = combine(outbox.view, connection.machines, connection.state) { view, machines, state ->
    OutboxSlice(
        pending_card_ids = view.pendingCardIds.sorted(), pending_message_ids = view.pendingMessageIds.sorted(),
        accepted_ids = view.acceptedIds.sorted(), failed_ids = view.failedIds.sorted(),
        machines = view.machines.map { (daemonId, summary) ->
            val machine = machines.machine(daemonId)
            val name = machine?.name?.ifBlank { daemonId } ?: "Dieter machine"
            // Delivery needs the machine online and the gateway connection live.
            val online = state.phase == ConnectionPhase.CONNECTED && machine?.online(machines.evaluatedAt) == true
            MachineOutbox(
                daemonId, summary.itemCount, if (summary.failed) summary.itemCount else 0,
                message_count = summary.messageCount, change_count = summary.changeCount, retrying = summary.retrying,
                phase = deliveryPhase(summary.phase(online)), machine_name = name,
                title = summary.title(name, online), detail = summary.detail(name, online), retry_title = summary.retryTitle(online),
                status_suffix = summary.statusSuffix,
            )
        }.sortedBy { it.daemon_id },
        resolutions = view.resolutions,
        failures = view.failedIds.associateWith { view.failure(it).orEmpty() }.filterValues { it.isNotEmpty() },
        storage_error = view.storageError.orEmpty(),
        failed_operations = view.entries.filter { it.state == OutboxState.OUTBOX_STATE_FAILED }.sortedBy { it.created_at_millis }.map { entry ->
            FailedOperation(
                id = entry.optimistic_id, label = operationLabel(entry.kind), target_id = entry.server_id.ifEmpty { entry.optimistic_id },
                failure = entry.last_error.ifEmpty { "The queued operation failed." }, created_at_millis = entry.created_at_millis,
            )
        },
    )
}

private fun deliveryPhase(phase: DeliveryPhase): MachineOutbox.Phase = when (phase) {
    DeliveryPhase.SENDING -> MachineOutbox.Phase.PHASE_SENDING
    DeliveryPhase.WAITING -> MachineOutbox.Phase.PHASE_WAITING
    DeliveryPhase.WAITING_FOR_STORAGE -> MachineOutbox.Phase.PHASE_WAITING_FOR_STORAGE
    DeliveryPhase.RETRYING -> MachineOutbox.Phase.PHASE_RETRYING
    DeliveryPhase.FAILED -> MachineOutbox.Phase.PHASE_FAILED
}

internal fun operationLabel(kind: OutboxKind): String = when (kind) {
    OutboxKind.OUTBOX_KIND_CREATE_CARD -> "Create card"
    OutboxKind.OUTBOX_KIND_CREATE_CHAT -> "Create chat"
    OutboxKind.OUTBOX_KIND_SEND_MESSAGE -> "Send message"
    OutboxKind.OUTBOX_KIND_START_CARD -> "Start card"
    else -> "Queued operation"
}

/** The activity feed; sent again when a menu bar row leaves its six-hour window. */
@OptIn(ExperimentalCoroutinesApi::class)
internal fun CoreRuntime.activitySlices(): Flow<ActivitySlice> = activity().transformLatest { items ->
    while (true) {
        val now = platform.clock.now()
        emit(activitySlice(items, now))
        val next = MenuBar.nextChange(items, now) ?: break
        delay(next - now)
    }
}

internal fun activitySlice(items: List<ActivityItem>, now: Instant): ActivitySlice {
    val counts = ActivityCounts.of(items)
    val island = IslandModel.build(items)
    return ActivitySlice(
        rows = items.map { item ->
            ActivityRow(
                card = item.card, kind = item.kind.name,
                section = when (item.section) {
                    ActivitySection.ATTENTION -> ActivityRow.Section.SECTION_ATTENTION
                    ActivitySection.RUNNING -> ActivityRow.Section.SECTION_RUNNING
                    ActivitySection.RECENT -> ActivityRow.Section.SECTION_RECENT
                },
                detail = item.detail, at_millis = item.at?.toEpochMilliseconds() ?: 0, started_at_millis = item.start?.toEpochMilliseconds() ?: 0,
                project_name = item.projectName.orEmpty(), board_name = item.boardName.orEmpty(), chat = item.chat,
                needs_you = item.needsYou, can_finish = item.canFinish, kind_label = item.kind.label, title = item.title,
                shown_at_millis = item.shownAt?.toEpochMilliseconds() ?: 0, menu_bar_title = MenuBar.title(item.kind),
            )
        },
        summary = ActivitySummary(
            running = counts.running, attention = counts.attention, recent = counts.recent, review = counts.review, subagents = counts.subagents,
        ),
        island_ids = island.items.map { it.id },
        menu_bar_ids = MenuBar.items(items, now).map { it.id },
        island_accessibility = island.accessibility,
    )
}

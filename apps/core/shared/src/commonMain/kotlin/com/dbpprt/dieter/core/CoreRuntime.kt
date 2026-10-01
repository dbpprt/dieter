package com.dbpprt.dieter.core

import com.dbpprt.dieter.api.v1.Card
import com.dbpprt.dieter.api.v1.CreateConversationRequest
import com.dbpprt.dieter.api.v1.DieterServiceClient
import com.dbpprt.dieter.api.v1.HarnessSelection
import com.dbpprt.dieter.api.v1.MessagePart
import com.dbpprt.dieter.core.admin.BackgroundPolicy
import com.dbpprt.dieter.core.board.BoardOperations
import com.dbpprt.dieter.core.composition.ConversationDrafts
import com.dbpprt.dieter.core.composition.CreationMemory
import com.dbpprt.dieter.core.composition.TaskCaptures
import com.dbpprt.dieter.core.legacy.ForGateway
import com.dbpprt.dieter.core.legacy.LegacyImportReport
import com.dbpprt.dieter.core.legacy.LegacyState
import com.dbpprt.dieter.core.admin.Administration
import com.dbpprt.dieter.core.admin.MachineAdmin
import com.dbpprt.dieter.core.admin.MachineTelemetry
import com.dbpprt.dieter.core.activity.Activity
import com.dbpprt.dieter.core.activity.ActivityItem
import com.dbpprt.dieter.core.connection.ConnectionSupervisor
import com.dbpprt.dieter.core.notifications.NotificationPlanner
import com.dbpprt.dieter.core.notifications.NotificationSettings
import com.dbpprt.dieter.core.outbox.OutboxView
import com.dbpprt.dieter.core.runtime.CoreException
import com.dbpprt.dieter.core.runtime.FailureKind
import com.dbpprt.dieter.core.screens.LocalClipboard
import com.dbpprt.dieter.core.screens.ScreenConfig
import com.dbpprt.dieter.core.screens.ScreenMediaEngineFactory
import com.dbpprt.dieter.core.screens.ScreenRouteFactory
import com.dbpprt.dieter.core.screens.ScreenSession
import com.dbpprt.dieter.core.screens.screenRoutes
import com.dbpprt.dieter.core.files.FileTree
import com.dbpprt.dieter.core.files.Files
import com.dbpprt.dieter.core.store.WorkspaceView
import com.dbpprt.dieter.core.workspace.ProjectChanges
import com.dbpprt.dieter.core.workspace.ProjectWorkspaces
import com.dbpprt.dieter.core.workspace.WorkspaceReview
import com.dbpprt.dieter.core.terminals.TerminalInputPumps
import com.dbpprt.dieter.core.terminals.TerminalSelections
import com.dbpprt.dieter.core.terminals.TerminalOverview
import com.dbpprt.dieter.core.terminals.Terminals
import com.dbpprt.dieter.core.executions.Processes
import com.dbpprt.dieter.core.quotas.ProviderQuotas
import com.dbpprt.dieter.core.schedules.Schedules
import com.dbpprt.dieter.core.conversation.ConversationConfig
import com.dbpprt.dieter.core.conversation.ConversationSession
import com.dbpprt.dieter.core.conversation.Conversations
import com.dbpprt.dieter.core.connection.SupervisorConfig
import com.dbpprt.dieter.core.identity.AccountStore
import com.dbpprt.dieter.core.identity.ClientIdentity
import com.dbpprt.dieter.core.identity.Credentials
import com.dbpprt.dieter.core.identity.Gateway
import com.dbpprt.dieter.core.identity.SignIn
import com.dbpprt.dieter.core.journal.OutboxPlacement
import com.dbpprt.dieter.core.metadata.MachineMetadataStore
import com.dbpprt.dieter.core.navigation.NavigationEditor
import com.dbpprt.dieter.core.navigation.NavigationLayout
import com.dbpprt.dieter.core.navigation.SharedKv
import com.dbpprt.dieter.core.outbox.Outbox
import com.dbpprt.dieter.core.platform.Platform
import com.dbpprt.dieter.core.routing.RouteSelector
import com.dbpprt.dieter.core.routing.RoutingPolicy
import com.dbpprt.dieter.core.routing.WebRtcCooldown
import com.dbpprt.dieter.core.session.MachineSessions
import com.dbpprt.dieter.core.storage.CoreStorage
import com.dbpprt.dieter.core.store.WorkspaceStore
import com.dbpprt.dieter.core.presentation.LiveActivities
import com.dbpprt.dieter.api.v1.ConversationSnapshot
import com.dbpprt.dieter.core.sync.DirectoryPoller
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.job
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull

/** Marks an install whose legacy app state was imported. */
private const val LEGACY_IMPORTED = "legacy-imported"

data class RuntimeConfig(
    /** The canonical Dieter release of the app. */
    val clientVersion: String,
    /** The platform's OAuth callback, e.g. `dieter-android://oauth/callback`. */
    val oauthRedirectUri: String,
    /** Only hosts that can run a daemon themselves (macOS, JVM) try loopback routes. */
    val includeLoopbackRoutes: Boolean,
    /** Prefix of a newly generated sync client ID, e.g. `android` or `mac`. */
    val clientIdPrefix: String = "core",
    /** The install's existing sync client ID from a legacy store, kept for command idempotency. */
    val legacyClientId: () -> String? = { null },
    val supervisor: SupervisorConfig = SupervisorConfig(clientVersion),
    val routing: RoutingPolicy = RoutingPolicy(includeLoopbackRoutes),
    val conversations: ConversationConfig = ConversationConfig(),
)

/**
 * The shared client core. Every piece of mutable state is confined to one
 * serialized dispatcher; public entry points hop onto it, and [StateFlow]s
 * may be read from any thread.
 */
class CoreRuntime(val platform: Platform, val config: RuntimeConfig) {
    val dispatcher: CoroutineDispatcher = Dispatchers.Default.limitedParallelism(1)
    val scope = CoroutineScope(SupervisorJob() + dispatcher)

    val storage = CoreStorage(platform.fileSystem, platform.stateDirectory)
    val credentials = Credentials(platform.secureStore)
    val accounts = AccountStore(storage)
    val signIn = SignIn(storage, platform.http, credentials, config.oauthRedirectUri, platform.clock)
    val workspace = WorkspaceStore(platform.clock)
    private val cooldown = WebRtcCooldown(platform.clock)
    private val routes = RouteSelector(platform.transport, platform.controlChannels, config.routing, cooldown, platform.logger, platform.clock)
    val sessions = MachineSessions(routes, scope)
    val clientId: String = ClientIdentity.load(storage, config.clientIdPrefix, config.legacyClientId)
    val outbox = Outbox(clientId, sessions, workspace, platform.clock, platform.logger)
    val board = BoardOperations(sessions, workspace)
    val navigationKv = SharedKv("navigation", sessions, platform.clock, platform.logger)
    val navigation = NavigationEditor(navigationKv)
    val metadata = MachineMetadataStore(sessions, scope, platform.clock, platform.logger)
    val drafts = ConversationDrafts(platform.clock, platform.logger, scope)
    val captures = TaskCaptures(platform.clock, platform.logger, scope)
    val creation = CreationMemory(storage, platform.logger)
    val connection: ConnectionSupervisor = ConnectionSupervisor(
        scope, accounts, credentials, sessions, workspace, ::storageFor, platform.transport,
        config.supervisor.copy(clientVersion = config.clientVersion), platform.clock, platform.logger,
        onGatewayPrepared = { _, prepared ->
            gatewayStorage = prepared
            terminalSelections.reload()
            terminalPumps.cancelAll()
            outbox.bind(prepared.scope("outbox"))
            navigationKv.bind(prepared.scope("navigation"))
            drafts.bind(prepared.scope("drafts"))
            captures.bind(prepared.scope("captures"))
            metadata.forget()
            conversations.reset()
            schedules.bind(null)
            processes.bind(null, active = false)
            quotas.reset()
        },
    )
    val schedules = Schedules(sessions, workspace, scope)
    val processes = Processes(sessions, scope)
    val quotas = ProviderQuotas(platform.logger)
    private var gatewayStorage: CoreStorage? = null
    val terminalPumps = TerminalInputPumps(sessions, scope)
    val terminalSelections = TerminalSelections { gatewayStorage }
    val conversations: Conversations = Conversations(
        sessions, workspace, outbox, board, drafts, connection.feedStatus, config.conversations, platform.clock, platform.logger, scope,
    )

    /** Per-gateway state lives in its own namespace, so switching accounts never mixes data. */
    fun storageFor(gateway: Gateway): CoreStorage = storage.scope("gateway-${gateway.origin}")

    private var started = false

    fun start() {
        started = true
        scope.launch { connection.start() }
        scope.launch { outbox.run(reachableMachines()) }
        scope.launch { workspace.revision.collect { outbox.reconcile() } }
        scope.launch { navigationKv.run(connection.active.map { it?.attachedMachineId }) }
        // Pinned chats keep the order they were first seen in; later pins append. Only after
        // a full replay, so a saved order elsewhere is never mistaken for none.
        scope.launch {
            combine(workspace.state, navigationKv.values, navigationKv.status) { view, values, status ->
                view.chats.takeIf { chats -> status.caughtUp && chats.any { it.pinned } && NavigationLayout(values).ordered("pinned-order").isEmpty() }
            }.collect { chats -> if (chats != null) navigation.initializePinnedChatOrder(chats) }
        }
        notificationPlanner?.let { planner ->
            scope.launch {
                accounts.state.map { it.active }.distinctUntilChanged().collect { planner.reset() }
            }
            scope.launch {
                workspace.state.collect { view ->
                    if (!view.loaded) return@collect
                    val boardNames = view.boards.values.flatten().associate { it.id to it.name }
                    planner.frame(view.allItems, view.conversations, NotificationSettings.load(platform.settings), boardNames, { card -> runningDetail(card, view.conversations[card.id]) }, visibleConversationId)
                }
            }
        }
        scope.launch { quotas.run(connection.active.map { it?.gateway?.client }.distinctUntilChanged()) }
        scope.launch {
            var known = emptyMap<String, String>()
            outbox.view.map { it.resolutions }.distinctUntilChanged().collect { resolutions ->
                for ((local, server) in resolutions) if (known[local] != server) drafts.retargetAll(local, server)
                known = resolutions
            }
        }
    }

    /** Machines that can take commands now: the attached one first, then every other online, compatible machine. */
    private fun reachableMachines(): Flow<List<String>> = combine(connection.active, connection.machines) { active, machines ->
        if (active == null) {
            emptyList()
        } else {
            (listOf(active.attachedMachineId) + machines.online.filter { it.compatible }.map { it.id }).distinct()
        }
    }

    /** Foreground, or a background window the platform allows (e.g. Android's sync service). */
    fun setActive(active: Boolean) = connection.setRunning(active)

    /** Runs [block] on the core's confined dispatcher. */
    suspend fun <T> onCore(block: suspend CoroutineScope.() -> T): T = withContext(dispatcher, block)

    /** The URL to open for GitHub sign-in to [gateway]. */
    suspend fun beginSignIn(gateway: Gateway): String = onCore { signIn.begin(gateway) }

    /** Whether [importLegacy] still has to run on this install. */
    val needsLegacyImport: Boolean get() = storage.read(LEGACY_IMPORTED) == null

    /**
     * Moves a legacy app's state into the core, once per install; later calls
     * report `skipped`. Run it before [start]. Nothing is deleted from the
     * legacy stores, so a rollback to the legacy implementation still works.
     */
    suspend fun importLegacy(state: LegacyState): LegacyImportReport = onCore {
        if (!needsLegacyImport) return@onCore LegacyImportReport(skipped = true)
        // Started components hold their stores in memory and would overwrite what is imported.
        check(!started) { "Import legacy state before starting the core." }
        val now = platform.clock.now().toEpochMilliseconds()
        var tokens = 0
        var outboxEntries = 0
        var navigationCaches = 0
        var draftCount = 0
        var selections = 0
        if (state.gateways.isNotEmpty()) {
            val known = accounts.state.value.gateways.filterNot { existing -> state.gateways.any { it.origin == existing.origin } }
            accounts.setGateways(state.gateways + known, state.activeOrigin)
            for ((origin, daemonId) in state.preferredMachines) {
                if (state.gateways.none { it.origin == origin }) continue
                accounts.select(origin)
                accounts.preferMachine(daemonId)
            }
            state.activeOrigin?.let(accounts::select)
        }
        val gateways = accounts.state.value.gateways.associateBy { it.origin }
        for ((origin, token) in state.tokens) {
            // A token is only valid for the exact origin it was issued for; migrated hosts sign in again.
            val gateway = gateways[origin] ?: continue
            if (token.isBlank() || credentials.token(gateway) != null) continue
            credentials.save(gateway, token)
            tokens++
        }
        fun <T> byGateway(items: List<ForGateway<T>>) = items.groupBy({ it.origin }, { it.value }).mapNotNull { (origin, values) -> gateways[origin]?.let { it to values } }
        for ((gateway, entries) in byGateway(state.outbox)) outboxEntries += Outbox.importInto(storageFor(gateway).scope("outbox"), entries, now)
        val active = state.activeNavigation
        for ((gateway, caches) in byGateway(state.navigation)) {
            val activeHere = active?.takeIf { gateways[it.origin] == gateway }?.value
            navigationCaches += SharedKv.importInto(storageFor(gateway).scope("navigation"), "navigation", caches, activeHere)
        }
        for ((gateway, drafts) in byGateway(state.drafts)) draftCount += ConversationDrafts.importInto(storageFor(gateway).scope("drafts"), drafts)
        for ((gateway, pairs) in byGateway(state.terminalSelections)) {
            val selectionsHere = TerminalSelections { storageFor(gateway) }
            for ((key, terminalId) in pairs) if (selectionsHere.get(key) == null) {
                selectionsHere.set(key, terminalId)
                selections++
            }
        }
        state.notifications?.let { if (platform.settings.string("notifications.enabled") == null) it.save(platform.settings) }
        state.creation?.let(creation::adopt)
        storage.write(LEGACY_IMPORTED, "1".encodeToByteArray())
        terminalSelections.reload()
        LegacyImportReport(
            skipped = false, gateways = state.gateways.size, tokens = tokens, outboxEntries = outboxEntries, navigationCaches = navigationCaches,
            drafts = draftCount, terminalSelections = selections,
        )
    }

    /** Completes sign-in from the OAuth callback URL and connects. */
    suspend fun completeSignIn(callbackUrl: String): Gateway = onCore {
        val gateway = signIn.complete(callbackUrl)
        activate(gateway)
        gateway
    }

    /**
     * Uses a gateway session obtained elsewhere, such as a token a legacy app
     * stored, and connects to that gateway.
     */
    suspend fun adoptSession(gateway: Gateway, token: String) = onCore {
        require(token.isNotBlank()) { "The session token is empty." }
        credentials.save(gateway, token)
        activate(gateway)
    }

    private fun activate(gateway: Gateway) {
        if (accounts.state.value.gateways.none { it.origin == gateway.origin }) {
            accounts.setGateways(accounts.state.value.gateways + gateway, gateway.origin)
        } else {
            accounts.select(gateway.origin)
        }
        accounts.setDesiredConnected(true)
        connection.restart()
    }

    /**
     * Drops this gateway's cached machine views and feed so the next sync
     * starts from scratch. Undelivered changes, drafts, and navigation stay.
     */
    suspend fun resync() = onCore {
        val cache = storageFor(accounts.state.value.active)
        cache.names().filter { it.startsWith("feed-") || it.startsWith(DirectoryPoller.CACHE_PREFIX) }.forEach(cache::delete)
        workspace.clear()
        connection.restart()
    }

    /** Forgets the active gateway's session and its cached data. */
    suspend fun signOut() = onCore {
        val gateway = accounts.state.value.active
        credentials.remove(gateway)
        workspace.clear()
        storageFor(gateway).clear()
        connection.restart()
    }

    suspend fun selectGateway(origin: String) = onCore { accounts.select(origin) }

    suspend fun setGateways(gateways: List<Gateway>, activeOrigin: String? = null) = onCore {
        accounts.setGateways(gateways, activeOrigin)
    }

    /** Attaches the feed to [daemonId]; the rest of the account stays visible through the poller. */
    suspend fun attachMachine(daemonId: String) = onCore {
        accounts.preferMachine(daemonId)
        connection.restart()
    }

    suspend fun setConnected(value: Boolean) = onCore { accounts.setDesiredConnected(value) }

    /** Queues a card or chat; returns its optimistic row. */
    suspend fun createConversation(request: CreateConversationRequest, chat: Boolean, submissionId: String? = null): Card =
        onCore { outbox.createConversation(request, chat, submissionId) }

    /** Queues a message; returns its ID. */
    suspend fun sendMessage(
        cardId: String,
        parts: List<MessagePart>,
        selection: HarnessSelection = HarnessSelection(),
        placement: OutboxPlacement = OutboxPlacement.OUTBOX_PLACEMENT_TRANSCRIPT,
    ): String = onCore { outbox.sendMessage(cardId, parts, selection, placement) }

    /**
     * Submits capture [id] as a task or chat. The first submit freezes the
     * request; retries reuse it, so the daemon creates the task at most once.
     */
    suspend fun submitCapture(id: String, request: CreateConversationRequest, chat: Boolean = false): Card = onCore {
        captures.flush(id)
        val frozen = captures.freeze(id, request)
        val card = outbox.createConversation(frozen.request ?: request, chat, frozen.submission_id)
        captures.accepted(id)
        card
    }

    suspend fun startCard(cardId: String, hasDraftAttachments: Boolean = false) = onCore { outbox.startCard(cardId, hasDraftAttachments) }

    /** The shared navigation layout (folders, orders, disclosure), with pending edits applied. */
    fun navigationLayout(): Flow<NavigationLayout> = navigationKv.values.map(::NavigationLayout)

    /** Applies a navigation edit; it is queued durably and synchronized across the account. */
    suspend fun <T> editNavigation(block: NavigationEditor.() -> T): T = onCore { navigation.block() }

    /** Opens a conversation on the machine that runs it; the session streams until closed. */
    suspend fun openConversation(cardId: String): ConversationSession = onCore { conversations.open(cardId) }

    suspend fun closeConversation(cardId: String) = onCore { conversations.close(cardId) }

    /** Runs an action on an open conversation on the core dispatcher. */
    suspend fun <T> onConversation(session: ConversationSession, block: suspend ConversationSession.() -> T): T = onCore { session.block() }

    /** A conversation's workspace review surface; each view owns one. */
    fun workspaceReview(): WorkspaceReview = WorkspaceReview(sessions, workspace, board, scope)

    /** A project checkout's changes surface; each view owns one. */
    fun projectChanges(): ProjectChanges = ProjectChanges(sessions, workspace, scope)

    val projectWorkspaces = ProjectWorkspaces(sessions, workspace)
    val admin = Administration(sessions, workspace) { connection.active.value?.attachedMachineId }
    val telemetry = MachineTelemetry(sessions, scope)

    /** Renames a machine on the gateway; every client sees the new name through presence. */
    suspend fun renameMachine(daemonId: String, name: String) = onCore {
        val gateway = connection.active.value?.gateway?.client ?: throw CoreException(FailureKind.TRANSIENT, "Connect to the gateway first.")
        MachineAdmin.rename(gateway, daemonId, name)
    }

    /** Revokes a machine; if the feed was attached to it, the client attaches elsewhere. */
    suspend fun revokeMachine(daemonId: String) = onCore {
        val active = connection.active.value ?: throw CoreException(FailureKind.TRANSIENT, "Connect to the gateway first.")
        MachineAdmin.revoke(active.gateway.client, daemonId)
        sessions.invalidate(daemonId)
        if (accounts.state.value.preferredMachine[accounts.state.value.active.origin] == daemonId) accounts.preferMachine(null)
        if (active.attachedMachineId == daemonId) connection.restart()
    }

    /** A files surface (checkout or conversation workspace); each view owns one. */
    fun files(): Files = Files(sessions)

    /** A conversation's lazily expanded file tree. */
    fun fileTree(): FileTree = FileTree(sessions)

    /**
     * A screen-sharing view; the host supplies its WebRTC engine and
     * pasteboard. Connect it with [screenRoutes]. Call it on [dispatcher].
     */
    fun screen(engines: ScreenMediaEngineFactory, config: ScreenConfig, clipboard: LocalClipboard? = null): ScreenSession {
        val verifier = platform.signatures ?: throw CoreException(FailureKind.PERMANENT, "Screen sharing is unavailable on this device.")
        return ScreenSession(engines, verifier, config, platform.clock, scope, platform.logger, clipboard)
    }

    fun screenRoutes(daemonId: String): ScreenRouteFactory = sessions.screenRoutes(daemonId)

    /** A terminal surface (machine, project, or conversation); each view owns one. */
    fun terminals(): Terminals = Terminals(sessions, terminalPumps, terminalSelections, scope)

    /** Every terminal on every online, compatible machine, with its own terminal surface. */
    fun terminalOverview(): TerminalOverview =
        TerminalOverview(sessions, { connection.machines.value.online.filter { it.compatible } }, terminals())

    /** The account-wide activity feed: needs-you, running, and recent conversations. */
    fun activity(): Flow<List<ActivityItem>> = combine(workspace.state, outbox.view, ::activity).distinctUntilChanged()

    /** The activity projection now, e.g. for a widget rendered outside the app. */
    fun currentActivity(): List<ActivityItem> = activity(workspace.state.value, outbox.view.value)

    private fun activity(view: WorkspaceView, pending: OutboxView): List<ActivityItem> = Activity.project(
        cards = view.allItems,
        conversations = view.conversations,
        projects = view.projects,
        boards = view.boards.values.flatten(),
        hiddenMessageIds = pending.pendingMessageIds + pending.failedIds,
        excludedIds = pending.pendingCardIds,
    )

    private val notificationPlanner = platform.notifications?.let { NotificationPlanner(it, platform.settings) }

    /** The user dismissed a running chat's notification; it stays hidden until that chat's next turn. */
    suspend fun dismissRunningNotification(cardId: String, session: String) = onCore { notificationPlanner?.dismissRunning(cardId, session) }

    /**
     * One periodic background check: waits up to [BackgroundPolicy.WINDOW_TIMEOUT]
     * for a fresh feed frame, then stays until no agent works and nothing waits
     * for delivery. The platform keeps the device awake around it.
     */
    suspend fun periodicWindow() {
        val previous = connection.feedStatus.value.lastAppliedAt
        val synced = withTimeoutOrNull(BackgroundPolicy.WINDOW_TIMEOUT) {
            connection.feedStatus.first { status -> status.live && status.lastAppliedAt != previous }
        }
        if (synced != null) combine(workspace.state, outbox.view) { view, pending -> BackgroundPolicy.hasActiveWork(view.allItems, pending) }.first { !it }
    }

    /** What a running chat is doing now, from its live transcript tail; else its summary. */
    private fun runningDetail(card: Card, snapshot: ConversationSnapshot?): String? {
        val conversation = snapshot?.conversation ?: return card.summary.ifBlank { null }
        return LiveActivities.resolve(
            conversation.messages, conversation.pending_tools, conversation.task_plans, conversationStatus = conversation.status,
            cardRuntime = card.runtime, providerStatus = conversation.provider_status,
        ).english()
    }

    /** The conversation on screen; its results and review requests are not notified. */
    @kotlin.concurrent.Volatile
    var visibleConversationId: String? = null

    /** Runs a board or card mutation on the core dispatcher. */
    suspend fun <T> onBoard(block: suspend BoardOperations.() -> T): T = onCore { board.block() }

    suspend fun retryPending(id: String) = onCore { outbox.retry(id) }

    suspend fun retryPendingOn(daemonId: String) = onCore { outbox.retryMachine(daemonId) }

    suspend fun discardPending(id: String) = onCore { outbox.discard(id).size }

    suspend fun discardPendingOn(daemonId: String) = onCore { outbox.discardMachine(daemonId) }

    /** Runs [block] against one machine over its shared, scoped data plane. */
    suspend fun <T> onMachine(daemonId: String, block: suspend (DieterServiceClient) -> T): T =
        onCore { sessions.call(daemonId, block) }

    /** Stops all work, persisting what the feed applied, and closes every connection. */
    suspend fun shutdown() {
        scope.coroutineContext.job.cancelAndJoin()
        withContext(dispatcher) {
            drafts.flush()
            sessions.closeAll()
        }
    }
}

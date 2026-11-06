package com.getdieter.core

import com.getdieter.api.v1.Card
import com.getdieter.api.v1.Conversation
import com.getdieter.api.v1.CreateConversationRequest
import com.getdieter.api.v1.Harness
import com.getdieter.api.v1.HarnessSelection
import com.getdieter.api.v1.MessagePart
import com.getdieter.core.activity.Activity
import com.getdieter.core.activity.ActivityItem
import com.getdieter.core.activity.FilteredActivity
import com.getdieter.core.activity.InboxFilter
import com.getdieter.core.admin.Administration
import com.getdieter.core.admin.BackgroundPolicy
import com.getdieter.core.admin.MachineAdmin
import com.getdieter.core.admin.MachineTelemetry
import com.getdieter.core.api.DaemonApi
import com.getdieter.core.board.BoardOperations
import com.getdieter.core.channels.ChannelSettingsStore
import com.getdieter.core.channels.ChannelSwitches
import com.getdieter.core.composition.ConversationDrafts
import com.getdieter.core.composition.Creation
import com.getdieter.core.composition.CreationDestinations
import com.getdieter.core.composition.CreationInput
import com.getdieter.core.composition.CreationMemory
import com.getdieter.core.composition.CreationPlan
import com.getdieter.core.composition.DraftKey
import com.getdieter.core.composition.TaskCaptures
import com.getdieter.core.connection.ConnectionPhase
import com.getdieter.core.connection.ConnectionSupervisor
import com.getdieter.core.connection.MachineDirectory
import com.getdieter.core.connection.MachineSync
import com.getdieter.core.connection.MachineSyncs
import com.getdieter.core.connection.SupervisorConfig
import com.getdieter.core.conversation.ConversationConfig
import com.getdieter.core.conversation.ConversationSession
import com.getdieter.core.conversation.Conversations
import com.getdieter.core.files.FileTree
import com.getdieter.core.files.Files
import com.getdieter.core.identity.AccountStore
import com.getdieter.core.identity.ClientIdentity
import com.getdieter.core.identity.Credentials
import com.getdieter.core.identity.Gateway
import com.getdieter.core.identity.SignIn
import com.getdieter.core.machines.MachineChoice
import com.getdieter.core.mail.MailMachine
import com.getdieter.core.mail.MailProjection
import com.getdieter.core.mail.MailRules
import com.getdieter.core.mail.Mailbox
import com.getdieter.core.metadata.MachineMetadataStore
import com.getdieter.core.navigation.KvAcceptor
import com.getdieter.core.navigation.NavigationEditor
import com.getdieter.core.navigation.NavigationLayout
import com.getdieter.core.navigation.SharedKv
import com.getdieter.core.navigation.kvMachines
import com.getdieter.core.notifications.NotificationPlanner
import com.getdieter.core.notifications.NotificationSettings
import com.getdieter.core.outbox.Outbox
import com.getdieter.core.outbox.OutboxPolicy
import com.getdieter.core.outbox.OutboxView
import com.getdieter.core.platform.Platform
import com.getdieter.core.presentation.LiveActivities
import com.getdieter.core.quotas.ProviderQuotas
import com.getdieter.core.routing.RouteSelector
import com.getdieter.core.routing.RoutingPolicy
import com.getdieter.core.routing.WebRtcCooldown
import com.getdieter.core.runtime.CoreException
import com.getdieter.core.runtime.FailureKind
import com.getdieter.core.runtime.Failures
import com.getdieter.core.schedules.Schedules
import com.getdieter.core.screens.LocalClipboard
import com.getdieter.core.screens.ScreenConfig
import com.getdieter.core.screens.ScreenMediaEngineFactory
import com.getdieter.core.screens.ScreenRouteFactory
import com.getdieter.core.screens.ScreenSession
import com.getdieter.core.screens.screenRoutes
import com.getdieter.core.selection.Selections
import com.getdieter.core.session.MachineSessions
import com.getdieter.core.storage.CoreStorage
import com.getdieter.core.store.WorkspaceStore
import com.getdieter.core.store.WorkspaceView
import com.getdieter.core.sync.AccountSync
import com.getdieter.core.terminals.TerminalInputPumps
import com.getdieter.core.terminals.TerminalOverview
import com.getdieter.core.terminals.TerminalSelections
import com.getdieter.core.terminals.Terminals
import com.getdieter.core.trust.DeviceTrust
import com.getdieter.core.trust.TrustState
import com.getdieter.core.workspace.ProjectChanges
import com.getdieter.core.workspace.ProjectWorkspaces
import com.getdieter.core.workspace.WorkspaceReview
import kotlin.concurrent.Volatile
import kotlin.coroutines.cancellation.CancellationException
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
import okio.ByteString

data class RuntimeConfig(
    /** The canonical Dieter release of the app. */
    val clientVersion: String,
    /** The platform's OAuth callback, e.g. `dieter-android://oauth/callback`. */
    val oauthRedirectUri: String,
    /** Only hosts that can run a daemon themselves (macOS, JVM) try loopback routes. */
    val includeLoopbackRoutes: Boolean,
    /** Prefix of a newly generated sync client ID, e.g. `android` or `mac`. */
    val clientIdPrefix: String = "core",
    val conversations: ConversationConfig = ConversationConfig(),
)

/**
 * The shared client core. Every piece of mutable state is confined to one serialized dispatcher;
 * public entry points hop onto it, and [StateFlow]s may be read from any thread.
 */
class CoreRuntime(val platform: Platform, val config: RuntimeConfig) {
    val dispatcher: CoroutineDispatcher = Dispatchers.Default.limitedParallelism(1)
    val scope = CoroutineScope(SupervisorJob() + dispatcher)

    val storage = CoreStorage(platform.fileSystem, platform.stateDirectory)
    val credentials = Credentials(platform.secureStore)
    val accounts = AccountStore(storage)
    val signIn =
        SignIn(storage, platform.http, credentials, config.oauthRedirectUri, platform.clock)
    val workspace = WorkspaceStore(platform.clock)

    /** The account view from every machine's change stream. */
    val accountSync = AccountSync(workspace, scope, platform.clock, platform.logger)

    /**
     * This device's membership in the account's device roster. Kept outside every account's
     * namespace, so signing out keeps the device's key and pinned roster.
     */
    val trust =
        DeviceTrust(
            platform.deviceKeys,
            platform.signatures,
            storage.scope(TRUST_NAMESPACE),
            platform.clock,
            platform.logger,
        )
    private val cooldown = WebRtcCooldown(platform.clock)
    private val routes =
        RouteSelector(
            platform.transport,
            platform.tunnels,
            platform.controlChannels,
            trust,
            RoutingPolicy(config.includeLoopbackRoutes),
            cooldown,
            platform.logger,
            platform.clock,
        )
    val sessions =
        MachineSessions(routes, scope) { plane ->
            // Every authenticated connection compares roster heads with its machine.
            scope.launch {
                try {
                    trust.gossip(plane.daemonId, plane.client)
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (error: Throwable) {
                    platform.logger.info(
                        "DeviceTrust",
                        "roster gossip with ${plane.daemonId} failed: ${Failures.message(error)}",
                    )
                }
            }
        }
    val clientId: String = ClientIdentity.load(storage, config.clientIdPrefix)
    val connection: ConnectionSupervisor =
        ConnectionSupervisor(
            scope,
            accounts,
            credentials,
            sessions,
            accountSync,
            trust,
            ::storageFor,
            platform.transport,
            SupervisorConfig(config.clientVersion),
            platform.clock,
            platform.logger,
            onGatewayPrepared = { _, prepared ->
                // Overlays and pending results belong to the previous account; everything below
                // rebinds.
                workspace.clear()
                trust.forget()
                gatewayStorage = prepared
                terminalSelections.reload()
                terminalPumps.cancelAll()
                outbox.bind(prepared.scope("outbox"))
                mailbox.bind(prepared.scope("mail"))
                navigationKv.bind(prepared.scope("navigation"))
                drafts.bind(prepared.scope("drafts"))
                captures.bind(prepared.scope("captures"))
                metadata.forget()
                conversations.reset()
                board.reset()
                schedules.stop()
                telemetry.reset()
                projectWorkspaces.reset()
                quotas.reset()
                channelSettings.reset()
                gatewayListeners.forEach { it() }
            },
        )

    /** Which machine serves what. */
    val choice = MachineChoice(workspace, accountSync, connection.machines, sessions.routes)
    val outbox =
        Outbox(clientId, sessions, workspace, choice, platform.clock, platform.logger) {
            accountSync.snapshot.value.mail
        }

    /** The account's mail on this device: kept bodies, pending changes, preferences. */
    val mailbox =
        Mailbox(sessions, outbox, platform.settings, scope, platform.logger, ::mailProjection)
    val board = BoardOperations(sessions, workspace, choice)
    val navigationKv =
        SharedKv(
            NAVIGATION_NAMESPACE,
            sessions.kvMachines(),
            acceptor = { machineId ->
                accountSync
                    .replica(machineId)
                    ?.takeIf { it.hasView && it.account.isNotEmpty() }
                    ?.let { KvAcceptor(it.account, it.daemonId) }
            },
            logger = platform.logger,
        )
    val navigation = NavigationEditor(navigationKv)

    /** The account's agent channel settings (experimental), written on a reachable machine. */
    val channelSettings = ChannelSettingsStore(sessions, choice::reachable, platform.logger)
    val metadata = MachineMetadataStore(sessions, scope, platform.clock, platform.logger)
    val drafts = ConversationDrafts(platform.clock, platform.logger, scope)
    val captures = TaskCaptures(platform.clock, platform.logger, scope)
    val creation = CreationMemory(storage, platform.logger)
    val schedules = Schedules(sessions, workspace, choice, scope, metadata)
    val telemetry = MachineTelemetry(sessions, scope)
    val projectWorkspaces = ProjectWorkspaces(sessions, workspace, choice)
    val quotas = ProviderQuotas(platform.logger)
    private var gatewayStorage: CoreStorage? = null
    val terminalPumps = TerminalInputPumps(sessions, scope)
    val terminalSelections = TerminalSelections { gatewayStorage }
    val conversations: Conversations =
        Conversations(
            sessions,
            workspace,
            outbox,
            board,
            drafts,
            config.conversations,
            platform.clock,
            platform.logger,
            scope,
            platform.settings,
            catalog = { daemonId -> metadata.machines.value[daemonId]?.harnesses?.harnesses },
            syncs = connection.syncs,
        )

    @Volatile private var gatewayListeners = emptyList<() -> Unit>()

    /**
     * Runs [listener] on the core dispatcher whenever the active gateway changes, after the runtime
     * dropped the previous account's state. Register before [start].
     */
    fun onGatewayChange(listener: () -> Unit) {
        gatewayListeners = gatewayListeners + listener
    }

    /** Per-gateway state lives in its own namespace, so switching accounts never mixes data. */
    fun storageFor(gateway: Gateway): CoreStorage = storage.scope("gateway-${gateway.origin}")

    fun start() {
        scope.launch { connection.start() }
        // Connections exist only while this device is trusted, each pinned to its machine's
        // current roster key.
        scope.launch {
            trust.view
                .map { (it.state == TrustState.TRUSTED) to it.roster }
                .distinctUntilChanged()
                .collect { (trusted, _) ->
                    if (!trusted) sessions.closeAll()
                    else
                        sessions.retainTrusted { daemonId, key -> trust.daemonKey(daemonId) == key }
                }
        }
        scope.launch { outbox.run(reachableMachines()) }
        scope.launch { workspace.revision.collect { outbox.reconcile() } }
        // Mail changes settle when their machine's headers show them.
        scope.launch {
            accountSync.snapshot
                .map { it.mail }
                .distinctUntilChanged()
                .collect {
                    outbox.reconcile()
                    mailbox.mailChanged()
                }
        }
        scope.launch {
            mailbox.run(
                connection.syncs
                    .map { syncs -> syncs.filterValues { it.current }.keys }
                    .distinctUntilChanged(),
                reachableMachines(),
            )
        }
        // An inline error goes with its card.
        scope.launch {
            workspace.state.collect { view -> board.retainErrors { view.card(it) != null } }
        }
        // A machine the account no longer lists leaves the account view with its cache.
        scope.launch {
            combine(connection.session, connection.machines) { session, machines ->
                    machines.all.map { it.id }.toSet().takeIf { session != null }
                }
                .collect { listed -> if (listed != null) accountSync.retain(listed) }
        }
        scope.launch {
            accountSync.snapshot
                .map { it.kv[NAVIGATION_NAMESPACE].orEmpty() }
                .distinctUntilChanged()
                .collect(navigationKv::apply)
        }
        scope.launch {
            accountSync.snapshot
                .map { it.kv[ChannelSwitches.NAMESPACE].orEmpty() }
                .distinctUntilChanged()
                .collect(channelSettings::apply)
        }
        scope.launch {
            navigationKv.run(
                reachableMachines(),
                connection.syncs
                    .map { syncs -> syncs.values.any { it.current } }
                    .distinctUntilChanged(),
            )
        }
        // Pinned chats keep the order they were first seen in; later pins append. Only after
        // a machine's full view, so a saved order elsewhere is never mistaken for none.
        scope.launch {
            combine(workspace.state, navigationKv.values, navigationKv.status) {
                    view,
                    values,
                    status ->
                    view.chats.takeIf { chats ->
                        status.caughtUp &&
                            chats.any { it.pinned } &&
                            NavigationLayout(values).savedPinnedChatOrder().isEmpty()
                    }
                }
                .collect { chats -> if (chats != null) navigation.initializePinnedChatOrder(chats) }
        }
        notificationPlanner?.let { planner ->
            scope.launch {
                accounts.state.map { it.active }.distinctUntilChanged().collect { planner.reset() }
            }
            scope.launch {
                // Machines current before a frame: a machine catching up never replays its backlog
                // as notifications.
                var current = emptySet<String>()
                workspace.state.collect { view ->
                    if (!view.loaded) return@collect
                    val boardNames = view.boards.values.flatten().associate { it.id to it.name }
                    val before = current
                    planner.frame(
                        view.allItems,
                        view.activities,
                        NotificationSettings.load(platform.settings),
                        boardNames,
                        { card -> runningDetail(card, view.activities[card.id]) },
                        visibleConversationId,
                        replaying = { card ->
                            workspace.directoryProjection.owner(card) !in before
                        },
                    )
                    current = connection.syncs.value.filterValues { it.current }.keys
                }
            }
            scope.launch {
                // As for cards: mail a machine replays while catching up is never notified. A
                // machine's catch-up is published before it reports Live, so the set of current
                // machines is read after each mail view, and also follows Live alone: a machine
                // that caught up without new mail notifies its next message.
                var current = emptySet<String>()
                combine(
                        accountSync.snapshot.map { it.mail }.distinctUntilChanged(),
                        connection.syncs
                            .map { syncs -> syncs.filterValues { it.current }.keys }
                            .distinctUntilChanged(),
                    ) { mail, live ->
                        mail to live
                    }
                    .collect { (mail, live) ->
                        if (!accountSync.loaded.value) return@collect
                        val before = current
                        planner.mail(
                            mail,
                            MailRules.overlay(mail, outbox.view.value.entries),
                            NotificationSettings.load(platform.settings),
                            mailbox.preferences.value,
                            name = ::machineName,
                            open = mailbox.openRefs(),
                            replaying = { it !in before },
                        )
                        current = live
                    }
            }
            // A message read, archived or deleted on this device loses its notification at once.
            scope.launch {
                outbox.view
                    .map { view -> view.entries.filter(MailRules::changesMail) }
                    .distinctUntilChanged()
                    .collect { entries ->
                        planner.mailShown(
                            MailRules.overlay(accountSync.snapshot.value.mail, entries)
                        )
                    }
            }
        }
        scope.launch { quotas.run(connection.session.map { it?.client }.distinctUntilChanged()) }
        scope.launch {
            var known = emptyMap<String, String>()
            outbox.view
                .map { it.resolutions }
                .distinctUntilChanged()
                .collect { resolutions ->
                    for ((local, server) in resolutions) if (known[local] != server)
                        drafts.retargetAll(local, server)
                    known = resolutions
                }
        }
    }

    /**
     * Machines that can take commands now: every online, compatible machine while connected, this
     * device's first.
     */
    private fun reachableMachines(): Flow<List<String>> =
        combine(
                connection.session,
                connection.machines,
                sessions.routes,
                trust.view.map { it.state == TrustState.TRUSTED }.distinctUntilChanged(),
            ) { session, machines, routes, trusted ->
                if (session == null || !trusted) emptyList()
                else MachineChoice.ordered(machines, routes)
            }
            .distinctUntilChanged()

    /** Foreground, or a background window the platform allows (e.g. Android's sync service). */
    fun setActive(active: Boolean) = connection.setRunning(active)

    /** Runs [block] on the core's confined dispatcher. */
    suspend fun <T> onCore(block: suspend CoroutineScope.() -> T): T =
        withContext(dispatcher, block)

    /** The URL to open for GitHub sign-in to [gateway]. */
    suspend fun beginSignIn(gateway: Gateway): String = onCore { signIn.begin(gateway) }

    /** Completes sign-in from the OAuth callback URL and connects. */
    suspend fun completeSignIn(callbackUrl: String): Gateway = onCore {
        val gateway = signIn.complete(callbackUrl)
        activate(gateway)
        gateway
    }

    /**
     * Uses a gateway session obtained elsewhere, such as an isolated test run's token, and connects
     * to that gateway. An isolated fixture's [pairingCode] makes this device pair with that code,
     * which the fixture's machine approves.
     */
    suspend fun adoptSession(gateway: Gateway, token: String, pairingCode: String? = null) =
        onCore {
            require(token.isNotBlank()) { "The session token is empty." }
            pairingCode?.takeIf { it.isNotBlank() }?.let(trust::usePairingCode)
            credentials.save(gateway, token.trim())
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
     * Replays every machine's stream from scratch. Each machine's view stays shown until its replay
     * caught up, then is replaced as a whole. Undelivered changes, drafts, and navigation stay.
     */
    suspend fun resync() = onCore {
        accountSync.rewind()
        connection.restart()
    }

    /**
     * Forgets the active gateway's session and everything this device kept for that account:
     * undelivered changes, drafts, captures, navigation, terminal selections, and the cached
     * workspace. Routes and streams stop and the session asks for sign-in again; the gateway stays
     * listed.
     */
    suspend fun signOut() = onCore {
        val gateway = accounts.state.value.active
        credentials.remove(gateway)
        // Detach the journals first, so nothing writes the namespace while it is removed.
        outbox.bind(null)
        mailbox.bind(null)
        navigationKv.bind(null)
        drafts.bind(null)
        captures.bind(null)
        gatewayStorage = null
        terminalPumps.cancelAll()
        // The restart prepares the gateway afresh, rebinding everything to the empty namespace.
        connection.unprepare()
        storageFor(gateway).clear()
        workspace.clear()
        trust.forget()
        connection.restart()
    }

    /** Rereads the account's trusted devices and, while shown, the devices waiting to join. */
    suspend fun refreshDevices() = onCore { trust.refresh() }

    /** Signs the device that shows [code] into the account's device roster. */
    suspend fun approveDevice(code: String) = onCore { trust.approve(code) }

    /** Removes [deviceId] from the account's device roster. */
    suspend fun revokeDevice(deviceId: String) = onCore { trust.revoke(deviceId) }

    /**
     * Forgets the pinned roster and this device's key, then asks to join again; used after a
     * conflict or a revocation.
     */
    suspend fun resetTrust() = onCore {
        sessions.closeAll()
        trust.reset()
    }

    suspend fun selectGateway(origin: String) = onCore { accounts.select(origin) }

    suspend fun setGateways(gateways: List<Gateway>, activeOrigin: String? = null) = onCore {
        accounts.setGateways(gateways, activeOrigin)
    }

    /** Makes [gateway] active, adding it when it is new. */
    suspend fun useGateway(gateway: Gateway) = onCore { accounts.use(gateway) }

    /** Removes the gateway at [origin]; the last one stays. */
    suspend fun removeGateway(origin: String) = onCore { accounts.remove(origin) }

    suspend fun setConnected(value: Boolean) = onCore { accounts.setDesiredConnected(value) }

    /**
     * Connects now: restarts the connection instead of waiting for its next retry, and undoes a
     * disconnect.
     */
    suspend fun reconnect() = onCore {
        accounts.setDesiredConnected(true)
        connection.restart()
    }

    /** The device woke from sleep: reopens a live connection without undoing a disconnect. */
    suspend fun systemWoke() = onCore { connection.systemWoke() }

    /**
     * Queues a card or chat as [request] says; returns its optimistic row. [create] applies the
     * creation rules first.
     */
    suspend fun createConversation(
        request: CreateConversationRequest,
        chat: Boolean,
        submissionId: String? = null,
    ): Card = onCore { outbox.createConversation(request, chat, submissionId) }

    /** What the core knows of machines and their loaded catalogs for new conversations now. */
    fun creationDestinations(): CreationDestinations =
        CreationDestinations(
            online = connection.machines.value.online.mapTo(HashSet()) { it.id },
            localDaemonId = choice.local(),
            projectMachines =
                workspace.state.value.projects
                    .mapNotNull { project -> choice.project(project.id)?.let { project.id to it } }
                    .toMap(),
            catalogs =
                metadata.machines.value
                    .mapNotNull { (id, machine) -> machine.harnesses?.let { id to it.harnesses } }
                    .toMap(),
        )

    /**
     * [input] checked against its destination ([Creation.plan]). The machine whose catalog the
     * pickers show starts loading it when it is online.
     */
    suspend fun planCreation(input: CreationInput): CreationPlan = onCore {
        val destinations = creationDestinations()
        val plan = Creation.plan(input, destinations)
        Creation.catalogMachine(plan.checkout, destinations.projectMachines[input.project.id])
            ?.takeIf { it in destinations.online }
            ?.let { metadata.ensure(it) }
        plan
    }

    /**
     * Queues [input] once it passes the creation rules ([CreationPlan.problem]), waiting up to
     * [Creation.CATALOG_WAIT] for an online destination's catalog, and remembers its choices
     * ([CreationMemory.remember]). With [captureId], that capture is submitted at most once
     * ([submitCapture]); otherwise reusing [submissionId] never creates a second conversation.
     */
    suspend fun create(
        input: CreationInput,
        captureId: String? = null,
        submissionId: String? = null,
    ): Card = onCore {
        var plan = planCreation(input)
        val daemonId = plan.daemonId
        if (plan.needsCatalog && daemonId != null) {
            withTimeoutOrNull(Creation.CATALOG_WAIT) {
                metadata.machines.first { it[daemonId]?.loaded == true }
            }
            plan = Creation.plan(input, creationDestinations())
        }
        plan.problem?.let { problem ->
            // A destination whose catalog did not load yet may still take it later.
            throw CoreException(
                if (plan.checkout != null && plan.catalog == null) FailureKind.TRANSIENT
                else FailureKind.PERMANENT,
                problem,
            )
        }
        val request = Creation.request(plan.input)
        val card =
            if (captureId != null) submitCapture(captureId, request, input.chat)
            else outbox.createConversation(request, input.chat, submissionId)
        creation.remember(plan.input)
        card
    }

    /**
     * Queues a message; returns its ID. An open conversation sends it ([ConversationSession.send]);
     * otherwise it goes straight to the outbox under the same rules: its agent is [selection], else
     * the composer's choice, else the conversation's ([Selections.forSend] against the conversation
     * machine's catalog), and it joins the queue while the agent works or messages wait
     * ([ConversationSession.placement]).
     */
    suspend fun sendMessage(
        cardId: String,
        parts: List<MessagePart>,
        selection: HarnessSelection? = null,
    ): String = onCore {
        conversations.session(cardId)?.let { session ->
            return@onCore session.send(
                parts,
                selection,
                session.view.value.daemonId?.let(::loadedCatalog),
            )
        }
        ConversationSession.checkSendable(parts)
        val target = outbox.view.value.resolve(cardId)
        val view = workspace.state.value
        // A conversation still being created is known by its outbox entry.
        val card =
            view.card(target)
                ?: outbox.view.value.entries
                    .firstOrNull { target in OutboxPolicy.conversationIds(it) }
                    ?.let(OutboxPolicy::optimisticCard)
                ?: throw CoreException(
                    FailureKind.PERMANENT,
                    "The conversation is no longer available.",
                )
        val conversation = view.activities[target]
        val owner = workspace.directoryProjection.owner(card)
        val chosen = selection ?: owner?.let { drafts.state.value[DraftKey(it, target)] }?.selection
        val locked = Selections.locked(card, conversation?.messages.orEmpty().isNotEmpty())
        outbox.sendMessage(
            cardId,
            parts,
            Selections.forSend(chosen, card, owner?.let(::loadedCatalog), locked),
            ConversationSession.placement(card, conversation),
        )
    }

    /** [daemonId]'s agent catalog once it has loaded, else null. */
    fun loadedCatalog(daemonId: String): List<Harness>? =
        metadata.machines.value[daemonId]?.harnesses?.harnesses

    /**
     * Submits capture [id] as a task or chat. The first submit freezes the request; retries reuse
     * it, so the daemon creates the task at most once.
     */
    suspend fun submitCapture(
        id: String,
        request: CreateConversationRequest,
        chat: Boolean = false,
    ): Card = onCore {
        captures.flush(id)
        val frozen = captures.freeze(id, request)
        val card = outbox.createConversation(frozen.request ?: request, chat, frozen.submission_id)
        captures.accepted(id)
        card
    }

    suspend fun startCard(cardId: String, hasDraftAttachments: Boolean = false) = onCore {
        outbox.startCard(cardId, hasDraftAttachments)
    }

    /** The shared navigation layout (folders, orders, disclosure), with pending edits applied. */
    fun navigationLayout(): Flow<NavigationLayout> = navigationKv.values.map(::NavigationLayout)

    /** Applies a navigation edit; it is queued durably and synchronized across the account. */
    suspend fun <T> editNavigation(block: NavigationEditor.() -> T): T = onCore {
        navigation.block()
    }

    /** Opens a conversation on the machine that runs it; the session streams until closed. */
    suspend fun openConversation(cardId: String): ConversationSession = onCore {
        conversations.open(cardId)
    }

    suspend fun closeConversation(cardId: String) = onCore { conversations.close(cardId) }

    /** Runs an action on an open conversation on the core dispatcher. */
    suspend fun <T> onConversation(
        session: ConversationSession,
        block: suspend ConversationSession.() -> T,
    ): T = onCore { session.block() }

    /** A conversation's workspace review surface; each view owns one. */
    fun workspaceReview(): WorkspaceReview = WorkspaceReview(sessions, workspace, board, scope)

    /** A project checkout's changes surface; each view owns one. */
    fun projectChanges(): ProjectChanges = ProjectChanges(sessions, workspace, scope)

    val admin = Administration(sessions, workspace, choice)

    /** Renames a machine on the gateway; every client sees the new name through presence. */
    suspend fun renameMachine(daemonId: String, name: String) = onCore {
        val gateway =
            connection.session.value?.client
                ?: throw CoreException(FailureKind.TRANSIENT, "Connect to the gateway first.")
        MachineAdmin.rename(gateway, daemonId, name)
    }

    /** Revokes a machine; its view leaves the account. */
    suspend fun revokeMachine(daemonId: String) = onCore {
        val gateway =
            connection.session.value?.client
                ?: throw CoreException(FailureKind.TRANSIENT, "Connect to the gateway first.")
        MachineAdmin.revoke(gateway, daemonId)
        sessions.invalidate(daemonId)
        accountSync.forget(daemonId)
    }

    /** A files surface (checkout or conversation workspace); each view owns one. */
    fun files(): Files = Files(sessions)

    /** A conversation's lazily expanded file tree. */
    fun fileTree(): FileTree = FileTree(sessions)

    /**
     * A screen-sharing view; the host supplies its WebRTC engine and pasteboard. Connect it with
     * [screenRoutes]. Call it on [dispatcher].
     */
    fun screen(
        engines: ScreenMediaEngineFactory,
        config: ScreenConfig,
        clipboard: LocalClipboard? = null,
    ): ScreenSession =
        ScreenSession(
            engines,
            platform.signatures,
            config,
            platform.clock,
            scope,
            platform.logger,
            clipboard,
        )

    fun screenRoutes(daemonId: String): ScreenRouteFactory = sessions.screenRoutes(daemonId)

    /** A terminal surface (machine, project, or conversation); each view owns one. */
    fun terminals(): Terminals = Terminals(sessions, terminalPumps, terminalSelections, scope)

    /** Every terminal on every online, compatible machine, with its own terminal surface. */
    fun terminalOverview(): TerminalOverview =
        TerminalOverview(
            sessions,
            { connection.machines.value.online.filter { it.compatible } },
            terminals(),
        )

    /**
     * The account-wide activity feed: needs-you, running, and recent conversations that the
     * account's Inbox rules show.
     */
    fun activity(): Flow<List<ActivityItem>> =
        filteredActivity().map { it.items }.distinctUntilChanged()

    /** [activity] with how many conversations the Inbox rules hide. */
    internal fun filteredActivity(): Flow<FilteredActivity> =
        combine(
                combine(
                        workspace.state,
                        outbox.view,
                        connection.syncs,
                        connection.machines,
                        ::activity,
                    )
                    .distinctUntilChanged(),
                navigationKv.values,
            ) { items, values ->
                filtered(items, values)
            }
            .distinctUntilChanged()

    /** The activity projection now, e.g. for a widget rendered outside the app. */
    fun currentActivity(): List<ActivityItem> =
        filtered(
                activity(
                    workspace.state.value,
                    outbox.view.value,
                    connection.syncs.value,
                    connection.machines.value,
                ),
                navigationKv.values.value,
            )
            .items

    private fun filtered(items: List<ActivityItem>, values: Map<String, ByteString>) =
        InboxFilter(NavigationLayout(values).inboxRules()).apply(items)

    private fun activity(
        view: WorkspaceView,
        pending: OutboxView,
        syncs: Map<String, MachineSync>,
        machines: MachineDirectory,
    ): List<ActivityItem> =
        Activity.project(
            cards = view.allItems,
            activities = view.activities,
            projects = view.projects,
            boards = view.boards.values.flatten(),
            hiddenMessageIds = pending.pendingMessageIds + pending.failedIds,
            excludedIds = pending.pendingCardIds,
            staleness = { card -> staleness(card, syncs, machines) },
        )

    /** [machineId]'s name, else its ID. */
    fun machineName(machineId: String): String =
        connection.machines.value.machine(machineId)?.name?.ifBlank { null } ?: machineId

    /**
     * The account-wide mailbox now: every machine's mail headers with this device's pending
     * changes, each machine named, with why its view may be old ([MachineSyncs.staleness]) and
     * whether it is reachable.
     */
    fun mailProjection(): MailProjection {
        val mail = MailRules.overlay(accountSync.snapshot.value.mail, outbox.view.value.entries)
        val syncs = connection.syncs.value
        val reachable =
            if (connection.session.value == null) emptySet() else choice.reachable().toSet()
        return MailRules.project(
            mail,
            mail.keys.associateWith { id ->
                val name = machineName(id)
                MailMachine(id, name, MachineSyncs.staleness(syncs[id], name), id in reachable)
            },
        )
    }

    /** Why [card]'s owner data may be old ([MachineSyncs.staleness]); null while current. */
    fun staleness(
        card: Card,
        syncs: Map<String, MachineSync>,
        machines: MachineDirectory,
    ): String? {
        val owner = workspace.directoryProjection.owner(card) ?: return null
        return MachineSyncs.staleness(
            syncs[owner],
            machines.machine(owner)?.name?.ifBlank { null } ?: "Its machine",
        )
    }

    private val notificationPlanner =
        platform.notifications?.let { NotificationPlanner(it, platform.settings) }

    /**
     * The user dismissed a running chat's notification; it stays hidden until that chat's next
     * turn.
     */
    suspend fun dismissRunningNotification(cardId: String, session: String) = onCore {
        notificationPlanner?.dismissRunning(cardId, session)
    }

    /**
     * One periodic background check: waits up to [BackgroundPolicy.WINDOW_TIMEOUT] until every
     * online machine's view is current, then stays until no agent works and nothing waits for
     * delivery. The platform keeps the device awake around it.
     */
    suspend fun periodicWindow() {
        val synced =
            withTimeoutOrNull(BackgroundPolicy.WINDOW_TIMEOUT) {
                combine(connection.state, connection.machines, connection.syncs) {
                        state,
                        machines,
                        syncs ->
                        state.phase == ConnectionPhase.CONNECTED &&
                            MachineSyncs.current(machines, syncs)
                    }
                    .first { it }
            }
        if (synced != null)
            combine(workspace.state, outbox.view) { view, pending ->
                    BackgroundPolicy.hasActiveWork(view.allItems, pending)
                }
                .first { !it }
    }

    /** What a running chat is doing now, from its owner's activity; else its summary. */
    private fun runningDetail(card: Card, activity: Conversation?): String? {
        val conversation = activity ?: return card.summary.ifBlank { null }
        return LiveActivities.resolve(
                conversation.messages,
                conversation.pending_tools,
                conversation.task_plans,
                conversationStatus = conversation.status,
                cardRuntime = card.runtime,
                providerStatus = conversation.provider_status,
            )
            .english()
    }

    /** The conversation on screen; its results and review requests are not notified. */
    @Volatile var visibleConversationId: String? = null

    /** Runs a board or card mutation on the core dispatcher. */
    suspend fun <T> onBoard(block: suspend BoardOperations.() -> T): T = onCore { board.block() }

    suspend fun retryPending(id: String) = onCore { outbox.retry(id) }

    suspend fun retryPendingOn(daemonId: String) = onCore { outbox.retryMachine(daemonId) }

    suspend fun discardPending(id: String) = onCore { outbox.discard(id).size }

    suspend fun discardPendingOn(daemonId: String) = onCore { outbox.discardMachine(daemonId) }

    /** Runs [block] against one machine over its shared, scoped data plane. */
    suspend fun <T> onMachine(daemonId: String, block: suspend (DaemonApi) -> T): T = onCore {
        sessions.call(daemonId, block)
    }

    /** Stops all work, persisting every machine's view, and closes every connection. */
    suspend fun shutdown() {
        scope.coroutineContext.job.cancelAndJoin()
        withContext(dispatcher) {
            drafts.flush()
            accountSync.flush()
            sessions.closeAll()
        }
    }

    private companion object {
        /** The shared navigation layout's KV namespace. */
        const val NAVIGATION_NAMESPACE = "navigation"

        /** Device trust's directory, outside every account's namespace. */
        const val TRUST_NAMESPACE = "trust"
    }
}

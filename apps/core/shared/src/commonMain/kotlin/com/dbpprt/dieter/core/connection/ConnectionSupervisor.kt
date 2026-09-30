package com.dbpprt.dieter.core.connection

import com.dbpprt.dieter.core.identity.AccountStore
import com.dbpprt.dieter.core.identity.Credentials
import com.dbpprt.dieter.core.identity.Gateway
import com.dbpprt.dieter.core.machines.Machine
import com.dbpprt.dieter.core.machines.MachinePresence
import com.dbpprt.dieter.core.machines.MachineSelection
import com.dbpprt.dieter.core.platform.RpcTransport
import com.dbpprt.dieter.core.runtime.Backoff
import com.dbpprt.dieter.core.runtime.CoreLogger
import com.dbpprt.dieter.core.runtime.FailureKind
import com.dbpprt.dieter.core.runtime.Failures
import com.dbpprt.dieter.core.session.GatewaySession
import com.dbpprt.dieter.core.session.MachineSessions
import com.dbpprt.dieter.core.storage.CoreStorage
import com.dbpprt.dieter.core.store.WorkspaceStore
import com.dbpprt.dieter.core.sync.DirectoryPoller
import com.dbpprt.dieter.core.sync.Feed
import com.dbpprt.dieter.core.sync.FeedConfig
import com.dbpprt.dieter.core.sync.FeedStatus
import com.dbpprt.dieter.core.sync.MachineFreshness
import com.dbpprt.dieter.core.sync.PollerConfig
import kotlin.coroutines.cancellation.CancellationException
import kotlin.time.Clock
import kotlin.time.Duration
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.seconds
import kotlin.time.Instant
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.Job
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull

enum class ConnectionPhase {
    DISCONNECTED,
    CONNECTING,
    /** Connected; the attached machine is sending its first projection. */
    SYNCING,
    CONNECTED,
    RECONNECTING,
    /** Signed in, but no compatible machine is online. */
    NO_MACHINE,
    AUTH_REQUIRED,
    UPDATE_REQUIRED,
}

data class ConnectionState(
    val phase: ConnectionPhase = ConnectionPhase.DISCONNECTED,
    val gateway: Gateway? = null,
    val attachedMachineId: String? = null,
    val error: String? = null,
    val retryAt: Instant? = null,
)

/** The daemons of the active account, with presence evaluated at [evaluatedAt]. */
data class MachineDirectory(val all: List<Machine> = emptyList(), val evaluatedAt: Instant = Instant.DISTANT_PAST) {
    val online: List<Machine> get() = all.filter { it.online(evaluatedAt) }

    fun machine(id: String): Machine? = all.firstOrNull { it.id == id }
}

/** The live gateway session and attached machine, for modules that run while connected. */
class ActiveSession(val gateway: GatewaySession, val attachedMachineId: String)

data class SupervisorConfig(
    val clientVersion: String,
    val feed: FeedConfig = FeedConfig(),
    val poller: PollerConfig = PollerConfig(),
    val presenceHeartbeat: Duration = 15.seconds,
)

/**
 * Owns the connection phase machine. The feed attaches to one machine and
 * stays there; other machines are refreshed by the poller and reached over
 * scoped connections, so navigation never reconnects the app.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class ConnectionSupervisor(
    private val scope: CoroutineScope,
    private val accounts: AccountStore,
    private val credentials: Credentials,
    private val sessions: MachineSessions,
    private val store: WorkspaceStore,
    private val storageFor: (Gateway) -> CoreStorage,
    private val transport: RpcTransport,
    private val config: SupervisorConfig,
    private val clock: Clock,
    private val logger: CoreLogger,
    /** Called once a gateway's cached state is restored, before any network access. */
    private val onGatewayPrepared: (Gateway, CoreStorage) -> Unit = { _, _ -> },
) {
    private val mutableState = MutableStateFlow(ConnectionState())
    val state: StateFlow<ConnectionState> = mutableState.asStateFlow()

    private val mutableMachines = MutableStateFlow(MachineDirectory())
    val machines: StateFlow<MachineDirectory> = mutableMachines.asStateFlow()

    private val mutableActive = MutableStateFlow<ActiveSession?>(null)
    val active: StateFlow<ActiveSession?> = mutableActive.asStateFlow()

    private val mutableFeedStatus = MutableStateFlow(FeedStatus())
    val feedStatus: StateFlow<FeedStatus> = mutableFeedStatus.asStateFlow()

    private val mutableFreshness = MutableStateFlow<Map<String, MachineFreshness>>(emptyMap())
    val freshness: StateFlow<Map<String, MachineFreshness>> = mutableFreshness.asStateFlow()

    private val running = MutableStateFlow(false)
    private val leases = MutableStateFlow(0)
    private val restarts = MutableStateFlow(0L)
    private var gatewayScope: GatewayScope? = null
    private var freshnessJob: Job? = null
    private var loop: Job? = null

    private class GatewayScope(val gateway: Gateway, val storage: CoreStorage, val poller: DirectoryPoller) {
        val feeds = HashMap<String, Feed>()
    }

    fun start() {
        if (loop != null) return
        loop = scope.launch {
            combine(accounts.state.map { it.active to it.wantsConnection }.distinctUntilChanged(), running, leases, restarts) { account, run, leased, restart ->
                Triple(account.first, account.second && (run || leased > 0), restart)
            }.distinctUntilChanged().collectLatest { (gateway, shouldRun, _) ->
                val current = prepareGateway(gateway)
                try {
                    if (!shouldRun) {
                        publish(ConnectionState(ConnectionPhase.DISCONNECTED, gateway))
                        sessions.attach(null)
                        return@collectLatest
                    }
                    supervise(current)
                } finally {
                    mutableActive.value = null
                    current.feeds.values.forEach(Feed::flush)
                }
            }
        }
    }

    /** Foreground, or a background window the platform allows. */
    fun setRunning(value: Boolean) {
        running.value = value
    }

    /**
     * Connects briefly for a widget or background check without changing
     * [setRunning]: waits for a usable (or terminal) state, refreshes every
     * machine once, and releases the connection. Returns true when connected.
     */
    suspend fun refreshForWidget(timeout: Duration): Boolean {
        if (!accounts.state.value.wantsConnection) return false
        leases.update { it + 1 }
        try {
            val reached = withTimeoutOrNull(timeout) {
                state.first { it.phase == ConnectionPhase.CONNECTED || it.phase == ConnectionPhase.AUTH_REQUIRED || it.phase == ConnectionPhase.UPDATE_REQUIRED }
            } ?: return false
            if (reached.phase != ConnectionPhase.CONNECTED) return false
            val now = clock.now()
            gatewayScope?.poller?.refresh(mutableMachines.value.all.filter { it.id != reached.attachedMachineId && it.online(now) && it.compatible })
            return true
        } finally {
            leases.update { it - 1 }
        }
    }

    /** Restarts the session, e.g. after sign-in or an explicit machine choice. */
    fun restart() {
        restarts.update { it + 1 }
    }

    private fun setMachines(machines: List<Machine>) {
        mutableMachines.value = MachineDirectory(machines, clock.now())
    }

    private fun prepareGateway(gateway: Gateway): GatewayScope {
        gatewayScope?.takeIf { it.gateway == gateway }?.let { return it }
        sessions.attach(null)
        store.clear()
        mutableMachines.value = MachineDirectory()
        val storage = storageFor(gateway)
        val poller = DirectoryPoller(sessions, storage, store, config.poller, clock, logger)
        val prepared = GatewayScope(gateway, storage, poller)
        gatewayScope = prepared
        // Offline-first: render the cached projection and machine views immediately.
        val preferred = accounts.state.value.preferredMachine[gateway.origin]
        if (preferred != null) feed(prepared, preferred).restoreCached()
        poller.restoreCached(preferred)
        freshnessJob?.cancel()
        freshnessJob = scope.launch { poller.freshness.collect { mutableFreshness.value = it } }
        onGatewayPrepared(gateway, storage)
        return prepared
    }

    private fun feed(gateway: GatewayScope, daemonId: String): Feed = gateway.feeds.getOrPut(daemonId) {
        Feed(daemonId, sessions, gateway.storage, store, scope, config.feed, clock, logger)
    }

    private suspend fun supervise(gateway: GatewayScope) {
        var attempt = 0
        while (true) {
            val token = credentials.token(gateway.gateway)
            if (token == null) {
                publish(ConnectionState(ConnectionPhase.AUTH_REQUIRED, gateway.gateway))
                awaitCancellation()
            }
            val session = GatewaySession(gateway.gateway, token, transport, config.clientVersion)
            sessions.attach(session)
            try {
                publish(ConnectionState(if (attempt == 0) ConnectionPhase.CONNECTING else ConnectionPhase.RECONNECTING, gateway.gateway))
                session.verify()
                setMachines(session.machines())
                runSession(gateway, session) { attempt = 0 }
                error("the session loop ended")
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Throwable) {
                when (Failures.kind(error)) {
                    FailureKind.UNAUTHENTICATED -> {
                        publish(ConnectionState(ConnectionPhase.AUTH_REQUIRED, gateway.gateway, error = Failures.message(error)))
                        awaitCancellation()
                    }
                    FailureKind.UPDATE_REQUIRED -> {
                        publish(ConnectionState(ConnectionPhase.UPDATE_REQUIRED, gateway.gateway, error = Failures.message(error)))
                        awaitCancellation()
                    }
                    else -> {
                        val wait = Backoff.CONNECTION.delay(attempt++)
                        logger.info(TAG, "session ended: ${Failures.message(error)}; retrying in $wait")
                        publish(
                            ConnectionState(
                                ConnectionPhase.RECONNECTING, gateway.gateway, mutableState.value.attachedMachineId,
                                error = Failures.message(error), retryAt = clock.now() + wait,
                            ),
                        )
                        delay(wait)
                    }
                }
            } finally {
                mutableActive.value = null
                sessions.attach(null)
                session.close()
            }
        }
    }

    /**
     * Keeps the feed attached. A feed failure only retries the attached
     * machine: the gateway session, presence, and other machines' planes stay
     * up unless the gateway itself rejects or loses the session.
     */
    private suspend fun runSession(gateway: GatewayScope, session: GatewaySession, onLive: () -> Unit): Unit = coroutineScope {
        launch { watchPresence(session) }
        launch { expirePresence() }
        var attempt = 0
        while (true) {
            val preferred = accounts.state.value.preferredMachine[gateway.gateway.origin]
            val target = MachineSelection.candidates(mutableMachines.value.all, preferred, explicit = false, now = clock.now()).firstOrNull()
            if (target == null) {
                publish(ConnectionState(ConnectionPhase.NO_MACHINE, gateway.gateway))
                mutableMachines.first { directory -> MachineSelection.candidates(directory.all, preferred, false, clock.now()).isNotEmpty() }
                continue
            }
            if (preferred == null) accounts.preferMachine(target.id)
            val feed = feed(gateway, target.id)
            if (mutableFeedStatus.value.daemonId != target.id) feed.restoreCached()
            publish(ConnectionState(ConnectionPhase.SYNCING, gateway.gateway, target.id))
            mutableActive.value = ActiveSession(session, target.id)
            try {
                coroutineScope {
                    launch { feed.status.collect { mutableFeedStatus.value = it } }
                    launch {
                        feed.status.first { it.live }
                        attempt = 0
                        onLive()
                        publish(ConnectionState(ConnectionPhase.CONNECTED, gateway.gateway, target.id))
                    }
                    launch { pollOthers(gateway, target.id) }
                    feed.run()
                }
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Throwable) {
                // A daemon can reject an expired daemon token too; only the gateway decides whether the session is gone.
                session.verify()
                setMachines(session.machines())
                val wait = Backoff.CONNECTION.delay(attempt++)
                logger.info(TAG, "feed for ${target.id} ended: ${Failures.message(error)}; retrying in $wait")
                publish(
                    ConnectionState(
                        ConnectionPhase.RECONNECTING, gateway.gateway, target.id,
                        error = Failures.message(error), retryAt = clock.now() + wait,
                    ),
                )
                delay(wait)
            }
        }
    }

    private suspend fun pollOthers(gateway: GatewayScope, attachedId: String) {
        while (true) {
            val now = clock.now()
            gateway.poller.refresh(mutableMachines.value.all.filter { it.id != attachedId && it.online(now) && it.compatible })
            delay(config.poller.interval)
        }
    }

    /** Presence is advisory: losing this stream never tears down the feed. */
    private suspend fun watchPresence(session: GatewaySession) {
        var attempt = 0
        while (true) {
            try {
                session.presence(config.presenceHeartbeat).collect { machines ->
                    attempt = 0
                    setMachines(machines)
                }
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Throwable) {
                logger.debug(TAG, "presence stream ended: ${Failures.message(error)}")
            }
            delay(Backoff.CONNECTION.delay(attempt++))
            runCatching { setMachines(session.machines()) }.onFailure { if (it is CancellationException) throw it }
        }
    }

    /** Re-publishes machines when a presence lease lapses, so "online" never lingers. */
    private suspend fun expirePresence() {
        while (true) {
            val next = MachinePresence.nextExpiry(mutableMachines.value.all, clock.now())
            delay(next?.let { (it - clock.now()).coerceAtLeast(Duration.ZERO) + 50.milliseconds } ?: 5.seconds)
            setMachines(mutableMachines.value.all)
        }
    }

    private fun publish(state: ConnectionState) {
        mutableState.value = state
    }

    private companion object {
        const val TAG = "Connection"
    }
}

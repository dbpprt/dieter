package com.dbpprt.dieter.core.connection

import com.dbpprt.dieter.api.gateway.v1.GatewayInformation
import com.dbpprt.dieter.core.identity.AccountStore
import com.dbpprt.dieter.core.identity.Credentials
import com.dbpprt.dieter.core.identity.Gateway
import com.dbpprt.dieter.core.machines.Machine
import com.dbpprt.dieter.core.machines.MachinePresence
import com.dbpprt.dieter.core.platform.RpcTransport
import com.dbpprt.dieter.core.runtime.Backoff
import com.dbpprt.dieter.core.runtime.CoreLogger
import com.dbpprt.dieter.core.runtime.FailureKind
import com.dbpprt.dieter.core.runtime.Failures
import com.dbpprt.dieter.core.session.GatewaySession
import com.dbpprt.dieter.core.session.MachineSessions
import com.dbpprt.dieter.core.storage.CoreStorage
import com.dbpprt.dieter.core.sync.AccountSync
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

/** The gateway connection. Machines have their own [SyncState]; none is special. */
enum class ConnectionPhase {
    DISCONNECTED,
    CONNECTING,
    CONNECTED,
    RECONNECTING,
    AUTH_REQUIRED,
    UPDATE_REQUIRED,
}

data class ConnectionState(
    val phase: ConnectionPhase = ConnectionPhase.DISCONNECTED,
    val gateway: Gateway? = null,
    val error: String? = null,
    val retryAt: Instant? = null,
)

/** The daemons of the active account, with presence evaluated at [evaluatedAt]. */
data class MachineDirectory(val all: List<Machine> = emptyList(), val evaluatedAt: Instant = Instant.DISTANT_PAST) {
    val online: List<Machine> get() = all.filter { it.online(evaluatedAt) }

    fun machine(id: String): Machine? = all.firstOrNull { it.id == id }
}

data class SupervisorConfig(
    val clientVersion: String,
    val streams: StreamConfig = StreamConfig(),
    /** The gateway's presence report interval; keep three within [MachinePresence.STALE_AFTER]. */
    val presenceHeartbeat: Duration = 15.seconds,
)

/**
 * Owns the gateway connection: its phase, presence, and a change stream to
 * every online, compatible machine ([MachineStreams]). A machine that fails
 * only affects its own view; only the gateway rejecting or losing the
 * session reconnects the app.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class ConnectionSupervisor(
    private val scope: CoroutineScope,
    private val accounts: AccountStore,
    private val credentials: Credentials,
    private val sessions: MachineSessions,
    private val sync: AccountSync,
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
    private val mutableGatewayInformation = MutableStateFlow<GatewayInformation?>(null)

    /** The active gateway's build, once it has described itself. */
    val gatewayInformation: StateFlow<GatewayInformation?> = mutableGatewayInformation.asStateFlow()

    private val mutableSession = MutableStateFlow<GatewaySession?>(null)

    /** The verified gateway session while connected, for modules that run while connected. */
    val session: StateFlow<GatewaySession?> = mutableSession.asStateFlow()

    val streams = MachineStreams(sessions, sync, config.streams, clock, logger)

    /** Machine ID → how current its part of the account view is. */
    val syncs: StateFlow<Map<String, MachineSync>> get() = streams.syncs

    private val running = MutableStateFlow(false)
    private val leases = MutableStateFlow(0)
    private val restarts = MutableStateFlow(0L)
    private var prepared: Gateway? = null
    private var loop: Job? = null

    fun start() {
        if (loop != null) return
        scope.launch { streams.expire() }
        loop = scope.launch {
            combine(accounts.state.map { it.active to it.wantsConnection }.distinctUntilChanged(), running, leases, restarts) { account, run, leased, restart ->
                Triple(account.first, account.second && (run || leased > 0), restart)
            }.distinctUntilChanged().collectLatest { (gateway, shouldRun, _) ->
                prepareGateway(gateway)
                try {
                    if (!shouldRun) {
                        publish(ConnectionState(ConnectionPhase.DISCONNECTED, gateway))
                        sessions.attach(null)
                        return@collectLatest
                    }
                    supervise(gateway)
                } finally {
                    mutableSession.value = null
                    sync.flush()
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
     * [setRunning]: waits until every online, compatible machine is live (or
     * a terminal state) and releases the connection. Returns true when every
     * reachable machine was current.
     */
    suspend fun refreshForWidget(timeout: Duration): Boolean {
        if (!accounts.state.value.wantsConnection) return false
        leases.update { it + 1 }
        try {
            return withTimeoutOrNull(timeout) {
                combine(state, machines, syncs) { connection, directory, syncs ->
                    when (connection.phase) {
                        ConnectionPhase.AUTH_REQUIRED, ConnectionPhase.UPDATE_REQUIRED -> false
                        ConnectionPhase.CONNECTED -> MachineSyncs.current(directory, syncs).takeIf { it }
                        else -> null
                    }
                }.first { it != null }
            } == true
        } finally {
            leases.update { it - 1 }
        }
    }

    /**
     * Forgets the prepared gateway and unbinds its machine views, so nothing
     * writes its namespace and the next start prepares it afresh. Call
     * [restart] afterwards.
     */
    fun unprepare() {
        prepared = null
        sync.bind(null)
    }

    /** Restarts the session, e.g. after sign-in. */
    fun restart() {
        restarts.update { it + 1 }
    }

    private fun setMachines(machines: List<Machine>) {
        mutableMachines.value = MachineDirectory(machines, clock.now())
    }

    /** Reads the directory from [session], with the gateway's build. */
    private suspend fun refreshMachines(session: GatewaySession) {
        setMachines(session.machines())
        session.information?.let { mutableGatewayInformation.value = it }
    }

    private fun prepareGateway(gateway: Gateway) {
        if (prepared == gateway) return
        sessions.attach(null)
        mutableMachines.value = MachineDirectory()
        mutableGatewayInformation.value = null
        streams.reset()
        val storage = storageFor(gateway)
        // Offline-first: every machine's cached view renders before any network access.
        sync.bind(storage)
        prepared = gateway
        onGatewayPrepared(gateway, storage)
    }

    private suspend fun supervise(gateway: Gateway) {
        var attempt = 0
        while (true) {
            val token = credentials.token(gateway)
            if (token == null) {
                publish(ConnectionState(ConnectionPhase.AUTH_REQUIRED, gateway))
                awaitCancellation()
            }
            val session = GatewaySession(gateway, token, transport, config.clientVersion, clock)
            sessions.attach(session)
            try {
                publish(ConnectionState(if (attempt == 0) ConnectionPhase.CONNECTING else ConnectionPhase.RECONNECTING, gateway))
                session.verify()
                refreshMachines(session)
                attempt = 0
                mutableSession.value = session
                publish(ConnectionState(ConnectionPhase.CONNECTED, gateway))
                coroutineScope {
                    launch { expirePresence() }
                    launch { streams.run(machines) }
                    watchPresence(session)
                }
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Throwable) {
                when (Failures.kind(error)) {
                    FailureKind.UNAUTHENTICATED -> {
                        publish(ConnectionState(ConnectionPhase.AUTH_REQUIRED, gateway, error = Failures.message(error)))
                        awaitCancellation()
                    }
                    FailureKind.UPDATE_REQUIRED -> {
                        publish(ConnectionState(ConnectionPhase.UPDATE_REQUIRED, gateway, error = Failures.message(error)))
                        awaitCancellation()
                    }
                    else -> {
                        val wait = Backoff.CONNECTION.delay(attempt++)
                        logger.info(TAG, "session ended: ${Failures.message(error)}; retrying in $wait")
                        publish(ConnectionState(ConnectionPhase.RECONNECTING, gateway, error = Failures.message(error), retryAt = clock.now() + wait))
                        delay(wait)
                    }
                }
            } finally {
                mutableSession.value = null
                sessions.attach(null)
                session.close()
            }
        }
    }

    /**
     * Keeps presence current. The gateway reports every heartbeat, so a
     * stream silent for two is restarted before its last report goes stale.
     * A broken stream re-verifies the session: only the gateway decides
     * whether it is gone, which ends this session.
     */
    private suspend fun watchPresence(session: GatewaySession): Nothing {
        var attempt = 0
        while (true) {
            try {
                session.presence(config.presenceHeartbeat).collectLatest { machines ->
                    attempt = 0
                    setMachines(machines)
                    session.information?.let { mutableGatewayInformation.value = it }
                    delay(config.presenceHeartbeat * 2)
                    error("presence stream stalled")
                }
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Throwable) {
                logger.debug(TAG, "presence stream ended: ${Failures.message(error)}")
            }
            delay(Backoff.CONNECTION.delay(attempt++))
            session.verify()
            refreshMachines(session)
        }
    }

    /** Re-publishes machines when a presence report goes stale, so "online" never lingers. */
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

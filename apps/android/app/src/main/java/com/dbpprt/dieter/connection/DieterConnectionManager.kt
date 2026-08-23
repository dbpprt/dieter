package com.dbpprt.dieter.connection

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import android.util.Base64
import com.dbpprt.dieter.data.DIETER_API_VERSION
import com.dbpprt.dieter.data.DIETER_ENDPOINTS
import com.dbpprt.dieter.data.DieterEndpoint
import com.dbpprt.dieter.data.DieterRepository
import com.dbpprt.dieter.data.AndroidOutboxEntry
import com.dbpprt.dieter.data.CachedProjectHost
import com.dbpprt.dieter.data.DieterSyncStore
import com.dbpprt.dieter.data.OutboxKind
import com.dbpprt.dieter.widget.DieterWidgetPrefs
import com.dbpprt.dieter.v1.Board
import com.dbpprt.dieter.v1.Card
import com.dbpprt.dieter.v1.ConversationSnapshot
import com.dbpprt.dieter.v1.CreateConversationRequest
import com.dbpprt.dieter.v1.GlobalSnapshot
import com.dbpprt.dieter.v1.GlobalDelta
import com.dbpprt.dieter.v1.GetStateRequest
import com.dbpprt.dieter.v1.Harness
import com.dbpprt.dieter.v1.Project
import com.dbpprt.dieter.v1.RuntimeStatus
import com.dbpprt.dieter.v1.SendMessageRequest
import com.dbpprt.dieter.v1.MessagePart
import com.dbpprt.dieter.v1.Schedule
import com.dbpprt.dieter.v1.ScheduleRun
import com.dbpprt.dieter.v1.State
import com.dbpprt.dieter.v1.StartCardRequest
import com.dbpprt.dieter.v1.StartCardResponse
import io.grpc.Status
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.cancel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeout
import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.UUID
import kotlin.time.TimeSource

enum class ConnectionPhase { STOPPED, CONNECTING, SYNCING, CONNECTED, RECONNECTING, AUTH_REQUIRED, INCOMPATIBLE, UNAVAILABLE }

enum class EndpointPhase { PENDING, TRYING, CONNECTED, FAILED }

data class EndpointConnection(
    val id: String,
    val label: String,
    val address: String,
    val phase: EndpointPhase = EndpointPhase.PENDING,
    val detail: String = "Waiting",
    val latencyMs: Long? = null,
    val online: Boolean = true,
    val daemonId: String? = null,
)

data class ProjectHost(
    val endpointId: String,
    val daemonId: String,
    val hostname: String,
    val online: Boolean,
)

data class DieterConnectionState(
    val desiredConnected: Boolean,
    val backgroundSyncEnabled: Boolean,
    val phase: ConnectionPhase = ConnectionPhase.STOPPED,
    val connectionInterruptedAtMs: Long? = null,
    val endpoint: DieterEndpoint? = null,
    val activeGatewayId: String,
    val configuredConnections: List<EndpointConnection>,
    val endpointConnections: List<EndpointConnection>,
    val runtimeStatus: RuntimeStatus? = null,
    val harnesses: List<Harness> = emptyList(),
    val selectedState: State? = null,
    val projects: List<Project> = emptyList(),
    val projectHosts: Map<String, ProjectHost> = emptyMap(),
    val boards: List<Board> = emptyList(),
    val cards: List<Card> = emptyList(),
    val chats: List<Card> = emptyList(),
    val activeConversations: Map<String, ConversationSnapshot> = emptyMap(),
    val schedules: List<Schedule> = emptyList(),
    val scheduleRuns: List<ScheduleRun> = emptyList(),
    val pendingCardIds: Set<String> = emptySet(),
    val pendingMessageIds: Set<String> = emptySet(),
    val acceptedOutboxIds: Set<String> = emptySet(),
    val failedOutboxIds: Set<String> = emptySet(),
    val resolvedConversationIds: Map<String, String> = emptyMap(),
    val error: String? = null,
)

/**
 * Process-wide owner of the Dieter connection. The Activity observes this
 * state, while [DieterSyncService] keeps the same stream alive in background.
 */
class DieterConnectionManager(
    context: Context,
    val repository: DieterRepository,
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.IO),
) {
    private val appContext = context.applicationContext
    private val preferences = appContext.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
    private val syncStore = DieterSyncStore(appContext)
    private val lock = Any()
    private var configuredEndpoints = loadEndpoints().also(repository::replaceEndpoints)
    private var activeGatewayId = preferences.getString(KEY_ACTIVE_GATEWAY, null)
        ?.takeIf { saved -> configuredEndpoints.any { it.id == saved } }
        ?: configuredEndpoints.first().id
    private var cachedDirectory = syncStore.loadMachineDirectory(activeGatewayId)
    private var preferredEndpointId = preferences.getString(KEY_PREFERRED_ENDPOINT, null)
        ?: preferences.getString(KEY_PREFERRED_DAEMON, null)
    private var activeProjectionKey = preferredEndpointId.orEmpty()
    private var globalSnapshot = activeProjectionKey.takeIf(String::isNotBlank)?.let(syncStore::loadSnapshot)
    private var syncCursor = activeProjectionKey.takeIf(String::isNotBlank)?.let(syncStore::loadCursor).takeIf { globalSnapshot != null }
    private val outbox = syncStore.loadOutbox()
    private val conversationIdResolutions = linkedMapOf<String, String>().apply {
        outbox.forEach { entry ->
            if (entry.kind != OutboxKind.SEND_MESSAGE && entry.serverId != null) {
                put(entry.optimisticId, entry.serverId)
            }
        }
    }
    private var connectionJob: Job? = null
    private var generation = 0L

    @Volatile
    private var lastSyncFrameAtMs = 0L
    private var selectedProjectId = ""
    private var appForeground = false
    private var serviceActive = false
    private var discoveredEndpoints: List<DieterEndpoint> = emptyList()

    private val _state = MutableStateFlow(
        DieterConnectionState(
            desiredConnected = preferences.getBoolean(KEY_DESIRED_CONNECTED, true),
            backgroundSyncEnabled = preferences.getBoolean(KEY_BACKGROUND_SYNC, true),
            activeGatewayId = activeGatewayId,
            configuredConnections = configuredEndpointRows(),
            endpointConnections = configuredEndpointRows(),
            projects = cachedDirectory?.state?.projectsList.orEmpty(),
            projectHosts = cachedDirectory?.hosts.orEmpty().mapValues { (_, host) ->
                ProjectHost(host.endpointId, host.daemonId, host.hostname, online = false)
            },
            boards = cachedDirectory?.state?.boardsList.orEmpty(),
            cards = cachedDirectory?.state?.cardsList.orEmpty(),
            chats = cachedDirectory?.state?.chatsList.orEmpty(),
        ),
    )
    val state: StateFlow<DieterConnectionState> = _state.asStateFlow()

    init {
        if (_state.value.projects.isNotEmpty()) {
            synchronized(lock) { selectedProjectId = _state.value.projects.first().id }
            updateSelectedState()
        }
        globalSnapshot?.let(::applyGlobalSnapshot)
    }

    fun onAppForegrounded(projectId: String = selectedProjectId) {
        synchronized(lock) {
            appForeground = true
            if (projectId.isNotBlank()) selectedProjectId = projectId
        }
        if (_state.value.desiredConnected && _state.value.backgroundSyncEnabled) DieterSyncService.start(appContext)
        reconcile()
        probeStaleConnection()
    }

    /**
     * Doze can silently kill the transport underneath an "active" stream. When
     * the app comes back with a connection that claims to be healthy but has
     * not produced a sync frame in longer than the heartbeat interval, verify
     * it with a short health check and rebuild immediately on failure instead
     * of waiting for keepalive to notice.
     */
    private fun probeStaleConnection() {
        val probedGeneration = synchronized(lock) { generation }
        val lastFrame = lastSyncFrameAtMs
        val stale = lastFrame > 0 && System.currentTimeMillis() - lastFrame > STALE_SYNC_PROBE_MS
        if (!stale || _state.value.phase != ConnectionPhase.CONNECTED) return
        scope.launch {
            val healthy = runCatching { repository.health(timeoutSeconds = 2).status == "ok" }.getOrDefault(false)
            val current = synchronized(lock) { generation }
            if (!healthy && shouldRun() && current == probedGeneration) restart()
        }
    }

    fun onAppBackgrounded() {
        synchronized(lock) { appForeground = false }
        reconcile()
    }

    fun onServiceStarted() {
        synchronized(lock) { serviceActive = true }
        reconcile()
    }

    fun onServiceStopped() {
        synchronized(lock) { serviceActive = false }
        reconcile()
    }

    fun selectProject(projectId: String) {
        val nextEndpoint = endpointForProjectSelection(projectId, repository.activeEndpoint.id, _state.value.projectHosts)
        val endpointChanged = nextEndpoint != null
        val projectChanged = synchronized(lock) {
            if (selectedProjectId == projectId) false else {
                selectedProjectId = projectId
                true
            }
        }
        if (endpointChanged) {
            preferredEndpointId = nextEndpoint
            preferences.edit().putString(KEY_PREFERRED_ENDPOINT, preferredEndpointId).apply()
        }
        if (!endpointChanged) globalSnapshot?.let(::applyGlobalSnapshot)
        if (endpointChanged && shouldRun()) restart()
        else if (projectChanged) globalSnapshot?.let(::applyGlobalSnapshot)
    }

    suspend fun ensureProjectRoute(projectId: String) {
        if (projectId.isBlank()) return
        val target = _state.value.projectHosts[projectId] ?: return
        if (!target.online) error("${target.hostname} is offline. Start Dieter on that machine to continue.")
        if (repository.activeEndpoint.id == target.endpointId && _state.value.phase == ConnectionPhase.CONNECTED) return
        selectProject(projectId)
        withTimeout(20_000) {
            state.first { connection ->
                connection.phase == ConnectionPhase.CONNECTED && connection.endpoint?.id == target.endpointId
            }
        }
    }

    fun connect() {
        preferences.edit().putBoolean(KEY_DESIRED_CONNECTED, true).apply()
        _state.update { it.copy(desiredConnected = true, error = null) }
        if (_state.value.backgroundSyncEnabled) DieterSyncService.start(appContext)
        reconcile()
    }

    fun reconnect() {
        if (!_state.value.desiredConnected) return
        restart()
    }

    fun refreshProjectDirectory() {
        if (!shouldRun()) return
        scope.launch { refreshMachineDirectory() }
    }

    fun signIn() {
        val endpoint = activeGateway()
        if (!endpoint.secure) {
            _state.update { it.copy(error = "GitHub sign-in is available only for HTTPS connections.") }
            return
        }
        val verifierBytes = ByteArray(48).also(SecureRandom()::nextBytes)
        val verifier = Base64.encodeToString(verifierBytes, Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING)
        val challenge = Base64.encodeToString(MessageDigest.getInstance("SHA-256").digest(verifier.toByteArray()), Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING)
        preferences.edit().putString(KEY_AUTH_VERIFIER, verifier).putString(KEY_AUTH_ENDPOINT, endpoint.id).apply()
        val authorize = Uri.Builder().scheme("https").authority(if (endpoint.port == 443) endpoint.host else "${endpoint.host}:${endpoint.port}")
            .path("/auth/github/start")
            .appendQueryParameter("native_redirect_uri", "dieter-android://oauth/callback")
            .appendQueryParameter("native_code_challenge", challenge).build()
        appContext.startActivity(Intent(Intent.ACTION_VIEW, authorize).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }

    fun completeAuthentication(uri: Uri) {
        if (uri.scheme != "dieter-android" || uri.host != "oauth" || uri.path != "/callback") return
        val code = uri.getQueryParameter("code") ?: return
        val verifier = preferences.getString(KEY_AUTH_VERIFIER, null) ?: return
        val endpointID = preferences.getString(KEY_AUTH_ENDPOINT, null) ?: return
        val endpoint = synchronized(lock) { configuredEndpoints.firstOrNull { it.id == endpointID } } ?: return
        preferences.edit().remove(KEY_AUTH_VERIFIER).remove(KEY_AUTH_ENDPOINT).apply()
        scope.launch {
            try {
                val body = JSONObject().put("code", code).put("verifier", verifier).toString()
                val connection = URL("https://${endpoint.host}${if (endpoint.port == 443) "" else ":${endpoint.port}"}/auth/native/exchange").openConnection() as HttpURLConnection
                connection.requestMethod = "POST"; connection.setRequestProperty("Content-Type", "application/json"); connection.connectTimeout = 15_000; connection.readTimeout = 15_000; connection.doOutput = true
                connection.outputStream.use { it.write(body.toByteArray()) }
                if (connection.responseCode != 200) error("Dieter rejected the sign-in exchange (${connection.responseCode}).")
                val token = connection.inputStream.bufferedReader().use { JSONObject(it.readText()).getString("accessToken") }
                repository.replaceEndpoints(listOf(endpoint)); repository.selectEndpoint(endpoint); repository.setAccessToken(endpoint, token)
                _state.update { it.copy(endpoint = endpoint, phase = ConnectionPhase.CONNECTING, error = null) }
                restart()
            } catch (error: Throwable) {
                _state.update { it.copy(phase = ConnectionPhase.AUTH_REQUIRED, error = error.message ?: "Dieter sign-in failed") }
            }
        }
    }

    fun updateEndpoints(endpoints: List<DieterEndpoint>, selectedGatewayId: String? = null) {
        require(endpoints.isNotEmpty()) { "At least one Dieter connection is required" }
        require(endpoints.map { it.id }.distinct().size == endpoints.size) { "Connection IDs must be unique" }
        require(endpoints.map { it.address.lowercase() }.distinct().size == endpoints.size) { "Connection addresses must be unique" }
        require(endpoints.all { it.secure || isLoopbackHost(it.host) }) { "Remote gateways must use HTTPS" }
        val nextActive = selectedGatewayId?.takeIf { id -> endpoints.any { it.id == id } }
            ?: activeGatewayId.takeIf { id -> endpoints.any { it.id == id } }
            ?: endpoints.first().id
        val gatewayChanged = nextActive != activeGatewayId
        val nextDirectory = if (gatewayChanged) syncStore.loadMachineDirectory(nextActive) else cachedDirectory
        synchronized(lock) {
            configuredEndpoints = endpoints.toList()
            activeGatewayId = nextActive
            if (gatewayChanged) {
                preferredEndpointId = null
                discoveredEndpoints = emptyList()
                cachedDirectory = nextDirectory
                selectedProjectId = nextDirectory?.state?.projectsList?.firstOrNull()?.id.orEmpty()
            }
        }
        preferences.edit().putString(KEY_ACTIVE_GATEWAY, nextActive).also {
            if (gatewayChanged) it.remove(KEY_PREFERRED_ENDPOINT)
        }.apply()
        persistEndpoints(endpoints)
        repository.replaceEndpoints(listOf(endpoints.first { it.id == nextActive }))
        val rows = configuredEndpointRows()
        if (gatewayChanged) {
            activeProjectionKey = ""
            globalSnapshot = null
            syncCursor = null
        }
        _state.update {
            it.copy(
                activeGatewayId = nextActive,
                configuredConnections = rows,
                endpointConnections = rows,
                endpoint = if (gatewayChanged) endpoints.first { endpoint -> endpoint.id == nextActive } else it.endpoint,
                selectedState = if (gatewayChanged) nextDirectory?.state else it.selectedState,
                projects = if (gatewayChanged) nextDirectory?.state?.projectsList.orEmpty() else it.projects,
                projectHosts = if (gatewayChanged) nextDirectory?.hosts.orEmpty().mapValues { (_, host) ->
                    ProjectHost(host.endpointId, host.daemonId, host.hostname, online = false)
                } else it.projectHosts,
                boards = if (gatewayChanged) nextDirectory?.state?.boardsList.orEmpty() else it.boards,
                cards = if (gatewayChanged) nextDirectory?.state?.cardsList.orEmpty() else it.cards,
                chats = if (gatewayChanged) nextDirectory?.state?.chatsList.orEmpty() else it.chats,
                activeConversations = if (gatewayChanged) emptyMap() else it.activeConversations,
                schedules = if (gatewayChanged) emptyList() else it.schedules,
                scheduleRuns = if (gatewayChanged) emptyList() else it.scheduleRuns,
                error = null,
            )
        }
        if (gatewayChanged) updateSelectedState()
        if (_state.value.desiredConnected && shouldRun()) restart()
    }

    fun resetEndpoints() = updateEndpoints(DIETER_ENDPOINTS)

    fun selectGateway(id: String) {
        val gateway = synchronized(lock) { configuredEndpoints.firstOrNull { it.id == id } } ?: return
        if (gateway.id == activeGatewayId) return
        val nextDirectory = syncStore.loadMachineDirectory(gateway.id)
        synchronized(lock) {
            activeGatewayId = gateway.id
            preferredEndpointId = null
            discoveredEndpoints = emptyList()
            cachedDirectory = nextDirectory
            selectedProjectId = nextDirectory?.state?.projectsList?.firstOrNull()?.id.orEmpty()
        }
        preferences.edit()
            .putString(KEY_ACTIVE_GATEWAY, gateway.id)
            .remove(KEY_PREFERRED_ENDPOINT)
            .apply()
        activeProjectionKey = ""
        globalSnapshot = null
        syncCursor = null
        repository.replaceEndpoints(listOf(gateway))
        _state.update {
            it.copy(
                activeGatewayId = gateway.id,
                endpoint = gateway,
                endpointConnections = listOf(endpointRow(gateway)),
                selectedState = nextDirectory?.state,
                projects = nextDirectory?.state?.projectsList.orEmpty(),
                projectHosts = nextDirectory?.hosts.orEmpty().mapValues { (_, host) ->
                    ProjectHost(host.endpointId, host.daemonId, host.hostname, online = false)
                },
                boards = nextDirectory?.state?.boardsList.orEmpty(),
                cards = nextDirectory?.state?.cardsList.orEmpty(),
                chats = nextDirectory?.state?.chatsList.orEmpty(),
                activeConversations = emptyMap(),
                schedules = emptyList(),
                scheduleRuns = emptyList(),
                error = null,
            )
        }
        updateSelectedState()
        if (_state.value.desiredConnected && shouldRun()) restart()
    }

    fun disconnect(stopService: Boolean = true) {
        preferences.edit().putBoolean(KEY_DESIRED_CONNECTED, false).apply()
        synchronized(lock) {
            generation++
            connectionJob?.cancel()
            connectionJob = null
        }
        repository.reconnect()
        _state.update {
            it.copy(
                desiredConnected = false,
                phase = ConnectionPhase.STOPPED,
                connectionInterruptedAtMs = null,
                endpoint = null,
                endpointConnections = configuredEndpointRows(),
                activeConversations = emptyMap(),
                error = null,
            )
        }
        if (stopService) DieterSyncService.stop(appContext)
    }

    fun setBackgroundSyncEnabled(enabled: Boolean) {
        preferences.edit().putBoolean(KEY_BACKGROUND_SYNC, enabled).apply()
        _state.update { it.copy(backgroundSyncEnabled = enabled) }
        if (enabled && _state.value.desiredConnected) DieterSyncService.start(appContext)
        if (!enabled) DieterSyncService.stop(appContext)
        reconcile()
    }

    fun requestBatteryOptimizationExemption() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return
        val power = appContext.getSystemService(PowerManager::class.java)
        if (power.isIgnoringBatteryOptimizations(appContext.packageName)) return
        runCatching {
            appContext.startActivity(
                Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS)
                    .setData(Uri.parse("package:${appContext.packageName}"))
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            )
        }
    }

    private fun reconcile() {
        if (shouldRun()) ensureStarted() else pause()
    }

    private fun shouldRun(): Boolean = synchronized(lock) {
        _state.value.desiredConnected && (appForeground || serviceActive)
    }

    private fun ensureStarted() {
        synchronized(lock) {
            if (connectionJob?.isActive == true) return
            val currentGeneration = ++generation
            connectionJob = scope.launch { connectionLoop(currentGeneration) }
        }
    }

    private fun restart() {
        synchronized(lock) {
            generation++
            connectionJob?.cancel()
            connectionJob = null
        }
        repository.reconnect()
        _state.update {
            it.copy(
                phase = ConnectionPhase.CONNECTING,
                connectionInterruptedAtMs = it.connectionInterruptedAtMs ?: System.currentTimeMillis(),
                endpointConnections = configuredEndpointRows(),
                error = null,
            )
        }
        if (shouldRun()) ensureStarted()
    }

    private fun pause() {
        synchronized(lock) {
            generation++
            connectionJob?.cancel()
            connectionJob = null
        }
        repository.reconnect()
        if (_state.value.desiredConnected) {
            _state.update {
                it.copy(
                    phase = ConnectionPhase.STOPPED,
                    connectionInterruptedAtMs = null,
                    endpoint = null,
                    endpointConnections = configuredEndpointRows(),
                )
            }
        }
    }

    private suspend fun connectionLoop(currentGeneration: Long) {
        var retryAttempt = 0
        while (shouldRun() && currentGeneration == synchronized(lock) { generation }) {
            try {
                _state.update {
                    it.copy(
                        phase = if (retryAttempt == 0) ConnectionPhase.CONNECTING else ConnectionPhase.RECONNECTING,
                        connectionInterruptedAtMs = it.connectionInterruptedAtMs ?: System.currentTimeMillis(),
                        endpointConnections = configuredEndpointRows(),
                        error = null,
                    )
                }
                val health = connectToGateway(currentGeneration)
                if (health.status != "ok" || health.version != DIETER_API_VERSION) {
                    _state.update {
                        it.copy(
                            phase = ConnectionPhase.INCOMPATIBLE,
                            error = "Dieter API ${health.version.ifBlank { "unknown" }} is incompatible; Android requires $DIETER_API_VERSION.",
                        )
                    }
                    return
                }
                val (runtime, catalog) = coroutineScope {
                    val runtime = async { repository.runtimeStatus() }
                    val catalog = async { repository.harnesses() }
                    runtime.await() to catalog.await()
                }
                _state.update {
                    it.copy(
                        phase = ConnectionPhase.SYNCING,
                        runtimeStatus = runtime,
                        harnesses = catalog.harnessesList,
                        error = null,
                    )
                }
                refreshMachineDirectory()
                retryAttempt = 0
                coroutineScope {
                    launch { collectGlobalSync(currentGeneration) }
                    launch { drainOutbox(currentGeneration) }
                    launch { watchDaemonPresence(currentGeneration) }
                    launch { maintainMachineDirectory(currentGeneration) }
                    launch {
                        val refreshAt = repository.directRefreshAtMillis() ?: return@launch awaitCancellation()
                        delay((refreshAt - System.currentTimeMillis()).coerceAtLeast(1_000))
                        throw DirectCredentialRefresh()
                    }
                    awaitCancellation()
                }
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Throwable) {
                if (!shouldRun() || currentGeneration != synchronized(lock) { generation }) return
                if (error is DirectCredentialRefresh) {
                    retryAttempt = 0
                    continue
                }
                if (Status.fromThrowable(error).code == Status.Code.UNAUTHENTICATED) {
                    _state.update { it.copy(phase = ConnectionPhase.AUTH_REQUIRED, error = "Sign in with GitHub to use ${repository.activeEndpoint.label}.") }
                    return
                }
                val transient = Status.fromThrowable(error).code in setOf(
                    Status.Code.UNAVAILABLE,
                    Status.Code.DEADLINE_EXCEEDED,
                    Status.Code.UNKNOWN,
                )
                _state.update {
                    it.copy(
                        phase = if (transient) ConnectionPhase.RECONNECTING else ConnectionPhase.UNAVAILABLE,
                        connectionInterruptedAtMs = it.connectionInterruptedAtMs ?: System.currentTimeMillis(),
                        error = readableError(error),
                    )
                }
                delay((750L shl retryAttempt.coerceAtMost(4)).coerceAtMost(10_000L))
                retryAttempt++
            }
        }
    }

    private suspend fun connectToGateway(currentGeneration: Long): com.dbpprt.dieter.v1.HealthResponse {
        val origin = activeGateway()
        repository.replaceEndpoints(listOf(origin))
        repository.selectEndpoint(origin)
        updateEndpoint(origin, EndpointPhase.TRYING, "Finding machines", null)
        val directory = repository.daemons()
        val discovered = directory.daemonsList.map { daemon ->
            DieterEndpoint(
                id = "${origin.credentialId}#${daemon.id}",
                label = daemon.name.ifBlank { daemon.id },
                host = origin.host,
                port = origin.port,
                secure = origin.secure,
                daemonId = daemon.id,
                online = daemon.online,
                lastSeenAt = daemon.lastSeenAt,
                version = daemon.version,
            )
        }.sortedWith(
            compareBy<DieterEndpoint> { !it.online }
                .thenBy { if (it.id == preferredEndpointId || it.daemonId == preferredEndpointId) 0 else 1 }
                .thenBy { it.label.lowercase() },
        )
        if (discovered.isEmpty()) throw IllegalStateException("No Dieter machines are enrolled for this gateway")
        discoveredEndpoints = discovered.toList()
        repository.replaceEndpoints(discovered)
        _state.update {
            val availability = discovered.associate { endpoint -> endpoint.id to endpoint.online }
            it.copy(
                endpointConnections = discovered.map(::endpointRow),
                projectHosts = it.projectHosts.mapValues { (_, host) ->
                    host.copy(online = availability[host.endpointId] ?: false)
                },
            )
        }
        for (endpoint in discovered.filter(DieterEndpoint::online)) {
            if (!shouldRun() || currentGeneration != synchronized(lock) { generation }) {
                throw CancellationException("Connection superseded")
            }
            repository.selectEndpoint(endpoint)
            updateEndpoint(endpoint, EndpointPhase.TRYING, "Trying", null)
            val started = TimeSource.Monotonic.markNow()
            try {
                val path = repository.prepareDaemon()
                val health = repository.health(timeoutSeconds = 3)
                val latency = started.elapsedNow().inWholeMilliseconds.coerceAtLeast(1)
                updateEndpoint(endpoint, EndpointPhase.CONNECTED, "$path · ${latency} ms", latency)
                _state.update {
                    it.copy(
                        endpoint = endpoint,
                        phase = ConnectionPhase.SYNCING,
                    )
                }
                activateProjection(endpoint)
                return health
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Throwable) {
                updateEndpoint(endpoint, EndpointPhase.FAILED, endpointFailure(error), null)
                repository.reconnect()
                if (Status.fromThrowable(error).code == Status.Code.UNAUTHENTICATED) {
                    _state.update { it.copy(endpoint = endpoint) }
                    throw error
                }
            }
        }
        throw IllegalStateException("No Dieter connection target is available")
    }

    private suspend fun collectGlobalSync(currentGeneration: Long) {
        repository.watchSync(
            syncCursor,
            conversationLimit = SYNC_CONVERSATION_MESSAGES,
            recentConversationLimit = SYNC_RECENT_CONVERSATIONS,
        ).collect { frame ->
            if (currentGeneration != synchronized(lock) { generation }) return@collect
            lastSyncFrameAtMs = System.currentTimeMillis()
            DieterWidgetPrefs.recordSyncFrame(appContext, lastSyncFrameAtMs)
            var projectionChanged = false
            if (frame.hasSnapshot()) {
                globalSnapshot = frame.snapshot
                projectionChanged = true
            } else if (frame.hasDelta() && globalSnapshot != null) {
                globalSnapshot = applyGlobalDelta(requireNotNull(globalSnapshot), frame.delta)
                projectionChanged = true
            }
            if (frame.hasCursor()) {
                syncCursor = frame.cursor
            }
            if (activeProjectionKey.isNotBlank() && (projectionChanged || frame.hasCursor() && !frame.heartbeat)) {
                syncStore.saveProjection(
                    activeProjectionKey,
                    globalSnapshot.takeIf { projectionChanged },
                    frame.cursor.takeIf { frame.hasCursor() },
                )
            }
            globalSnapshot?.let {
                reconcileOutbox(it)
                applyGlobalSnapshot(it)
            }
            _state.update { it.copy(phase = ConnectionPhase.CONNECTED, connectionInterruptedAtMs = null, error = null) }
        }
    }

    private suspend fun watchDaemonPresence(currentGeneration: Long) {
        var attempt = 0
        while (currentCoroutineContext().isActive && currentGeneration == synchronized(lock) { generation }) {
            try {
                repository.watchDaemons().collect { update ->
                    if (currentGeneration != synchronized(lock) { generation }) return@collect
                    attempt = 0
                    applyDaemonPresence(update.daemonsList)
                }
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Throwable) {
                // Presence is advisory. Losing the gateway stream must not tear
                // down an otherwise healthy direct daemon connection.
                delay((750L shl attempt.coerceAtMost(4)).coerceAtMost(10_000L))
                attempt++
            }
        }
    }

    private suspend fun maintainMachineDirectory(currentGeneration: Long) {
        while (currentCoroutineContext().isActive && currentGeneration == synchronized(lock) { generation }) {
            delay(MACHINE_DIRECTORY_REFRESH_MS)
            runCatching { refreshMachineDirectory() }
        }
    }

    private fun activateProjection(endpoint: DieterEndpoint) {
        if (activeProjectionKey != endpoint.id) {
            activeProjectionKey = endpoint.id
            preferredEndpointId = endpoint.id
            preferences.edit().putString(KEY_PREFERRED_ENDPOINT, endpoint.id).apply()
            globalSnapshot = syncStore.loadSnapshot(endpoint.id)
                ?: endpoint.daemonId?.let(syncStore::loadSnapshot)
            syncCursor = (syncStore.loadCursor(endpoint.id)
                ?: endpoint.daemonId?.let(syncStore::loadCursor)).takeIf { globalSnapshot != null }
        }
        val cached = globalSnapshot
        if (cached != null) {
            applyGlobalSnapshot(cached)
        } else {
            updateSelectedState()
        }
    }

    private fun applyDaemonPresence(daemons: List<com.dbpprt.dieter.gateway.v1.Daemon>) {
        val byID = daemons.associateBy { it.id }
        discoveredEndpoints = discoveredEndpoints.map { endpoint ->
            val daemon = endpoint.daemonId?.let(byID::get) ?: return@map endpoint
            endpoint.copy(
                label = daemon.name.ifBlank { daemon.id },
                online = daemon.online,
                lastSeenAt = daemon.lastSeenAt,
                version = daemon.version,
            )
        }
        _state.update { current ->
            val availability = discoveredEndpoints.associate { it.id to it.online }
            current.copy(
                endpointConnections = current.endpointConnections.map { row ->
                    val endpoint = discoveredEndpoints.firstOrNull { it.id == row.id } ?: return@map row
                    when {
                        endpoint.online && endpoint.id == current.endpoint?.id && current.phase in setOf(ConnectionPhase.SYNCING, ConnectionPhase.CONNECTED) -> row.copy(
                            label = endpoint.label,
                            online = endpoint.online,
                        )
                        else -> endpointRow(endpoint)
                    }
                },
                projectHosts = current.projectHosts.mapValues { (_, host) ->
                    host.copy(online = availability[host.endpointId] ?: false)
                },
            )
        }
    }

    suspend fun refreshMachineDirectory(includeArchivedChats: Boolean = false) {
        val machines = discoveredEndpoints.filter(DieterEndpoint::online)
        if (machines.isEmpty()) return
        // Directory refresh is intentionally sequential. Each lookup is a
        // short relay RPC; bounding it to one at a time prevents a large
        // account from consuming every logical stream on a daemon link.
        val snapshots = buildList {
            for (machine in machines) {
                val snapshot = runCatching {
                    val root = repository.relayState(machine)
                    val projects = root.projectsList.filterNot(Project::getArchived)
                    val projectStates = buildList {
                        for (project in projects) {
                            add(repository.relayState(machine, GetStateRequest.newBuilder().setProjectId(project.id).setLimit(500).build()))
                        }
                    }
                    val chats = repository.relayChats(machine, includeArchived = includeArchivedChats).chatsList
                        .filter { includeArchivedChats || !it.archived }
                    MachineSnapshot(machine, projects, projectStates.flatMap { it.boardsList }, projectStates.flatMap { it.cardsList }, chats)
                }.getOrNull()
                if (snapshot != null) add(snapshot)
            }
        }
        if (snapshots.isEmpty()) return
        val refreshedEndpointIDs = snapshots.mapTo(hashSetOf()) { it.endpoint.id }
        _state.update { current ->
            val retainedProjects = current.projects.filter { current.projectHosts[it.id]?.endpointId !in refreshedEndpointIDs }
            val retainedProjectIDs = retainedProjects.mapTo(hashSetOf()) { it.id }
            val projects = (retainedProjects + snapshots.flatMap { it.projects }).distinctBy { it.id }
                .sortedBy { it.name.lowercase() }
            val hosts = current.projectHosts.filterKeys { it in retainedProjectIDs }.toMutableMap()
            snapshots.forEach { snapshot ->
                snapshot.projects.forEach { project ->
                    hosts[project.id] = ProjectHost(
                        endpointId = snapshot.endpoint.id,
                        daemonId = requireNotNull(snapshot.endpoint.daemonId),
                        hostname = snapshot.endpoint.label,
                        online = snapshot.endpoint.online,
                    )
                }
            }
            val combined = current.copy(
                projects = projects,
                projectHosts = hosts,
                boards = (current.boards.filter { it.projectId in retainedProjectIDs } + snapshots.flatMap { it.boards }).distinctBy { it.id },
                cards = (current.cards.filter { it.projectId in retainedProjectIDs } + snapshots.flatMap { it.cards }).distinctBy { it.id },
                chats = (current.chats.filter { it.projectId in retainedProjectIDs } + snapshots.flatMap { it.chats }).distinctBy { it.id },
                error = null,
            )
            combined.copy(selectedState = selectedState(combined))
        }
        persistMachineDirectory()
    }

    private fun persistMachineDirectory() {
        val current = _state.value
        val directoryState = State.newBuilder()
            .addAllProjects(current.projects)
            .addAllBoards(current.boards)
            .addAllCards(current.cards)
            .addAllChats(current.chats)
            .build()
        val hosts = current.projectHosts.mapValues { (_, host) ->
            CachedProjectHost(host.endpointId, host.daemonId, host.hostname)
        }
        syncStore.saveMachineDirectory(activeGatewayId, directoryState, hosts)
        cachedDirectory = syncStore.loadMachineDirectory(activeGatewayId)
    }

    private fun applyGlobalDelta(snapshot: GlobalSnapshot, delta: GlobalDelta): GlobalSnapshot {
        fun <T> merge(current: List<T>, changed: List<T>, removed: Set<String>, id: (T) -> String): List<T> {
            val changedByID = changed.associateBy(id)
            return (current.filter { id(it) !in removed && id(it) !in changedByID } + changed)
        }
        val state = snapshot.state.toBuilder()
            .clearProjects()
            .addAllProjects(merge(snapshot.state.projectsList, delta.projectsList, delta.removedProjectIdsList.toSet(), Project::getId))
            .clearBoards()
            .addAllBoards(merge(snapshot.state.boardsList, delta.boardsList, delta.removedBoardIdsList.toSet(), Board::getId))
            .clearCards()
            .addAllCards(merge(snapshot.state.cardsList, delta.cardsList, delta.removedCardIdsList.toSet(), Card::getId))
            .clearChats()
            .addAllChats(merge(snapshot.state.chatsList, delta.chatsList, delta.removedChatIdsList.toSet(), Card::getId))
            .build()
        return snapshot.toBuilder()
            .setState(state)
            .clearSchedules()
            .addAllSchedules(merge(snapshot.schedulesList, delta.schedulesList, delta.removedScheduleIdsList.toSet(), Schedule::getId))
            .clearScheduleRuns()
            .addAllScheduleRuns(merge(snapshot.scheduleRunsList, delta.scheduleRunsList, delta.removedScheduleRunIdsList.toSet(), ScheduleRun::getId))
            .clearConversations()
            .addAllConversations(
                merge(snapshot.conversationsList, delta.conversationsList, delta.removedConversationIdsList.toSet()) { it.detail.card.id },
            )
            .also { if (delta.hasSettings()) it.settings = delta.settings }
            .build()
    }

    private fun applyGlobalSnapshot(snapshot: GlobalSnapshot) {
        _state.update { current ->
            // Read the outbox inside StateFlow's CAS update. The lambda may be
            // retried after a foreground conversation frame reconciles a send;
            // an earlier captured list would then restore the stale pending
            // presentation until another global frame arrives.
            val (entries, resolvedConversationIds) = synchronized(outbox) {
                outbox.toList() to conversationIdResolutions.toMap()
            }
            val activeEndpoint = current.endpoint
            val activeEndpointId = activeEndpoint?.id ?: activeProjectionKey
            val replacedProjectIds = current.projectHosts
                .filterValues { it.endpointId == activeEndpointId }
                .keys
            val incomingProjects = snapshot.state.projectsList
            val incomingProjectIds = incomingProjects.mapTo(hashSetOf()) { it.id }
            val retainedProjects = current.projects.filter { it.id !in replacedProjectIds && it.id !in incomingProjectIds }
            val projects = (retainedProjects + incomingProjects).distinctBy { it.id }.sortedBy { it.name.lowercase() }
            val retainedProjectIds = retainedProjects.mapTo(hashSetOf()) { it.id }
            val boards = (current.boards.filter { it.projectId in retainedProjectIds } + snapshot.state.boardsList)
                .distinctBy { it.id }
            val cards = (current.cards.filter { it.projectId in retainedProjectIds } + snapshot.state.cardsList)
                .distinctBy { it.id }
                .toMutableList()
            val chats = (current.chats.filter { it.projectId in retainedProjectIds } + snapshot.state.chatsList)
                .distinctBy { it.id }
                .toMutableList()
            val hosts = current.projectHosts
                .filterKeys { it !in replacedProjectIds && it !in incomingProjectIds }
                .toMutableMap()
            if (activeEndpoint?.daemonId != null) {
                incomingProjects.forEach { project ->
                    hosts[project.id] = ProjectHost(
                        endpointId = activeEndpoint.id,
                        daemonId = activeEndpoint.daemonId,
                        hostname = activeEndpoint.label,
                        online = activeEndpoint.online,
                    )
                }
            }

            val knownCards = (cards + chats).associateBy { it.id }
            val conversations = current.activeConversations.toMutableMap().apply {
                resolvedConversationIds.forEach { (localId, serverId) ->
                    val local = remove(localId) ?: return@forEach
                    val migrated = retargetConversation(local, knownCards[serverId], serverId)
                    put(serverId, freshestConversation(get(serverId), migrated))
                }
                snapshot.conversationsList.forEach { incoming ->
                    val id = incoming.detail.card.id
                    put(id, freshestConversation(get(id), incoming))
                }
                // Evict stale entries the stream no longer covers, but never
                // the ones it is actively keeping warm.
                val synced = snapshot.conversationsList.mapTo(hashSetOf()) { it.detail.card.id }
                val iterator = keys.iterator()
                while (size > MAX_ACTIVE_CONVERSATIONS && iterator.hasNext()) {
                    if (iterator.next() !in synced) iterator.remove()
                }
            }
            entries.forEach { entry ->
                when (entry.kind) {
                    OutboxKind.CREATE_CARD, OutboxKind.CREATE_CHAT -> {
                        val request = runCatching { CreateConversationRequest.parseFrom(entry.request) }.getOrNull() ?: return@forEach
                        val conversationId = optimisticConversationId(entry)
                        val card = knownCards[conversationId] ?: Card.newBuilder()
                            .setId(conversationId)
                            .setScope(if (entry.kind == OutboxKind.CREATE_CHAT) "chat" else "board")
                            .setProjectId(request.projectId)
                            .setBoardId(if (entry.kind == OutboxKind.CREATE_CHAT) "" else request.boardId)
                            .setLane(request.lane)
                            .setTitle(request.title)
                            .setInitialPrompt(request.prompt)
                            .setProvider(request.provider)
                            .setModel(request.model)
                            .setEffort(request.effort)
                            .setRuntime("pending")
                            .setCreatedAt(java.time.Instant.ofEpochMilli(entry.createdAtMillis).toString())
                            .setUpdatedAt(java.time.Instant.ofEpochMilli(entry.createdAtMillis).toString())
                            .build()
                        if (entry.kind == OutboxKind.CREATE_CHAT) {
                            if (chats.none { it.id == card.id }) chats.add(0, card)
                        } else if (cards.none { it.id == card.id }) {
                            cards += card
                        }
                        if (conversations[conversationId] == null) {
                            val detail = com.dbpprt.dieter.v1.CardDetail.newBuilder()
                                .setCard(card)
                                .also { builder -> projects.firstOrNull { it.id == card.projectId }?.let(builder::setProject) }
                                .also { builder -> boards.firstOrNull { it.id == card.boardId }?.let(builder::setBoard) }
                                .build()
                            val conversationBuilder = com.dbpprt.dieter.v1.Conversation.newBuilder()
                                .setCardId(conversationId)
                                .setStatus("pending")
                            if (entry.kind != OutboxKind.CREATE_CHAT || request.deferStart) {
                                conversationBuilder.addAllDraftAttachments(request.attachmentsList)
                            }
                            if (entry.kind == OutboxKind.CREATE_CHAT) {
                                optimisticChatMessage(request, "${entry.optimisticId}_initial")
                                    ?.let(conversationBuilder::addMessages)
                            }
                            conversations[conversationId] = ConversationSnapshot.newBuilder()
                                .setDetail(detail)
                                .setConversation(conversationBuilder.build())
                                .build()
                        }
                    }
                    OutboxKind.SEND_MESSAGE -> {
                        val request = runCatching { SendMessageRequest.parseFrom(entry.request) }.getOrNull() ?: return@forEach
                        val conversation = conversations[request.cardId] ?: return@forEach
                        if (conversation.conversation.messagesList.none { it.id == entry.optimisticId }) {
                            val message = com.dbpprt.dieter.v1.UiMessage.newBuilder()
                                .setId(entry.optimisticId)
                                .setRole("user")
                                .addAllParts(request.partsList)
                                .build()
                            conversations[request.cardId] = conversation.toBuilder()
                                .setConversation(conversation.conversation.toBuilder().addMessages(message))
                                .build()
                        }
                    }
                }
            }
            conversations.replaceAll { _, conversation -> overlayOptimisticMessages(conversation, entries) }

            val retainedSchedules = current.schedules.filter { it.projectId in retainedProjectIds }
            val schedules = (retainedSchedules + snapshot.schedulesList).distinctBy { it.id }
            val retainedScheduleIds = retainedSchedules.mapTo(hashSetOf()) { it.id }
            val scheduleRuns = (current.scheduleRuns.filter { it.scheduleId in retainedScheduleIds } + snapshot.scheduleRunsList)
                .distinctBy { it.id }
            val selectedProject = synchronized(lock) { selectedProjectId }
                .takeIf { id -> projects.any { it.id == id } }
                ?: projects.firstOrNull()?.id.orEmpty()
            synchronized(lock) { selectedProjectId = selectedProject }
            val combined = current.copy(
                projects = projects,
                projectHosts = hosts,
                boards = boards,
                cards = cards,
                chats = chats.sortedByDescending { it.lastActivityAt.ifBlank { it.updatedAt } },
                activeConversations = conversations,
                schedules = schedules,
                scheduleRuns = scheduleRuns,
                pendingCardIds = pendingCardIds(entries),
                pendingMessageIds = pendingMessageIds(entries),
                acceptedOutboxIds = acceptedOutboxIds(entries),
                failedOutboxIds = failedOutboxIds(entries),
                resolvedConversationIds = resolvedConversationIds,
            )
            combined.copy(selectedState = selectedState(combined, snapshot.state))
        }
    }

    private fun updateSelectedState() {
        _state.update { current -> current.copy(selectedState = selectedState(current)) }
    }

    private fun selectedState(connection: DieterConnectionState, base: State = connection.selectedState ?: State.getDefaultInstance()): State? {
        val selectedProject = synchronized(lock) { selectedProjectId }
            .takeIf { id -> connection.projects.any { it.id == id } }
            ?: connection.projects.firstOrNull()?.id
            ?: return null
        return base.toBuilder()
            .clearProjects()
            .addAllProjects(connection.projects)
            .clearBoards()
            .addAllBoards(connection.boards.filter { it.projectId == selectedProject })
            .clearCards()
            .addAllCards(connection.cards.filter { it.projectId == selectedProject })
            .clearChats()
            .addAllChats(connection.chats.filter { it.projectId == selectedProject })
            .setProject(connection.projects.first { it.id == selectedProject })
            .build()
    }

    private fun reconcileOutbox(snapshot: GlobalSnapshot): Boolean {
        val cardIds = (snapshot.state.cardsList + snapshot.state.chatsList).mapTo(hashSetOf()) { it.id }
        return reconcileOutbox(cardIds, snapshot.conversationsList)
    }

    private fun reconcileOutbox(snapshot: ConversationSnapshot): Boolean {
        val cardId = snapshot.detail.card.id.ifBlank { snapshot.conversation.cardId }
        return reconcileOutbox(setOf(cardId).filter(String::isNotBlank).toSet(), listOf(snapshot))
    }

    private fun reconcileOutbox(
        cardIds: Set<String>,
        conversations: List<ConversationSnapshot>,
    ): Boolean {
        val changed = synchronized(outbox) {
            outbox.removeAll { entry -> outboxEntryIsSynced(entry, cardIds, conversations) }
        }
        if (changed) syncStore.saveOutbox(synchronized(outbox) { outbox.toList() })
        return changed
    }

    suspend fun startCard(cardId: String): StartCardResponse {
        val projectId = (_state.value.cards + _state.value.chats)
            .firstOrNull { it.id == cardId }
            ?.projectId
            .orEmpty()
        ensureProjectRoute(projectId)
        val response = repository.startCard(
            StartCardRequest.newBuilder()
                .setCardId(cardId)
                .setClientId(syncStore.clientId)
                .setCommandId(UUID.randomUUID().toString().lowercase())
                .build(),
        )
        acceptStartedCard(response.card)
        return response
    }

    private fun acceptStartedCard(card: Card) {
        fun replace(cards: List<Card>): List<Card> =
            if (cards.any { it.id == card.id }) cards.map { if (it.id == card.id) card else it }
            else cards + card

        globalSnapshot = globalSnapshot?.let { snapshot ->
            snapshot.toBuilder()
                .setState(
                    snapshot.state.toBuilder()
                        .clearCards()
                        .addAllCards(replace(snapshot.state.cardsList)),
                )
                .build()
        }
        _state.update { current ->
            val combined = current.copy(cards = replace(current.cards))
            combined.copy(selectedState = selectedState(combined))
        }
        persistMachineDirectory()
    }

    fun acceptConversation(snapshot: ConversationSnapshot): ConversationSnapshot {
        val cardId = snapshot.detail.card.id
        if (cardId.isBlank()) return snapshot
        reconcileOutbox(snapshot)
        var accepted = snapshot
        _state.update { current ->
            // Keep delivery presentation tied to the outbox state used for
            // this exact CAS attempt; a concurrent global reconciliation must
            // not be overwritten by an older pending snapshot.
            val entries = synchronized(outbox) { outbox.toList() }
            val conversations = LinkedHashMap(current.activeConversations)
            accepted = overlayOptimisticMessages(freshestConversation(conversations[cardId], snapshot), entries)
            conversations[cardId] = accepted
            while (conversations.size > MAX_ACTIVE_CONVERSATIONS && conversations.keys.first() != cardId) {
                conversations.remove(conversations.keys.first())
            }
            current.copy(
                activeConversations = conversations,
                pendingCardIds = pendingCardIds(entries),
                pendingMessageIds = pendingMessageIds(entries),
                acceptedOutboxIds = acceptedOutboxIds(entries),
                failedOutboxIds = failedOutboxIds(entries),
            )
        }
        return accepted
    }

    private fun retargetConversation(snapshot: ConversationSnapshot, card: Card?, cardId: String): ConversationSnapshot {
        val targetCard = card ?: snapshot.detail.card.toBuilder().setId(cardId).build()
        return snapshot.toBuilder()
            .setDetail(snapshot.detail.toBuilder().setCard(targetCard))
            .setConversation(snapshot.conversation.toBuilder().setCardId(cardId))
            .build()
    }

    private fun pendingCardIds(entries: List<AndroidOutboxEntry>): Set<String> = buildSet {
        entries.filter { it.kind != OutboxKind.SEND_MESSAGE }.forEach { entry ->
            add(entry.optimisticId)
            entry.serverId?.let(::add)
        }
    }

    private fun pendingMessageIds(entries: List<AndroidOutboxEntry>): Set<String> = buildSet {
        entries.forEach { entry ->
            when (entry.kind) {
                OutboxKind.SEND_MESSAGE -> add(entry.optimisticId)
                OutboxKind.CREATE_CHAT -> optimisticInitialMessageId(entry)?.let(::add)
                OutboxKind.CREATE_CARD -> Unit
            }
        }
    }

    private fun acceptedOutboxIds(entries: List<AndroidOutboxEntry>): Set<String> = buildSet {
        entries.filter { it.serverId != null }.forEach { entry -> addAll(outboxPresentationIds(entry)) }
    }

    private fun failedOutboxIds(entries: List<AndroidOutboxEntry>): Set<String> = buildSet {
        entries.filter { it.lastError != null }.forEach { entry -> addAll(outboxPresentationIds(entry)) }
    }

    private fun outboxPresentationIds(entry: AndroidOutboxEntry): Set<String> = buildSet {
        add(entry.optimisticId)
        entry.serverId?.let(::add)
        optimisticInitialMessageId(entry)?.let(::add)
    }

    suspend fun enqueueConversation(request: CreateConversationRequest, chat: Boolean): Card {
        ensureProjectRoute(request.projectId)
        val commandId = UUID.randomUUID().toString().lowercase()
        val stable = request.toBuilder().setClientId(syncStore.clientId).setCommandId(commandId).build()
        val optimisticId = "local_${UUID.randomUUID().toString().replace("-", "").lowercase()}"
        val targetEndpoint = _state.value.projectHosts[stable.projectId]?.endpointId
            ?: repository.activeEndpoint.id
        synchronized(outbox) {
            outbox += AndroidOutboxEntry(
                commandId = commandId,
                clientId = syncStore.clientId,
                endpointId = targetEndpoint,
                kind = if (chat) OutboxKind.CREATE_CHAT else OutboxKind.CREATE_CARD,
                request = stable.toByteArray(),
                optimisticId = optimisticId,
            )
            syncStore.saveOutbox(outbox)
        }
        globalSnapshot?.let(::applyGlobalSnapshot)
        val resolvedId = synchronized(outbox) { conversationIdResolutions[optimisticId] }
        return _state.value.let { state ->
            (if (chat) state.chats else state.cards).first { card ->
                card.id == resolvedId || card.id == optimisticId
            }
        }
    }

    suspend fun enqueueMessage(
        cardId: String,
        parts: List<MessagePart>,
        provider: String,
        model: String,
        effort: String,
    ): String {
        val projectId = (_state.value.cards + _state.value.chats)
            .firstOrNull { it.id == cardId }
            ?.projectId
            .orEmpty()
        ensureProjectRoute(projectId)
        val commandId = UUID.randomUUID().toString().lowercase()
        val messageId = "msg_${UUID.randomUUID().toString().replace("-", "").lowercase()}"
        val request = SendMessageRequest.newBuilder()
            .setCardId(cardId)
            .addAllParts(parts)
            .setProvider(provider)
            .setModel(model)
            .setEffort(effort)
            .setClientId(syncStore.clientId)
            .setCommandId(commandId)
            .setMessageId(messageId)
            .build()
        val targetEndpoint = _state.value.cards.firstOrNull { it.id == cardId }?.projectId
            ?.let(_state.value.projectHosts::get)
            ?.endpointId
            ?: repository.activeEndpoint.id
        synchronized(outbox) {
            outbox += AndroidOutboxEntry(
                commandId = commandId,
                clientId = syncStore.clientId,
                endpointId = targetEndpoint,
                kind = OutboxKind.SEND_MESSAGE,
                request = request.toByteArray(),
                optimisticId = messageId,
            )
            syncStore.saveOutbox(outbox)
        }
        globalSnapshot?.let(::applyGlobalSnapshot)
        return messageId
    }

    private suspend fun drainOutbox(currentGeneration: Long) {
        while (currentCoroutineContext().isActive && currentGeneration == synchronized(lock) { generation }) {
            val activeEndpoint = repository.activeEndpoint.id
            val entry = synchronized(outbox) { outbox.firstOrNull { it.endpointId == activeEndpoint && it.serverId == null } }
            if (entry == null) {
                delay(500)
                continue
            }
            try {
                val serverId = when (entry.kind) {
                    OutboxKind.CREATE_CARD -> repository.createConversation(CreateConversationRequest.parseFrom(entry.request), false).id
                    OutboxKind.CREATE_CHAT -> repository.createConversation(CreateConversationRequest.parseFrom(entry.request), true).id
                    OutboxKind.SEND_MESSAGE -> repository.sendMessage(SendMessageRequest.parseFrom(entry.request)).messageId
                        .ifBlank { entry.optimisticId }
                }
                synchronized(outbox) {
                    val index = outbox.indexOfFirst { it.commandId == entry.commandId }
                    if (index >= 0) outbox[index] = entry.copy(serverId = serverId, lastError = null)
                    if (entry.kind != OutboxKind.SEND_MESSAGE) {
                        conversationIdResolutions[entry.optimisticId] = serverId
                        while (conversationIdResolutions.size > MAX_RESOLVED_CONVERSATIONS) {
                            conversationIdResolutions.remove(conversationIdResolutions.keys.first())
                        }
                    }
                    syncStore.saveOutbox(outbox)
                }
                globalSnapshot?.let {
                    reconcileOutbox(it)
                    applyGlobalSnapshot(it)
                }
            } catch (error: Throwable) {
                synchronized(outbox) {
                    val index = outbox.indexOfFirst { it.commandId == entry.commandId }
                    if (index >= 0) outbox[index] = entry.copy(attempts = entry.attempts + 1, lastError = readableError(error))
                    syncStore.saveOutbox(outbox)
                }
                globalSnapshot?.let(::applyGlobalSnapshot)
                delay((750L shl entry.attempts.coerceAtMost(4)).coerceAtMost(15_000L))
            }
        }
    }

    private fun updateEndpoint(endpoint: DieterEndpoint, phase: EndpointPhase, detail: String, latencyMs: Long?) {
        _state.update { current ->
            current.copy(
                endpointConnections = current.endpointConnections.map {
                    if (it.id == endpoint.id) it.copy(phase = phase, detail = detail, latencyMs = latencyMs) else it
                },
            )
        }
    }

    private fun configuredEndpointRows(): List<EndpointConnection> = synchronized(lock) { configuredEndpoints.toList() }.map {
        EndpointConnection(it.id, it.label, it.address, detail = if (it.id == activeGatewayId) "Active gateway" else "Separate deployment")
    }

    private fun activeGateway(): DieterEndpoint = synchronized(lock) {
        configuredEndpoints.firstOrNull { it.id == activeGatewayId } ?: configuredEndpoints.first()
    }

    private fun endpointRow(endpoint: DieterEndpoint): EndpointConnection = EndpointConnection(
        id = endpoint.id,
        label = endpoint.label,
        address = endpoint.address,
        phase = if (endpoint.online) EndpointPhase.PENDING else EndpointPhase.FAILED,
        detail = if (endpoint.online) "Available" else "Offline",
        online = endpoint.online,
        daemonId = endpoint.daemonId,
    )

    private fun loadEndpoints(): List<DieterEndpoint> {
        val encoded = preferences.getString(KEY_ENDPOINTS, null) ?: return DIETER_ENDPOINTS
        return runCatching {
            val array = JSONArray(encoded)
            val loaded = buildList {
                for (index in 0 until array.length()) {
                    val item = array.getJSONObject(index)
                    add(
                        DieterEndpoint(
                            id = item.getString("id"),
                            label = item.getString("label"),
                            host = item.getString("host"),
                            port = item.getInt("port"),
                            secure = item.optBoolean("secure", false),
                            daemonId = item.optString("daemonId").ifBlank { null },
                        ),
                    )
                }
            }.also { require(it.isNotEmpty()) }
            val origins = loaded.mapIndexed { index, endpoint ->
                if (endpoint.daemonId == null) {
                    endpoint
                } else {
                    DIETER_ENDPOINTS.firstOrNull { it.credentialId == endpoint.credentialId }
                        ?: endpoint.copy(id = "gateway_$index", label = endpoint.host, daemonId = null)
                }
            }.filter { it.secure || isLoopbackHost(it.host) }
                .distinctBy { it.credentialId }
                .ifEmpty { DIETER_ENDPOINTS }
            if (origins != loaded) persistEndpoints(origins)
            origins
        }.getOrDefault(DIETER_ENDPOINTS)
    }

    private fun persistEndpoints(endpoints: List<DieterEndpoint>) {
        val encoded = JSONArray().apply {
            endpoints.forEach { endpoint ->
                put(
                    JSONObject()
                        .put("id", endpoint.id)
                        .put("label", endpoint.label)
                        .put("host", endpoint.host)
                        .put("port", endpoint.port)
                        .put("secure", endpoint.secure)
                        .put("daemonId", endpoint.daemonId),
                )
            }
        }.toString()
        preferences.edit().putString(KEY_ENDPOINTS, encoded).apply()
    }

    private fun endpointFailure(error: Throwable): String = when (Status.fromThrowable(error).code) {
        Status.Code.DEADLINE_EXCEEDED -> "Timed out"
        Status.Code.UNAVAILABLE -> "Unavailable"
        Status.Code.UNAUTHENTICATED -> "Sign in required"
        else -> readableError(error).take(36)
    }

    private fun readableError(error: Throwable): String {
        val status = Status.fromThrowable(error)
        return status.description?.takeIf { it.isNotBlank() }
            ?: error.message?.substringBefore('\n')
            ?: "Dieter connection failed"
    }

    fun close() {
        synchronized(lock) {
            generation++
            connectionJob?.cancel()
            connectionJob = null
        }
        repository.close()
        scope.cancel()
    }

    companion object {
        private const val PREFERENCES = "dieter_connection"
        private const val KEY_DESIRED_CONNECTED = "desired_connected"
        private const val KEY_BACKGROUND_SYNC = "background_sync"
        private const val KEY_ENDPOINTS = "endpoints"
        private const val KEY_AUTH_VERIFIER = "auth_verifier"
        private const val KEY_AUTH_ENDPOINT = "auth_endpoint"
        private const val KEY_ACTIVE_GATEWAY = "active_gateway"
        private const val KEY_PREFERRED_ENDPOINT = "preferred_endpoint"
        // Read-only migration key from pre gateway-scoped builds.
        private const val KEY_PREFERRED_DAEMON = "preferred_daemon"
        private const val MACHINE_DIRECTORY_REFRESH_MS = 15_000L
        private const val MAX_RESOLVED_CONVERSATIONS = 256
        private const val MAX_ACTIVE_CONVERSATIONS = 24
        /** Messages per conversation carried by the global sync stream. */
        private const val SYNC_CONVERSATION_MESSAGES = 30
        /** Recently active conversations kept warm beyond the running ones. */
        private const val SYNC_RECENT_CONVERSATIONS = 8
        /** One missed heartbeat (15 s) plus slack marks the stream suspect. */
        private const val STALE_SYNC_PROBE_MS = 20_000L
    }
}

private data class MachineSnapshot(
    val endpoint: DieterEndpoint,
    val projects: List<Project>,
    val boards: List<Board>,
    val cards: List<Card>,
    val chats: List<Card>,
)

private class DirectCredentialRefresh : RuntimeException()

fun isActiveRuntime(runtime: String): Boolean = runtime.lowercase() in setOf(
    "running",
    "starting",
    "working",
    "streaming",
)

internal fun endpointForProjectSelection(
    projectId: String,
    currentEndpointId: String?,
    hosts: Map<String, ProjectHost>,
): String? = hosts[projectId]?.endpointId?.takeUnless { it == currentEndpointId }

internal fun isLoopbackHost(host: String): Boolean = host.equals("localhost", ignoreCase = true) ||
    host == "127.0.0.1" || host == "::1"

package com.dbpprt.dieter.connection

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import android.util.Base64
import android.util.Log
import com.dbpprt.dieter.data.DIETER_API_VERSION
import com.dbpprt.dieter.data.DIETER_ENDPOINTS
import com.dbpprt.dieter.data.DieterEndpoint
import com.dbpprt.dieter.data.DieterRepository
import com.dbpprt.dieter.data.AndroidOutboxEntry
import com.dbpprt.dieter.data.CachedProjectHost
import com.dbpprt.dieter.data.DieterSyncStore
import com.dbpprt.dieter.data.OutboxKind
import com.dbpprt.dieter.data.OutboxState
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
import io.grpc.Status
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.cancel
import kotlinx.coroutines.cancelAndJoin
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
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
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

// WatchSync emits every 15 seconds. Rebuild the transport only after three
// missed frames so ordinary Android scheduling jitter or one slow projection
// cannot turn a healthy connection into a reconnect loop.
internal const val SYNC_STALE_AFTER_MS = 45_000L

internal fun syncStreamIsStale(
    lastFrameAtMs: Long,
    nowMs: Long = System.currentTimeMillis(),
    staleAfterMs: Long = SYNC_STALE_AFTER_MS,
): Boolean = lastFrameAtMs > 0 && nowMs >= lastFrameAtMs && nowMs - lastFrameAtMs >= staleAfterMs

internal fun foregroundConnectionPhase(current: ConnectionPhase, becameForeground: Boolean): ConnectionPhase =
    if (becameForeground && current == ConnectionPhase.CONNECTED) ConnectionPhase.SYNCING else current

data class EndpointConnection(
    val id: String,
    val label: String,
    val address: String,
    val phase: EndpointPhase = EndpointPhase.PENDING,
    val detail: String = "Waiting",
    val latencyMs: Long? = null,
    val online: Boolean = true,
    val daemonId: String? = null,
    val lastSeenAt: String = "",
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
    val lastConnectedAtMs: Long? = null,
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
    val conversationRefreshedAtMillis: Map<String, Long> = emptyMap(),
    val schedules: List<Schedule> = emptyList(),
    val scheduleRuns: List<ScheduleRun> = emptyList(),
    val pendingCardIds: Set<String> = emptySet(),
    val pendingMessageIds: Set<String> = emptySet(),
    val acceptedOutboxIds: Set<String> = emptySet(),
    val failedOutboxIds: Set<String> = emptySet(),
    val machineOutboxSummaries: Map<String, MachineOutboxSummary> = emptyMap(),
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
    private var activeProjectionRefreshedAtMillis = activeProjectionKey.takeIf(String::isNotBlank)
        ?.let(syncStore::projectionRefreshedAtMillis)
    private var lastProjectionPersistedAtMillis = activeProjectionKey.takeIf(String::isNotBlank)
        ?.let(syncStore::projectionPersistedAtMillis)
    private var projectionSnapshotDirty = false
    private var projectionCursorDirty = false
    private val outbox = syncStore.loadOutbox()
    private val conversationIdResolutions = linkedMapOf<String, String>().apply {
        outbox.forEach { entry ->
            if (entry.kind in setOf(OutboxKind.CREATE_CARD, OutboxKind.CREATE_CHAT) && entry.serverId != null) {
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
    @Volatile
    private var discoveredEndpoints: List<DieterEndpoint> = emptyList()

    private val _state = MutableStateFlow(
        DieterConnectionState(
            desiredConnected = preferences.getBoolean(KEY_DESIRED_CONNECTED, true),
            backgroundSyncEnabled = preferences.getBoolean(KEY_BACKGROUND_SYNC, true),
            activeGatewayId = activeGatewayId,
            configuredConnections = configuredEndpointRows(),
            endpointConnections = configuredEndpointRows(),
            lastConnectedAtMs = DieterWidgetPrefs.lastSyncAtMs(appContext).takeIf { it > 0L },
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
        globalSnapshot?.let { snapshot ->
            applyGlobalSnapshot(
                snapshot,
                refreshedConversationIds = snapshot.conversationsList.mapTo(hashSetOf()) { it.detail.card.id },
                refreshedAtMillis = activeProjectionRefreshedAtMillis,
            )
        }
        if (outbox.isNotEmpty()) refreshOutboxPresentation()
    }

    fun onAppForegrounded(projectId: String = selectedProjectId) {
        val becameForeground = synchronized(lock) {
            val changed = !appForeground
            appForeground = true
            if (projectId.isNotBlank()) selectedProjectId = projectId
            changed
        }
        if (becameForeground) {
            val foregroundedAt = System.currentTimeMillis()
            _state.update { current ->
                val phase = foregroundConnectionPhase(current.phase, becameForeground = true)
                if (phase == current.phase) current else current.copy(
                    phase = phase,
                    connectionInterruptedAtMs = foregroundedAt,
                )
            }
        }
        if (_state.value.desiredConnected && _state.value.backgroundSyncEnabled) DieterSyncService.start(appContext)
        reconcile()
        recoverStaleConnection()
    }

    /**
     * Doze can silently kill the transport underneath an "active" stream. When
     * the app comes back with a connection that claims to be healthy but has
     * not produced a sync frame in longer than the heartbeat interval, rebuild
     * it immediately. A successful unary health RPC cannot prove that the
     * separate server-streaming call is still delivering frames.
     */
    private fun recoverStaleConnection() {
        if (_state.value.phase in setOf(ConnectionPhase.SYNCING, ConnectionPhase.CONNECTED) &&
            syncStreamIsStale(lastSyncFrameAtMs)
        ) {
            restart()
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
        if (projectRouteIsReady(target.endpointId, repository.activeEndpoint.id, _state.value.phase)) return
        if (!target.online) error("${target.hostname} is offline. Start Dieter on that machine to continue.")
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

    fun cleanSync() {
        val previousJob = synchronized(lock) {
            generation++
            connectionJob.also { connectionJob = null }
        }
        _state.update {
            it.copy(
                phase = if (it.desiredConnected) ConnectionPhase.SYNCING else ConnectionPhase.STOPPED,
                connectionInterruptedAtMs = if (it.desiredConnected) System.currentTimeMillis() else null,
                error = null,
            )
        }
        scope.launch {
            previousJob?.cancelAndJoin()
            repository.reconnect()
            syncStore.clearProjections()
            synchronized(lock) {
                cachedDirectory = null
                preferredEndpointId = null
                activeProjectionKey = ""
                selectedProjectId = ""
                discoveredEndpoints = emptyList()
            }
            preferences.edit().remove(KEY_PREFERRED_ENDPOINT).remove(KEY_PREFERRED_DAEMON).apply()
            globalSnapshot = null
            syncCursor = null
            activeProjectionRefreshedAtMillis = null
            lastProjectionPersistedAtMillis = null
            projectionSnapshotDirty = false
            projectionCursorDirty = false
            lastSyncFrameAtMs = 0L
            _state.update {
                it.copy(
                    phase = if (it.desiredConnected) ConnectionPhase.CONNECTING else ConnectionPhase.STOPPED,
                    endpoint = null,
                    endpointConnections = configuredEndpointRows(),
                    selectedState = null,
                    projects = emptyList(),
                    projectHosts = emptyMap(),
                    boards = emptyList(),
                    cards = emptyList(),
                    chats = emptyList(),
                    activeConversations = emptyMap(),
                    conversationRefreshedAtMillis = emptyMap(),
                    schedules = emptyList(),
                    scheduleRuns = emptyList(),
                    error = null,
                )
            }
            updateSelectedState()
            if (shouldRun()) ensureStarted()
        }
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
            activeProjectionRefreshedAtMillis = null
            lastProjectionPersistedAtMillis = null
            projectionSnapshotDirty = false
            projectionCursorDirty = false
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
                conversationRefreshedAtMillis = if (gatewayChanged) emptyMap() else it.conversationRefreshedAtMillis,
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
        activeProjectionRefreshedAtMillis = null
        lastProjectionPersistedAtMillis = null
        projectionSnapshotDirty = false
        projectionCursorDirty = false
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
                conversationRefreshedAtMillis = emptyMap(),
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
                conversationRefreshedAtMillis = emptyMap(),
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
                retryAttempt = 0
                coroutineScope {
                    launch { collectGlobalSync(currentGeneration) }
                    launch { monitorGlobalSync(currentGeneration) }
                    launch { drainOutbox(currentGeneration) }
                    launch { watchDaemonPresence(currentGeneration) }
                    // Cross-machine discovery must not delay the selected
                    // daemon's delta stream. The cached directory is usable
                    // immediately and this refresh fills in newer routes in
                    // the background.
                    launch { runCatching { refreshMachineDirectory() } }
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
                if (error is StaleSyncStream) {
                    repository.reconnect()
                    retryAttempt = 0
                    continue
                }
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
                online = machinePresenceOnline(daemon.online, daemon.lastSeenAt),
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
        // Give each newly opened stream one complete heartbeat window to
        // deliver its bootstrap frame before the liveness monitor intervenes.
        lastSyncFrameAtMs = System.currentTimeMillis()
        repository.watchSync(
            syncCursor,
            conversationLimit = SYNC_CONVERSATION_MESSAGES,
            recentConversationLimit = SYNC_RECENT_CONVERSATIONS,
        ).collect { frame ->
            if (currentGeneration != synchronized(lock) { generation }) return@collect
            val receivedAtMillis = System.currentTimeMillis()
            lastSyncFrameAtMs = receivedAtMillis
            DieterWidgetPrefs.recordSyncFrame(appContext, receivedAtMillis)
            val refreshedConversationIds = when {
                frame.hasSnapshot() -> frame.snapshot.conversationsList.mapTo(hashSetOf()) { it.detail.card.id }
                frame.hasDelta() -> frame.delta.conversationsList.mapTo(hashSetOf()) { it.detail.card.id }
                else -> emptySet()
            }
            var projectionChanged = false
            if (frame.hasSnapshot()) {
                if (globalSnapshot != frame.snapshot) {
                    globalSnapshot = frame.snapshot
                    projectionChanged = true
                }
            } else if (frame.hasDelta() && frame.delta.changesProjection() && globalSnapshot != null) {
                val current = requireNotNull(globalSnapshot)
                val next = applyGlobalDelta(current, frame.delta)
                if (next != current) {
                    globalSnapshot = next
                    projectionChanged = true
                }
            }
            if (frame.hasCursor()) {
                syncCursor = frame.cursor
            }
            if (refreshedConversationIds.isNotEmpty()) {
                activeProjectionRefreshedAtMillis = receivedAtMillis
            }
            projectionSnapshotDirty = projectionSnapshotDirty || projectionChanged || refreshedConversationIds.isNotEmpty()
            projectionCursorDirty = projectionCursorDirty || frame.hasCursor() && !frame.heartbeat
            if (activeProjectionKey.isNotBlank() &&
                (projectionSnapshotDirty || projectionCursorDirty) &&
                syncProjectionShouldPersist(lastProjectionPersistedAtMillis, receivedAtMillis)
            ) {
                syncStore.saveProjection(
                    activeProjectionKey,
                    globalSnapshot.takeIf { projectionSnapshotDirty },
                    syncCursor.takeIf { projectionCursorDirty },
                )
                lastProjectionPersistedAtMillis = receivedAtMillis
                projectionSnapshotDirty = false
                projectionCursorDirty = false
            }
            if (projectionChanged || refreshedConversationIds.isNotEmpty()) {
                globalSnapshot?.let {
                    reconcileOutbox(it)
                    applyGlobalSnapshot(it, refreshedConversationIds, receivedAtMillis)
                }
            }
            _state.update {
                it.copy(
                    phase = ConnectionPhase.CONNECTED,
                    connectionInterruptedAtMs = null,
                    lastConnectedAtMs = receivedAtMillis,
                    error = null,
                )
            }
        }
    }

    private suspend fun monitorGlobalSync(currentGeneration: Long) {
        while (currentCoroutineContext().isActive && currentGeneration == synchronized(lock) { generation }) {
            delay(SYNC_LIVENESS_CHECK_MS)
            if (syncStreamIsStale(lastSyncFrameAtMs)) throw StaleSyncStream()
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
            val currentSnapshot = syncStore.loadSnapshot(endpoint.id)
            val legacyScope = endpoint.daemonId.takeIf { currentSnapshot == null }
            globalSnapshot = currentSnapshot ?: legacyScope?.let(syncStore::loadSnapshot)
            syncCursor = (syncStore.loadCursor(endpoint.id)
                ?: endpoint.daemonId?.let(syncStore::loadCursor)).takeIf { globalSnapshot != null }
            activeProjectionRefreshedAtMillis = if (currentSnapshot != null) {
                syncStore.projectionRefreshedAtMillis(endpoint.id)
            } else {
                legacyScope?.let(syncStore::projectionRefreshedAtMillis)
            }
            lastProjectionPersistedAtMillis = if (currentSnapshot != null) {
                syncStore.projectionPersistedAtMillis(endpoint.id)
            } else {
                legacyScope?.let(syncStore::projectionPersistedAtMillis)
            }
            projectionSnapshotDirty = false
            projectionCursorDirty = false
            _state.update { current ->
                current.copy(lastConnectedAtMs = activeProjectionRefreshedAtMillis ?: current.lastConnectedAtMs)
            }
        }
        val cached = globalSnapshot
        if (cached != null) {
            applyGlobalSnapshot(
                cached,
                cached.conversationsList.mapTo(hashSetOf()) { it.detail.card.id },
                activeProjectionRefreshedAtMillis,
            )
        } else {
            updateSelectedState()
        }
    }

    private fun applyDaemonPresence(daemons: List<com.dbpprt.dieter.gateway.v1.Daemon>) {
        val byID = daemons.associateBy { it.id }
        val endpoints = synchronized(lock) {
            discoveredEndpoints = discoveredEndpoints.map { endpoint ->
                val daemon = endpoint.daemonId?.let(byID::get) ?: return@map endpoint
                endpoint.copy(
                    label = daemon.name.ifBlank { daemon.id },
                    online = machinePresenceOnline(daemon.online, daemon.lastSeenAt),
                    lastSeenAt = daemon.lastSeenAt,
                    version = daemon.version,
                )
            }
            discoveredEndpoints
        }
        _state.update { current ->
            val availability = endpoints.associate { it.id to it.online }
            current.copy(
                endpointConnections = current.endpointConnections.map { row ->
                    val endpoint = endpoints.firstOrNull { it.id == row.id } ?: return@map row
                    when {
                        projectRouteIsReady(endpoint.id, current.endpoint?.id, current.phase) -> row.copy(
                            label = endpoint.label,
                            online = true,
                            lastSeenAt = endpoint.lastSeenAt,
                        )
                        else -> endpointRow(endpoint)
                    }
                },
                projectHosts = current.projectHosts.mapValues { (_, host) ->
                    host.copy(
                        online = availability[host.endpointId] == true ||
                            projectRouteIsReady(host.endpointId, current.endpoint?.id, current.phase),
                    )
                },
            )
        }
    }

    suspend fun refreshMachineDirectory(includeArchivedChats: Boolean = false) {
        val activeEndpointId = repository.activeEndpoint.id
        val machines = discoveredEndpoints.filter { machine ->
            machine.online && (includeArchivedChats || machine.id != activeEndpointId)
        }
        if (machines.isEmpty()) return
        // Relay calls use independent channels, so fetch machines and their
        // project partitions concurrently. Keep one shared bound across the
        // batch to avoid exhausting the gateway's logical-stream allowance.
        val permits = Semaphore(MAX_MACHINE_DIRECTORY_RPCS)
        val snapshots = coroutineScope {
            machines.map { machine ->
                async {
                    runCatching {
                        val root = permits.withPermit { repository.relayState(machine) }
                        val projects = root.projectsList.filterNot(Project::getArchived)
                        coroutineScope {
                            val projectStates = projects.map { project ->
                                async {
                                    permits.withPermit {
                                        repository.relayState(
                                            machine,
                                            GetStateRequest.newBuilder().setProjectId(project.id).setLimit(500).build(),
                                        )
                                    }
                                }
                            }
                            val chats = async {
                                permits.withPermit {
                                    repository.relayChats(machine, includeArchived = includeArchivedChats)
                                }
                            }
                            val states = projectStates.awaitAll()
                            MachineSnapshot(
                                machine,
                                projects,
                                states.flatMap { it.boardsList },
                                states.flatMap { it.cardsList },
                                chats.await().chatsList.filter { includeArchivedChats || !it.archived },
                            )
                        }
                    }.getOrNull()
                }
            }.awaitAll().filterNotNull()
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

    private fun applyGlobalSnapshot(
        snapshot: GlobalSnapshot,
        refreshedConversationIds: Set<String> = emptySet(),
        refreshedAtMillis: Long? = null,
    ) {
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
            val cards = overlayPendingCardStarts(
                (current.cards.filter { it.projectId in retainedProjectIds } + snapshot.state.cardsList)
                    .distinctBy { it.id },
                boards,
                entries,
            ).toMutableList()
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
                            .setRuntime(if (entry.state == OutboxState.FAILED) "failed" else "pending")
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
                                .setStatus(if (entry.state == OutboxState.FAILED) "failed" else "pending")
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
                    OutboxKind.START_CARD -> Unit
                }
            }
            conversations.replaceAll { _, conversation -> overlayOptimisticMessages(conversation, entries) }
            val conversationRefreshes = current.conversationRefreshedAtMillis.toMutableMap().apply {
                resolvedConversationIds.forEach { (localId, serverId) ->
                    remove(localId)?.let { localRefresh -> put(serverId, maxOf(get(serverId) ?: 0L, localRefresh)) }
                }
                if (refreshedAtMillis != null) {
                    refreshedConversationIds.forEach { cardId -> put(cardId, refreshedAtMillis) }
                }
                keys.retainAll(conversations.keys)
            }

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
                conversationRefreshedAtMillis = conversationRefreshes,
                schedules = schedules,
                scheduleRuns = scheduleRuns,
                pendingCardIds = pendingCardIds(entries),
                pendingMessageIds = pendingMessageIds(entries),
                acceptedOutboxIds = acceptedOutboxIds(entries),
                failedOutboxIds = failedOutboxIds(entries),
                machineOutboxSummaries = machineOutboxSummaries(entries),
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
        val startedCardIds = snapshot.state.cardsList
            .filter { it.initialPromptSentAt.isNotBlank() }
            .mapTo(hashSetOf(), Card::getId)
        return reconcileOutbox(cardIds, snapshot.conversationsList, startedCardIds)
    }

    private fun reconcileOutbox(snapshot: ConversationSnapshot): Boolean {
        val cardId = snapshot.detail.card.id.ifBlank { snapshot.conversation.cardId }
        val startedCardIds = setOf(snapshot.detail.card)
            .filter { it.id.isNotBlank() && it.initialPromptSentAt.isNotBlank() }
            .mapTo(hashSetOf(), Card::getId)
        return reconcileOutbox(
            setOf(cardId).filter(String::isNotBlank).toSet(),
            listOf(snapshot),
            startedCardIds,
        )
    }

    private fun reconcileOutbox(
        cardIds: Set<String>,
        conversations: List<ConversationSnapshot>,
        startedCardIds: Set<String>,
    ): Boolean {
        val changed = synchronized(outbox) {
            outbox.removeAll { entry -> outboxEntryIsSynced(entry, cardIds, conversations, startedCardIds) }
        }
        if (changed) syncStore.saveOutbox(synchronized(outbox) { outbox.toList() })
        return changed
    }

    suspend fun enqueueCardStart(cardId: String): Card {
        val current = _state.value
        val card = current.cards.firstOrNull { it.id == cardId }
            ?: error("Card is no longer available")
        var existing = synchronized(outbox) {
            outbox.firstOrNull {
                it.kind == OutboxKind.START_CARD && it.optimisticId == cardId
            }
        }
        if (existing?.state == OutboxState.FAILED) {
            synchronized(outbox) {
                val index = outbox.indexOfFirst { it.commandId == existing?.commandId }
                if (index >= 0) {
                    outbox[index] = outbox[index].copy(
                        attempts = 0,
                        lastError = null,
                        state = OutboxState.QUEUED,
                        nextAttemptAtMillis = null,
                    )
                    existing = outbox[index]
                    syncStore.saveOutbox(outbox)
                }
            }
        }
        if (existing == null) {
            val request = StartCardRequest.newBuilder()
                .setCardId(cardId)
                .setClientId(syncStore.clientId)
                .setCommandId(UUID.randomUUID().toString().lowercase())
                .build()
            val endpointId = endpointForProject(card.projectId) ?: repository.activeEndpoint.id
            synchronized(outbox) {
                outbox += AndroidOutboxEntry(
                    commandId = request.commandId,
                    clientId = request.clientId,
                    endpointId = endpointId,
                    kind = OutboxKind.START_CARD,
                    request = request.toByteArray(),
                    optimisticId = cardId,
                )
                syncStore.saveOutbox(outbox)
            }
        }
        refreshOutboxPresentation()
        return _state.value.cards.firstOrNull { it.id == cardId } ?: card
    }

    private fun refreshOutboxPresentation() {
        retargetOutboxToKnownHosts()
        val snapshot = globalSnapshot
        if (snapshot != null) {
            applyGlobalSnapshot(snapshot)
            return
        }
        _state.update { current ->
            val entries = synchronized(outbox) { outbox.toList() }
            val combined = current.copy(
                cards = overlayPendingCardStarts(current.cards, current.boards, entries),
                pendingCardIds = pendingCardIds(entries),
                pendingMessageIds = pendingMessageIds(entries),
                acceptedOutboxIds = acceptedOutboxIds(entries),
                failedOutboxIds = failedOutboxIds(entries),
                machineOutboxSummaries = machineOutboxSummaries(entries),
            )
            combined.copy(selectedState = selectedState(combined))
        }
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
            val refreshed = current.conversationRefreshedAtMillis.toMutableMap().apply {
                put(cardId, System.currentTimeMillis())
                keys.retainAll(conversations.keys)
            }
            current.copy(
                activeConversations = conversations,
                conversationRefreshedAtMillis = refreshed,
                pendingCardIds = pendingCardIds(entries),
                pendingMessageIds = pendingMessageIds(entries),
                acceptedOutboxIds = acceptedOutboxIds(entries),
                failedOutboxIds = failedOutboxIds(entries),
                machineOutboxSummaries = machineOutboxSummaries(entries),
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
                OutboxKind.CREATE_CARD, OutboxKind.START_CARD -> Unit
            }
        }
    }

    private fun acceptedOutboxIds(entries: List<AndroidOutboxEntry>): Set<String> = buildSet {
        entries.filter { it.serverId != null }.forEach { entry -> addAll(outboxPresentationIds(entry)) }
    }

    private fun failedOutboxIds(entries: List<AndroidOutboxEntry>): Set<String> = buildSet {
        entries.filter { it.state == OutboxState.FAILED }.forEach { entry -> addAll(outboxPresentationIds(entry)) }
    }

    private fun outboxPresentationIds(entry: AndroidOutboxEntry): Set<String> = buildSet {
        add(entry.optimisticId)
        entry.serverId?.let(::add)
        optimisticInitialMessageId(entry)?.let(::add)
    }

    suspend fun enqueueConversation(request: CreateConversationRequest, chat: Boolean): Card {
        val commandId = UUID.randomUUID().toString().lowercase()
        val stable = request.toBuilder().setClientId(syncStore.clientId).setCommandId(commandId).build()
        val optimisticId = "local_${UUID.randomUUID().toString().replace("-", "").lowercase()}"
        val targetEndpoint = endpointForProject(stable.projectId) ?: repository.activeEndpoint.id
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
        val targetEndpoint = projectForCard(cardId)
            ?.let(::endpointForProject)
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
            retargetOutboxToKnownHosts()
            val activeEndpoint = repository.activeEndpoint.id
            val entry = synchronized(outbox) { nextOutboxEntry(outbox, activeEndpoint) }
            if (entry == null) {
                val onlineEndpointIds = discoveredEndpoints.filter(DieterEndpoint::online).mapTo(hashSetOf()) { it.id }
                val nextEndpoint = synchronized(outbox) {
                    nextOutboxEndpoint(outbox, activeEndpoint, onlineEndpointIds)
                }
                if (nextEndpoint != null) {
                    preferredEndpointId = nextEndpoint
                    preferences.edit().putString(KEY_PREFERRED_ENDPOINT, nextEndpoint).apply()
                    restart()
                    return
                }
                delay(500)
                continue
            }
            try {
                val serverId = when (entry.kind) {
                    OutboxKind.CREATE_CARD -> repository.createConversation(CreateConversationRequest.parseFrom(entry.request), false).id
                    OutboxKind.CREATE_CHAT -> repository.createConversation(CreateConversationRequest.parseFrom(entry.request), true).id
                    OutboxKind.SEND_MESSAGE -> repository.sendMessage(SendMessageRequest.parseFrom(entry.request)).messageId
                        .ifBlank { entry.optimisticId }
                    OutboxKind.START_CARD -> repository.startCard(StartCardRequest.parseFrom(entry.request)).card
                        .also(::acceptStartedCard)
                        .id
                }
                synchronized(outbox) {
                    val index = outbox.indexOfFirst { it.commandId == entry.commandId }
                    if (index >= 0) {
                        outbox[index] = entry.copy(
                            serverId = serverId,
                            lastError = null,
                            state = OutboxState.QUEUED,
                            nextAttemptAtMillis = null,
                        )
                    }
                    if (entry.kind == OutboxKind.CREATE_CARD || entry.kind == OutboxKind.CREATE_CHAT) {
                        conversationIdResolutions[entry.optimisticId] = serverId
                        val retargeted = retargetOutboxDependencies(outbox, entry.optimisticId, serverId)
                        outbox.clear()
                        outbox.addAll(retargeted)
                        while (conversationIdResolutions.size > MAX_RESOLVED_CONVERSATIONS) {
                            conversationIdResolutions.remove(conversationIdResolutions.keys.first())
                        }
                    }
                    syncStore.saveOutbox(outbox)
                }
                globalSnapshot?.let(::reconcileOutbox)
                refreshOutboxPresentation()
            } catch (error: Throwable) {
                val attempts = entry.attempts + 1
                val terminal = outboxFailureIsPermanent(error)
                synchronized(outbox) {
                    val index = outbox.indexOfFirst { it.commandId == entry.commandId }
                    if (index >= 0) {
                        outbox[index] = entry.copy(
                            attempts = attempts,
                            lastError = readableRpcError(error),
                            state = if (terminal) OutboxState.FAILED else OutboxState.RETRYING,
                            nextAttemptAtMillis = if (terminal) null else System.currentTimeMillis() + outboxBackoffMillis(attempts),
                        )
                    }
                    syncStore.saveOutbox(outbox)
                }
                Log.e(
                    "DieterOutbox",
                    "operation=${entry.kind} card=${entry.serverId ?: entry.optimisticId} " +
                        "endpoint=$activeEndpoint route=${repository.dataRoute()} status=${Status.fromThrowable(error).code} " +
                        "message=${readableRpcError(error)} terminal=$terminal",
                )
                refreshOutboxPresentation()
            }
        }
    }

    private fun projectForCard(cardId: String): String? {
        val current = _state.value
        return (current.cards + current.chats).firstOrNull { it.id == cardId }?.projectId
            ?.takeIf(String::isNotBlank)
            ?: current.activeConversations[cardId]?.detail?.card?.projectId?.takeIf(String::isNotBlank)
            ?: globalSnapshot?.state?.let { state ->
                (state.cardsList + state.chatsList).firstOrNull { it.id == cardId }?.projectId
            }?.takeIf(String::isNotBlank)
            ?: cachedDirectory?.state?.let { state ->
                (state.cardsList + state.chatsList).firstOrNull { it.id == cardId }?.projectId
            }?.takeIf(String::isNotBlank)
    }

    private fun endpointForProject(projectId: String): String? {
        if (projectId.isBlank()) return null
        val current = _state.value.projectHosts[projectId]?.endpointId?.takeIf(String::isNotBlank)
        val cached = cachedDirectory?.hosts?.get(projectId)?.endpointId?.takeIf(String::isNotBlank)
        return when {
            current != null && (current in discoveredEndpoints.map(DieterEndpoint::id) || '#' in current) -> current
            cached != null && '#' in cached -> cached
            else -> current ?: cached
        }
    }

    private fun retargetOutboxToKnownHosts(): Boolean {
        val current = _state.value
        val cardProjects = buildMap {
            cachedDirectory?.state?.let { state ->
                (state.cardsList + state.chatsList).forEach { card -> put(card.id, card.projectId) }
            }
            globalSnapshot?.state?.let { state ->
                (state.cardsList + state.chatsList).forEach { card -> put(card.id, card.projectId) }
            }
            current.activeConversations.forEach { (cardId, snapshot) ->
                snapshot.detail.card.projectId.takeIf(String::isNotBlank)?.let { put(cardId, it) }
            }
            (current.cards + current.chats).forEach { card -> put(card.id, card.projectId) }
        }
        val projectIds = buildSet {
            addAll(cachedDirectory?.hosts?.keys.orEmpty())
            addAll(current.projectHosts.keys)
        }
        val projectEndpoints = projectIds.mapNotNull { projectId ->
            endpointForProject(projectId)?.let { projectId to it }
        }.toMap()
        return synchronized(outbox) {
            val retargeted = retargetOutboxEndpoints(outbox, cardProjects, projectEndpoints)
            if (retargeted == outbox) return@synchronized false
            outbox.clear()
            outbox.addAll(retargeted)
            syncStore.saveOutbox(outbox)
            true
        }
    }

    fun retryOutboxItem(id: String) {
        synchronized(outbox) {
            val index = outbox.indexOfFirst {
                (it.optimisticId == id || it.serverId == id) && it.state == OutboxState.FAILED
            }
            if (index < 0) return
            outbox[index] = outbox[index].copy(
                attempts = 0,
                lastError = null,
                state = OutboxState.QUEUED,
                nextAttemptAtMillis = null,
            )
            syncStore.saveOutbox(outbox)
        }
        refreshOutboxPresentation()
    }

    fun retryOutboxForEndpoint(endpointId: String) {
        var changed = false
        synchronized(outbox) {
            outbox.indices
                .filter { outbox[it].endpointId == endpointId && outbox[it].serverId == null }
                .forEach { index ->
                    outbox[index] = outbox[index].copy(
                        attempts = 0,
                        lastError = null,
                        state = OutboxState.QUEUED,
                        nextAttemptAtMillis = null,
                    )
                    changed = true
                }
            if (changed) syncStore.saveOutbox(outbox)
        }
        if (changed) refreshOutboxPresentation()
        preferredEndpointId = endpointId
        preferences.edit().putString(KEY_PREFERRED_ENDPOINT, endpointId).apply()
        if (_state.value.desiredConnected) restart()
    }

    fun outboxFailure(id: String): String? = synchronized(outbox) {
        outbox.firstOrNull {
            (it.optimisticId == id || it.serverId == id) && it.state == OutboxState.FAILED
        }?.lastError
    }

    fun discardOutboxItem(id: String) {
        val removed = synchronized(outbox) {
            val index = outbox.indexOfFirst {
                (it.optimisticId == id || it.serverId == id) && it.state == OutboxState.FAILED
            }
            if (index < 0) return
            outbox.removeAt(index).also { syncStore.saveOutbox(outbox) }
        }
        _state.update { current ->
            val ids = buildSet {
                add(removed.optimisticId)
                removed.serverId?.let(::add)
            }
            val conversations = current.activeConversations.toMutableMap()
            when (removed.kind) {
                OutboxKind.SEND_MESSAGE -> {
                    conversations.replaceAll { _, snapshot ->
                        snapshot.toBuilder()
                            .setConversation(
                                snapshot.conversation.toBuilder()
                                    .clearMessages()
                                    .addAllMessages(snapshot.conversation.messagesList.filterNot { it.id == removed.optimisticId }),
                            )
                            .build()
                    }
                }
                OutboxKind.CREATE_CARD, OutboxKind.CREATE_CHAT -> ids.forEach(conversations::remove)
                OutboxKind.START_CARD -> Unit
            }
            current.copy(
                activeConversations = conversations,
                conversationRefreshedAtMillis = current.conversationRefreshedAtMillis.filterKeys(conversations::containsKey),
            )
        }
        refreshOutboxPresentation()
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
        detail = if (endpoint.online) "Available" else machinePresenceAgeLabel(endpoint.lastSeenAt)?.let { "Last seen $it" } ?: "Offline",
        online = endpoint.online,
        daemonId = endpoint.daemonId,
        lastSeenAt = endpoint.lastSeenAt,
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
        private const val MAX_MACHINE_DIRECTORY_RPCS = 4
        private const val MAX_RESOLVED_CONVERSATIONS = 256
        private const val MAX_ACTIVE_CONVERSATIONS = 24
        /** Messages per conversation carried by the global sync stream. */
        private const val SYNC_CONVERSATION_MESSAGES = 30
        /** Recently active conversations kept warm beyond the running ones. */
        private const val SYNC_RECENT_CONVERSATIONS = 8
        private const val SYNC_LIVENESS_CHECK_MS = 5_000L
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

private class StaleSyncStream : RuntimeException("Live sync stopped producing frames")

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

internal fun projectRouteIsReady(
    targetEndpointId: String,
    activeEndpointId: String?,
    phase: ConnectionPhase,
): Boolean = targetEndpointId == activeEndpointId &&
    phase in setOf(ConnectionPhase.SYNCING, ConnectionPhase.CONNECTED)

internal fun isLoopbackHost(host: String): Boolean = host.equals("localhost", ignoreCase = true) ||
    host == "127.0.0.1" || host == "::1"

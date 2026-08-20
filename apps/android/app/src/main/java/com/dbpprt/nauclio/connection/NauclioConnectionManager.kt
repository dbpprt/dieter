package com.dbpprt.nauclio.connection

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import android.util.Base64
import com.dbpprt.nauclio.data.NAUCLIO_API_VERSION
import com.dbpprt.nauclio.data.NAUCLIO_ENDPOINTS
import com.dbpprt.nauclio.data.NauclioEndpoint
import com.dbpprt.nauclio.data.NauclioRepository
import com.dbpprt.nauclio.data.AndroidOutboxEntry
import com.dbpprt.nauclio.data.NauclioSyncStore
import com.dbpprt.nauclio.data.OutboxKind
import com.dbpprt.nauclio.v1.Board
import com.dbpprt.nauclio.v1.Card
import com.dbpprt.nauclio.v1.ConversationSnapshot
import com.dbpprt.nauclio.v1.CreateConversationRequest
import com.dbpprt.nauclio.v1.GlobalSnapshot
import com.dbpprt.nauclio.v1.GetStateRequest
import com.dbpprt.nauclio.v1.Harness
import com.dbpprt.nauclio.v1.Project
import com.dbpprt.nauclio.v1.RuntimeStatus
import com.dbpprt.nauclio.v1.SendMessageRequest
import com.dbpprt.nauclio.v1.MessagePart
import com.dbpprt.nauclio.v1.Schedule
import com.dbpprt.nauclio.v1.ScheduleRun
import com.dbpprt.nauclio.v1.State
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
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.UUID
import kotlin.time.TimeSource

enum class ConnectionPhase { STOPPED, CONNECTING, CONNECTED, RECONNECTING, AUTH_REQUIRED, INCOMPATIBLE, UNAVAILABLE }

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

data class NauclioConnectionState(
    val desiredConnected: Boolean,
    val backgroundSyncEnabled: Boolean,
    val phase: ConnectionPhase = ConnectionPhase.STOPPED,
    val connectionInterruptedAtMs: Long? = null,
    val endpoint: NauclioEndpoint? = null,
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
 * Process-wide owner of the Nauclio connection. The Activity observes this
 * state, while [NauclioSyncService] keeps the same stream alive in background.
 */
class NauclioConnectionManager(
    context: Context,
    val repository: NauclioRepository,
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.IO),
) {
    private val appContext = context.applicationContext
    private val preferences = appContext.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
    private val syncStore = NauclioSyncStore(appContext)
    private var globalSnapshot = syncStore.loadSnapshot()
    private var syncCursor = syncStore.loadCursor().takeIf { globalSnapshot != null }
    private val outbox = syncStore.loadOutbox()
    private val conversationIdResolutions = linkedMapOf<String, String>().apply {
        outbox.forEach { entry ->
            if (entry.kind != OutboxKind.SEND_MESSAGE && entry.serverId != null) {
                put(entry.optimisticId, entry.serverId)
            }
        }
    }
    private val lock = Any()
    private var configuredEndpoints = loadEndpoints().also(repository::replaceEndpoints)
    private var connectionJob: Job? = null
    private var generation = 0L
    private var selectedProjectId = ""
    private var appForeground = false
    private var serviceActive = false
    private var preferredDaemonId = preferences.getString(KEY_PREFERRED_DAEMON, null)
    private var discoveredEndpoints: List<NauclioEndpoint> = emptyList()

    private val _state = MutableStateFlow(
        NauclioConnectionState(
            desiredConnected = preferences.getBoolean(KEY_DESIRED_CONNECTED, true),
            backgroundSyncEnabled = preferences.getBoolean(KEY_BACKGROUND_SYNC, true),
            configuredConnections = configuredEndpointRows(),
            endpointConnections = configuredEndpointRows(),
        ),
    )
    val state: StateFlow<NauclioConnectionState> = _state.asStateFlow()

    init {
        globalSnapshot?.let(::applyGlobalSnapshot)
    }

    fun onAppForegrounded(projectId: String = selectedProjectId) {
        synchronized(lock) {
            appForeground = true
            if (projectId.isNotBlank()) selectedProjectId = projectId
        }
        if (_state.value.desiredConnected && _state.value.backgroundSyncEnabled) NauclioSyncService.start(appContext)
        reconcile()
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
        val nextDaemon = daemonForProjectSelection(projectId, preferredDaemonId, _state.value.projectHosts)
        val daemonChanged = nextDaemon != null
        val changed = synchronized(lock) {
            if (selectedProjectId == projectId && !daemonChanged) false else {
                selectedProjectId = projectId
                true
            }
        }
        if (daemonChanged) {
            preferredDaemonId = nextDaemon
            preferences.edit().putString(KEY_PREFERRED_DAEMON, preferredDaemonId).apply()
        }
        if (!daemonChanged) globalSnapshot?.let(::applyGlobalSnapshot)
        if (changed && shouldRun()) restart()
    }

    fun connect() {
        preferences.edit().putBoolean(KEY_DESIRED_CONNECTED, true).apply()
        _state.update { it.copy(desiredConnected = true, error = null) }
        if (_state.value.backgroundSyncEnabled) NauclioSyncService.start(appContext)
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

    fun selectDaemon(endpointId: String) {
        val target = discoveredEndpoints.firstOrNull { it.id == endpointId }
        if (target != null && !target.online) return
        preferredDaemonId = endpointId.substringAfterLast('#', endpointId)
        preferences.edit().putString(KEY_PREFERRED_DAEMON, preferredDaemonId).apply()
        if (_state.value.desiredConnected) restart()
    }

    fun signIn() {
        val endpoint = _state.value.endpoint ?: repository.activeEndpoint
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
            .appendQueryParameter("native_redirect_uri", "nauclio-android://oauth/callback")
            .appendQueryParameter("native_code_challenge", challenge).build()
        appContext.startActivity(Intent(Intent.ACTION_VIEW, authorize).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }

    fun completeAuthentication(uri: Uri) {
        if (uri.scheme != "nauclio-android" || uri.host != "oauth" || uri.path != "/callback") return
        val code = uri.getQueryParameter("code") ?: return
        val verifier = preferences.getString(KEY_AUTH_VERIFIER, null) ?: return
        val endpointID = preferences.getString(KEY_AUTH_ENDPOINT, null) ?: return
        val endpoint = repository.endpoints.firstOrNull { it.id == endpointID } ?: return
        preferences.edit().remove(KEY_AUTH_VERIFIER).remove(KEY_AUTH_ENDPOINT).apply()
        scope.launch {
            try {
                val body = JSONObject().put("code", code).put("verifier", verifier).toString()
                val connection = URL("https://${endpoint.host}${if (endpoint.port == 443) "" else ":${endpoint.port}"}/auth/native/exchange").openConnection() as HttpURLConnection
                connection.requestMethod = "POST"; connection.setRequestProperty("Content-Type", "application/json"); connection.connectTimeout = 15_000; connection.readTimeout = 15_000; connection.doOutput = true
                connection.outputStream.use { it.write(body.toByteArray()) }
                if (connection.responseCode != 200) error("Nauclio rejected the sign-in exchange (${connection.responseCode}).")
                val token = connection.inputStream.bufferedReader().use { JSONObject(it.readText()).getString("accessToken") }
                repository.selectEndpoint(endpoint); repository.setAccessToken(endpoint, token)
                _state.update { it.copy(endpoint = endpoint, phase = ConnectionPhase.CONNECTING, error = null) }
                restart()
            } catch (error: Throwable) {
                _state.update { it.copy(phase = ConnectionPhase.AUTH_REQUIRED, error = error.message ?: "Nauclio sign-in failed") }
            }
        }
    }

    fun updateEndpoints(endpoints: List<NauclioEndpoint>) {
        require(endpoints.isNotEmpty()) { "At least one Nauclio connection is required" }
        require(endpoints.map { it.id }.distinct().size == endpoints.size) { "Connection IDs must be unique" }
        require(endpoints.map { it.address.lowercase() }.distinct().size == endpoints.size) { "Connection addresses must be unique" }
        synchronized(lock) { configuredEndpoints = endpoints.toList() }
        persistEndpoints(endpoints)
        repository.replaceEndpoints(endpoints)
        val rows = configuredEndpointRows()
        _state.update { it.copy(configuredConnections = rows, endpointConnections = rows, error = null) }
        if (_state.value.desiredConnected && shouldRun()) restart()
    }

    fun resetEndpoints() = updateEndpoints(NAUCLIO_ENDPOINTS)

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
        if (stopService) NauclioSyncService.stop(appContext)
    }

    fun setBackgroundSyncEnabled(enabled: Boolean) {
        preferences.edit().putBoolean(KEY_BACKGROUND_SYNC, enabled).apply()
        _state.update { it.copy(backgroundSyncEnabled = enabled) }
        if (enabled && _state.value.desiredConnected) NauclioSyncService.start(appContext)
        if (!enabled) NauclioSyncService.stop(appContext)
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
                val health = connectToFirstEndpoint(currentGeneration)
                if (health.status != "ok" || health.version != NAUCLIO_API_VERSION) {
                    _state.update {
                        it.copy(
                            phase = ConnectionPhase.INCOMPATIBLE,
                            error = "Nauclio API ${health.version.ifBlank { "unknown" }} is incompatible; Android requires $NAUCLIO_API_VERSION.",
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
                        phase = ConnectionPhase.CONNECTED,
                        connectionInterruptedAtMs = null,
                        runtimeStatus = runtime,
                        harnesses = catalog.harnessesList,
                        error = null,
                    )
                }
                retryAttempt = 0
                coroutineScope {
                    launch { collectGlobalSync(currentGeneration) }
                    launch { drainOutbox(currentGeneration) }
                    launch { pollDaemonPresence(currentGeneration) }
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

    private suspend fun connectToFirstEndpoint(currentGeneration: Long): com.dbpprt.nauclio.v1.HealthResponse {
        val origins = synchronized(lock) { configuredEndpoints.toList() }.distinctBy { it.credentialId }
        repository.replaceEndpoints(origins)
        val discovered = mutableListOf<NauclioEndpoint>()
        var lastError: Throwable? = null
        for (origin in origins) {
            repository.selectEndpoint(origin)
            updateEndpoint(origin, EndpointPhase.TRYING, "Finding daemons", null)
            try {
                val directory = repository.daemons()
                discovered += directory.daemonsList.map { daemon ->
                    NauclioEndpoint(
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
                }
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Throwable) {
                lastError = error
                updateEndpoint(origin, EndpointPhase.FAILED, endpointFailure(error), null)
                if (Status.fromThrowable(error).code == Status.Code.UNAUTHENTICATED) {
                    _state.update { it.copy(endpoint = origin) }
                    throw error
                }
            }
        }
        if (discovered.isEmpty()) throw lastError ?: IllegalStateException("No Nauclio daemons are enrolled for this account")
        discovered.sortWith(compareBy<NauclioEndpoint> { !it.online }.thenBy { if (it.daemonId == preferredDaemonId) 0 else 1 }.thenBy { it.label.lowercase() })
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
        for (endpoint in discovered.filter(NauclioEndpoint::online)) {
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
                        phase = ConnectionPhase.CONNECTED,
                        connectionInterruptedAtMs = null,
                    )
                }
                return health
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Throwable) {
                lastError = error
                updateEndpoint(endpoint, EndpointPhase.FAILED, endpointFailure(error), null)
                repository.reconnect()
                if (Status.fromThrowable(error).code == Status.Code.UNAUTHENTICATED) {
                    _state.update { it.copy(endpoint = endpoint) }
                    throw error
                }
            }
        }
        throw lastError ?: IllegalStateException("No Nauclio connection target is available")
    }

    private suspend fun collectSelectedState(currentGeneration: Long) {
        val projectId = synchronized(lock) { selectedProjectId }
        val filter = GetStateRequest.newBuilder().setProjectId(projectId).build()
        repository.watchState(filter).collectLatest { remote ->
            if (currentGeneration != synchronized(lock) { generation }) return@collectLatest
            _state.update {
                it.copy(
                    phase = ConnectionPhase.CONNECTED,
                    connectionInterruptedAtMs = null,
                    selectedState = remote,
                    error = null,
                )
            }
        }
    }

    private suspend fun collectGlobalSync(currentGeneration: Long) {
        repository.watchSync(syncCursor, conversationLimit = 100).collect { frame ->
            if (currentGeneration != synchronized(lock) { generation }) return@collect
            if (frame.hasSnapshot()) {
                globalSnapshot = frame.snapshot
            }
            if (frame.hasCursor()) {
                syncCursor = frame.cursor
            }
            syncStore.saveProjection(frame.snapshot.takeIf { frame.hasSnapshot() }, frame.cursor.takeIf { frame.hasCursor() })
            globalSnapshot?.let {
                reconcileOutbox(it)
                applyGlobalSnapshot(it)
            }
            _state.update { it.copy(phase = ConnectionPhase.CONNECTED, connectionInterruptedAtMs = null, error = null) }
        }
    }

    private suspend fun pollDaemonPresence(currentGeneration: Long) {
        while (currentCoroutineContext().isActive && currentGeneration == synchronized(lock) { generation }) {
            refreshDaemonPresence()
            delay(MACHINE_POLL_INTERVAL_MS)
        }
    }

    private suspend fun pollGlobalState(currentGeneration: Long) {
        while (currentCoroutineContext().isActive && currentGeneration == synchronized(lock) { generation }) {
            refreshDaemonPresence()
            refreshMachineDirectory()
            val cards = _state.value.cards
            val chats = _state.value.chats
            val activeCards = (cards + chats).filter { isActiveRuntime(it.runtime) }
                .filter { _state.value.projectHosts[it.projectId]?.daemonId == repository.activeEndpoint.daemonId }
            val conversations = coroutineScope {
                activeCards.map { card ->
                    async {
                        runCatching { repository.conversation(card.id, limit = 4) }.getOrNull()?.let { card.id to it }
                    }
                }.mapNotNull { it.await() }.toMap()
            }
            _state.update {
                it.copy(
                    phase = ConnectionPhase.CONNECTED,
                    connectionInterruptedAtMs = null,
                    activeConversations = conversations,
                    error = null,
                )
            }
            delay(MACHINE_POLL_INTERVAL_MS)
        }
    }

    private suspend fun refreshDaemonPresence() {
        val directory = repository.daemons()
        val byID = directory.daemonsList.associateBy { it.id }
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
                        endpoint.online && endpoint.id == current.endpoint?.id && current.phase == ConnectionPhase.CONNECTED -> row.copy(
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
        val machines = discoveredEndpoints.filter(NauclioEndpoint::online)
        if (machines.isEmpty()) return
        val snapshots = coroutineScope {
            machines.map { machine ->
                async {
                    runCatching {
                        val root = repository.relayState(machine)
                        val projects = root.projectsList.filterNot(Project::getArchived)
                        val projectStates = projects.map { project ->
                            async { repository.relayState(machine, GetStateRequest.newBuilder().setProjectId(project.id).setLimit(500).build()) }
                        }.map { it.await() }
                        val chats = repository.relayChats(machine, includeArchived = includeArchivedChats).chatsList
                            .filter { includeArchivedChats || !it.archived }
                        MachineSnapshot(machine, projects, projectStates.flatMap { it.boardsList }, projectStates.flatMap { it.cardsList }, chats)
                    }.getOrNull()
                }
            }.mapNotNull { it.await() }
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
            current.copy(
                projects = projects,
                projectHosts = hosts,
                boards = (current.boards.filter { it.projectId in retainedProjectIDs } + snapshots.flatMap { it.boards }).distinctBy { it.id },
                cards = (current.cards.filter { it.projectId in retainedProjectIDs } + snapshots.flatMap { it.cards }).distinctBy { it.id },
                chats = (current.chats.filter { it.projectId in retainedProjectIDs } + snapshots.flatMap { it.chats }).distinctBy { it.id },
                error = null,
            )
        }
    }

    private fun applyGlobalSnapshot(snapshot: GlobalSnapshot) {
        val (entries, resolvedConversationIds) = synchronized(outbox) {
            outbox.toList() to conversationIdResolutions.toMap()
        }
        val projects = snapshot.state.projectsList
        val selectedProject = synchronized(lock) { selectedProjectId }
            .takeIf { id -> projects.any { it.id == id } }
            ?: projects.firstOrNull()?.id.orEmpty()
        if (selectedProject.isNotBlank()) synchronized(lock) { selectedProjectId = selectedProject }

        val cards = snapshot.state.cardsList.toMutableList()
        val chats = snapshot.state.chatsList.toMutableList()
        val conversations = snapshot.conversationsList.associateBy { it.detail.card.id }.toMutableMap()
        entries.forEach { entry ->
            when (entry.kind) {
                OutboxKind.CREATE_CARD, OutboxKind.CREATE_CHAT -> {
                    val request = runCatching { CreateConversationRequest.parseFrom(entry.request) }.getOrNull() ?: return@forEach
                    val card = Card.newBuilder()
                        .setId(entry.optimisticId)
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
                    if (conversations[card.id] == null) {
                        val detail = com.dbpprt.nauclio.v1.CardDetail.newBuilder()
                            .setCard(card)
                            .also { builder -> projects.firstOrNull { it.id == card.projectId }?.let(builder::setProject) }
                            .also { builder -> snapshot.state.boardsList.firstOrNull { it.id == card.boardId }?.let(builder::setBoard) }
                            .build()
                        val conversationBuilder = com.dbpprt.nauclio.v1.Conversation.newBuilder()
                            .setCardId(card.id)
                            .setStatus("pending")
                        if (entry.kind != OutboxKind.CREATE_CHAT || request.deferStart) {
                            conversationBuilder.addAllDraftAttachments(request.attachmentsList)
                        }
                        if (entry.kind == OutboxKind.CREATE_CHAT) {
                            optimisticChatMessage(request, "${entry.optimisticId}_initial")
                                ?.let(conversationBuilder::addMessages)
                        }
                        val conversation = conversationBuilder.build()
                        conversations[card.id] = ConversationSnapshot.newBuilder()
                            .setDetail(detail)
                            .setConversation(conversation)
                            .build()
                    }
                }
                OutboxKind.SEND_MESSAGE -> {
                    val request = runCatching { SendMessageRequest.parseFrom(entry.request) }.getOrNull() ?: return@forEach
                    val current = conversations[request.cardId] ?: return@forEach
                    if (current.conversation.messagesList.none { it.id == entry.optimisticId }) {
                        val message = com.dbpprt.nauclio.v1.UiMessage.newBuilder()
                            .setId(entry.optimisticId)
                            .setRole("user")
                            .addAllParts(request.partsList)
                            .build()
                        conversations[request.cardId] = current.toBuilder()
                            .setConversation(current.conversation.toBuilder().addMessages(message))
                            .build()
                    }
                }
            }
        }

        val selectedState = snapshot.state.toBuilder()
            .clearBoards()
            .clearCards()
            .clearChats()
            .addAllBoards(snapshot.state.boardsList.filter { it.projectId == selectedProject })
            .addAllCards(cards.filter { it.projectId == selectedProject })
            .addAllChats(chats.filter { it.projectId == selectedProject })
            .also { builder -> projects.firstOrNull { it.id == selectedProject }?.let(builder::setProject) }
            .build()
        val activeEndpoint = _state.value.endpoint
        val hosts = _state.value.projectHosts.toMutableMap()
        if (activeEndpoint?.daemonId != null) {
            projects.forEach { project ->
                hosts[project.id] = ProjectHost(activeEndpoint.id, activeEndpoint.daemonId, activeEndpoint.label, activeEndpoint.online)
            }
        }
        _state.update { current ->
            current.copy(
                selectedState = selectedState,
                projects = projects,
                projectHosts = hosts,
                boards = snapshot.state.boardsList,
                cards = cards,
                chats = chats.sortedByDescending { it.lastActivityAt.ifBlank { it.updatedAt } },
                activeConversations = conversations,
                schedules = snapshot.schedulesList,
                scheduleRuns = snapshot.scheduleRunsList,
                pendingCardIds = entries.filter { it.kind != OutboxKind.SEND_MESSAGE }.mapTo(mutableSetOf()) { it.optimisticId },
                pendingMessageIds = entries.filter { it.kind == OutboxKind.SEND_MESSAGE }.mapTo(mutableSetOf()) { it.optimisticId },
                acceptedOutboxIds = entries.filter { it.serverId != null }.mapTo(mutableSetOf()) { it.optimisticId },
                failedOutboxIds = entries.filter { it.lastError != null }.mapTo(mutableSetOf()) { it.optimisticId },
                resolvedConversationIds = resolvedConversationIds,
            )
        }
    }

    private fun reconcileOutbox(snapshot: GlobalSnapshot) {
        val cardIds = (snapshot.state.cardsList + snapshot.state.chatsList).mapTo(hashSetOf()) { it.id }
        val messageIds = snapshot.conversationsList.flatMapTo(hashSetOf()) { conversation ->
            conversation.conversation.messagesList.map { it.id }
        }
        val changed = synchronized(outbox) {
            outbox.removeAll { entry ->
                val serverId = entry.serverId ?: return@removeAll false
                if (entry.kind == OutboxKind.SEND_MESSAGE) serverId in messageIds else serverId in cardIds
            }
        }
        if (changed) syncStore.saveOutbox(synchronized(outbox) { outbox.toList() })
    }

    suspend fun enqueueConversation(request: CreateConversationRequest, chat: Boolean): Card {
        val commandId = UUID.randomUUID().toString().lowercase()
        val stable = request.toBuilder().setClientId(syncStore.clientId).setCommandId(commandId).build()
        val optimisticId = "local_${UUID.randomUUID().toString().replace("-", "").lowercase()}"
        val targetDaemon = _state.value.projectHosts[stable.projectId]?.daemonId
            ?: repository.activeEndpoint.daemonId
            ?: repository.activeEndpoint.id
        synchronized(outbox) {
            outbox += AndroidOutboxEntry(
                commandId = commandId,
                clientId = syncStore.clientId,
                daemonId = targetDaemon,
                kind = if (chat) OutboxKind.CREATE_CHAT else OutboxKind.CREATE_CARD,
                request = stable.toByteArray(),
                optimisticId = optimisticId,
            )
            syncStore.saveOutbox(outbox)
        }
        globalSnapshot?.let(::applyGlobalSnapshot)
        return _state.value.let { state ->
            (if (chat) state.chats else state.cards).first { it.id == optimisticId }
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
        val targetDaemon = repository.activeEndpoint.daemonId ?: repository.activeEndpoint.id
        synchronized(outbox) {
            outbox += AndroidOutboxEntry(
                commandId = commandId,
                clientId = syncStore.clientId,
                daemonId = targetDaemon,
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
            val activeDaemon = repository.activeEndpoint.daemonId ?: repository.activeEndpoint.id
            val entry = synchronized(outbox) { outbox.firstOrNull { it.daemonId == activeDaemon && it.serverId == null } }
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

    private fun updateEndpoint(endpoint: NauclioEndpoint, phase: EndpointPhase, detail: String, latencyMs: Long?) {
        _state.update { current ->
            current.copy(
                endpointConnections = current.endpointConnections.map {
                    if (it.id == endpoint.id) it.copy(phase = phase, detail = detail, latencyMs = latencyMs) else it
                },
            )
        }
    }

    private fun configuredEndpointRows(): List<EndpointConnection> = synchronized(lock) { configuredEndpoints.toList() }.map {
        EndpointConnection(it.id, it.label, it.address)
    }

    private fun endpointRow(endpoint: NauclioEndpoint): EndpointConnection = EndpointConnection(
        id = endpoint.id,
        label = endpoint.label,
        address = endpoint.address,
        phase = if (endpoint.online) EndpointPhase.PENDING else EndpointPhase.FAILED,
        detail = if (endpoint.online) "Available" else "Offline",
        online = endpoint.online,
        daemonId = endpoint.daemonId,
    )

    private fun loadEndpoints(): List<NauclioEndpoint> {
        val encoded = preferences.getString(KEY_ENDPOINTS, null) ?: return NAUCLIO_ENDPOINTS
        return runCatching {
            val array = JSONArray(encoded)
            val loaded = buildList {
                for (index in 0 until array.length()) {
                    val item = array.getJSONObject(index)
                    add(
                        NauclioEndpoint(
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
                    NAUCLIO_ENDPOINTS.firstOrNull { it.credentialId == endpoint.credentialId }
                        ?: endpoint.copy(id = "gateway_$index", label = endpoint.host, daemonId = null)
                }
            }.distinctBy { it.credentialId }
            if (origins != loaded) persistEndpoints(origins)
            origins
        }.getOrDefault(NAUCLIO_ENDPOINTS)
    }

    private fun persistEndpoints(endpoints: List<NauclioEndpoint>) {
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
            ?: "Nauclio connection failed"
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
        private const val PREFERENCES = "nauclio_connection"
        private const val KEY_DESIRED_CONNECTED = "desired_connected"
        private const val KEY_BACKGROUND_SYNC = "background_sync"
        private const val KEY_ENDPOINTS = "endpoints"
        private const val KEY_AUTH_VERIFIER = "auth_verifier"
        private const val KEY_AUTH_ENDPOINT = "auth_endpoint"
        private const val KEY_PREFERRED_DAEMON = "preferred_daemon"
        private const val MACHINE_POLL_INTERVAL_MS = 5_000L
        private const val MAX_RESOLVED_CONVERSATIONS = 256
    }
}

private data class MachineSnapshot(
    val endpoint: NauclioEndpoint,
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

internal fun daemonForProjectSelection(
    projectId: String,
    currentDaemonId: String?,
    hosts: Map<String, ProjectHost>,
): String? = hosts[projectId]?.daemonId?.takeUnless { it == currentDaemonId }

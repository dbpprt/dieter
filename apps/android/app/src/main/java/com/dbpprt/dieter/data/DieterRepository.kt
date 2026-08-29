package com.dbpprt.dieter.data

import android.content.Context
import com.dbpprt.dieter.gateway.v1.DaemonRef
import com.dbpprt.dieter.gateway.v1.DaemonPresenceUpdate
import com.dbpprt.dieter.gateway.v1.ExchangeDaemonTokenRequest
import com.dbpprt.dieter.gateway.v1.GatewayServiceGrpcKt
import com.dbpprt.dieter.gateway.v1.ListDaemonsResponse
import com.dbpprt.dieter.gateway.v1.WatchDaemonsRequest
import com.dbpprt.dieter.v1.AddCommentRequest
import com.dbpprt.dieter.v1.ArchiveCardRequest
import com.dbpprt.dieter.v1.ArchiveProjectRequest
import com.dbpprt.dieter.v1.Board
import com.dbpprt.dieter.v1.BoardRef
import com.dbpprt.dieter.v1.DieterServiceGrpcKt
import com.dbpprt.dieter.v1.Card
import com.dbpprt.dieter.v1.CardDetail
import com.dbpprt.dieter.v1.CardsResponse
import com.dbpprt.dieter.v1.ChatsResponse
import com.dbpprt.dieter.v1.Comment
import com.dbpprt.dieter.v1.ConversationSnapshot
import com.dbpprt.dieter.v1.CreateBoardLabelRequest
import com.dbpprt.dieter.v1.CreateBoardRequest
import com.dbpprt.dieter.v1.CreateConversationRequest
import com.dbpprt.dieter.v1.CreateFileRequest
import com.dbpprt.dieter.v1.CreateProjectRequest
import com.dbpprt.dieter.v1.CreateProjectResponse
import com.dbpprt.dieter.v1.CreateTerminalRequest
import com.dbpprt.dieter.v1.DeleteBoardLabelRequest
import com.dbpprt.dieter.v1.DeleteFileRequest
import com.dbpprt.dieter.v1.DirectoryListing
import com.dbpprt.dieter.v1.FileDocument
import com.dbpprt.dieter.v1.FileEntry
import com.dbpprt.dieter.v1.FileList
import com.dbpprt.dieter.v1.ForkChatRequest
import com.dbpprt.dieter.v1.GetCardRequest
import com.dbpprt.dieter.v1.GetConversationRequest
import com.dbpprt.dieter.v1.GetStateRequest
import com.dbpprt.dieter.v1.GetToolOutputRequest
import com.dbpprt.dieter.v1.HarnessCatalog
import com.dbpprt.dieter.v1.HealthResponse
import com.dbpprt.dieter.v1.ListChatsRequest
import com.dbpprt.dieter.v1.ListDirectoriesRequest
import com.dbpprt.dieter.v1.ListFilesRequest
import com.dbpprt.dieter.v1.ListScheduleRunsRequest
import com.dbpprt.dieter.v1.ListSchedulesRequest
import com.dbpprt.dieter.v1.ListTerminalsRequest
import com.dbpprt.dieter.v1.AddChangeCommentRequest
import com.dbpprt.dieter.v1.ChangeComment
import com.dbpprt.dieter.v1.ChangeCommentsResponse
import com.dbpprt.dieter.v1.Changeset
import com.dbpprt.dieter.v1.ConversationRef
import com.dbpprt.dieter.v1.FileDiff
import com.dbpprt.dieter.v1.GetChangesetRequest
import com.dbpprt.dieter.v1.GetDiffRequest
import com.dbpprt.dieter.v1.GitOperation
import com.dbpprt.dieter.v1.GitOperationFrame
import com.dbpprt.dieter.v1.GitOperationRef
import com.dbpprt.dieter.v1.ListChangeCommentsRequest
import com.dbpprt.dieter.v1.MessagePart
import com.dbpprt.dieter.v1.MoveCardRequest
import com.dbpprt.dieter.v1.MoveFileRequest
import com.dbpprt.dieter.v1.MoveFileResponse
import com.dbpprt.dieter.v1.ProjectRef
import com.dbpprt.dieter.v1.SCMCapabilities
import com.dbpprt.dieter.v1.StartGitOperationRequest
import com.dbpprt.dieter.v1.UpdateConversationWorkspaceRequest
import com.dbpprt.dieter.v1.WatchGitOperationRequest
import com.dbpprt.dieter.v1.Workspace
import com.dbpprt.dieter.v1.WorkspacesResponse
import com.dbpprt.dieter.v1.PinChatRequest
import com.dbpprt.dieter.v1.PreviewScheduleRequest
import com.dbpprt.dieter.v1.Project
import com.dbpprt.dieter.v1.ProjectsResponse
import com.dbpprt.dieter.v1.ReadFileRequest
import com.dbpprt.dieter.v1.RenameCardRequest
import com.dbpprt.dieter.v1.RuntimeStatus
import com.dbpprt.dieter.v1.ResizeTerminalRequest
import com.dbpprt.dieter.v1.SaveFileRequest
import com.dbpprt.dieter.v1.SaveScheduleRequest
import com.dbpprt.dieter.v1.Schedule
import com.dbpprt.dieter.v1.SchedulePreview
import com.dbpprt.dieter.v1.ScheduleRef
import com.dbpprt.dieter.v1.ScheduleRun
import com.dbpprt.dieter.v1.ScheduleRunsResponse
import com.dbpprt.dieter.v1.SchedulesResponse
import com.dbpprt.dieter.v1.SendMessageRequest
import com.dbpprt.dieter.v1.SendMessageResponse
import com.dbpprt.dieter.v1.SetBoardArchivePolicyRequest
import com.dbpprt.dieter.v1.SetCardLabelsRequest
import com.dbpprt.dieter.v1.SetScheduleEnabledRequest
import com.dbpprt.dieter.v1.Settings
import com.dbpprt.dieter.v1.SettingsOptions
import com.dbpprt.dieter.v1.State
import com.dbpprt.dieter.v1.StartCardRequest
import com.dbpprt.dieter.v1.StartCardResponse
import com.dbpprt.dieter.v1.SyncCursor
import com.dbpprt.dieter.v1.SyncFrame
import com.dbpprt.dieter.v1.SyncRequest
import com.dbpprt.dieter.v1.Terminal
import com.dbpprt.dieter.v1.TerminalFrame
import com.dbpprt.dieter.v1.TerminalInputRequest
import com.dbpprt.dieter.v1.TerminalRef
import com.dbpprt.dieter.v1.TerminalsResponse
import com.dbpprt.dieter.v1.ToolOutput
import com.dbpprt.dieter.v1.UpdateCardRequest
import com.dbpprt.dieter.v1.UpdateProjectRequest
import com.dbpprt.dieter.v1.UpdateSettingsRequest
import com.dbpprt.dieter.v1.WatchConversationRequest
import com.dbpprt.dieter.v1.WatchStateRequest
import com.dbpprt.dieter.v1.WatchTerminalRequest
import com.dbpprt.dieter.v1.RenameTerminalRequest
import com.google.protobuf.Empty
import io.grpc.ManagedChannel
import io.grpc.Metadata
import io.grpc.Status
import io.grpc.stub.MetadataUtils
import io.grpc.android.AndroidChannelBuilder
import io.grpc.okhttp.OkHttpChannelBuilder
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.flow
import java.io.ByteArrayInputStream
import java.security.KeyStore
import java.security.cert.CertificateFactory
import java.security.cert.X509Certificate
import java.time.Instant
import java.util.concurrent.TimeUnit
import javax.net.ssl.SSLContext
import javax.net.ssl.TrustManagerFactory

const val DIETER_LOCAL_HOST = "127.0.0.1"
const val DIETER_LOCAL_PORT = 4242
const val DIETER_LOCAL_ENDPOINT = "$DIETER_LOCAL_HOST:$DIETER_LOCAL_PORT"
const val DIETER_API_VERSION = "2"

data class DieterEndpoint(
    val id: String,
    val label: String,
    val host: String,
    val port: Int = DIETER_LOCAL_PORT,
    val secure: Boolean = false,
    val daemonId: String? = null,
    val online: Boolean = true,
    val lastSeenAt: String = "",
    val version: String = "",
) {
    val address: String get() = "${if (secure) "https" else "http"}://$host:$port"
    val credentialId: String get() = address
}

val DIETER_ENDPOINTS = listOf(
    DieterEndpoint("gateway", "Dieter Gateway", "board.dbpprt.com", 443, true),
)

fun dieterEndpointFromAddress(id: String, label: String, address: String): DieterEndpoint {
    require(id.isNotBlank()) { "Connection ID is missing" }
    require(label.trim().isNotBlank()) { "Enter a connection name" }
    var value = address.trim()
    require(value.isNotBlank()) { "Enter a host or host:port" }
    val secure = value.startsWith("https://", ignoreCase = true) || value.startsWith("grpcs://", ignoreCase = true)
    value = when {
        value.startsWith("https://", ignoreCase = true) -> value.substring(8)
        value.startsWith("grpcs://", ignoreCase = true) -> value.substring(8)
        value.startsWith("http://", ignoreCase = true) -> value.substring(7)
        value.startsWith("grpc://", ignoreCase = true) -> value.substring(7)
        else -> value
    }
    require('/' !in value) { "Use a host and port without a path" }

    val (host, portText) = if (value.startsWith("[")) {
        val closing = value.indexOf(']')
        require(closing > 1) { "Invalid IPv6 address" }
        val host = value.substring(1, closing)
        val suffix = value.substring(closing + 1)
        require(suffix.isEmpty() || suffix.startsWith(':')) { "Invalid address" }
        host to suffix.removePrefix(":").ifBlank { DIETER_LOCAL_PORT.toString() }
    } else {
        require(value.count { it == ':' } <= 1) { "Wrap IPv6 addresses in brackets" }
        val separator = value.lastIndexOf(':')
        if (separator > 0) value.substring(0, separator) to value.substring(separator + 1)
        else value to if (secure) "443" else DIETER_LOCAL_PORT.toString()
    }
    require(host.isNotBlank()) { "Enter a host" }
    val port = portText.toIntOrNull()
    require(port != null && port in 1..65535) { "Port must be between 1 and 65535" }
    return DieterEndpoint(id.trim(), label.trim(), host.trim(), port, secure)
}

/** The complete native client boundary for the shared dieter.v1 service. */
interface DieterRepository {
    val endpoints: List<DieterEndpoint>
    val activeEndpoint: DieterEndpoint
    fun replaceEndpoints(endpoints: List<DieterEndpoint>)
    fun selectEndpoint(endpoint: DieterEndpoint)
    fun setAccessToken(endpoint: DieterEndpoint, token: String?)
    suspend fun daemons(): ListDaemonsResponse
    fun watchDaemons(): Flow<DaemonPresenceUpdate>
    suspend fun relayState(endpoint: DieterEndpoint, filter: GetStateRequest = GetStateRequest.getDefaultInstance()): State
    suspend fun relayChats(endpoint: DieterEndpoint, includeArchived: Boolean = false): ChatsResponse
    suspend fun prepareDaemon(): String
    fun directRefreshAtMillis(): Long?
    fun dataRoute(): String = "unknown"
    suspend fun health(timeoutSeconds: Long = 15): HealthResponse
    suspend fun runtimeStatus(): RuntimeStatus
    suspend fun state(filter: GetStateRequest = GetStateRequest.getDefaultInstance()): State
    fun watchState(filter: GetStateRequest = GetStateRequest.getDefaultInstance()): Flow<State>
    fun watchSync(after: SyncCursor? = null, conversationLimit: Int = 0, recentConversationLimit: Int = 0): Flow<SyncFrame>
    suspend fun harnesses(): HarnessCatalog
    suspend fun settings(): Settings
    suspend fun settingsOptions(): SettingsOptions
    suspend fun updateSettings(settings: Settings): Settings

    suspend fun listDirectories(path: String = ""): DirectoryListing
    suspend fun createProject(request: CreateProjectRequest): CreateProjectResponse
    suspend fun updateProject(request: UpdateProjectRequest): Project
    suspend fun archiveProject(projectId: String, archived: Boolean): Project
    suspend fun archivedProjects(): ProjectsResponse
    suspend fun createBoard(request: CreateBoardRequest): Board
    suspend fun setBoardArchivePolicy(boardId: String, policy: String): Board
    suspend fun archivedCards(boardId: String): CardsResponse
    suspend fun createBoardLabel(boardId: String, name: String, color: String): Board
    suspend fun deleteBoardLabel(boardId: String, labelId: String): Board

    suspend fun createConversation(request: CreateConversationRequest, chat: Boolean): Card
    suspend fun forkChat(sourceCardId: String, messageId: String = "", title: String = ""): Card
    suspend fun chats(includeArchived: Boolean = true): ChatsResponse
    suspend fun card(cardId: String): CardDetail
    suspend fun conversation(cardId: String, limit: Int = 30, before: Int? = null): ConversationSnapshot
    fun watchConversation(cardId: String, limit: Int = 30): Flow<ConversationSnapshot>
    suspend fun toolOutput(cardId: String, messageId: String, toolCallId: String, revision: String = ""): ToolOutput
    suspend fun sendMessage(
        cardId: String,
        parts: List<MessagePart>,
        provider: String = "",
        model: String = "",
        effort: String = "",
    ): SendMessageResponse
    suspend fun sendMessage(request: SendMessageRequest): SendMessageResponse
    suspend fun addComment(cardId: String, text: String, name: String = "You"): Comment
    suspend fun moveCard(cardId: String, lane: String, position: Long? = null): Card
    suspend fun startCard(request: StartCardRequest): StartCardResponse
    suspend fun setCardLabels(cardId: String, labelIds: List<String>): Card
    suspend fun cancelCard(cardId: String)
    suspend fun renameCard(cardId: String, title: String): Card
    suspend fun updateCard(cardId: String, title: String, initialPrompt: String): Card
    suspend fun archiveCard(cardId: String, archived: Boolean): Card
    suspend fun pinChat(cardId: String, pinned: Boolean): Card

    suspend fun updateConversationWorkspace(cardId: String, mode: String, branch: String, baseBranch: String): Card
    suspend fun workspace(cardId: String): Workspace
    suspend fun projectWorkspaces(projectId: String): WorkspacesResponse
    suspend fun changeset(cardId: String): Changeset
    suspend fun fileDiff(request: GetDiffRequest): FileDiff
    suspend fun commitDiff(request: GetDiffRequest): FileDiff
    suspend fun addChangeComment(request: AddChangeCommentRequest): ChangeComment
    suspend fun changeComments(cardId: String, revision: String = ""): ChangeCommentsResponse
    suspend fun scmCapabilities(cardId: String): SCMCapabilities
    suspend fun startGitOperation(cardId: String, kind: String, expectedRevision: String, parameters: Map<String, String> = emptyMap()): GitOperation
    suspend fun gitOperation(operationId: String): GitOperation
    fun watchGitOperation(operationId: String, afterSequence: Long = 0): Flow<GitOperationFrame>
    suspend fun cancelGitOperation(operationId: String): GitOperation

    suspend fun files(projectId: String, path: String = "", showHidden: Boolean = false, cardId: String = ""): FileList
    suspend fun readFile(projectId: String, path: String, cardId: String = ""): FileDocument
    suspend fun saveFile(projectId: String, path: String, content: String, revision: String, cardId: String = ""): FileDocument
    suspend fun createFile(projectId: String, path: String, kind: String, content: String = "", cardId: String = ""): FileEntry
    suspend fun moveFile(projectId: String, source: String, destination: String): MoveFileResponse
    suspend fun deleteFile(projectId: String, path: String, recursive: Boolean = false)

    suspend fun terminals(projectId: String = ""): TerminalsResponse
    suspend fun createTerminal(request: CreateTerminalRequest): Terminal
    fun watchTerminal(terminalId: String, afterSequence: Long = 0): Flow<TerminalFrame>
    suspend fun writeTerminal(terminalId: String, data: ByteArray): Terminal
    suspend fun resizeTerminal(terminalId: String, columns: Int, rows: Int): Terminal
    suspend fun renameTerminal(terminalId: String, name: String): Terminal
    suspend fun closeTerminal(terminalId: String)

    suspend fun schedules(projectId: String): SchedulesResponse
    suspend fun previewSchedule(cron: String, timezone: String, count: Int = 5): SchedulePreview
    suspend fun saveSchedule(scheduleId: String = "", request: SaveScheduleRequest): Schedule
    suspend fun runSchedule(scheduleId: String): ScheduleRun
    suspend fun setScheduleEnabled(scheduleId: String, enabled: Boolean): Schedule
    suspend fun scheduleRuns(scheduleId: String, limit: Int = 10): ScheduleRunsResponse
    suspend fun deleteSchedule(scheduleId: String)

    fun reconnect()
    fun close()
}

class GrpcDieterRepository(context: Context) : DieterRepository {
    private val appContext = context.applicationContext
    private val lock = Any()
    private var channel: ManagedChannel? = null
    private var gatewayChannel: ManagedChannel? = null
    private var directAccessToken: String? = null
    private var directRefreshAt: Long? = null
    private var configuredEndpoints = DIETER_ENDPOINTS
    private var selectedEndpoint = DIETER_ENDPOINTS.first()
    private val credentials = DieterCredentialStore(appContext)

    override val endpoints: List<DieterEndpoint>
        get() = synchronized(lock) { configuredEndpoints }

    override val activeEndpoint: DieterEndpoint
        get() = synchronized(lock) { selectedEndpoint }

    override fun replaceEndpoints(endpoints: List<DieterEndpoint>) {
        require(endpoints.isNotEmpty()) { "At least one Dieter connection is required" }
        synchronized(lock) {
            val replacement = endpoints.firstOrNull { it.id == selectedEndpoint.id } ?: endpoints.first()
            if (replacement != selectedEndpoint) {
                channel?.shutdownNow()
                channel = null
                directAccessToken = null
                directRefreshAt = null
            }
            if (replacement.credentialId != selectedEndpoint.credentialId) {
                gatewayChannel?.shutdownNow()
                gatewayChannel = null
            }
            configuredEndpoints = endpoints.toList()
            selectedEndpoint = replacement
        }
    }

    override fun selectEndpoint(endpoint: DieterEndpoint) {
        synchronized(lock) {
            if (selectedEndpoint == endpoint && channel?.isShutdown == false && channel?.isTerminated == false) return
            channel?.shutdownNow()
            channel = null
            directAccessToken = null
            directRefreshAt = null
            if (selectedEndpoint.credentialId != endpoint.credentialId) {
                gatewayChannel?.shutdownNow()
                gatewayChannel = null
            }
            selectedEndpoint = endpoint
        }
    }

    override fun setAccessToken(endpoint: DieterEndpoint, token: String?) {
        credentials.set(endpoint.credentialId, token)
        if (endpoint.credentialId == activeEndpoint.credentialId) reconnect()
    }

    private fun channel(): ManagedChannel = synchronized(lock) {
        if (channel == null || channel?.isShutdown == true || channel?.isTerminated == true) {
            val builder = AndroidChannelBuilder.forAddress(selectedEndpoint.host, selectedEndpoint.port)
                .context(appContext)
                .maxInboundMessageSize(16 * 1024 * 1024)
                .keepAliveTime(30, TimeUnit.SECONDS)
                .keepAliveTimeout(5, TimeUnit.SECONDS)
                .keepAliveWithoutCalls(true)
            if (!selectedEndpoint.secure) builder.usePlaintext()
            channel = builder.build()
        }
        requireNotNull(channel)
    }

    private fun gatewayChannel(): ManagedChannel = synchronized(lock) {
        if (gatewayChannel == null || gatewayChannel?.isShutdown == true || gatewayChannel?.isTerminated == true) {
            val builder = AndroidChannelBuilder.forAddress(selectedEndpoint.host, selectedEndpoint.port)
                .context(appContext)
                .maxInboundMessageSize(16 * 1024 * 1024)
                .keepAliveTime(30, TimeUnit.SECONDS)
                .keepAliveTimeout(5, TimeUnit.SECONDS)
                .keepAliveWithoutCalls(true)
            if (!selectedEndpoint.secure) builder.usePlaintext()
            gatewayChannel = builder.build()
        }
        requireNotNull(gatewayChannel)
    }

    private fun metadata(token: String, daemonId: String? = null): Metadata = Metadata().apply {
        put(Metadata.Key.of("authorization", Metadata.ASCII_STRING_MARSHALLER), "Bearer $token")
        daemonId?.let { put(Metadata.Key.of("x-dieter-daemon-id", Metadata.ASCII_STRING_MARSHALLER), it) }
    }

    private fun authenticated(stub: DieterServiceGrpcKt.DieterServiceCoroutineStub): DieterServiceGrpcKt.DieterServiceCoroutineStub {
        val direct = synchronized(lock) { directAccessToken }
        val token = direct ?: credentials.get(activeEndpoint.credentialId) ?: return stub
        val daemonId = if (direct == null) activeEndpoint.daemonId else null
        return stub.withInterceptors(MetadataUtils.newAttachHeadersInterceptor(metadata(token, daemonId)))
    }

    private fun gatewayStub(): GatewayServiceGrpcKt.GatewayServiceCoroutineStub {
        val stub = GatewayServiceGrpcKt.GatewayServiceCoroutineStub(gatewayChannel()).withDeadlineAfter(15, TimeUnit.SECONDS)
        val token = credentials.get(activeEndpoint.credentialId) ?: return stub
        return stub.withInterceptors(MetadataUtils.newAttachHeadersInterceptor(metadata(token)))
    }

    private fun gatewayStreamingStub(): GatewayServiceGrpcKt.GatewayServiceCoroutineStub {
        val stub = GatewayServiceGrpcKt.GatewayServiceCoroutineStub(gatewayChannel())
        val token = credentials.get(activeEndpoint.credentialId) ?: return stub
        return stub.withInterceptors(MetadataUtils.newAttachHeadersInterceptor(metadata(token)))
    }

    override suspend fun daemons(): ListDaemonsResponse = gatewayStub().listDaemons(Empty.getDefaultInstance())

    override fun watchDaemons(): Flow<DaemonPresenceUpdate> = flow {
        gatewayStreamingStub().watchDaemons(
            WatchDaemonsRequest.newBuilder().setHeartbeatSeconds(15).build(),
        ).collect(::emit)
    }

    override suspend fun relayState(endpoint: DieterEndpoint, filter: GetStateRequest): State = withRelay(endpoint) {
        getState(filter)
    }

    override suspend fun relayChats(endpoint: DieterEndpoint, includeArchived: Boolean): ChatsResponse = withRelay(endpoint) {
        listChats(ListChatsRequest.newBuilder().setIncludeArchived(includeArchived).build())
    }

    private suspend fun <T> withRelay(
        endpoint: DieterEndpoint,
        operation: suspend DieterServiceGrpcKt.DieterServiceCoroutineStub.() -> T,
    ): T {
        requireNotNull(endpoint.daemonId) { "No routed Dieter machine is available" }
        val builder = AndroidChannelBuilder.forAddress(endpoint.host, endpoint.port)
            .context(appContext)
            .maxInboundMessageSize(16 * 1024 * 1024)
        if (!endpoint.secure) builder.usePlaintext()
        val relay = builder.build()
        return try {
            var stub = DieterServiceGrpcKt.DieterServiceCoroutineStub(relay).withDeadlineAfter(15, TimeUnit.SECONDS)
            credentials.get(endpoint.credentialId)?.let { token ->
                stub = stub.withInterceptors(MetadataUtils.newAttachHeadersInterceptor(metadata(token, endpoint.daemonId)))
            }
            stub.operation()
        } finally {
            relay.shutdownNow()
        }
    }

    override suspend fun prepareDaemon(): String {
        val endpoint = activeEndpoint
        val daemonId = endpoint.daemonId ?: error("No routed Dieter machine is available")
        synchronized(lock) {
            channel?.shutdownNow()
            channel = null
            directAccessToken = null
            directRefreshAt = null
        }
        val route = gatewayStub().resolveDaemonRoute(DaemonRef.newBuilder().setDaemonId(daemonId).build())
        if (route.directCandidatesCount > 0) {
            val access = gatewayStub().exchangeDaemonToken(ExchangeDaemonTokenRequest.newBuilder().setDaemonId(daemonId).build())
            require(access.tokenType == "Bearer") { "Gateway returned an unsupported daemon token" }
            // Probe every candidate concurrently so reconnecting costs one
            // health round-trip instead of one per unreachable address.
            val reachable = coroutineScope {
                route.directCandidatesList.map { candidate ->
                    async {
                        val direct = runCatching {
                            directChannel(candidate.host, candidate.port, daemonId, route.daemonCaPem.toByteArray())
                        }.getOrNull() ?: return@async null
                        val stub = DieterServiceGrpcKt.DieterServiceCoroutineStub(direct)
                            .withInterceptors(MetadataUtils.newAttachHeadersInterceptor(metadata(access.accessToken)))
                            .withDeadlineAfter(2, TimeUnit.SECONDS)
                        val healthy = runCatching { stub.health(Empty.getDefaultInstance()).status == "ok" }.getOrDefault(false)
                        if (healthy) candidate to direct else null.also { direct.shutdownNow() }
                    }
                }.awaitAll()
            }.filterNotNull()
            val chosen = reachable.maxByOrNull { (candidate, _) -> candidate.priority }
            reachable.forEach { (candidate, direct) -> if (candidate !== chosen?.first) direct.shutdownNow() }
            if (chosen != null) {
                val (candidate, direct) = chosen
                if (activeEndpoint.id == endpoint.id) {
                    val refreshAt = runCatching { Instant.parse(access.expiresAt).toEpochMilli() - 30_000 }.getOrNull()
                    synchronized(lock) {
                        channel = direct
                        directAccessToken = access.accessToken
                        directRefreshAt = refreshAt
                    }
                    return "Direct · ${candidate.host}:${candidate.port}"
                }
                direct.shutdownNow()
            }
        }
        if (!route.relayAvailable) throw Status.UNAVAILABLE.withDescription("Dieter daemon is offline").asRuntimeException()
        return "Gateway relay"
    }

    override fun directRefreshAtMillis(): Long? = synchronized(lock) { directRefreshAt }

    override fun dataRoute(): String = synchronized(lock) {
        if (directAccessToken != null) "local" else "gateway"
    }

    private fun directChannel(host: String, port: Int, daemonId: String, daemonCA: ByteArray): ManagedChannel {
        val certificate = CertificateFactory.getInstance("X.509").generateCertificate(ByteArrayInputStream(daemonCA))
        val keyStore = KeyStore.getInstance(KeyStore.getDefaultType()).apply {
            load(null)
            setCertificateEntry("dieter-daemon-ca", certificate)
        }
        val managers = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm()).apply { init(keyStore) }
        val ssl = SSLContext.getInstance("TLS").apply { init(null, managers.trustManagers, null) }
        return OkHttpChannelBuilder.forAddress(host, port)
            .sslSocketFactory(ssl.socketFactory)
            .hostnameVerifier { _, session ->
                val leaf = runCatching { session.peerCertificates.firstOrNull() as? X509Certificate }.getOrNull()
                    ?: return@hostnameVerifier false
                leaf.subjectAlternativeNames.orEmpty().any { name ->
                    name.size >= 2 && name[0] == 6 && name[1] == "spiffe://board/daemon/$daemonId"
                }
            }
            .maxInboundMessageSize(16 * 1024 * 1024)
            .keepAliveTime(30, TimeUnit.SECONDS)
            .keepAliveTimeout(5, TimeUnit.SECONDS)
            .keepAliveWithoutCalls(true)
            .build()
    }

    private fun unary(deadlineSeconds: Long = 15): DieterServiceGrpcKt.DieterServiceCoroutineStub =
        authenticated(DieterServiceGrpcKt.DieterServiceCoroutineStub(channel())).withDeadlineAfter(deadlineSeconds, TimeUnit.SECONDS)

    private fun streaming(): DieterServiceGrpcKt.DieterServiceCoroutineStub =
        authenticated(DieterServiceGrpcKt.DieterServiceCoroutineStub(channel()))

    override suspend fun health(timeoutSeconds: Long): HealthResponse = unary(timeoutSeconds).health(Empty.getDefaultInstance())

    override suspend fun runtimeStatus(): RuntimeStatus = unary().getRuntimeStatus(Empty.getDefaultInstance())

    override suspend fun state(filter: GetStateRequest): State = unary().getState(filter)

    override fun watchState(filter: GetStateRequest): Flow<State> = flow {
        streaming().watchState(
            WatchStateRequest.newBuilder().setFilter(filter).setIntervalMs(1_000).build(),
        ).collect(::emit)
    }

    override fun watchSync(after: SyncCursor?, conversationLimit: Int, recentConversationLimit: Int): Flow<SyncFrame> = flow {
        val request = SyncRequest.newBuilder()
            .setConversationLimit(conversationLimit.coerceIn(0, 100))
            .setRecentConversationLimit(recentConversationLimit.coerceIn(0, 100))
            .setHeartbeatMs(15_000)
            .also { if (after != null) it.after = after }
            .build()
        streaming().watchSync(request).collect(::emit)
    }

    override suspend fun harnesses(): HarnessCatalog = unary().getHarnesses(Empty.getDefaultInstance())

    override suspend fun settings(): Settings = unary().getSettings(Empty.getDefaultInstance())

    override suspend fun settingsOptions(): SettingsOptions = unary().getSettingsOptions(Empty.getDefaultInstance())

    override suspend fun updateSettings(settings: Settings): Settings = unary().updateSettings(
        UpdateSettingsRequest.newBuilder().setSettings(settings).build(),
    )

    override suspend fun listDirectories(path: String): DirectoryListing = unary().listDirectories(
        ListDirectoriesRequest.newBuilder().setPath(path).build(),
    )

    override suspend fun createProject(request: CreateProjectRequest): CreateProjectResponse = unary().createProject(request)

    override suspend fun updateProject(request: UpdateProjectRequest): Project = unary().updateProject(request)

    override suspend fun archiveProject(projectId: String, archived: Boolean): Project = unary().archiveProject(
        ArchiveProjectRequest.newBuilder().setProjectId(projectId).setArchived(archived).build(),
    )

    override suspend fun archivedProjects(): ProjectsResponse = unary().listArchivedProjects(Empty.getDefaultInstance())

    override suspend fun createBoard(request: CreateBoardRequest): Board = unary().createBoard(request)

    override suspend fun setBoardArchivePolicy(boardId: String, policy: String): Board = unary().setBoardArchivePolicy(
        SetBoardArchivePolicyRequest.newBuilder().setBoardId(boardId).setDoneArchivePolicy(policy).build(),
    )

    override suspend fun archivedCards(boardId: String): CardsResponse = unary().listArchivedCards(
        BoardRef.newBuilder().setBoardId(boardId).build(),
    )

    override suspend fun createBoardLabel(boardId: String, name: String, color: String): Board = unary().createBoardLabel(
        CreateBoardLabelRequest.newBuilder().setBoardId(boardId).setName(name).setColor(color).build(),
    )

    override suspend fun deleteBoardLabel(boardId: String, labelId: String): Board = unary().deleteBoardLabel(
        DeleteBoardLabelRequest.newBuilder().setBoardId(boardId).setLabelId(labelId).build(),
    )

    override suspend fun createConversation(request: CreateConversationRequest, chat: Boolean): Card =
        if (chat) unary().createChat(request) else unary().createCard(request)

    override suspend fun chats(includeArchived: Boolean): ChatsResponse = unary().listChats(
        ListChatsRequest.newBuilder().setIncludeArchived(includeArchived).build(),
    )

    override suspend fun card(cardId: String): CardDetail = unary().getCard(cardRequest(cardId))

    override suspend fun conversation(cardId: String, limit: Int, before: Int?): ConversationSnapshot {
        val request = GetConversationRequest.newBuilder().setCardId(cardId).setLimit(limit)
        if (before != null) request.before = before
        return unary().getConversation(request.build())
    }

    override fun watchConversation(cardId: String, limit: Int): Flow<ConversationSnapshot> = flow {
        var snapshot: ConversationSnapshot? = null
        streaming().watchConversation(
            WatchConversationRequest.newBuilder()
                .setCardId(cardId)
                .setLimit(limit)
                .setIntervalMs(250)
                .build(),
        ).collect { update ->
            snapshot = ConversationReducer.apply(snapshot, update)
            emit(requireNotNull(snapshot))
        }
    }

    override suspend fun toolOutput(cardId: String, messageId: String, toolCallId: String, revision: String): ToolOutput =
        unary().getToolOutput(
            GetToolOutputRequest.newBuilder()
                .setCardId(cardId)
                .setMessageId(messageId)
                .setToolCallId(toolCallId)
                .setRevision(revision)
                .build(),
        )

    override suspend fun sendMessage(
        cardId: String,
        parts: List<MessagePart>,
        provider: String,
        model: String,
        effort: String,
    ): SendMessageResponse = sendMessage(
        SendMessageRequest.newBuilder()
            .setCardId(cardId)
            .addAllParts(parts)
            .setProvider(provider)
            .setModel(model)
            .setEffort(effort)
            .build(),
    )

    override suspend fun sendMessage(request: SendMessageRequest): SendMessageResponse =
        unary(deadlineSeconds = 60).sendMessage(request)

    override suspend fun addComment(cardId: String, text: String, name: String): Comment = unary().addComment(
        AddCommentRequest.newBuilder().setCardId(cardId).setMessage(text).setName(name).build(),
    )

    override suspend fun moveCard(cardId: String, lane: String, position: Long?): Card {
        val request = MoveCardRequest.newBuilder().setCardId(cardId).setLane(lane)
        if (position != null) request.position = position
        return unary().moveCard(request.build())
    }

    override suspend fun startCard(request: StartCardRequest): StartCardResponse =
        unary(deadlineSeconds = 15).startCard(request)

    override suspend fun setCardLabels(cardId: String, labelIds: List<String>): Card = unary().setCardLabels(
        SetCardLabelsRequest.newBuilder().setCardId(cardId).addAllLabelIds(labelIds).build(),
    )

    override suspend fun cancelCard(cardId: String) {
        unary().cancelCard(cardRequest(cardId))
    }

    override suspend fun renameCard(cardId: String, title: String): Card = unary().renameCard(
        RenameCardRequest.newBuilder().setCardId(cardId).setTitle(title).build(),
    )

    override suspend fun forkChat(sourceCardId: String, messageId: String, title: String): Card = unary().forkChat(
        ForkChatRequest.newBuilder()
            .setSourceCardId(sourceCardId)
            .setMessageId(messageId)
            .setTitle(title)
            .build(),
    )

    override suspend fun updateCard(cardId: String, title: String, initialPrompt: String): Card = unary().updateCard(
        UpdateCardRequest.newBuilder()
            .setCardId(cardId)
            .setTitle(title)
            .setInitialPrompt(initialPrompt)
            .build(),
    )

    override suspend fun archiveCard(cardId: String, archived: Boolean): Card = unary().archiveCard(
        ArchiveCardRequest.newBuilder().setCardId(cardId).setArchived(archived).build(),
    )

    override suspend fun pinChat(cardId: String, pinned: Boolean): Card = unary().pinChat(
        PinChatRequest.newBuilder().setCardId(cardId).setPinned(pinned).build(),
    )

    override suspend fun updateConversationWorkspace(cardId: String, mode: String, branch: String, baseBranch: String): Card =
        unary().updateConversationWorkspace(
            UpdateConversationWorkspaceRequest.newBuilder()
                .setCardId(cardId)
                .setMode(mode)
                .setBranch(branch.trim())
                .setBaseBranch(baseBranch.trim())
                .build(),
        )

    // GetWorkspace may lazily provision a project projection or worktree, so it gets a
    // provisioning-sized deadline rather than the default UI read deadline.
    override suspend fun workspace(cardId: String): Workspace =
        unary(deadlineSeconds = 60).getWorkspace(conversationRequest(cardId))

    override suspend fun projectWorkspaces(projectId: String): WorkspacesResponse =
        unary().listProjectWorkspaces(ProjectRef.newBuilder().setProjectId(projectId).build())

    override suspend fun changeset(cardId: String): Changeset =
        unary(deadlineSeconds = 30).getChangeset(GetChangesetRequest.newBuilder().setCardId(cardId).build())

    override suspend fun fileDiff(request: GetDiffRequest): FileDiff = unary(deadlineSeconds = 30).getFileDiff(request)

    override suspend fun commitDiff(request: GetDiffRequest): FileDiff = unary(deadlineSeconds = 30).getCommitDiff(request)

    override suspend fun addChangeComment(request: AddChangeCommentRequest): ChangeComment =
        unary().addChangeComment(request)

    override suspend fun changeComments(cardId: String, revision: String): ChangeCommentsResponse =
        unary().listChangeComments(
            ListChangeCommentsRequest.newBuilder().setCardId(cardId).setRevision(revision).build(),
        )

    // Capability discovery may run `gh auth status` on the daemon host.
    override suspend fun scmCapabilities(cardId: String): SCMCapabilities =
        unary(deadlineSeconds = 30).getSCMCapabilities(conversationRequest(cardId))

    override suspend fun startGitOperation(
        cardId: String,
        kind: String,
        expectedRevision: String,
        parameters: Map<String, String>,
    ): GitOperation = unary().startGitOperation(
        StartGitOperationRequest.newBuilder()
            .setCardId(cardId)
            .setKind(kind)
            .setExpectedRevision(expectedRevision)
            .putAllParameters(parameters)
            .build(),
    )

    override suspend fun gitOperation(operationId: String): GitOperation =
        unary().getGitOperation(GitOperationRef.newBuilder().setOperationId(operationId).build())

    override fun watchGitOperation(operationId: String, afterSequence: Long): Flow<GitOperationFrame> = flow {
        streaming().watchGitOperation(
            WatchGitOperationRequest.newBuilder()
                .setOperationId(operationId)
                .setAfterSequence(afterSequence)
                .setHeartbeatMs(15_000)
                .build(),
        ).collect(::emit)
    }

    override suspend fun cancelGitOperation(operationId: String): GitOperation =
        unary().cancelGitOperation(GitOperationRef.newBuilder().setOperationId(operationId).build())

    override suspend fun files(projectId: String, path: String, showHidden: Boolean, cardId: String): FileList = unary().listFiles(
        ListFilesRequest.newBuilder()
            .setProjectId(projectId)
            .setPath(path)
            .setShowHidden(showHidden)
            .setCardId(cardId)
            .build(),
    )

    override suspend fun readFile(projectId: String, path: String, cardId: String): FileDocument = unary().readFile(
        ReadFileRequest.newBuilder().setProjectId(projectId).setPath(path).setCardId(cardId).build(),
    )

    override suspend fun saveFile(projectId: String, path: String, content: String, revision: String, cardId: String): FileDocument =
        unary().saveFile(
            SaveFileRequest.newBuilder()
                .setProjectId(projectId)
                .setPath(path)
                .setContent(content)
                .setRevision(revision)
                .setCardId(cardId)
                .build(),
        )

    override suspend fun createFile(projectId: String, path: String, kind: String, content: String, cardId: String): FileEntry =
        unary().createFile(
            CreateFileRequest.newBuilder()
                .setProjectId(projectId)
                .setPath(path)
                .setKind(kind)
                .setContent(content)
                .setCardId(cardId)
                .build(),
        )

    override suspend fun moveFile(projectId: String, source: String, destination: String): MoveFileResponse =
        unary().moveFile(
            MoveFileRequest.newBuilder()
                .setProjectId(projectId)
                .setSource(source)
                .setDestination(destination)
                .build(),
        )

    override suspend fun deleteFile(projectId: String, path: String, recursive: Boolean) {
        unary().deleteFile(
            DeleteFileRequest.newBuilder()
                .setProjectId(projectId)
                .setPath(path)
                .setRecursive(recursive)
                .build(),
        )
    }

    override suspend fun terminals(projectId: String): TerminalsResponse = unary().listTerminals(
        ListTerminalsRequest.newBuilder().setProjectId(projectId).build(),
    )

    override suspend fun createTerminal(request: CreateTerminalRequest): Terminal = unary().createTerminal(request)

    override fun watchTerminal(terminalId: String, afterSequence: Long): Flow<TerminalFrame> = flow {
        streaming().watchTerminal(
            WatchTerminalRequest.newBuilder()
                .setTerminalId(terminalId)
                .setAfterSequence(afterSequence)
                .setHeartbeatMs(15_000)
                .build(),
        ).collect(::emit)
    }

    override suspend fun writeTerminal(terminalId: String, data: ByteArray): Terminal = unary().writeTerminal(
        TerminalInputRequest.newBuilder()
            .setTerminalId(terminalId)
            .setData(com.google.protobuf.ByteString.copyFrom(data))
            .build(),
    )

    override suspend fun resizeTerminal(terminalId: String, columns: Int, rows: Int): Terminal = unary().resizeTerminal(
        ResizeTerminalRequest.newBuilder()
            .setTerminalId(terminalId)
            .setColumns(columns)
            .setRows(rows)
            .build(),
    )

    override suspend fun renameTerminal(terminalId: String, name: String): Terminal = unary().renameTerminal(
        RenameTerminalRequest.newBuilder().setTerminalId(terminalId).setName(name).build(),
    )

    override suspend fun closeTerminal(terminalId: String) {
        unary().closeTerminal(TerminalRef.newBuilder().setTerminalId(terminalId).build())
    }

    override suspend fun schedules(projectId: String): SchedulesResponse = unary().listSchedules(
        ListSchedulesRequest.newBuilder().setProjectId(projectId).build(),
    )

    override suspend fun previewSchedule(cron: String, timezone: String, count: Int): SchedulePreview =
        unary().previewSchedule(
            PreviewScheduleRequest.newBuilder().setCron(cron).setTimezone(timezone).setCount(count).build(),
        )

    override suspend fun saveSchedule(scheduleId: String, request: SaveScheduleRequest): Schedule {
        val normalized = request.toBuilder().setScheduleId(scheduleId).build()
        return if (scheduleId.isBlank()) unary().createSchedule(normalized) else unary().updateSchedule(normalized)
    }

    override suspend fun runSchedule(scheduleId: String): ScheduleRun = unary().runSchedule(scheduleRequest(scheduleId))

    override suspend fun setScheduleEnabled(scheduleId: String, enabled: Boolean): Schedule = unary().setScheduleEnabled(
        SetScheduleEnabledRequest.newBuilder().setScheduleId(scheduleId).setEnabled(enabled).build(),
    )

    override suspend fun scheduleRuns(scheduleId: String, limit: Int): ScheduleRunsResponse = unary().listScheduleRuns(
        ListScheduleRunsRequest.newBuilder().setScheduleId(scheduleId).setLimit(limit).build(),
    )

    override suspend fun deleteSchedule(scheduleId: String) {
        unary().deleteSchedule(scheduleRequest(scheduleId))
    }

    override fun reconnect() {
        synchronized(lock) {
            channel?.shutdownNow()
            channel = null
            gatewayChannel?.shutdownNow()
            gatewayChannel = null
            directAccessToken = null
            directRefreshAt = null
        }
    }

    override fun close() = reconnect()

    private fun cardRequest(cardId: String): GetCardRequest =
        GetCardRequest.newBuilder().setCardId(cardId).build()

    private fun conversationRequest(cardId: String): ConversationRef =
        ConversationRef.newBuilder().setCardId(cardId).build()

    private fun scheduleRequest(scheduleId: String): ScheduleRef =
        ScheduleRef.newBuilder().setScheduleId(scheduleId).build()
}

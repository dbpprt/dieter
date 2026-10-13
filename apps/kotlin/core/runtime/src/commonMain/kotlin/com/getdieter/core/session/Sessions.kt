package com.getdieter.core.session

import com.getdieter.api.gateway.v1.Account
import com.getdieter.api.gateway.v1.CompatibilityComponent
import com.getdieter.api.gateway.v1.CompatibilityRequest
import com.getdieter.api.gateway.v1.CompatibilityStatus
import com.getdieter.api.gateway.v1.GatewayInformation
import com.getdieter.api.gateway.v1.GatewayServiceClient
import com.getdieter.api.gateway.v1.GrpcGatewayServiceClient
import com.getdieter.api.gateway.v1.WatchDaemonsRequest
import com.getdieter.core.api.DaemonApi
import com.getdieter.core.identity.Gateway
import com.getdieter.core.machines.Machine
import com.getdieter.core.platform.GatewayAccess
import com.getdieter.core.platform.RpcTransport
import com.getdieter.core.routing.DataPlane
import com.getdieter.core.routing.RouteKind
import com.getdieter.core.routing.RouteSelector
import com.getdieter.core.runtime.CoreException
import com.getdieter.core.runtime.FailureKind
import com.getdieter.core.runtime.Failures
import com.getdieter.core.runtime.withDeadline
import com.squareup.wire.GrpcException
import com.squareup.wire.GrpcStatus
import kotlin.coroutines.cancellation.CancellationException
import kotlin.time.Clock
import kotlin.time.Duration
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.update
import okio.ByteString
import okio.IOException

/** An authenticated connection to one gateway. */
class GatewaySession(
    val gateway: Gateway,
    token: String,
    transport: RpcTransport,
    val clientVersion: String,
    /** Stamps presence reports on receipt; see [com.getdieter.core.machines.MachinePresence]. */
    private val clock: Clock,
) {
    val access = GatewayAccess(gateway.httpBase, token, clientVersion)
    private val channel = transport.gateway(access)
    val client: GatewayServiceClient = GrpcGatewayServiceClient(channel.client)

    /** Rejects an outdated client or a revoked session before any other work. */
    suspend fun verify() {
        val compatibility = classified {
            client
                .GetCompatibility()
                .execute(
                    CompatibilityRequest(
                        release_version = clientVersion,
                        component = CompatibilityComponent.COMPATIBILITY_COMPONENT_CLIENT,
                    )
                )
        }
        if (compatibility.status != CompatibilityStatus.COMPATIBILITY_STATUS_COMPATIBLE) {
            throw CoreException(
                FailureKind.UPDATE_REQUIRED,
                "Dieter update required: installed $clientVersion, minimum ${compatibility.minimum_release_version}",
            )
        }
        account = classified { client.GetAccount().execute(Unit) }
    }

    /** The signed-in account, once [verify] read it. */
    var account: Account? = null
        private set

    /** The gateway's build, as its latest directory or presence report described it. */
    var information: GatewayInformation? = null
        private set

    suspend fun machines(): List<Machine> {
        val response = classified { client.ListDaemons().execute(Unit) }
        response.gateway_information?.let { information = it }
        val receivedAt = clock.now()
        return response.daemons.map { Machine.from(it, receivedAt) }
    }

    /** Presence updates; advisory, so callers retry them independently of the machines' streams. */
    fun presence(heartbeat: Duration): Flow<List<Machine>> = flow {
        coroutineScope {
            val call = client.WatchDaemons()
            val updates =
                call.executeIn(
                    this,
                    WatchDaemonsRequest(heartbeat_seconds = heartbeat.inWholeSeconds.toInt()),
                )
            try {
                for (update in updates) {
                    update.gateway_information?.let { information = it }
                    val receivedAt = clock.now()
                    emit(update.daemons.map { Machine.from(it, receivedAt) })
                }
            } finally {
                call.cancel()
            }
        }
    }

    fun close() = channel.close()

    /** Gateway rejections that need user action become typed failures. */
    private suspend fun <T> classified(call: suspend () -> T): T =
        try {
            call()
        } catch (error: GrpcException) {
            when (error.grpcStatus) {
                GrpcStatus.UNAUTHENTICATED ->
                    throw CoreException(
                        FailureKind.UNAUTHENTICATED,
                        "The gateway session is no longer valid; sign in again.",
                        error,
                    )
                GrpcStatus.FAILED_PRECONDITION ->
                    throw CoreException(
                        FailureKind.UPDATE_REQUIRED,
                        error.grpcMessage ?: "Dieter update required",
                        error,
                    )
                else -> throw error
            }
        }
}

/** The route currently used to reach one machine, for status displays. */
data class MachineRoute(val kind: RouteKind, val latency: Duration)

/**
 * One shared data plane per daemon. Every feature that talks to a machine, its change stream
 * included, uses it, so opening a card never reconnects anything. [onPlane] runs for every newly
 * established plane, e.g. to compare roster heads with the machine. Confined to the core
 * dispatcher.
 */
class MachineSessions(
    private val selector: RouteSelector,
    private val scope: CoroutineScope,
    private val onPlane: (DataPlane) -> Unit = {},
) {
    private var gateway: GatewaySession? = null
    val gatewaySession: GatewaySession?
        get() = gateway

    private val planes = mutableMapOf<String, DataPlane>()
    private val selecting = mutableMapOf<String, Deferred<DataPlane>>()
    private val mutableRoutes = MutableStateFlow<Map<String, MachineRoute>>(emptyMap())
    val routes: StateFlow<Map<String, MachineRoute>> = mutableRoutes.asStateFlow()

    /** Switches the gateway; existing planes belong to the old session and are closed. */
    fun attach(session: GatewaySession?) {
        if (session === gateway) return
        closeAll()
        gateway = session
    }

    suspend fun plane(daemonId: String): DataPlane {
        planes[daemonId]?.let {
            return it
        }
        val session =
            gateway ?: throw CoreException(FailureKind.TRANSIENT, "Not connected to a gateway.")
        val pending =
            selecting.getOrPut(daemonId) {
                scope.async { selector.select(session.client, session.access, daemonId) }
            }
        val plane =
            try {
                pending.await()
            } finally {
                if (selecting[daemonId] === pending) selecting.remove(daemonId)
            }
        if (gateway !== session) {
            plane.close()
            throw CoreException(FailureKind.TRANSIENT, "The gateway changed while connecting.")
        }
        planes[daemonId]?.let { existing ->
            if (existing !== plane) plane.close()
            return existing
        }
        planes[daemonId] = plane
        mutableRoutes.update { it + (daemonId to MachineRoute(plane.kind, plane.latency)) }
        onPlane(plane)
        return plane
    }

    /**
     * Closes every plane whose pinned machine key [trusted] no longer accepts, e.g. after the
     * machine was removed from the roster.
     */
    fun retainTrusted(trusted: (daemonId: String, key: ByteString) -> Boolean) {
        for ((daemonId, plane) in planes.toList()) {
            if (!trusted(daemonId, plane.daemonKey)) invalidate(daemonId, plane)
        }
    }

    /**
     * Runs [block] against [daemonId]. A transport failure retires the plane so the next call
     * selects a route again; the call itself is not replayed.
     */
    suspend fun <T> call(daemonId: String, block: suspend (DaemonApi) -> T): T {
        val plane = plane(daemonId)
        return try {
            block(plane.client)
        } catch (error: Throwable) {
            if (isTransportFailure(error)) invalidate(daemonId, plane)
            throw error
        }
    }

    /** [call] within [deadline]; an expired deadline is a transient failure. */
    suspend fun <T> call(
        daemonId: String,
        deadline: Duration,
        block: suspend (DaemonApi) -> T,
    ): T = withDeadline(deadline) { call(daemonId, block) }

    fun invalidate(daemonId: String, plane: DataPlane? = null) {
        val current = planes[daemonId] ?: return
        if (plane != null && current !== plane) return
        planes.remove(daemonId)
        current.close()
        mutableRoutes.update { it - daemonId }
    }

    fun closeAll() {
        selecting.values.forEach { it.cancel() }
        selecting.clear()
        planes.values.forEach(DataPlane::close)
        planes.clear()
        mutableRoutes.value = emptyMap()
    }

    companion object {
        fun isTransportFailure(error: Throwable): Boolean =
            when (error) {
                is GrpcException ->
                    error.grpcStatus == GrpcStatus.UNAVAILABLE ||
                        error.grpcStatus == GrpcStatus.UNKNOWN ||
                        error.grpcStatus == GrpcStatus.UNAUTHENTICATED
                is IOException -> true
                is CoreException -> error.kind == FailureKind.TRANSIENT
                else ->
                    Failures.kind(error) == FailureKind.TRANSIENT && error !is CancellationException
            }
    }
}

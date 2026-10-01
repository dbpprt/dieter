package com.dbpprt.dieter.core.session

import com.dbpprt.dieter.api.gateway.v1.CompatibilityComponent
import com.dbpprt.dieter.api.gateway.v1.CompatibilityRequest
import com.dbpprt.dieter.api.gateway.v1.CompatibilityStatus
import com.dbpprt.dieter.api.gateway.v1.GatewayServiceClient
import com.dbpprt.dieter.api.gateway.v1.GrpcGatewayServiceClient
import com.dbpprt.dieter.api.gateway.v1.WatchDaemonsRequest
import com.dbpprt.dieter.api.v1.DieterServiceClient
import com.dbpprt.dieter.core.identity.Gateway
import com.dbpprt.dieter.core.machines.Machine
import com.dbpprt.dieter.core.platform.GatewayAccess
import com.dbpprt.dieter.core.platform.RpcTransport
import com.dbpprt.dieter.core.routing.DataPlane
import com.dbpprt.dieter.core.routing.RouteKind
import com.dbpprt.dieter.core.routing.RouteSelector
import com.dbpprt.dieter.core.runtime.CoreException
import com.dbpprt.dieter.core.runtime.FailureKind
import com.dbpprt.dieter.core.runtime.Failures
import com.squareup.wire.GrpcException
import com.squareup.wire.GrpcStatus
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
import okio.IOException

/** An authenticated connection to one gateway. */
class GatewaySession(
    val gateway: Gateway,
    token: String,
    transport: RpcTransport,
    val clientVersion: String,
    /** Stamps presence reports on receipt; see [com.dbpprt.dieter.core.machines.MachinePresence]. */
    private val clock: Clock,
) {
    val access = GatewayAccess(gateway.httpBase, token, clientVersion)
    private val channel = transport.gateway(access)
    val client: GatewayServiceClient = GrpcGatewayServiceClient(channel.client)

    /** Rejects an outdated client or a revoked session before any other work. */
    suspend fun verify() {
        val compatibility = classified {
            client.GetCompatibility().execute(
                CompatibilityRequest(release_version = clientVersion, component = CompatibilityComponent.COMPATIBILITY_COMPONENT_CLIENT),
            )
        }
        if (compatibility.status != CompatibilityStatus.COMPATIBILITY_STATUS_COMPATIBLE) {
            throw CoreException(
                FailureKind.UPDATE_REQUIRED,
                "Dieter update required: installed $clientVersion, minimum ${compatibility.minimum_release_version}",
            )
        }
        classified { client.GetAccount().execute(Unit) }
    }

    suspend fun machines(): List<Machine> {
        val daemons = classified { client.ListDaemons().execute(Unit) }.daemons
        val receivedAt = clock.now()
        return daemons.map { Machine.from(it, receivedAt) }
    }

    /** Presence updates; advisory, so callers retry independently of the feed. */
    fun presence(heartbeat: Duration): Flow<List<Machine>> = flow {
        coroutineScope {
            val call = client.WatchDaemons()
            val updates = call.executeIn(this, WatchDaemonsRequest(heartbeat_seconds = heartbeat.inWholeSeconds.toInt()))
            try {
                for (update in updates) {
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
    private suspend fun <T> classified(call: suspend () -> T): T = try {
        call()
    } catch (error: GrpcException) {
        when (error.grpcStatus) {
            GrpcStatus.UNAUTHENTICATED ->
                throw CoreException(FailureKind.UNAUTHENTICATED, "The gateway session is no longer valid; sign in again.", error)
            GrpcStatus.FAILED_PRECONDITION ->
                throw CoreException(FailureKind.UPDATE_REQUIRED, error.grpcMessage ?: "Dieter update required", error)
            else -> throw error
        }
    }
}

/** The route currently used to reach one machine, for status displays. */
data class MachineRoute(val kind: RouteKind, val latency: Duration)

/**
 * One shared data plane per daemon. Every feature that talks to a machine
 * uses it, so opening a card on another machine never moves the feed or
 * reconnects the app. Confined to the core dispatcher.
 */
class MachineSessions(private val selector: RouteSelector, private val scope: CoroutineScope) {
    private var gateway: GatewaySession? = null
    val gatewaySession: GatewaySession? get() = gateway
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
        planes[daemonId]?.let { return it }
        val session = gateway ?: throw CoreException(FailureKind.TRANSIENT, "Not connected to a gateway.")
        val pending = selecting.getOrPut(daemonId) {
            scope.async { selector.select(session.client, session.access, daemonId) }
        }
        val plane = try {
            pending.await()
        } finally {
            if (selecting[daemonId] === pending) selecting.remove(daemonId)
        }
        if (gateway !== session) {
            plane.close()
            throw CoreException(FailureKind.TRANSIENT, "The gateway changed while connecting.")
        }
        planes[daemonId]?.let { existing -> if (existing !== plane) plane.close(); return existing }
        planes[daemonId] = plane
        mutableRoutes.update { it + (daemonId to MachineRoute(plane.kind, plane.latency)) }
        return plane
    }

    /**
     * Runs [block] against [daemonId]. A transport failure retires the plane
     * so the next call selects a route again; the call itself is not replayed.
     */
    suspend fun <T> call(daemonId: String, block: suspend (DieterServiceClient) -> T): T {
        val plane = plane(daemonId)
        return try {
            block(plane.client)
        } catch (error: Throwable) {
            if (isTransportFailure(error)) invalidate(daemonId, plane)
            throw error
        }
    }

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
        fun isTransportFailure(error: Throwable): Boolean = when (error) {
            is GrpcException -> error.grpcStatus == GrpcStatus.UNAVAILABLE || error.grpcStatus == GrpcStatus.UNKNOWN ||
                error.grpcStatus == GrpcStatus.UNAUTHENTICATED
            is IOException -> true
            is CoreException -> error.kind == FailureKind.TRANSIENT
            else -> Failures.kind(error) == FailureKind.TRANSIENT && error !is kotlin.coroutines.cancellation.CancellationException
        }
    }
}

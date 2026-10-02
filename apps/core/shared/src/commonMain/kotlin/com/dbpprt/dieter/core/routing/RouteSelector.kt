package com.dbpprt.dieter.core.routing

import com.dbpprt.dieter.api.gateway.v1.DaemonRef
import com.dbpprt.dieter.api.gateway.v1.DaemonRoute
import com.dbpprt.dieter.api.gateway.v1.DirectCandidate
import com.dbpprt.dieter.api.gateway.v1.ExchangeDaemonTokenRequest
import com.dbpprt.dieter.api.gateway.v1.GatewayServiceClient
import com.dbpprt.dieter.api.gateway.v1.RTCConfiguration
import com.dbpprt.dieter.api.v1.ControlConnectionRef
import com.dbpprt.dieter.api.v1.DieterServiceClient
import com.dbpprt.dieter.api.v1.GrpcDieterServiceClient
import com.dbpprt.dieter.api.v1.StartControlConnectionRequest
import com.dbpprt.dieter.core.identity.Hosts
import com.dbpprt.dieter.core.platform.ControlChannelFactory
import com.dbpprt.dieter.core.platform.DaemonTokenExchange
import com.dbpprt.dieter.core.platform.DirectTarget
import com.dbpprt.dieter.core.platform.GatewayAccess
import com.dbpprt.dieter.core.platform.RpcChannel
import com.dbpprt.dieter.core.platform.RpcTransport
import com.dbpprt.dieter.core.runtime.CoreException
import com.dbpprt.dieter.core.runtime.CoreLogger
import com.dbpprt.dieter.core.runtime.FailureKind
import com.dbpprt.dieter.core.runtime.Failures
import kotlin.coroutines.cancellation.CancellationException
import kotlin.time.Clock
import kotlin.time.Duration
import kotlin.time.Duration.Companion.seconds
import kotlin.time.TimeSource
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeout

data class RoutingPolicy(
    /** Try loopback candidates: only hosts that can run a daemon themselves (macOS, JVM). */
    val includeLoopback: Boolean,
    val probeTimeout: Duration = 2.seconds,
    val relayProbeTimeout: Duration = 5.seconds,
    /** Head start the WebRTC route gets over the relay. */
    val hedgeDelay: Duration = 1.seconds,
    val controlTimeout: Duration = 12.seconds,
)

/**
 * One route-selection policy for every caller: pinned direct TLS by priority,
 * then the WebRTC control route hedged against the relay, then the relay.
 * Only connection setup races; application RPCs are never replayed.
 */
class RouteSelector(
    private val transport: RpcTransport,
    private val controlChannels: ControlChannelFactory?,
    private val policy: RoutingPolicy,
    private val cooldown: WebRtcCooldown,
    private val logger: CoreLogger,
    private val clock: Clock = Clock.System,
) {
    suspend fun select(gateway: GatewayServiceClient, access: GatewayAccess, daemonId: String): DataPlane {
        val route = gateway.ResolveDaemonRoute().execute(DaemonRef(daemon_id = daemonId))
        val exchange = DaemonTokenExchange {
            gateway.ExchangeDaemonToken().execute(ExchangeDaemonTokenRequest(daemon_id = daemonId))
        }
        val candidates = candidates(route.direct_candidates)
        if (candidates.isNotEmpty()) {
            val tokens = runCatching { RenewingDaemonToken(exchange.exchange(), exchange, clock) }
                .onFailure { if (it is CancellationException) throw it }
                .getOrNull()
            if (tokens != null) {
                for (candidate in candidates) {
                    direct(daemonId, candidate, route, tokens, access)?.let { return it }
                }
            }
        }
        val control = controlChannels
        if (control != null && route.control_webrtc && route.relay_available && cooldown.allows(daemonId)) {
            return hedged(gateway, access, daemonId, route, exchange, control)
        }
        if (!route.relay_available) {
            throw CoreException(FailureKind.TRANSIENT, "This machine has no reachable route and its relay is unavailable.")
        }
        return relay(access, daemonId)
    }

    private fun candidates(all: List<DirectCandidate>): List<DirectCandidate> = all
        .filter { policy.includeLoopback || (!it.network.equals("loopback", ignoreCase = true) && !Hosts.isLoopback(it.host)) }
        .sortedByDescending { it.priority }

    private suspend fun direct(
        daemonId: String,
        candidate: DirectCandidate,
        route: DaemonRoute,
        tokens: RenewingDaemonToken,
        access: GatewayAccess,
    ): DataPlane? {
        val target = DirectTarget(daemonId, candidate.host, candidate.port, route.daemon_ca_pem.utf8(), access.clientVersion)
        val channel = transport.direct(target, tokens)
        val client = GrpcDieterServiceClient(channel.client)
        val started = TimeSource.Monotonic.markNow()
        return try {
            withTimeout(policy.probeTimeout) { client.Health().execute(Unit) }
            val kind = if (candidate.network.equals("loopback", ignoreCase = true)) RouteKind.LOCAL else RouteKind.DIRECT
            DataPlane(daemonId, kind, client, started.elapsedNow(), channel::close)
        } catch (cancelled: CancellationException) {
            channel.close()
            if (cancelled is TimeoutCancellationException) null else throw cancelled
        } catch (error: Throwable) {
            logger.debug(TAG, "direct candidate ${candidate.id} for $daemonId failed: ${Failures.message(error)}")
            channel.close()
            null
        }
    }

    private suspend fun relay(access: GatewayAccess, daemonId: String): DataPlane {
        val channel = transport.relay(access, daemonId)
        val client = GrpcDieterServiceClient(channel.client)
        val started = TimeSource.Monotonic.markNow()
        try {
            withTimeout(policy.relayProbeTimeout) { client.Health().execute(Unit) }
        } catch (error: Throwable) {
            channel.close()
            if (error is TimeoutCancellationException) {
                throw CoreException(FailureKind.TRANSIENT, "The relay did not answer in time.", error)
            }
            throw error
        }
        return DataPlane(daemonId, RouteKind.RELAY, client, started.elapsedNow(), channel::close)
    }

    private suspend fun control(
        gateway: GatewayServiceClient,
        access: GatewayAccess,
        daemonId: String,
        route: DaemonRoute,
        exchange: DaemonTokenExchange,
        factory: ControlChannelFactory,
    ): DataPlane = withTimeout(policy.controlTimeout) {
        val started = TimeSource.Monotonic.markNow()
        val configuration: RTCConfiguration = gateway.GetRTCConfiguration().execute(DaemonRef(daemon_id = daemonId))
        val tokens = RenewingDaemonToken(exchange.exchange(), exchange, clock)
        val channel = factory.create(RTCConfiguration.ADAPTER.encode(configuration))
        var direct: RpcChannel? = null
        try {
            val bootstrap = transport.relay(access, daemonId)
            val offer = channel.offer()
            val session = try {
                GrpcDieterServiceClient(bootstrap.client).StartControlConnection().execute(
                    StartControlConnectionRequest(rtc_configuration = configuration, offer_sdp = offer),
                )
            } finally {
                bootstrap.close()
            }
            val port = channel.connect(session.answer_sdp)
            val target = DirectTarget(daemonId, "127.0.0.1", port, route.daemon_ca_pem.utf8(), access.clientVersion)
            direct = transport.direct(target, tokens)
            val client: DieterServiceClient = GrpcDieterServiceClient(direct.client)
            client.Health().execute(Unit)
            val mode = runCatching { client.GetControlConnection().execute(ControlConnectionRef(session_id = session.session_id)).mode }
                .getOrDefault("")
            val kind = when (mode) {
                "turn" -> RouteKind.WEBRTC_TURN
                "direct" -> RouteKind.WEBRTC_DIRECT
                else -> RouteKind.WEBRTC
            }
            val owned = direct
            DataPlane(daemonId, kind, client, started.elapsedNow()) {
                owned.close()
                channel.close()
            }
        } catch (error: Throwable) {
            direct?.close()
            channel.close()
            throw error
        }
    }

    /** The WebRTC route gets a head start; the first healthy transport wins, the loser is closed. */
    private suspend fun hedged(
        gateway: GatewayServiceClient,
        access: GatewayAccess,
        daemonId: String,
        route: DaemonRoute,
        exchange: DaemonTokenExchange,
        factory: ControlChannelFactory,
    ): DataPlane = coroutineScope {
        val winner = CompletableDeferred<DataPlane>()
        var failures = 0
        var lastError: Throwable? = null
        val fallbackStart = CompletableDeferred<Unit>()
        fun offer(result: Result<DataPlane>) {
            result.onSuccess { plane -> if (!winner.complete(plane)) plane.close() }
            result.onFailure { error ->
                lastError = error
                if (++failures == 2) winner.completeExceptionally(error)
            }
        }
        val preferred = async {
            val result = runCatching { control(gateway, access, daemonId, route, exchange, factory) }
            if (result.exceptionOrNull() is CancellationException && winner.isCompleted) return@async
            result.exceptionOrNull()?.let { logger.info(TAG, "WebRTC control route unavailable for $daemonId: ${Failures.message(it)}") }
            offer(result)
            fallbackStart.complete(Unit)
        }
        val timer = launch { delay(policy.hedgeDelay); fallbackStart.complete(Unit) }
        val fallback = async {
            fallbackStart.await()
            if (winner.isCompleted) return@async
            offer(runCatching { relay(access, daemonId) })
        }
        try {
            val plane = winner.await()
            if (plane.kind == RouteKind.RELAY) cooldown.recordFailure(daemonId) else cooldown.recordSuccess(daemonId)
            plane
        } catch (error: Throwable) {
            if (error !is CancellationException) cooldown.recordFailure(daemonId)
            throw lastError ?: error
        } finally {
            timer.cancel()
            preferred.cancel()
            fallback.cancel()
        }
    }

    private companion object {
        const val TAG = "Routing"
    }
}

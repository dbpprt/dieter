package com.getdieter.core.routing

import com.getdieter.api.gateway.v1.DaemonRef
import com.getdieter.api.gateway.v1.DirectCandidate
import com.getdieter.api.gateway.v1.ExchangeDaemonTokenRequest
import com.getdieter.api.gateway.v1.GatewayServiceClient
import com.getdieter.api.gateway.v1.RTCConfiguration
import com.getdieter.api.gateway.v1.RelayLane
import com.getdieter.api.v1.ControlConnectionRef
import com.getdieter.api.v1.StartControlConnectionRequest
import com.getdieter.core.api.DaemonApi
import com.getdieter.core.api.GrpcDaemonApi
import com.getdieter.core.identity.Hosts
import com.getdieter.core.platform.ControlChannelFactory
import com.getdieter.core.platform.DaemonTokenExchange
import com.getdieter.core.platform.DaemonTokenSource
import com.getdieter.core.platform.DirectTarget
import com.getdieter.core.platform.GatewayAccess
import com.getdieter.core.platform.RpcChannel
import com.getdieter.core.platform.RpcTransport
import com.getdieter.core.platform.Tunnel
import com.getdieter.core.platform.TunnelFactory
import com.getdieter.core.runtime.CoreException
import com.getdieter.core.runtime.CoreLogger
import com.getdieter.core.runtime.Deadlines
import com.getdieter.core.runtime.FailureKind
import com.getdieter.core.runtime.Failures
import com.getdieter.core.runtime.GATEWAY_SILENT
import com.getdieter.core.runtime.withDeadline
import com.getdieter.core.trust.RoutePin
import com.getdieter.core.trust.RouteTrust
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
    /** Opening a relay tunnel plus the TLS handshake and first call through it. */
    val relayProbeTimeout: Duration = 8.seconds,
    /** Head start the WebRTC route gets over the relay. */
    val hedgeDelay: Duration = 1.seconds,
    val controlTimeout: Duration = 15.seconds,
)

/**
 * One route-selection policy for every caller: direct TLS by priority, then the WebRTC control
 * route hedged against the relay, then the relay. Every route is the same mutually authenticated
 * TLS to the daemon, pinned to its key in the device roster ([RouteTrust]); the relay is an opaque
 * tunnel and WebRTC signaling runs inside one. Only connection setup races; application RPCs are
 * never replayed.
 */
class RouteSelector(
    private val transport: RpcTransport,
    private val tunnels: TunnelFactory,
    private val controlChannels: ControlChannelFactory?,
    private val trust: RouteTrust,
    private val policy: RoutingPolicy,
    private val cooldown: WebRtcCooldown,
    private val logger: CoreLogger,
    private val clock: Clock = Clock.System,
) {
    suspend fun select(
        gateway: GatewayServiceClient,
        access: GatewayAccess,
        daemonId: String,
    ): DataPlane {
        val pin = trust.pin(daemonId)
        // A connection that outlived sleep can remain silent without failing.
        val route =
            withDeadline(Deadlines.CALL, GATEWAY_SILENT) {
                gateway.ResolveDaemonRoute().execute(DaemonRef(daemon_id = daemonId))
            }
        val exchange = DaemonTokenExchange {
            withDeadline(Deadlines.CALL, GATEWAY_SILENT) {
                gateway
                    .ExchangeDaemonToken()
                    .execute(
                        ExchangeDaemonTokenRequest(
                            daemon_id = daemonId,
                            client_key_thumbprint = pin.deviceId,
                        )
                    )
            }
        }
        val tokens = RenewingDaemonToken(exchange.exchange(), exchange, clock)
        val dial = Dial(access, daemonId, pin, tokens)
        for (candidate in candidates(route.direct_candidates)) {
            direct(dial, candidate)?.let {
                return it
            }
        }
        val control = controlChannels
        if (
            control != null &&
                route.control_webrtc &&
                route.relay_available &&
                cooldown.allows(daemonId)
        ) {
            return hedged(gateway, dial, control)
        }
        if (!route.relay_available) {
            throw CoreException(
                FailureKind.TRANSIENT,
                "This machine has no reachable route and its relay is unavailable.",
            )
        }
        return relay(dial)
    }

    /** One selection's target and credentials. */
    private class Dial(
        val access: GatewayAccess,
        val daemonId: String,
        val pin: RoutePin,
        val tokens: DaemonTokenSource,
    ) {
        fun target(host: String, port: Int) =
            DirectTarget(
                daemonId,
                host,
                port,
                pin.daemonPublicKey,
                pin.clientCertificate,
                access.clientVersion,
            )
    }

    private fun candidates(all: List<DirectCandidate>): List<DirectCandidate> =
        all.filter {
                policy.includeLoopback ||
                    (!it.network.equals("loopback", ignoreCase = true) &&
                        !Hosts.isLoopback(it.host))
            }
            .sortedByDescending { it.priority }

    private suspend fun direct(dial: Dial, candidate: DirectCandidate): DataPlane? {
        val channel = transport.direct(dial.target(candidate.host, candidate.port), dial.tokens)
        val client = GrpcDaemonApi(channel.client)
        val started = TimeSource.Monotonic.markNow()
        return try {
            withTimeout(policy.probeTimeout) { client.Health().execute(Unit) }
            val kind =
                if (candidate.network.equals("loopback", ignoreCase = true)) RouteKind.LOCAL
                else RouteKind.DIRECT
            DataPlane(
                dial.daemonId,
                kind,
                client,
                started.elapsedNow(),
                dial.pin.daemonPublicKey,
                channel::close,
            )
        } catch (cancelled: CancellationException) {
            channel.close()
            if (cancelled is TimeoutCancellationException) null else throw cancelled
        } catch (error: Throwable) {
            logger.debug(
                TAG,
                "direct candidate ${candidate.id} for ${dial.daemonId} failed: ${Failures.message(error)}",
            )
            channel.close()
            null
        }
    }

    /**
     * A relay tunnel to the daemon's own endpoint, bridged to a loopback port, carrying the same
     * pinned TLS as a direct route: the gateway relays ciphertext only.
     */
    private suspend fun relay(dial: Dial): DataPlane {
        val started = TimeSource.Monotonic.markNow()
        var tunnel: Tunnel? = null
        var channel: RpcChannel? = null
        try {
            return withTimeout(policy.relayProbeTimeout) {
                val opened = tunnels.open(dial.access, dial.daemonId, RelayLane.RELAY_LANE_COMMAND)
                tunnel = opened
                val direct = transport.direct(dial.target(LOOPBACK, opened.port), dial.tokens)
                channel = direct
                val client = GrpcDaemonApi(direct.client)
                client.Health().execute(Unit)
                DataPlane(
                    dial.daemonId,
                    RouteKind.RELAY,
                    client,
                    started.elapsedNow(),
                    dial.pin.daemonPublicKey,
                ) {
                    direct.close()
                    opened.close()
                }
            }
        } catch (error: Throwable) {
            channel?.close()
            tunnel?.close()
            if (error is TimeoutCancellationException) {
                throw CoreException(
                    FailureKind.TRANSIENT,
                    "The relay did not answer in time.",
                    error,
                )
            }
            throw error
        }
    }

    /**
     * WebRTC to the daemon's endpoint. Its signaling runs over a relay tunnel, so the gateway sees
     * neither the offer nor the answer; the data channel then carries the same pinned TLS.
     */
    private suspend fun control(
        gateway: GatewayServiceClient,
        dial: Dial,
        factory: ControlChannelFactory,
    ): DataPlane =
        withTimeout(policy.controlTimeout) {
            val started = TimeSource.Monotonic.markNow()
            val configuration: RTCConfiguration =
                gateway.GetRTCConfiguration().execute(DaemonRef(daemon_id = dial.daemonId))
            val channel = factory.create(RTCConfiguration.ADAPTER.encode(configuration))
            var direct: RpcChannel? = null
            try {
                val session = coroutineScope {
                    val bootstrap = async { relay(dial) }
                    val offer =
                        try {
                            channel.offer()
                        } catch (error: Throwable) {
                            bootstrap.cancel()
                            runCatching { bootstrap.await() }.getOrNull()?.close()
                            throw error
                        }
                    val signaling = bootstrap.await()
                    try {
                        signaling.client
                            .StartControlConnection()
                            .execute(
                                StartControlConnectionRequest(
                                    rtc_configuration = configuration,
                                    offer_sdp = offer,
                                )
                            )
                    } finally {
                        signaling.close()
                    }
                }
                val port = channel.connect(session.answer_sdp)
                direct = transport.direct(dial.target(LOOPBACK, port), dial.tokens)
                val client: DaemonApi = GrpcDaemonApi(direct.client)
                client.Health().execute(Unit)
                val mode = runCatching {
                    client
                        .GetControlConnection()
                        .execute(ControlConnectionRef(session_id = session.session_id))
                        .mode
                }
                    .getOrDefault("")
                val kind =
                    when (mode) {
                        "turn" -> RouteKind.WEBRTC_TURN
                        "direct" -> RouteKind.WEBRTC_DIRECT
                        else -> RouteKind.WEBRTC
                    }
                val owned = direct
                DataPlane(
                    dial.daemonId,
                    kind,
                    client,
                    started.elapsedNow(),
                    dial.pin.daemonPublicKey,
                ) {
                    owned.close()
                    channel.close()
                }
            } catch (error: Throwable) {
                direct?.close()
                channel.close()
                throw error
            }
        }

    /**
     * The WebRTC route gets a head start; the first healthy transport wins, the loser is closed.
     */
    private suspend fun hedged(
        gateway: GatewayServiceClient,
        dial: Dial,
        factory: ControlChannelFactory,
    ): DataPlane = coroutineScope {
        val daemonId = dial.daemonId
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
            val result = runCatching { control(gateway, dial, factory) }
            if (result.exceptionOrNull() is CancellationException && winner.isCompleted)
                return@async
            result.exceptionOrNull()?.let {
                logger.info(
                    TAG,
                    "WebRTC control route unavailable for $daemonId: ${Failures.message(it)}",
                )
            }
            offer(result)
            fallbackStart.complete(Unit)
        }
        val timer = launch {
            delay(policy.hedgeDelay)
            fallbackStart.complete(Unit)
        }
        val fallback = async {
            fallbackStart.await()
            if (winner.isCompleted) return@async
            offer(runCatching { relay(dial) })
        }
        try {
            val plane = winner.await()
            if (plane.kind == RouteKind.RELAY) cooldown.recordFailure(daemonId)
            else cooldown.recordSuccess(daemonId)
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
        const val LOOPBACK = "127.0.0.1"
    }
}

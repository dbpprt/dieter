package com.dbpprt.dieter.core.routing

import com.dbpprt.dieter.api.gateway.v1.DaemonAccessToken
import com.dbpprt.dieter.api.v1.DieterServiceClient
import com.dbpprt.dieter.core.platform.DaemonTokenExchange
import com.dbpprt.dieter.core.platform.DaemonTokenSource
import com.dbpprt.dieter.core.runtime.CoreException
import com.dbpprt.dieter.core.runtime.FailureKind
import com.dbpprt.dieter.core.runtime.Timestamps
import kotlin.math.pow
import kotlin.time.Clock
import kotlin.time.Duration
import kotlin.time.Duration.Companion.minutes
import kotlin.time.Duration.Companion.seconds
import kotlin.time.Instant
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/** How a data plane reaches its daemon, best first. */
enum class RouteKind(val rank: Int, val label: String) {
    LOCAL(5, "Local"),
    DIRECT(4, "Direct TLS"),
    WEBRTC_DIRECT(3, "WebRTC · Direct"),
    WEBRTC_TURN(2, "WebRTC · TURN"),
    WEBRTC(2, "WebRTC"),
    RELAY(1, "Relay"),
    ;

    fun prefers(other: RouteKind) = rank > other.rank
}

/**
 * A live connection to one daemon. [client] is shared by every feature that
 * talks to that machine; HTTP/2 multiplexes their calls.
 */
class DataPlane internal constructor(
    val daemonId: String,
    val kind: RouteKind,
    val client: DieterServiceClient,
    val latency: Duration,
    private val onClose: () -> Unit,
) {
    private var closed = false

    fun close() {
        if (closed) return
        closed = true
        onClose()
    }
}

/**
 * Renews the short-lived daemon token 30 s before expiry, per RPC. Concurrent
 * callers share one exchange. Renewing never reconnects a transport, so
 * streams are not reset by token refresh.
 */
class RenewingDaemonToken(
    private var access: DaemonAccessToken,
    private val exchange: DaemonTokenExchange,
    private val clock: Clock = Clock.System,
) : DaemonTokenSource {
    private val mutex = Mutex()

    val expiresAt: Instant? get() = Timestamps.parse(access.expires_at)

    override suspend fun token(): String = mutex.withLock {
        if (!usable(access, clock.now() + 30.seconds)) {
            val renewed = exchange.exchange()
            if (!usable(renewed, clock.now())) {
                throw CoreException(FailureKind.UNAUTHENTICATED, "The gateway returned an invalid daemon credential.")
            }
            access = renewed
        }
        access.access_token
    }

    companion object {
        fun usable(token: DaemonAccessToken, after: Instant): Boolean {
            val expires = Timestamps.parse(token.expires_at) ?: return false
            return token.token_type == "Bearer" && token.access_token.isNotEmpty() && expires > after
        }
    }
}

/**
 * Per-machine circuit breaker for the optional WebRTC control route: after a
 * failure, wait 2 min, doubling to at most 15 min. The relay stays usable.
 */
class WebRtcCooldown(private val clock: Clock = Clock.System) {
    private data class State(val failures: Int, val retryAt: Instant)

    private val states = mutableMapOf<String, State>()

    fun allows(daemonId: String): Boolean = states[daemonId]?.let { clock.now() >= it.retryAt } ?: true

    fun recordFailure(daemonId: String): Duration {
        val failures = (states[daemonId]?.failures ?: 0) + 1
        val delay = cooldown(failures)
        states[daemonId] = State(failures, clock.now() + delay)
        return delay
    }

    fun recordSuccess(daemonId: String) {
        states.remove(daemonId)
    }

    fun retryAt(daemonId: String): Instant? = states[daemonId]?.retryAt

    companion object {
        fun cooldown(failures: Int): Duration =
            if (failures <= 0) Duration.ZERO else minOf(15.minutes, 2.minutes * 2.0.pow(failures - 1))
    }
}

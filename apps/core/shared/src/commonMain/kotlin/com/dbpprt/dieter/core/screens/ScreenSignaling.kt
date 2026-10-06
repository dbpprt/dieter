package com.dbpprt.dieter.core.screens

import com.dbpprt.dieter.api.v1.RemoteDesktopICECandidate
import com.dbpprt.dieter.api.v1.RemoteDesktopRef
import com.dbpprt.dieter.api.v1.RemoteDesktopSignal
import com.dbpprt.dieter.api.v1.StartRemoteDesktopRequest
import com.dbpprt.dieter.core.runtime.CoreLogger
import com.dbpprt.dieter.core.runtime.Deadlines
import com.dbpprt.dieter.core.runtime.Failures
import com.dbpprt.dieter.core.runtime.withDeadline
import com.squareup.wire.GrpcException
import com.squareup.wire.GrpcStatus
import kotlin.coroutines.cancellation.CancellationException
import kotlin.time.Clock
import kotlin.time.Duration
import kotlin.time.Duration.Companion.seconds
import kotlin.time.Instant
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull

private const val TAG = "Screens"

/**
 * The signaling RPCs of a screen session: the daemon's signal stream and its resubscription, the
 * lease heartbeat, trickled local candidates, and closing sessions. [ScreenSession] owns it and
 * decides what each signal means. Confined to the core dispatcher.
 */
internal class ScreenSignaling(
    private val scope: CoroutineScope,
    private val clock: Clock,
    private val logger: CoreLogger,
) {
    /** Local candidates gathered before the session has an identity. */
    private val localCandidates = ArrayDeque<RemoteDesktopICECandidate>()

    /**
     * Receives [start]'s signals into [handle] while [active]. A dropped stream resubscribes with
     * the same nonce and offer, with backoff capped at 5 s, for up to 15 s between received
     * signals. This stays within the host's detach grace. Permanent failures stop immediately.
     */
    suspend fun receive(
        route: suspend () -> ScreenRoute,
        start: StartRemoteDesktopRequest,
        active: () -> Boolean,
        dropped: (Throwable) -> Unit,
        handle: suspend (RemoteDesktopSignal) -> Unit,
    ): Throwable? {
        var retries = 0
        var interruptedAt: Instant? = null
        while (active()) {
            var failure: Throwable
            try {
                coroutineScope {
                    val call = route().client.StartRemoteDesktop()
                    val signals = call.executeIn(this, start)
                    try {
                        for (received in signals) {
                            if (!active()) return@coroutineScope
                            handle(received)
                            interruptedAt = null
                            retries = 0
                        }
                    } finally {
                        call.cancel()
                    }
                }
                failure = GrpcException(GrpcStatus.UNAVAILABLE, "Screen-sharing signaling ended")
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (untrusted: ScreenTrustException) {
                // A forged or mismatched binding is fatal; resubscribing cannot fix it.
                return untrusted
            } catch (error: Throwable) {
                failure = error
            }
            if (!active()) return null
            if (!ScreenFailures.retryable(failure)) return failure
            val since = interruptedAt ?: clock.now().also { interruptedAt = it }
            val remaining = ScreenSession.PEER_GRACE - (clock.now() - since)
            if (remaining <= Duration.ZERO) return failure
            dropped(failure)
            val wait = (1 shl retries.coerceAtMost(3)).coerceAtMost(5).seconds
            retries = (retries + 1).coerceAtMost(3)
            delay(minOf(wait, remaining))
        }
        return null
    }

    /**
     * Renews [sessionId]'s lease every 5 s while [active]. A renewal that fails or times out is
     * reported to [missed]; the next one still runs.
     */
    suspend fun renewLease(
        route: () -> ScreenRoute?,
        sessionId: String,
        active: () -> Boolean,
        missed: () -> Unit,
    ) {
        while (active()) {
            delay(ScreenSession.LEASE_INTERVAL)
            try {
                val current = route() ?: continue
                withDeadline(Deadlines.CALL) {
                    current.client
                        .SendRemoteDesktopSignal()
                        .execute(
                            RemoteDesktopSignal(session_id = sessionId, lease_heartbeat = Unit)
                        )
                }
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Throwable) {
                // A healthy peer survives missed renewals; feedback also renews the lease.
                logger.debug(TAG, "lease renewal failed: ${Failures.message(error)}")
                missed()
            }
        }
    }

    /**
     * A local candidate: held (up to 256) until the session has an identity, then trickled to the
     * daemon.
     */
    fun localCandidate(
        route: ScreenRoute?,
        sessionId: String,
        candidate: RemoteDesktopICECandidate,
    ) {
        if (sessionId.isEmpty()) {
            if (localCandidates.size < ScreenSession.MAX_CANDIDATES)
                localCandidates.addLast(candidate)
        } else {
            send(route, sessionId, candidate)
        }
    }

    /** The session has its identity: trickles the local candidates held until now. */
    fun sendHeldCandidates(route: ScreenRoute?, sessionId: String) {
        while (localCandidates.isNotEmpty()) send(route, sessionId, localCandidates.removeFirst())
    }

    private fun send(route: ScreenRoute?, sessionId: String, candidate: RemoteDesktopICECandidate) {
        val current = route ?: return
        scope.launch {
            runCatching {
                withDeadline(Deadlines.CALL) {
                    current.client
                        .SendRemoteDesktopSignal()
                        .execute(RemoteDesktopSignal(session_id = sessionId, candidate = candidate))
                }
            }
                .onFailure { if (it is CancellationException) throw it }
        }
    }

    /** Closes a session the daemon replaced, without waiting for it. */
    fun closeReplaced(route: ScreenRoute, sessionId: String) {
        scope.launch { closeSession(route, sessionId) }
    }

    /**
     * Closes [sessionId], when there is one, and then [route]; the result completes once both are
     * done.
     */
    fun close(route: ScreenRoute, sessionId: String): CompletableDeferred<Unit> {
        val done = CompletableDeferred<Unit>()
        scope.launch {
            try {
                if (sessionId.isNotEmpty()) closeSession(route, sessionId)
            } finally {
                route.close()
                done.complete(Unit)
            }
        }
        return done
    }

    /** Asks the daemon to close [sessionId] within 3 s; a failure is ignored. */
    private suspend fun closeSession(route: ScreenRoute, sessionId: String) {
        withTimeoutOrNull(ScreenSession.CLOSE_TIMEOUT) {
            runCatching {
                route.client.CloseRemoteDesktop().execute(RemoteDesktopRef(session_id = sessionId))
            }
        }
    }

    /** Forgets the local candidates held for the stopped session. */
    fun reset() {
        localCandidates.clear()
    }
}

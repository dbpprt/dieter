package com.dbpprt.dieter.data

internal data class WebRTCRetrySnapshot(
    val consecutiveFailures: Int,
    val retryAtMillis: Long,
    val remainingMillis: Long,
)

/** Per-machine circuit breaker for expensive ICE negotiation. */
internal class WebRTCRetryCooldown(
    private val nowMillis: () -> Long = android.os.SystemClock::elapsedRealtime,
) {
    private data class State(val failures: Int, val retryAtMillis: Long)
    private val states = mutableMapOf<String, State>()

    @Synchronized
    fun allowsAttempt(machineId: String): Boolean =
        states[machineId]?.let { nowMillis() >= it.retryAtMillis } ?: true

    @Synchronized
    fun recordFailure(machineId: String): WebRTCRetrySnapshot {
        val failures = (states[machineId]?.failures ?: 0) + 1
        val now = nowMillis()
        val retryAt = now + cooldownMillis(failures)
        states[machineId] = State(failures, retryAt)
        return WebRTCRetrySnapshot(failures, retryAt, retryAt - now)
    }

    @Synchronized
    fun recordSuccess(machineId: String) {
        states.remove(machineId)
    }

    @Synchronized
    fun snapshot(machineId: String): WebRTCRetrySnapshot? {
        val state = states[machineId] ?: return null
        return WebRTCRetrySnapshot(
            state.failures,
            state.retryAtMillis,
            (state.retryAtMillis - nowMillis()).coerceAtLeast(0),
        )
    }

    companion object {
        const val INITIAL_MILLIS = 2 * 60 * 1000L
        const val MAXIMUM_MILLIS = 15 * 60 * 1000L

        fun cooldownMillis(consecutiveFailures: Int): Long {
            if (consecutiveFailures <= 0) return 0
            var delay = INITIAL_MILLIS
            repeat(consecutiveFailures - 1) {
                delay = (delay * 2).coerceAtMost(MAXIMUM_MILLIS)
            }
            return delay
        }
    }
}

package com.dbpprt.dieter.screens

import io.grpc.Status

/** One reconnect budget per interruption; brief connections must not reset a failure loop. */
internal class ScreenRecovery {
    private var attempts = 0
    private var streamingSince: Long? = null

    fun streaming(now: Long) { if (streamingSince == null) streamingSince = now }
    fun interrupted(now: Long) {
        if (streamingSince?.let { now - it >= 10_000 } == true) attempts = 0
        streamingSince = null
    }
    fun nextDelay(now: Long): Long? {
        interrupted(now)
        if (attempts == 3) return null
        return 1_000L shl attempts++
    }

    companion object {
        fun retryable(error: Throwable): Boolean = Status.fromThrowable(error).code in setOf(
            Status.Code.NOT_FOUND, Status.Code.UNAVAILABLE, Status.Code.DEADLINE_EXCEEDED,
            Status.Code.RESOURCE_EXHAUSTED, Status.Code.ABORTED, Status.Code.UNAUTHENTICATED,
        )

        fun retryableClosure(reason: String): Boolean = reason in setOf(
            "session lease expired", "signaling observer did not reconnect", "WebRTC peer did not reconnect",
            "peer connection failed", "peer connection closed", "daemon shutdown",
            "native capture rendition stopped", "native daemon heartbeat expired",
            "native capture helper unresponsive", "native capture helper stopped",
        )
    }
}

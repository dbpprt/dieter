package com.dbpprt.dieter.screens

import io.grpc.Status

/** Retry for the lifetime of the open screen; cap frequency, never attempts. */
internal class ScreenRecovery {
    private var attempts = 0
    private var streamingSince: Long? = null

    fun streaming(now: Long) { if (streamingSince == null) streamingSince = now }
    fun interrupted(now: Long) {
        if (streamingSince?.let { now - it >= 10_000 } == true) attempts = 0
        streamingSince = null
    }
    fun nextDelay(now: Long): Long {
        interrupted(now)
        val delay = minOf(5_000L, 250L shl attempts)
        attempts = minOf(attempts + 1, 5)
        return delay
    }

    companion object {
        fun retryable(error: Throwable): Boolean = Status.fromThrowable(error).code in setOf(
            Status.Code.NOT_FOUND, Status.Code.UNAVAILABLE, Status.Code.DEADLINE_EXCEEDED,
            Status.Code.RESOURCE_EXHAUSTED, Status.Code.ABORTED, Status.Code.UNAUTHENTICATED,
        )

        fun retryableClosure(reason: String): Boolean = reason in setOf(
            "session lease expired", "signaling observer did not reconnect", "WebRTC peer did not reconnect",
            "peer connection failed", "peer connection closed", "daemon shutdown",
            "remote desktop data channel closed", "remote desktop input channel failed",
            "remote input queue overflow", "remote input delivery failed",
            "native capture rendition stopped", "native daemon heartbeat expired",
            "native capture helper unresponsive", "native capture helper stopped",
        )
    }
}

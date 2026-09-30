package com.dbpprt.dieter.core.runtime

import com.squareup.wire.GrpcException
import com.squareup.wire.GrpcStatus
import kotlin.coroutines.cancellation.CancellationException
import okio.IOException

/** How the core reacts to a failed call. One classification for every domain. */
enum class FailureKind {
    /** The transport or daemon may recover; retry with backoff. */
    TRANSIENT,

    /** Retrying the same request cannot succeed. */
    PERMANENT,

    /** The gateway session is gone; the user must sign in again. */
    UNAUTHENTICATED,

    /** The gateway rejected this client release. */
    UPDATE_REQUIRED,

    /** The daemon's disk is full; retry slowly. */
    OUT_OF_STORAGE,

    /** An optimistic concurrency check failed; reload and retry. */
    CONFLICT,

    /** The caller cancelled; never retried. */
    CANCELLED,
}

/** A core failure with a user-safe message. */
open class CoreException(val kind: FailureKind, message: String, cause: Throwable? = null) : Exception(message, cause)

object Failures {
    private val permanent = setOf(
        GrpcStatus.NOT_FOUND, GrpcStatus.INVALID_ARGUMENT, GrpcStatus.PERMISSION_DENIED,
        GrpcStatus.FAILED_PRECONDITION, GrpcStatus.ALREADY_EXISTS,
    )
    private val transient = setOf(
        GrpcStatus.CANCELLED, GrpcStatus.DEADLINE_EXCEEDED, GrpcStatus.UNAVAILABLE, GrpcStatus.UNKNOWN,
        GrpcStatus.INTERNAL, GrpcStatus.RESOURCE_EXHAUSTED,
    )
    private val storagePhrases = listOf(
        "insufficient free disk space", "no space left on device", "disk quota exceeded", "disc quota exceeded",
    )

    fun kind(error: Throwable): FailureKind = when (error) {
        is CoreException -> error.kind
        is CancellationException -> FailureKind.CANCELLED
        is GrpcException -> when {
            isInsufficientStorage(error.grpcMessage) -> FailureKind.OUT_OF_STORAGE
            error.grpcStatus == GrpcStatus.UNAUTHENTICATED -> FailureKind.UNAUTHENTICATED
            error.grpcStatus == GrpcStatus.ABORTED -> FailureKind.CONFLICT
            error.grpcStatus == GrpcStatus.FAILED_PRECONDITION && isUpdateRequired(error.grpcMessage) -> FailureKind.UPDATE_REQUIRED
            error.grpcStatus in permanent -> FailureKind.PERMANENT
            error.grpcStatus in transient -> FailureKind.TRANSIENT
            else -> FailureKind.PERMANENT
        }
        // Socket, TLS, and stream failures below gRPC.
        is IOException -> FailureKind.TRANSIENT
        else -> error.cause?.let(::kind) ?: FailureKind.TRANSIENT
    }

    /** A failed read may be retried on a replacement transport. Mutations never are. */
    fun isRetryableRead(error: Throwable): Boolean = kind(error) == FailureKind.TRANSIENT

    /** A durable command must be dropped: retrying cannot succeed. */
    fun dropsCommand(error: Throwable): Boolean = kind(error) == FailureKind.PERMANENT

    fun isInsufficientStorage(message: String?): Boolean =
        message != null && storagePhrases.any { message.contains(it, ignoreCase = true) }

    private fun isUpdateRequired(message: String?): Boolean =
        message != null && message.contains("update required", ignoreCase = true)

    /** A single-line, token-free description suitable for UI and logs. */
    fun message(error: Throwable): String = when (error) {
        is CoreException -> error.message.orEmpty()
        is GrpcException -> {
            val detail = scrub(error.grpcMessage.orEmpty())
            if (detail.isEmpty()) "gRPC ${error.grpcStatus.name}" else "gRPC ${error.grpcStatus.name}: $detail"
        }
        else -> scrub(error.message ?: error.toString())
    }

    fun scrub(value: String): String {
        var result = value.replace(Regex("[\\r\\n\\t]+"), " ")
            .replace(Regex("(?i)bearer\\s+[^ ]+"), "Bearer [redacted]")
            .trim()
        if (result.length > 500) result = result.take(500) + "…"
        return result
    }
}

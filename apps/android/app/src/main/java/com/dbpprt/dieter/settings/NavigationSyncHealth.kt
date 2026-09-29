package com.dbpprt.dieter.settings

import io.grpc.Status

/** Routine stream replacement gets a short recovery window. Never display
 * arbitrary transport descriptions, which can contain addresses or metadata. */
internal fun navigationSyncFailure(error: Throwable, failedForMs: Long): String? =
    when (Status.fromThrowable(error).code) {
        Status.Code.CANCELLED, Status.Code.UNAVAILABLE, Status.Code.DEADLINE_EXCEEDED,
        Status.Code.RESOURCE_EXHAUSTED, Status.Code.ABORTED ->
            if (failedForMs < 10_000) null else "Folder and order sync is reconnecting."
        Status.Code.UNAUTHENTICATED -> "Sign in again to sync folders and order."
        Status.Code.PERMISSION_DENIED -> "Access to folder and order sync was denied."
        Status.Code.FAILED_PRECONDITION -> "This machine cannot sync folders and order yet. Check its connection."
        else -> "Folder and order sync failed. Check the machine connection."
    }
